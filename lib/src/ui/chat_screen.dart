import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../audio/speech_languages.dart';
import '../audio/voice_output.dart';
import '../audio/wav_codec.dart';
import '../chat/chat_message.dart';
import '../guard/guard_logic.dart';
import '../guard/guard_service.dart';
import '../models/model_installer.dart';
import 'message_bubble.dart';

/// Text-first chat with an on-device privacy guard.
///
/// Typing is the primary interaction. The microphone (voice input) and the
/// speaker (voice output) are both optional and only load their models the
/// first time they are used, which keeps startup and text checks fast.
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

enum _ModelPhase { loading, ready, failed }

class _ChatScreenState extends State<ChatScreen> with WidgetsBindingObserver {
  static const int _maxRecordingSeconds = 30;

  static const String _languagePreferenceKey = 'stt_language';

  /// Whisper language code, chosen in the UI and persisted across launches.
  /// The checkpoint is multilingual; switching it never reloads the model.
  String _sttLanguage = defaultSpeechLanguage;

  static const String _safeSpeech = 'Content is safe. You can proceed.';
  static const String _blockedSpeech =
      'Warning. Sensitive data detected and masked. Action blocked.';

  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _inputFocus = FocusNode();
  final _recorder = AudioRecorder();
  final _guard = const GuardService();

  final List<ChatMessage> _messages = [];

  InferenceModel? _model;
  InferenceChat? _chat;

  SpeechRecognizer? _stt;
  VoiceOutput? _voice;
  Future<VoiceOutput>? _voiceLoading;

  _ModelPhase _phase = _ModelPhase.loading;
  bool _busy = false;
  bool _recording = false;
  bool _transcribing = false;
  bool _preparingMicrophone = false;
  bool _ttsEnabled = false;
  bool _ttsBusy = false;
  double _progress = 0;
  String _banner = '';
  bool _welcomed = false;
  String? _recordingPath;
  Timer? _ticker;
  int _recordSeconds = 0;

  bool get _modelReady => _phase == _ModelPhase.ready;
  bool get _canSend =>
      _modelReady &&
      !_busy &&
      !_recording &&
      !_transcribing &&
      !_preparingMicrophone;
  bool get _canRecord =>
      _modelReady && !_busy && !_transcribing && !_preparingMicrophone;
  bool get _canToggleTts => _modelReady && !kIsWeb && !_ttsBusy;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_restoreLanguage());
    unawaited(_bootstrap());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker?.cancel();
    _input.dispose();
    _scroll.dispose();
    _inputFocus.dispose();
    unawaited(_recorder.dispose());
    unawaited(_stt?.close());
    unawaited(_voice?.dispose());
    unawaited(_chat?.close());
    unawaited(_model?.close());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed && _recording) {
      unawaited(_cancelRecording());
    }
  }

  // ---------------------------------------------------------------- startup

  Future<void> _bootstrap() async {
    setState(() {
      _phase = _ModelPhase.loading;
      _progress = 0;
      _banner = 'Installing the guard model…';
    });

    try {
      await ModelInstaller.installGuardModel(
        onProgress: (update) {
          if (!mounted) return;
          setState(() {
            _progress = update.fraction;
            _banner = update.step;
          });
        },
      );

      if (!mounted) return;
      setState(() => _banner = 'Loading the guard model…');

      // .litertlm needs at least a 1024-token context window; a larger one is
      // not needed for a short prompt plus a one-word answer, and a smaller KV
      // cache means a faster first token. The NPU preference falls back to GPU
      // and then CPU when a device lacks the libraries.
      final model = await FlutterEdgeAi.getActiveModel(
        maxTokens: 1024,
        preferredBackend: PreferredBackend.npu,
      );
      // `ModelType.general` keeps the chat layer from appending " /no_think" to
      // every user turn: the suffix lands right after the transcript and makes
      // the model answer with a fragment instead of its usual sentence. The
      // native prompt template still comes from the model file.
      final chat = await model.createChat(
        modelType: ModelType.general,
        temperature: 0,
        maxOutputTokens: GuardService.maxOutputTokens,
      );

      _model = model;
      _chat = chat;

      if (!mounted) return;
      setState(() => _banner = 'Warming up the guard model…');
      await _warmUp(chat);

      if (!mounted) return;
      setState(() {
        _phase = _ModelPhase.ready;
        _progress = 1;
        _banner = '';
      });

      if (!_welcomed) {
        _welcomed = true;
        _addMessage(
          const ChatMessage(
            sender: ChatSender.assistant,
            text:
                'Type a message and I will check it for sensitive data before '
                'it goes anywhere. Everything runs on this device — the '
                'microphone is optional.',
          ),
        );
      }
    } catch (error, stackTrace) {
      debugPrint('Guard model bootstrap failed: $error\n$stackTrace');
      if (!mounted) return;
      setState(() {
        _phase = _ModelPhase.failed;
        _banner = 'The on-device guard model could not be prepared.';
      });
    }
  }

  /// Runs one throwaway generation so the first real message does not pay the
  /// graph/cache initialisation cost.
  Future<void> _warmUp(InferenceChat chat) async {
    try {
      await chat.clearHistory();
      await chat.addQueryChunk(
        Message.text(text: 'Warm-up check: hello.', isUser: true),
      );
      await chat.generateChatResponse();
    } catch (error) {
      debugPrint('Warm-up skipped: $error');
    }
  }

  // -------------------------------------------------------------- language

  Future<void> _restoreLanguage() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final saved = preferences.getString(_languagePreferenceKey);
      if (!mounted || saved == null || speechLanguageFor(saved) == null) return;
      setState(() => _sttLanguage = saved);
    } catch (error) {
      debugPrint('Could not read the language preference: $error');
    }
  }

  Future<void> _setLanguage(String code) async {
    if (!mounted || code == _sttLanguage) return;

    setState(() => _sttLanguage = code);
    final label = speechLanguageFor(code)?.label ?? code;
    _addSystem('Voice input language set to $label.');

    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(_languagePreferenceKey, code);
    } catch (error) {
      debugPrint('Could not persist the language preference: $error');
    }
  }

  Future<void> _showLanguagePicker() async {
    final selected = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        final theme = Theme.of(context);
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Voice input language',
                      style: theme.textTheme.titleMedium,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Whisper transcribes your speech into this language. '
                      'Spoken verdicts stay in English.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 420),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: speechLanguages.length,
                  itemBuilder: (context, index) {
                    final language = speechLanguages[index];
                    final selected = language.code == _sttLanguage;
                    return ListTile(
                      title: Text(language.label),
                      subtitle: Text(language.code.toUpperCase()),
                      trailing: selected
                          ? Icon(Icons.check, color: theme.colorScheme.primary)
                          : null,
                      onTap: () => Navigator.of(context).pop(language.code),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );

    if (selected != null) await _setLanguage(selected);
  }

  // ------------------------------------------------------------- messaging

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || !_canSend) return;

    _input.clear();
    unawaited(_voice?.stop());
    _addMessage(ChatMessage(sender: ChatSender.user, text: text));
    setState(() => _busy = true);

    try {
      var chat = _chat;
      chat ??= await _recreateChat();
      if (chat == null) {
        if (mounted) {
          _addSystem(
            'The guard session could not be started. Please restart the app.',
          );
        }
        return;
      }

      var decision = await _guard.evaluate(transcript: text, chat: chat);

      // A model failure is a transport problem, not a verdict on the message.
      // Rebuild the session once and retry before failing closed, so one bad
      // session can never block every later message.
      if (decision.isModelError) {
        debugPrint(
          'Guard session failed; recreating it once. ${decision.reason}',
        );
        final retryChat = await _recreateChat();
        if (retryChat != null) {
          decision = await _guard.evaluate(transcript: text, chat: retryChat);
        }
      }

      if (!mounted) return;

      _addMessage(
        ChatMessage(
          sender: ChatSender.assistant,
          text: _replyFor(decision),
          decision: decision,
        ),
      );

      if (_ttsEnabled) unawaited(_speak(decision));
    } catch (error, stackTrace) {
      debugPrint('Guard evaluation failed: $error\n$stackTrace');
      _addSystem('The check could not be completed: ${_friendlyError(error)}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Wording for the verdict, so a blocked message says *why* it was blocked:
  /// content the rules caught, the model's decision, or a guard outage.
  String _replyFor(GuardDecision decision) {
    if (decision.isModelError) {
      return 'This message was blocked because the guard could not verify it. '
          'Nothing left your device.';
    }
    if (!decision.isBlocked) {
      return 'No sensitive data detected. This message looks safe to share.';
    }
    if (decision.decidedBy == 'rules') {
      if (decision.redactedText == null) {
        return 'This message mentions sensitive data, so it was blocked before '
            'it could leave this device. No value was given that could be '
            'masked.';
      }
      return 'This message contains sensitive data, so it was blocked before '
          'it could leave this device. Here it is again with the sensitive '
          'parts masked:';
    }
    if (decision.decidedBy == 'model-uncertain') {
      return 'The on-device model could not confirm this message is safe, so it '
          'was blocked. Nothing left your device.';
    }
    return 'The on-device model flagged this message as sensitive, so it was '
        'blocked. It could not point to the exact part to mask.';
  }

  /// Replaces the guard session after a failure. The model weights stay
  /// loaded; only the conversation (and its KV cache) is rebuilt.
  Future<InferenceChat?> _recreateChat() async {
    final model = _model;
    if (model == null) return null;

    try {
      final previous = _chat;
      _chat = null;
      try {
        await previous?.close();
      } catch (error) {
        debugPrint('Closing the failed guard session failed: $error');
      }

      final chat = await model.createChat(
        // See `_bootstrap`: `general` avoids the appended " /no_think".
        modelType: ModelType.general,
        temperature: 0,
        maxOutputTokens: GuardService.maxOutputTokens,
      );
      _chat = chat;
      return chat;
    } catch (error, stackTrace) {
      debugPrint('Could not recreate the guard session: $error\n$stackTrace');
      // Keep a usable-looking chat so the next send can try again instead of
      // hitting a null assertion.
      _chat = null;
      return null;
    }
  }

  // ------------------------------------------------------------ voice input

  Future<void> _toggleRecording() async {
    if (_recording) {
      await _stopRecording();
      return;
    }
    if (_canRecord) await _startRecording();
  }

  Future<void> _startRecording() async {
    // Never record while the speaker is still playing a verdict.
    await _voice?.stop();

    if (_stt == null) {
      setState(() {
        _preparingMicrophone = true;
        _banner = 'Preparing the microphone (first use only)…';
      });
      try {
        await ModelInstaller.installSpeechToText(
          onProgress: (update) {
            if (!mounted) return;
            setState(() => _banner = update.step);
          },
        );
        _stt = await FlutterEdgeAi.getActiveStt(language: _sttLanguage);
      } catch (error, stackTrace) {
        debugPrint('Speech-to-text setup failed: $error\n$stackTrace');
        if (!mounted) return;
        setState(() {
          _preparingMicrophone = false;
          _banner = '';
        });
        _addSystem('Voice input is unavailable: ${_friendlyError(error)}');
        return;
      }
      if (!mounted) return;
      setState(() {
        _preparingMicrophone = false;
        _banner = '';
      });
    }

    final permission = await Permission.microphone.request();
    if (!mounted) return;
    if (!permission.isGranted) {
      _addSystem(
        permission.isPermanentlyDenied
            ? 'Microphone access is blocked. Enable it in Settings to use '
                  'voice input, or just type your message.'
            : 'Microphone access was denied. You can still type your message.',
      );
      return;
    }

    try {
      final directory = await getTemporaryDirectory();
      final path =
          '${directory.path}/guard_input_${DateTime.now().millisecondsSinceEpoch}.wav';
      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: 16000,
          numChannels: 1,
        ),
        path: path,
      );

      _recordingPath = path;
      _recordSeconds = 0;
      if (!mounted) return;
      setState(() => _recording = true);

      _ticker = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (!mounted) {
          timer.cancel();
          return;
        }
        setState(() => _recordSeconds++);
        if (_recordSeconds >= _maxRecordingSeconds) {
          timer.cancel();
          _ticker = null;
          unawaited(_stopRecording());
        }
      });
    } catch (error, stackTrace) {
      debugPrint('Recording failed to start: $error\n$stackTrace');
      await _cancelRecording();
      _addSystem('Recording could not start: ${_friendlyError(error)}');
    }
  }

  Future<void> _stopRecording() async {
    if (!_recording) return;

    _ticker?.cancel();
    _ticker = null;
    setState(() {
      _recording = false;
      _transcribing = true;
      _banner = 'Transcribing on-device…';
    });

    String? path;
    try {
      path = await _recorder.stop();
    } catch (error) {
      debugPrint('Recording failed to stop: $error');
    }
    path ??= _recordingPath;
    _recordingPath = null;

    if (path == null) {
      if (!mounted) return;
      setState(() {
        _transcribing = false;
        _banner = '';
      });
      _addSystem('The recording could not be saved. Please try again.');
      return;
    }

    try {
      final pcm = await WavCodec.readPcmFromFile(path);
      final transcript = (await _stt!.transcribe(
        pcm,
        language: _sttLanguage,
      )).trim();

      if (!mounted) return;
      if (transcript.isEmpty) {
        _addSystem('No speech detected. Try again or type instead.');
      } else {
        _input.text = transcript;
        _input.selection = TextSelection.collapsed(offset: transcript.length);
        _inputFocus.requestFocus();
      }
    } catch (error, stackTrace) {
      debugPrint('Transcription failed: $error\n$stackTrace');
      if (mounted) {
        _addSystem('Transcription failed: ${_friendlyError(error)}');
      }
    } finally {
      await _deleteQuietly(path);
      if (mounted) {
        setState(() {
          _transcribing = false;
          _banner = '';
        });
      }
    }
  }

  Future<void> _cancelRecording() async {
    _ticker?.cancel();
    _ticker = null;

    try {
      await _recorder.stop();
    } catch (_) {
      // Recorder may not have started.
    }

    final path = _recordingPath;
    _recordingPath = null;
    if (path != null) await _deleteQuietly(path);

    if (!mounted) return;
    setState(() {
      _recording = false;
      _recordSeconds = 0;
    });
  }

  // ----------------------------------------------------------- voice output

  Future<void> _toggleTts() async {
    if (!_canToggleTts) return;

    if (_ttsEnabled) {
      setState(() => _ttsEnabled = false);
      await _voice?.stop();
      return;
    }

    setState(() {
      _ttsBusy = true;
      _banner = 'Preparing voice output (first use only)…';
    });

    try {
      final voice = await _ensureVoice();
      await voice.prepare(const [_safeSpeech, _blockedSpeech]);
      if (!mounted) return;
      setState(() {
        _ttsEnabled = true;
        _ttsBusy = false;
        _banner = '';
      });
      _addSystem('Voice output is on. Verdicts will be spoken.');
    } catch (error, stackTrace) {
      debugPrint('Voice output setup failed: $error\n$stackTrace');
      if (!mounted) return;
      setState(() {
        _ttsEnabled = false;
        _ttsBusy = false;
        _banner = '';
      });
      _addSystem('Voice output is unavailable: ${_friendlyError(error)}');
    }
  }

  Future<VoiceOutput> _ensureVoice() {
    final existing = _voice;
    if (existing != null) return Future.value(existing);

    return _voiceLoading ??= _createVoice().catchError((Object error) {
      _voiceLoading = null;
      throw error;
    });
  }

  Future<VoiceOutput> _createVoice() async {
    if (kIsWeb) {
      throw UnsupportedError(
        'On-device text-to-speech is not available on web.',
      );
    }
    await ModelInstaller.installVoiceOutput(
      onProgress: (update) {
        if (mounted) setState(() => _banner = update.step);
      },
    );
    final synthesizer = await FlutterEdgeAi.getActiveTts();
    final voice = VoiceOutput(synthesizer);
    _voice = voice;
    return voice;
  }

  Future<void> _speak(GuardDecision decision) async {
    try {
      final voice = await _ensureVoice();
      await voice.speak(decision.isBlocked ? _blockedSpeech : _safeSpeech);
    } catch (error, stackTrace) {
      debugPrint('Voice output failed: $error\n$stackTrace');
      if (!mounted) return;
      setState(() => _ttsEnabled = false);
      _addSystem('Voice output stopped working: ${_friendlyError(error)}');
    }
  }

  // ---------------------------------------------------------------- helpers

  void _addMessage(ChatMessage message) {
    if (!mounted) return;
    setState(() => _messages.add(message));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  void _addSystem(String text) =>
      _addMessage(ChatMessage(sender: ChatSender.system, text: text));

  Future<void> _deleteQuietly(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (error) {
      debugPrint('Could not delete temporary file $path: $error');
    }
  }

  String _friendlyError(Object error) {
    final message = error.toString();
    return message.length <= 180 ? message : '${message.substring(0, 180)}…';
  }

  // ------------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('SYcore Guard'),
        actions: [
          Tooltip(
            message: 'Voice input language',
            child: TextButton.icon(
              onPressed: _showLanguagePicker,
              icon: const Icon(Icons.translate, size: 18),
              label: Text(_sttLanguage.toUpperCase()),
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
            ),
          ),
          if (!kIsWeb)
            IconButton(
              onPressed: _canToggleTts ? _toggleTts : null,
              tooltip: _ttsEnabled
                  ? 'Turn off spoken verdicts'
                  : 'Turn on spoken verdicts',
              icon: _ttsBusy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(_ttsEnabled ? Icons.volume_up : Icons.volume_off),
            ),
          const Padding(
            padding: EdgeInsets.only(right: 12),
            child: Chip(
              avatar: Icon(Icons.lock_outline, size: 16),
              label: Text('Offline'),
              visualDensity: VisualDensity.compact,
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_phase != _ModelPhase.ready || _banner.isNotEmpty || _recording)
            _StatusStrip(
              phase: _phase,
              message: _banner,
              progress: _progress,
              onRetry: _phase == _ModelPhase.failed ? _bootstrap : null,
              recording: _recording,
              recordSeconds: _recordSeconds,
            ),
          Expanded(
            child: _messages.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text(
                        'Checking for sensitive data, entirely on this device.',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.outline,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  )
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                    itemCount: _messages.length,
                    itemBuilder: (context, index) => Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: MessageBubble(message: _messages[index]),
                    ),
                  ),
          ),
          _Composer(
            controller: _input,
            focusNode: _inputFocus,
            canSend: _canSend,
            busy: _busy,
            recording: _recording,
            recordSeconds: _recordSeconds,
            canUseMic: _canRecord || _recording,
            transcribing: _transcribing,
            preparing: _preparingMicrophone,
            hint: _transcribing
                ? 'Transcribing…'
                : (_preparingMicrophone
                      ? 'Preparing the microphone…'
                      : 'Type a message…'),
            onSend: _send,
            onMic: _toggleRecording,
          ),
        ],
      ),
    );
  }
}

class _StatusStrip extends StatelessWidget {
  const _StatusStrip({
    required this.phase,
    required this.message,
    required this.progress,
    required this.onRetry,
    required this.recording,
    required this.recordSeconds,
  });

  final _ModelPhase phase;
  final String message;
  final double progress;
  final Future<void> Function()? onRetry;
  final bool recording;
  final int recordSeconds;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final failed = phase == _ModelPhase.failed;

    return Material(
      color: failed
          ? Colors.red.shade50
          : theme.colorScheme.surfaceContainerHighest,
      child: Column(
        children: [
          if (phase == _ModelPhase.loading)
            LinearProgressIndicator(
              value: progress > 0 && progress < 1 ? progress : null,
              minHeight: 3,
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                if (recording) ...[
                  const Icon(
                    Icons.fiber_manual_record,
                    color: Colors.red,
                    size: 16,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Listening… ${recordSeconds}s',
                    style: TextStyle(
                      color: Colors.red.shade900,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ] else if (message.isNotEmpty) ...[
                  if (phase == _ModelPhase.loading)
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      message,
                      style: TextStyle(
                        fontSize: 13,
                        color: failed ? Colors.red.shade900 : null,
                      ),
                    ),
                  ),
                ],
                if (onRetry != null)
                  TextButton(onPressed: onRetry, child: const Text('Retry')),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.focusNode,
    required this.canSend,
    required this.busy,
    required this.recording,
    required this.recordSeconds,
    required this.canUseMic,
    required this.transcribing,
    required this.preparing,
    required this.hint,
    required this.onSend,
    required this.onMic,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool canSend;
  final bool busy;
  final bool recording;
  final int recordSeconds;
  final bool canUseMic;
  final bool transcribing;
  final bool preparing;
  final String hint;
  final Future<void> Function() onSend;
  final Future<void> Function() onMic;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Material(
      color: theme.colorScheme.surface,
      elevation: 8,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              IconButton.filledTonal(
                onPressed: canUseMic ? onMic : null,
                tooltip: recording
                    ? 'Stop recording'
                    : 'Voice input (optional)',
                icon: Icon(recording ? Icons.stop : Icons.mic),
                color: recording ? Colors.red : null,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: controller,
                  focusNode: focusNode,
                  minLines: 1,
                  maxLines: 4,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => onSend(),
                  decoration: InputDecoration(
                    hintText: hint,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: controller,
                builder: (context, value, _) {
                  final enabled = canSend && value.text.trim().isNotEmpty;
                  return IconButton.filled(
                    onPressed: enabled ? onSend : null,
                    tooltip: 'Check message',
                    icon: busy || transcribing || preparing
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.send),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}
