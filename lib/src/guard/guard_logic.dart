/// Pure, dependency-free guard logic: deterministic sensitive-data scanning
/// and the fail-closed parsing of the model's verdict.
///
/// This file is intentionally free of Flutter/platform imports so it can be
/// unit tested without initializing the on-device engines.
library;

/// The final verdict for one transcript.
enum GuardVerdict { safe, blocked }

/// One category of sensitive data found in the transcript.
///
/// Only a masked hint of the matched text is kept: the raw value never needs
/// to be shown (or held) by the UI.
class SensitiveFinding {
  const SensitiveFinding({required this.label, required this.maskedSample});

  /// Human readable category, e.g. `Phone number`.
  final String label;

  /// Redacted excerpt, e.g. `+••••••`.
  final String maskedSample;
}

/// The outcome of a guard evaluation.
class GuardDecision {
  const GuardDecision({
    required this.verdict,
    required this.reason,
    required this.decidedBy,
    this.findings = const [],
    this.rawReply,
    this.redactedText,
  });

  final GuardVerdict verdict;
  final String reason;

  /// `rules` for the deterministic scanner, `model` for the on-device LLM and
  /// `model-error` when the model could not be run at all (fail closed).
  /// `model-uncertain` means it answered without reaching a verdict.
  final String decidedBy;

  final List<SensitiveFinding> findings;

  /// The model's raw reply, when the model produced one. Diagnostics only:
  /// it holds the verdict, never the transcript.
  final String? rawReply;

  /// The transcript with the values the rules found replaced by `X` runs, so
  /// the user can reuse the message without its secrets. Null when nothing was
  /// masked (a model-only block).
  final String? redactedText;

  bool get isBlocked => verdict == GuardVerdict.blocked;

  /// True when the block happened because the classifier itself failed, not
  /// because of the message's content.
  bool get isModelError => decidedBy == 'model-error';
}

/// One detection and where it sits in the transcript.
class _Found {
  const _Found(this.label, this.start, this.end, {this.redact = true});

  final String label;
  final int start;
  final int end;

  /// False for a keyword that names a category (`password`, `passport`): the
  /// word itself is not a secret, only the value after it is.
  final bool redact;
}

/// Deterministic detector for the sensitive data categories SYcore Guard
/// protects: phone numbers, emails, government IDs, payment cards, bank
/// accounts and credentials.
///
/// Rules run before the LLM and short-circuit it, so obvious leaks are caught
/// instantly and never depend on a 0.6B model's mood.
class SensitiveDataScanner {
  const SensitiveDataScanner();

  static final RegExp _email = RegExp(
    r'[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+',
  );

  static final RegExp _cardCandidate = RegExp(
    r'(?<!\d)(?:\d[ -]?){12,18}\d(?!\d)',
  );

  static final RegExp _iban = RegExp(r'\b[A-Z]{2}\d{2}[A-Z0-9]{10,30}\b');

  static final RegExp _ssn = RegExp(r'\b\d{3}-\d{2}-\d{4}\b');

  static final RegExp _phoneCandidate = RegExp(
    r'(?<!\d)(?:\+|00)?\(?\d[\d\s().-]{5,}\d(?!\d)',
  );

  static final RegExp _secretWords = RegExp(
    r'(password|passcode|pass\s?phrase|secret\s+(?:key|phrase|code)|'
    r'api[\s_-]?key|access[\s_-]?token|private[\s_-]?key|seed\s?phrase|'
    r'one[\s-]?time\s?(?:code|password)|'
    r'\botp\b|pin\s?(?:code|number)|كلمة\s+(?:المرور|السر)|الرمز\s+السري|'
    r'العبارة\s+السرية|مفتاح\s+سري|رمز\s+التحقق)',
    caseSensitive: false,
    unicode: true,
  );

  static final RegExp _idWords = RegExp(
    r'(national\s?id|social\s?security|passport|identity\s?card|'
    r'رقم\s+(?:ال)?هوي(?:ة|تي|تك)|رقم\s+(?:البطاقة|الجواز)|جواز\s+السفر|'
    r'الهوية\s+الوطنية)',
    caseSensitive: false,
    unicode: true,
  );

  static final RegExp _digitRun = RegExp(r'\d{4,}');

  /// The value that follows a keyword: "password is hunter2", "هي 1234",
  /// "passport number is A1234567". Only an explicit `is`/`=`/`:` (or the
  /// Arabic `هي`/`هو`) makes the next token a value, so "I forgot my password
  /// yesterday" hides nothing.
  static final RegExp _valueAfterKeyword = RegExp(
    r'^\s*(?:(?:number|no\.?|code|رقم|الرقم)\s+)?'
    r'(?:is|are|was|were|هي|هو|=|:)\s*([^\s,;:]+)',
    caseSensitive: false,
    unicode: true,
  );

  static final RegExp _asciiDigit = RegExp(r'[0-9]');

  static final RegExp _trailingPunctuation = RegExp(r'[.,;:!?]+$');

  /// Arabic-Indic and Persian digits, which `\d` does not match.
  static final RegExp _nonAsciiDigit = RegExp('[٠-٩۰-۹]');

  /// Scans [text] and returns one finding per matched category.
  List<SensitiveFinding> scan(String text) {
    if (text.trim().isEmpty) return const [];

    final findings = <SensitiveFinding>[];
    final seenLabels = <String>{};

    for (final found in _detect(text)) {
      if (!seenLabels.add(found.label)) continue;
      findings.add(
        SensitiveFinding(
          label: found.label,
          maskedSample: mask(text.substring(found.start, found.end)),
        ),
      );
    }

    return findings;
  }

  /// [text] with every detected value replaced by a run of `X`s.
  ///
  /// The length is kept, so the reader sees how much was hidden without
  /// learning the value; format characters inside a value are hidden too.
  /// Category keywords ("password", "passport") stay readable: they say what
  /// was found, not what the secret is.
  String redact(String text) {
    if (text.trim().isEmpty) return text;

    final spans = _detect(text).where((found) => found.redact).toList()
      ..sort((a, b) => a.start.compareTo(b.start));
    if (spans.isEmpty) return text;

    final buffer = StringBuffer();
    var cursor = 0;
    for (final span in spans) {
      // Two rules can match the same value (a card is also a long number).
      if (span.start < cursor) continue;
      buffer.write(text.substring(cursor, span.start));
      buffer.write('X' * (span.end - span.start));
      cursor = span.end;
    }
    buffer.write(text.substring(cursor));
    return buffer.toString();
  }

  /// All matches, with their positions, so [scan] can show a sample and
  /// [redact] can replace the value itself.
  ///
  /// Matching runs on [text] with Arabic-Indic digits normalised to ASCII; the
  /// normalisation is one character for one character, so every span still
  /// points at the original text.
  List<_Found> _detect(String text) {
    final normalized = _normalizeDigits(text);
    final found = <_Found>[];

    for (final match in _email.allMatches(normalized)) {
      found.add(_Found('Email address', match.start, match.end));
    }

    // Payment cards are only reported when the checksum validates, which keeps
    // long order numbers from being mistaken for cards.
    for (final match in _cardCandidate.allMatches(normalized)) {
      if (_luhnValid(_digitsOnly(match.group(0)!))) {
        found.add(_Found('Payment card number', match.start, match.end));
      }
    }

    for (final match in _iban.allMatches(normalized)) {
      found.add(_Found('Bank account (IBAN)', match.start, match.end));
    }

    for (final match in _ssn.allMatches(normalized)) {
      found.add(_Found('Government ID number', match.start, match.end));
    }

    for (final match in _phoneCandidate.allMatches(normalized)) {
      if (_looksLikePhone(match.group(0)!)) {
        found.add(_Found('Phone number', match.start, match.end));
      }
    }

    for (final match in _secretWords.allMatches(normalized)) {
      found.add(
        _Found('Credential or secret', match.start, match.end, redact: false),
      );
      final value = _valueSpan(normalized, match.end);
      if (value != null) {
        found.add(_Found('Credential or secret', value.$1, value.$2));
      }
    }

    final idMatch = _idWords.firstMatch(normalized);
    if (idMatch != null) {
      final label = _digitRun.hasMatch(normalized)
          ? 'Government ID number'
          : 'Government ID reference';
      found.add(_Found(label, idMatch.start, idMatch.end, redact: false));
      final value = _valueSpan(normalized, idMatch.end, requireDigit: true);
      if (value != null) {
        found.add(_Found(label, value.$1, value.$2));
      }
    }

    return found;
  }

  /// The span of the secret after a keyword, or null when the text names a
  /// category without giving a value.
  static (int, int)? _valueSpan(
    String text,
    int keywordEnd, {
    bool requireDigit = false,
  }) {
    final match = _valueAfterKeyword.firstMatch(text.substring(keywordEnd));
    if (match == null) return null;
    final raw = match.group(1)!;
    final value = raw.replaceFirst(_trailingPunctuation, '');
    if (value.isEmpty) return null;
    if (requireDigit && !_asciiDigit.hasMatch(value)) return null;
    // The token is the last thing the pattern matches, so it ends with the
    // whole match; the value may lose trailing sentence punctuation.
    final end = keywordEnd + match.end;
    return (end - raw.length, end - raw.length + value.length);
  }

  /// Maps ٠-٩ (U+0660–U+0669) and ۰-۹ (U+06F0–U+06F9) to ASCII digits.
  ///
  /// Arabic-speaking users often type numbers this way, and `\d` does not match
  /// them. Each digit maps to exactly one character, so spans stay valid.
  static String _normalizeDigits(String text) {
    if (!_nonAsciiDigit.hasMatch(text)) return text;
    final buffer = StringBuffer();
    for (final rune in text.runes) {
      if (rune >= 0x0660 && rune <= 0x0669) {
        buffer.writeCharCode(rune - 0x0660 + 0x30);
      } else if (rune >= 0x06F0 && rune <= 0x06F9) {
        buffer.writeCharCode(rune - 0x06F0 + 0x30);
      } else {
        buffer.writeCharCode(rune);
      }
    }
    return buffer.toString();
  }

  /// Leaves only the first character visible so a finding can be shown in the
  /// UI without echoing the secret back to the user (or to logs).
  static String mask(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return '';
    if (trimmed.length <= 2) return '••';
    final hidden = (trimmed.length - 1).clamp(1, 8);
    return '${trimmed[0]}${'•' * hidden}';
  }

  static String _digitsOnly(String value) =>
      value.replaceAll(RegExp(r'[^0-9]'), '');

  /// Distinguishes a phone number from a run of unrelated numbers.
  ///
  /// A bare list such as `100 200 300` or `2024 2025 2026` is not a phone
  /// number: spaces are only accepted in international (`+33 1 23 45 67 89`)
  /// or parenthesised (`(415) 555-0132`) formats. Separated numbers also need
  /// at least nine digits, which rejects year ranges like `2024-2025`.
  static bool _looksLikePhone(String candidate) {
    final digits = _digitsOnly(candidate);
    if (digits.length < 8 || digits.length > 15) return false;

    final trimmed = candidate.trimLeft();
    final international = trimmed.startsWith('+') || trimmed.startsWith('00');
    final parenthesised = candidate.contains('(') || candidate.contains(')');
    final hasSpace = RegExp(r'\s').hasMatch(candidate);
    final hasSeparator = RegExp(r'[.\-]').hasMatch(candidate);

    if (hasSpace && !international && !parenthesised) return false;
    if ((hasSpace || hasSeparator) && digits.length < 9) return false;

    if (hasSpace || hasSeparator || parenthesised) {
      final groups = candidate
          .split(RegExp(r'[^0-9]+'))
          .where((group) => group.isNotEmpty);
      if (groups.any((group) => group.length > 5)) return false;
    }

    return true;
  }

  static bool _luhnValid(String digits) {
    if (digits.length < 13 || digits.length > 19) return false;
    var sum = 0;
    var doubleDigit = false;
    for (var index = digits.length - 1; index >= 0; index--) {
      var digit = digits.codeUnitAt(index) - 0x30;
      if (doubleDigit) {
        digit *= 2;
        if (digit > 9) digit -= 9;
      }
      sum += digit;
      doubleDigit = !doubleDigit;
    }
    return sum % 10 == 0;
  }
}

/// Applies the deterministic rules to one transcript.
class GuardRules {
  const GuardRules([this._scanner = const SensitiveDataScanner()]);

  final SensitiveDataScanner _scanner;

  GuardDecision evaluate(String transcript) {
    final findings = _scanner.scan(transcript);
    if (findings.isEmpty) {
      return const GuardDecision(
        verdict: GuardVerdict.safe,
        reason: 'No sensitive pattern was detected by the on-device rules.',
        decidedBy: 'rules',
      );
    }
    final redacted = _scanner.redact(transcript);
    return GuardDecision(
      verdict: GuardVerdict.blocked,
      reason: 'Sensitive data detected before the request left the device.',
      decidedBy: 'rules',
      findings: findings,
      redactedText: redacted == transcript ? null : redacted,
    );
  }
}

/// Maps the LLM's raw reply to a verdict — **fail closed**.
///
/// A small instruct model rarely answers with one bare word: it may think
/// first, write "The transcript is SAFE.", or explain "The text does not
/// contain personal data". The parser therefore accepts either a decisive
/// keyword or a clear sentence about personal data instead of demanding an
/// exact reply, and still blocks anything that decides nothing (empty output,
/// a refusal, a tool call, an exception).
///
/// A reply that both blocks and clears is blocked: `BLOCKED`, `UNSAFE` and a
/// positive statement always win over `SAFE` and a negated one.
class GuardVerdictParser {
  const GuardVerdictParser._();

  static final RegExp _thinkBlock = RegExp(
    r'<think>[\s\S]*?</think>',
    caseSensitive: false,
  );

  static final RegExp _channelBlock = RegExp(
    r'<\|channel>[\s\S]*?<channel\|>',
    caseSensitive: false,
  );

  /// `SENSITIVE` is deliberately absent: it appears in innocent replies such
  /// as "the text does not contain sensitive data" and used to block them.
  static final RegExp _blockedWord = RegExp(
    r'\bBLOCKED\b|\bNOT\s+SAFE\b|\bUNSAFE\b',
  );

  static final RegExp _safeWord = RegExp(r'\bSAFE\b');

  /// The sentence a model writes when it reasons instead of answering with a
  /// keyword, e.g. "The text does not contain personal data" or "It contains
  /// personal data (card number)". Bare category words are not matched: the
  /// categories are usually listed right after a negated phrase
  /// ("does not contain personal data (phone, email, ID)").
  static final RegExp _sensitivePhrase = RegExp(
    r'\b(?:personal|sensitive|private)\s+(?:data|information|details)\b'
    r'|\bis\s+sensitive\b|\bare\s+sensitive\b'
    r'|\bcontains?\s+(?:a|an|any)\s+'
    r'(?:phone|e-?mail|card|password|passport|bank|iban|address)\b',
    caseSensitive: false,
  );

  static final RegExp _negation = RegExp(
    r"\bnot\b|\bno\b|\bnever\b|\bwithout\b|\bnone\b|\bdoesn'?t\b|"
    r"\bdon'?t\b|\bisn'?t\b|\bfree\s+of\b|\bzero\b",
    caseSensitive: false,
  );

  /// How far before a sensitive phrase a negation still applies ("does not
  /// contain any sensitive personal data" has four words in between).
  static const int _negationWindow = 28;

  /// Drops reasoning so a thinking model's scratchpad is never read as its
  /// answer. An unterminated block (a reply cut off by the token cap) is
  /// dropped as well.
  static String stripReasoning(String rawReply) {
    var text = rawReply
        .replaceAll(_thinkBlock, ' ')
        .replaceAll(_channelBlock, ' ');
    final open = text.toLowerCase().indexOf('<think>');
    if (open >= 0) text = text.substring(0, open);
    return text;
  }

  /// True when [rawReply] already contains a decisive word.
  static bool hasVerdict(String rawReply) => verdictIn(rawReply) != null;

  /// The decisive verdict in [rawReply], or null when it decides nothing.
  ///
  /// Blocking evidence wins: a reply that mentions both a block and a clear
  /// verdict is blocked.
  static GuardVerdict? verdictIn(String rawReply) {
    final text = stripReasoning(rawReply);
    final upper = text.toUpperCase();
    if (_blockedWord.hasMatch(upper)) return GuardVerdict.blocked;

    final phrased = _phrasedVerdict(text.toLowerCase());
    if (phrased == GuardVerdict.blocked) return GuardVerdict.blocked;
    if (_safeWord.hasMatch(upper)) return GuardVerdict.safe;
    return phrased;
  }

  /// Reads "contains personal data" / "does not contain personal data".
  ///
  /// Every mention is judged by the words just before it, so a sentence that
  /// both states a leak and clears another category ("contains personal data
  /// (card number) and does not contain email") still blocks.
  static GuardVerdict? _phrasedVerdict(String text) {
    var positive = false;
    var negative = false;

    for (final match in _sensitivePhrase.allMatches(text)) {
      final start = match.start - _negationWindow;
      final before = text.substring(start < 0 ? 0 : start, match.start);
      if (_negation.hasMatch(before)) {
        negative = true;
      } else {
        positive = true;
      }
    }

    if (positive) return GuardVerdict.blocked;
    if (negative) return GuardVerdict.safe;
    return null;
  }

  /// Never returns null: a reply with no decisive word blocks.
  static GuardVerdict parse(String rawReply) =>
      verdictIn(rawReply) ?? GuardVerdict.blocked;
}
