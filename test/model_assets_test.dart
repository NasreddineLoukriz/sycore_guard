import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sycore_guard/src/models/model_installer.dart';

void main() {
  // The weights (~460 MB) are fetched by the developer, not committed; the repo
  // ships the code that uses them. See docs/models.md for the download steps.
  final modelsPresent = File(ModelAssets.llm).existsSync();

  group('bundled model assets', () {
    test('the files the installer references exist', () {
      final expected = <String>[
        ModelAssets.sttModel,
        ModelAssets.sttTokenizer,
        ModelAssets.llm,
        // The full Matcha bundle: the installer fails if any is missing.
        '${ModelAssets.ttsDirectory}/matcha_textenc_fp16.tflite',
        '${ModelAssets.ttsDirectory}/matcha_decoder_fp16.tflite',
        '${ModelAssets.ttsDirectory}/matcha_vocoder_fp16.tflite',
        '${ModelAssets.ttsDirectory}/dp_g2p_matcha_fp16.tflite',
        '${ModelAssets.ttsDirectory}/g2p_dict.txt.gz',
        '${ModelAssets.ttsDirectory}/emb.bin',
        '${ModelAssets.ttsDirectory}/config.json',
        '${ModelAssets.ttsDirectory}/g2p_meta.json',
      ];

      for (final path in expected) {
        expect(
          File(path).existsSync(),
          isTrue,
          reason: '$path is referenced by ModelInstaller but missing on disk.',
        );
      }
    }, skip: modelsPresent ? false : 'Model weights are not present — see docs/models.md.');

    test('pubspec.yaml declares the asset directories', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();

      for (final directory in const [
        'assets/models/stt/',
        'assets/models/llm/',
        'assets/models/tts/',
      ]) {
        expect(
          pubspec.contains('- $directory'),
          isTrue,
          reason: '$directory is not declared under flutter.assets.',
        );
      }

      // A file-level asset declaration that does not exist breaks the build
      // ("No file or variants found for asset").
      expect(pubspec.contains('model.onnx'), isFalse);
    });
  });
}
