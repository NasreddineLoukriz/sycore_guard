import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';

import 'guard_logic.dart';

/// Runs the two-stage guard: deterministic rules first, the on-device LLM as a
/// second opinion for anything the rules did not catch.
class GuardService {
  const GuardService();

  /// Upper bound on the transcript handed to the model. Keeps the prompt
  /// small and bounds the damage of a hostile/rambling transcript.
  static const int maxTranscriptChars = 1200;

  /// Room for a model that answers with a sentence. Decoding stops as soon as
  /// a decisive answer arrives, so this cap only bounds a rambling model.
  static const int maxOutputTokens = 24;

  /// A check that cannot answer in time is blocked (fail closed) instead of
  /// leaving the chat spinning forever.
  static const Duration modelTimeout = Duration(seconds: 20);

  /// The question asked about every message the rules did not block.
  ///
  /// This wording was measured against the shipped 0.6B model: it answers with
  /// a sentence ("The text does not contain personal data …"), which the
  /// parser reads. Two things are deliberately absent:
  ///
  /// * a system prompt — with one, the model answered `BLOCKED` for every
  ///   input, including "hello";
  /// * the answer labels `SAFE` / `BLOCKED` — the model echoes them, and an
  ///   echoed `BLOCKED` blocked benign text.
  static const String question =
      'Does the text contain personal data (phone, email, ID, card, password)?';

  /// Collapses runs of whitespace (including newlines) so a transcript cannot
  /// inject extra prompt lines such as its own `Answer:`.
  static final RegExp _whitespace = RegExp(r'\s+');

  /// Rule-only evaluation (fast path, no model call).
  GuardDecision evaluateRules(String transcript) =>
      const GuardRules().evaluate(transcript);

  /// Full evaluation for [transcript], using [chat] for the model stage.
  ///
  /// The chat history is cleared before every classification so one message
  /// can never bias the next one (and so each turn prefills a short prompt).
  /// The caller owns [chat] and is responsible for closing it.
  Future<GuardDecision> evaluate({
    required String transcript,
    required InferenceChat chat,
  }) async {
    final ruleDecision = evaluateRules(transcript);
    if (ruleDecision.isBlocked) return ruleDecision;

    final prompt = buildPrompt(transcript);

    try {
      await chat.clearHistory();
      await chat.addQueryChunk(Message.text(text: prompt, isUser: true));

      final rawReply = await _generate(chat);
      final trimmedReply = rawReply.trim();
      if (kDebugMode) {
        // The reply may quote the transcript, so only its length is logged.
        debugPrint(
          'Guard model reply: ${trimmedReply.length} chars, '
          'verdict: ${GuardVerdictParser.verdictIn(trimmedReply)}',
        );
      }

      // An empty reply is a decoding failure, not a verdict: let the caller
      // rebuild the session and retry before failing closed.
      if (trimmedReply.isEmpty) {
        return const GuardDecision(
          verdict: GuardVerdict.blocked,
          reason:
              'The on-device model returned no answer, so the message was '
              'blocked to stay safe.',
          decidedBy: 'model-error',
        );
      }

      final verdict = GuardVerdictParser.verdictIn(trimmedReply);

      if (verdict == GuardVerdict.safe) {
        return GuardDecision(
          verdict: GuardVerdict.safe,
          reason: 'The on-device model found no sensitive data.',
          decidedBy: 'model',
          rawReply: trimmedReply,
        );
      }
      if (verdict == GuardVerdict.blocked) {
        return GuardDecision(
          verdict: GuardVerdict.blocked,
          reason: 'The on-device model flagged this content as sensitive.',
          decidedBy: 'model',
          rawReply: trimmedReply,
        );
      }
      // The model talked but never decided (echoed the text, ran out of tokens,
      // refused): fail closed without pretending it flagged anything.
      return GuardDecision(
        verdict: GuardVerdict.blocked,
        reason:
            'The on-device model did not reach a clear answer, so the message '
            'was blocked to stay safe.',
        decidedBy: 'model-uncertain',
        rawReply: trimmedReply,
      );
    } on TimeoutException {
      return const GuardDecision(
        verdict: GuardVerdict.blocked,
        reason:
            'The on-device model did not answer in time, so the message was '
            'blocked to stay safe.',
        decidedBy: 'model-error',
      );
    } catch (error) {
      // Fail closed: if the classifier cannot run, the request is blocked.
      // `model-error` lets the caller retry on a fresh session instead of
      // treating a broken session as a verdict on the message.
      debugPrint('Guard model stage failed: $error');
      return GuardDecision(
        verdict: GuardVerdict.blocked,
        reason:
            'The on-device model could not run (${_short(error)}), so the '
            'message was blocked to stay safe.',
        decidedBy: 'model-error',
      );
    }
  }

  /// Streams the model's answer and stops decoding as soon as it is decisive.
  ///
  /// A stated block is final, and so is a short `SAFE`, which is why those stop
  /// at once. The measured reply style is a sentence ("does not contain
  /// personal data"), which is longer than the early-stop window and is read to
  /// the [maxOutputTokens] cap — still well under a second on CPU.
  Future<String> _generate(InferenceChat chat) async {
    final buffer = StringBuffer();
    final finished = Completer<void>();

    void finish([Object? error, StackTrace? stackTrace]) {
      if (finished.isCompleted) return;
      if (error != null) {
        finished.completeError(error, stackTrace);
      } else {
        finished.complete();
      }
    }

    final timer = Timer(modelTimeout, () {
      unawaited(_stopQuietly(chat));
      finish(TimeoutException('The guard model timed out.'));
    });

    late final StreamSubscription<ModelResponse> subscription;
    subscription = chat.generateChatResponseAsync().listen(
      (response) {
        if (finished.isCompleted || response is! TextResponse) return;
        buffer.write(response.token);

        final verdict = GuardVerdictParser.verdictIn(buffer.toString());
        // Stop early only when stopping cannot hide a later BLOCKED: a
        // "BLOCKED" answer stops at once, and a "SAFE" one only when it came
        // straight away (the usual case). A rambling reply is read in full so
        // any later "BLOCKED" still wins.
        final decided =
            verdict == GuardVerdict.blocked ||
            (verdict == GuardVerdict.safe && buffer.length <= 24);
        if (decided) {
          // The verdict is in hand: stop paying for the rest of the sentence.
          unawaited(_stopQuietly(chat));
          unawaited(subscription.cancel());
          finish();
        }
      },
      onError: (Object error, StackTrace stackTrace) =>
          finish(error, stackTrace),
      onDone: finish,
      cancelOnError: true,
    );

    try {
      await finished.future;
    } finally {
      timer.cancel();
      unawaited(subscription.cancel());
    }

    return buffer.toString();
  }

  /// Builds the prompt for [transcript].
  ///
  /// The transcript is flattened onto the `Text:` line and capped, which keeps
  /// prefill short (it dominates the on-device latency) and stops a transcript
  /// from adding prompt lines of its own.
  static String buildPrompt(String transcript) {
    final flat = transcript.replaceAll(_whitespace, ' ').trim();
    final truncated = flat.length > maxTranscriptChars
        ? flat.substring(0, maxTranscriptChars)
        : flat;
    return '$question\nText: $truncated';
  }

  static String _short(Object error) {
    final text = error.toString().replaceAll('\n', ' ');
    return text.length <= 140 ? text : '${text.substring(0, 140)}…';
  }

  /// Stops decoding without letting a teardown error escape: the stream may
  /// already be finished or the session already closed.
  static Future<void> _stopQuietly(InferenceChat chat) async {
    try {
      await chat.stopGeneration();
    } catch (error) {
      debugPrint('Stopping guard generation failed: $error');
    }
  }
}
