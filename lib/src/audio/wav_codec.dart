import 'dart:io';
import 'dart:typed_data';

/// Reads and writes the uncompressed 16-bit PCM WAV files used by the
/// on-device speech pipeline.
///
/// `record` writes a WAV container for `AudioEncoder.pcm16bits`, while the
/// speech recognizer expects raw 16-bit little-endian PCM. Matcha's
/// synthesizer does the opposite: it returns raw PCM, which `just_audio` can
/// only play inside a WAV container. Both directions live here so the
/// conversion is testable and platform independent.
class WavCodec {
  const WavCodec._();

  /// Size of the canonical RIFF/WAVE header this codec writes.
  static const int headerSize = 44;

  /// Reads [path] and returns its raw PCM payload.
  static Future<Uint8List> readPcmFromFile(String path) async {
    final bytes = await File(path).readAsBytes();
    return extractPcm(bytes);
  }

  /// Returns the raw PCM payload of [bytes].
  ///
  /// Walks the RIFF chunks instead of assuming the `data` chunk starts at byte
  /// 44, so files with extra chunks (LIST/INFO, fact, …) are handled. Bytes
  /// that are not a WAV container are returned unchanged, which keeps the
  /// helper usable if a platform ever writes headerless PCM.
  static Uint8List extractPcm(Uint8List bytes) {
    if (!_hasRiffHeader(bytes)) return bytes;

    var offset = 12; // "RIFF" + size + "WAVE"
    while (offset + 8 <= bytes.length) {
      final chunkId = String.fromCharCodes(bytes, offset, offset + 4);
      final chunkSize = ByteData.sublistView(
        bytes,
        offset + 4,
        offset + 8,
      ).getUint32(0, Endian.little);
      final dataStart = offset + 8;

      if (chunkId == 'data') {
        final dataEnd = (dataStart + chunkSize).clamp(dataStart, bytes.length);
        return Uint8List.sublistView(bytes, dataStart, dataEnd);
      }

      // Chunks are word aligned: an odd-sized chunk is followed by one pad byte.
      offset = dataStart + chunkSize + (chunkSize.isOdd ? 1 : 0);
    }

    throw const FormatException('WAV file has no data chunk');
  }

  /// Wraps raw 16-bit PCM in a canonical 44-byte RIFF/WAVE header.
  static Uint8List wrapPcm(
    Uint8List pcm, {
    required int sampleRate,
    int channels = 1,
    int bitsPerSample = 16,
  }) {
    if (sampleRate <= 0) {
      throw ArgumentError.value(sampleRate, 'sampleRate', 'must be positive');
    }
    if (channels <= 0) {
      throw ArgumentError.value(channels, 'channels', 'must be positive');
    }

    final blockAlign = channels * bitsPerSample ~/ 8;
    final byteRate = sampleRate * blockAlign;
    final output = Uint8List(headerSize + pcm.length);
    final header = ByteData.sublistView(output);

    void writeTag(int offset, String tag) {
      assert(tag.length == 4);
      output.setRange(offset, offset + 4, tag.codeUnits);
    }

    writeTag(0, 'RIFF');
    header.setUint32(4, 36 + pcm.length, Endian.little);
    writeTag(8, 'WAVE');

    writeTag(12, 'fmt ');
    header.setUint32(16, 16, Endian.little); // PCM fmt chunk size
    header.setUint16(20, 1, Endian.little); // format: PCM
    header.setUint16(22, channels, Endian.little);
    header.setUint32(24, sampleRate, Endian.little);
    header.setUint32(28, byteRate, Endian.little);
    header.setUint16(32, blockAlign, Endian.little);
    header.setUint16(34, bitsPerSample, Endian.little);

    writeTag(36, 'data');
    header.setUint32(40, pcm.length, Endian.little);

    output.setRange(headerSize, output.length, pcm);
    return output;
  }

  static bool _hasRiffHeader(Uint8List bytes) {
    if (bytes.length < 12) return false;
    return String.fromCharCodes(bytes, 0, 4) == 'RIFF' &&
        String.fromCharCodes(bytes, 8, 12) == 'WAVE';
  }
}
