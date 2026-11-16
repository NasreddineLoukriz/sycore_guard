import 'package:flutter/foundation.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';

/// Locations of the model files bundled with the app.
class ModelAssets {
  const ModelAssets._();

  /// Whisper-tiny, 30 s window, int8 — a `.tflite` graph plus its tokenizer.
  static const String sttModel = 'assets/models/stt/whisper_tiny_30s_i8.tflite';
  static const String sttTokenizer = 'assets/models/stt/tokenizer.json';

  /// Qwen3-0.6B, int4 weights / 32-bit activations.
  static const String llm =
      'assets/models/llm/Qwen3-0.6B_dynamic_wi4b32_afp32.litertlm';

  /// Matcha-TTS bundle directory (8 manifest files, laid out like the HF repo).
  static const String ttsDirectory = 'assets/models/tts';
}

/// One coarse progress update for a model installation.
@immutable
class InstallProgress {
  const InstallProgress({required this.step, required this.fraction});

  final String step;

  /// 0.0 → 1.0 for the install currently running.
  final double fraction;
}

/// Installs the on-device models.
///
/// Each model is installed **on demand** rather than at startup: text mode only
/// needs the guard LLM, so the 41 MB Whisper graph and the 90 MB Matcha bundle
/// are only copied the first time the microphone or voice output is used.
/// Installation is idempotent — files already installed from the same source
/// are skipped.
class ModelInstaller {
  const ModelInstaller._();

  /// Qwen3 guard model (~329 MB). Required for text mode.
  static Future<void> installGuardModel({
    ValueChanged<InstallProgress>? onProgress,
  }) async {
    void report(int percent) => onProgress?.call(
      InstallProgress(
        step: 'Installing the guard model…',
        fraction: percent / 100,
      ),
    );

    report(0);
    await FlutterEdgeAi.installModel(
      modelType: ModelType.qwen3,
      fileType: ModelFileType.litertlm,
    ).fromAsset(ModelAssets.llm).withProgress(report).install();
    report(100);
  }

  /// Whisper-tiny + tokenizer (~43 MB). Required for voice input only.
  static Future<void> installSpeechToText({
    ValueChanged<InstallProgress>? onProgress,
  }) async {
    void report(String step, double fraction) => onProgress?.call(
      InstallProgress(step: step, fraction: fraction.clamp(0.0, 1.0)),
    );

    report('Installing Whisper (speech-to-text)…', 0);
    await FlutterEdgeAi.installStt()
        .modelFromAsset(ModelAssets.sttModel)
        .tokenizerFromAsset(ModelAssets.sttTokenizer)
        .ofType(SttModelType.whisper)
        .withModelProgress(
          (percent) => report(
            'Installing Whisper (speech-to-text)…',
            0.9 * percent / 100,
          ),
        )
        .withTokenizerProgress(
          (percent) => report(
            'Installing Whisper tokenizer…',
            0.9 + 0.1 * percent / 100,
          ),
        )
        .install();
    report('Whisper ready', 1);
  }

  /// Matcha voice bundle (~90 MB). Required for voice output only.
  static Future<void> installVoiceOutput({
    ValueChanged<InstallProgress>? onProgress,
  }) async {
    onProgress?.call(
      const InstallProgress(step: 'Installing the voice model…', fraction: 0),
    );
    await FlutterEdgeAi.installTts()
        .fromAsset(ModelAssets.ttsDirectory)
        .ofType(TtsModelType.matcha)
        .withProgress(
          (percent) => onProgress?.call(
            InstallProgress(
              step: 'Installing the voice model…',
              fraction: percent / 100,
            ),
          ),
        )
        .install();
    onProgress?.call(
      const InstallProgress(step: 'Voice model ready', fraction: 1),
    );
  }
}
