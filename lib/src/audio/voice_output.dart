import 'dart:io';

import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';

import 'wav_codec.dart';

/// Optional spoken output.
///
/// Matcha synthesis takes seconds on a phone, so every phrase is synthesised at
/// most once and kept as a WAV file in the cache directory. Verdicts only use
/// two fixed phrases, so after the first preparation speaking is instant.
class VoiceOutput {
  VoiceOutput(this._synthesizer, {AudioPlayer? player})
    : _player = player ?? AudioPlayer();

  final SpeechSynthesizer _synthesizer;
  final AudioPlayer _player;

  final Map<String, String> _cachedFiles = {};
  final Map<String, Future<String>> _pending = {};

  var _requestId = 0;
  var _disposed = false;

  /// Synthesises (and caches) every phrase up front, e.g. when the user turns
  /// voice output on.
  Future<void> prepare(Iterable<String> phrases) async {
    for (final phrase in phrases) {
      if (_disposed) return;
      await _fileFor(phrase);
    }
  }

  /// Speaks [phrase], cancelling anything already playing.
  Future<void> speak(String phrase) async {
    if (_disposed) return;

    await stop();
    final requestId = _requestId;

    final path = await _fileFor(phrase);
    if (_disposed || requestId != _requestId) return;

    try {
      await _player.setFilePath(path);
      if (requestId != _requestId) return;
      await _player.play();
    } catch (_) {
      // A new request stopped playback mid-flight; nothing to report.
    }
  }

  /// Stops playback and cancels an in-flight [speak].
  Future<void> stop() async {
    _requestId++;
    try {
      await _player.stop();
    } catch (_) {
      // Player may already be stopped.
    }
  }

  Future<String> _fileFor(String phrase) {
    final cached = _cachedFiles[phrase];
    if (cached != null) return Future.value(cached);

    return _pending[phrase] ??= _createFile(phrase).catchError((Object error) {
      _pending.remove(phrase);
      throw error;
    });
  }

  Future<String> _createFile(String phrase) async {
    final pcm = await _synthesizer.synthesize(phrase);
    final wav = WavCodec.wrapPcm(pcm, sampleRate: _synthesizer.sampleRate);

    final directory = await getTemporaryDirectory();
    final path =
        '${directory.path}/guard_tts_${_cachedFiles.length}_'
        '${phrase.hashCode.toRadixString(16)}.wav';
    await File(path).writeAsBytes(wav, flush: true);

    _cachedFiles[phrase] = path;
    return path;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;

    await stop();
    await _player.dispose();
    await _synthesizer.close();

    for (final path in _cachedFiles.values) {
      try {
        final file = File(path);
        if (await file.exists()) await file.delete();
      } catch (_) {
        // Cache cleanup is best effort.
      }
    }
    _cachedFiles.clear();
    _pending.clear();
  }
}
