import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sycore_guard/src/audio/wav_codec.dart';

void main() {
  group('WavCodec', () {
    test('round-trips raw PCM through a WAV container', () {
      final pcm = Uint8List.fromList(List.generate(960, (i) => i % 256));

      final wav = WavCodec.wrapPcm(pcm, sampleRate: 16000);

      expect(wav.length, WavCodec.headerSize + pcm.length);
      expect(String.fromCharCodes(wav, 0, 4), 'RIFF');
      expect(String.fromCharCodes(wav, 8, 12), 'WAVE');
      expect(String.fromCharCodes(wav, 36, 40), 'data');

      expect(WavCodec.extractPcm(wav), pcm);
    });

    test('writes the correct header fields', () {
      final wav = WavCodec.wrapPcm(
        Uint8List(100),
        sampleRate: 22050,
        channels: 1,
      );
      final header = ByteData.sublistView(wav);

      expect(header.getUint32(4, Endian.little), 36 + 100);
      expect(header.getUint16(20, Endian.little), 1); // PCM
      expect(header.getUint16(22, Endian.little), 1); // mono
      expect(header.getUint32(24, Endian.little), 22050);
      expect(header.getUint32(28, Endian.little), 44100); // byte rate
      expect(header.getUint16(32, Endian.little), 2); // block align
      expect(header.getUint16(34, Endian.little), 16); // bits per sample
      expect(header.getUint32(40, Endian.little), 100);
    });

    test('skips unknown chunks before the data chunk', () {
      final pcm = Uint8List.fromList([1, 2, 3, 4, 5, 6]);
      final extraChunk = Uint8List(8 + 3 + 1); // odd payload + pad byte
      extraChunk.setRange(0, 4, 'LIST'.codeUnits);
      ByteData.sublistView(extraChunk).setUint32(4, 3, Endian.little);
      extraChunk.setRange(8, 11, [9, 9, 9]);

      final wav = WavCodec.wrapPcm(pcm, sampleRate: 16000);
      final withExtra = BytesBuilder()
        ..add(wav.sublist(0, 36))
        ..add(extraChunk)
        ..add(wav.sublist(36));
      final bytes = withExtra.toBytes();
      ByteData.sublistView(bytes).setUint32(4, bytes.length - 8, Endian.little);

      expect(WavCodec.extractPcm(bytes), pcm);
    });

    test('returns headerless input unchanged', () {
      final raw = Uint8List.fromList([7, 7, 7, 7]);
      expect(WavCodec.extractPcm(raw), raw);
    });

    test('rejects a WAV container without a data chunk', () {
      final wav = WavCodec.wrapPcm(Uint8List(8), sampleRate: 16000);
      final headerOnly = wav.sublist(0, 40); // drop the data chunk
      ByteData.sublistView(headerOnly).setUint32(4, 32, Endian.little);

      expect(() => WavCodec.extractPcm(headerOnly), throwsFormatException);
    });

    test('rejects invalid sample rates', () {
      expect(
        () => WavCodec.wrapPcm(Uint8List(2), sampleRate: 0),
        throwsArgumentError,
      );
    });
  });
}
