import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sycore_guard/src/guard/guard_service.dart';

/// A stand-in session that streams a scripted reply, so the whole
/// rules → model → verdict path can be tested without loading a real model.
class _FakeSession implements InferenceModelSession {
  _FakeSession(
    this.reply, {
    this.failOnAdd = false,
    this.failOnResponse = false,
  });

  final List<String> reply;
  final bool failOnAdd;
  final bool failOnResponse;

  final List<Message> queries = [];
  bool stopped = false;
  bool closed = false;

  @override
  Future<void> addQueryChunk(Message message) async {
    if (failOnAdd) throw StateError('the session is closed');
    queries.add(message);
  }

  @override
  Future<String> getResponse() async {
    if (failOnResponse) throw StateError('generation failed');
    return reply.join();
  }

  @override
  Stream<String> getResponseAsync() async* {
    if (failOnResponse) throw StateError('generation failed');
    for (final chunk in reply) {
      if (stopped) return;
      yield chunk;
    }
  }

  @override
  Future<int> sizeInTokens(String text) async => 0;

  @override
  Future<void> stopGeneration() async => stopped = true;

  @override
  SessionMetrics getSessionMetrics() => SessionMetrics();

  @override
  Future<void> close() async => closed = true;
}

/// Builds a chat whose sessions replay [reply] (a new one per
/// `clearHistory`, matching the real behaviour).
Future<InferenceChat> _chatFor(
  List<String> reply, {
  bool failOnAdd = false,
  bool failOnResponse = false,
  List<_FakeSession>? sessions,
}) async {
  final chat = InferenceChat(
    sessionCreator: () async {
      final session = _FakeSession(
        reply,
        failOnAdd: failOnAdd,
        failOnResponse: failOnResponse,
      );
      sessions?.add(session);
      return session;
    },
    maxTokens: 1024,
    tokenBuffer: 0,
  );
  // `createChat` initialises the first session; tests do the same.
  await chat.initSession();
  return chat;
}

void main() {
  const service = GuardService();

  test('a rules match blocks without ever calling the model', () async {
    final sessions = <_FakeSession>[];
    final chat = await _chatFor(
      ['SAFE'],
      failOnResponse: true,
      sessions: sessions,
    );

    final decision = await service.evaluate(
      transcript: 'Send it to jane.doe@example.com',
      chat: chat,
    );

    expect(decision.isBlocked, isTrue);
    expect(decision.decidedBy, 'rules');
    expect(
      decision.redactedText,
      'Send it to ${'X' * 20}',
      reason: 'the email is masked in the returned copy',
    );
    expect(
      sessions.every((session) => session.queries.isEmpty),
      isTrue,
      reason: 'the model must not be asked',
    );
  });

  test('a chatty SAFE reply is accepted', () async {
    final chat = await _chatFor(['The ', 'transcript ', 'is ', 'SAFE', '.']);

    final decision = await service.evaluate(
      transcript: 'What is the weather like today?',
      chat: chat,
    );

    expect(decision.isBlocked, isFalse);
    expect(decision.decidedBy, 'model');
    // Decoding stops at the verdict, so the closing "." is never generated.
    expect(decision.rawReply, contains('SAFE'));
  });

  test('decoding stops as soon as the verdict arrives', () async {
    final sessions = <_FakeSession>[];
    final chat = await _chatFor([
      'SAFE',
      ' and here is a long explanation nobody needs',
    ], sessions: sessions);

    final decision = await service.evaluate(
      transcript: 'Summarise the meeting notes.',
      chat: chat,
    );

    expect(decision.isBlocked, isFalse);
    expect(sessions.any((session) => session.stopped), isTrue);
  });

  test('BLOCKED blocks', () async {
    final chat = await _chatFor(['BLOCKED']);

    final decision = await service.evaluate(
      transcript: 'the quick brown fox',
      chat: chat,
    );

    expect(decision.isBlocked, isTrue);
    expect(decision.decidedBy, 'model');
  });

  test('an empty reply fails closed and is retryable', () async {
    final chat = await _chatFor(const []);

    final decision = await service.evaluate(
      transcript: 'the quick brown fox',
      chat: chat,
    );

    expect(decision.isBlocked, isTrue);
    expect(
      decision.isModelError,
      isTrue,
      reason: 'an empty reply is not a verdict',
    );
  });

  test(
    'a broken session is reported as a model error, not a verdict',
    () async {
      final chat = await _chatFor(['SAFE'], failOnAdd: true);

      final decision = await service.evaluate(
        transcript: 'the quick brown fox',
        chat: chat,
      );

      expect(decision.isBlocked, isTrue);
      expect(decision.isModelError, isTrue);
      expect(decision.reason, contains('could not run'));
    },
  );

  test('a generation failure is reported as a model error', () async {
    final chat = await _chatFor(['SAFE'], failOnResponse: true);

    final decision = await service.evaluate(
      transcript: 'the quick brown fox',
      chat: chat,
    );

    expect(decision.isBlocked, isTrue);
    expect(decision.isModelError, isTrue);
  });

  test('a chatty sentence is accepted', () async {
    final chat = await _chatFor([
      'The text "hello" does not contain personal data (phone, email, ID, '
          'card, password).',
    ]);

    final decision = await service.evaluate(
      transcript: 'hello',
      chat: chat,
    );

    expect(decision.isBlocked, isFalse);
    expect(decision.decidedBy, 'model');
  });

  test('a chatty detection blocks', () async {
    final chat = await _chatFor([
      'It contains personal data (card number).',
    ]);

    final decision = await service.evaluate(
      transcript: 'the quick brown fox',
      chat: chat,
    );

    expect(decision.isBlocked, isTrue);
    expect(decision.decidedBy, 'model');
  });

  test('a rambling reply with no verdict fails closed as uncertain', () async {
    final chat = await _chatFor([
      'The text',
    ]);

    final decision = await service.evaluate(
      transcript: 'the quick brown fox',
      chat: chat,
    );

    expect(decision.isBlocked, isTrue);
    expect(decision.decidedBy, 'model-uncertain');
    expect(decision.isModelError, isFalse);
  });

  test('the prompt asks one question and ends with the transcript', () {
    final prompt = GuardService.buildPrompt('hello there');
    expect(prompt, startsWith(GuardService.question));
    expect(prompt, endsWith('Text: hello there'));
  });
}
