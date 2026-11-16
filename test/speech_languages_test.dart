import 'package:flutter_test/flutter_test.dart';
import 'package:sycore_guard/src/audio/speech_languages.dart';

void main() {
  group('speech languages', () {
    test('the default language is offered', () {
      expect(speechLanguageFor(defaultSpeechLanguage), isNotNull);
    });

    test('every code is a unique two-letter Whisper code', () {
      final codes = speechLanguages.map((language) => language.code).toList();
      expect(codes.length, codes.toSet().length, reason: 'duplicate code');
      for (final code in codes) {
        expect(code, matches(RegExp(r'^[a-z]{2}$')));
      }
    });

    test('English and Arabic are available', () {
      expect(speechLanguageFor('en')?.label, 'English');
      expect(speechLanguageFor('ar')?.label, 'العربية');
    });

    test('unknown codes are rejected', () {
      expect(speechLanguageFor('xx'), isNull);
      expect(speechLanguageFor(''), isNull);
    });
  });
}
