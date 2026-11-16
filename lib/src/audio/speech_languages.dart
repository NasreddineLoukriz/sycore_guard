/// Speech-to-text languages offered in the UI.
///
/// Whisper's checkpoints are multilingual and take a language token per
/// transcription, so switching never reloads the model.
library;

class SpeechLanguage {
  const SpeechLanguage(this.code, this.label);

  /// Whisper language code (no delimiters), e.g. `en`, `ar`.
  final String code;

  /// Name shown in the picker, written in the language itself.
  final String label;
}

/// Curated list of the languages most likely to be used with this demo.
const List<SpeechLanguage> speechLanguages = [
  SpeechLanguage('en', 'English'),
  SpeechLanguage('ar', 'العربية'),
  SpeechLanguage('fr', 'Français'),
  SpeechLanguage('es', 'Español'),
  SpeechLanguage('de', 'Deutsch'),
  SpeechLanguage('tr', 'Türkçe'),
  SpeechLanguage('ur', 'اردو'),
  SpeechLanguage('hi', 'हिन्दी'),
  SpeechLanguage('zh', '中文'),
  SpeechLanguage('ru', 'Русский'),
  SpeechLanguage('pt', 'Português'),
  SpeechLanguage('it', 'Italiano'),
];

/// Used until the user picks another language.
const String defaultSpeechLanguage = 'en';

/// The entry for [code], or null when [code] is not offered.
SpeechLanguage? speechLanguageFor(String code) {
  for (final language in speechLanguages) {
    if (language.code == code) return language;
  }
  return null;
}
