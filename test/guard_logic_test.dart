import 'package:flutter_test/flutter_test.dart';
import 'package:sycore_guard/src/guard/guard_logic.dart';
import 'package:sycore_guard/src/guard/guard_service.dart';

void main() {
  const scanner = SensitiveDataScanner();
  const rules = GuardRules();

  group('SensitiveDataScanner', () {
    test('detects phone numbers', () {
      final findings = scanner.scan('Call me on +1 (415) 555-0132 tomorrow.');
      expect(findings.map((f) => f.label), contains('Phone number'));
    });

    test('detects email addresses', () {
      final findings = scanner.scan('Send it to jane.doe@example.com please.');
      expect(findings.map((f) => f.label), contains('Email address'));
    });

    test('detects payment cards only when the checksum is valid', () {
      final valid = scanner.scan('My card is 4111 1111 1111 1111.');
      expect(valid.map((f) => f.label), contains('Payment card number'));

      final invalid = scanner.scan('Order 1234 5678 9012 3456 shipped.');
      expect(
        invalid.map((f) => f.label),
        isNot(contains('Payment card number')),
      );
    });

    test('detects credentials in English and Arabic', () {
      expect(
        scanner.scan('The password is hunter2.').map((f) => f.label),
        contains('Credential or secret'),
      );
      expect(
        scanner.scan('كلمة المرور هي 1234').map((f) => f.label),
        contains('Credential or secret'),
      );
    });

    test('detects government ID references', () {
      final findings = scanner.scan('My passport number is A1234567.');
      expect(findings.map((f) => f.label), contains('Government ID number'));

      final reference = scanner.scan('I left my passport at the hotel.');
      expect(
        reference.map((f) => f.label),
        contains('Government ID reference'),
      );
    });

    test('leaves benign text alone', () {
      expect(scanner.scan('Please summarise the meeting notes.'), isEmpty);
      expect(scanner.scan('   '), isEmpty);
    });

    test('does not read a list of numbers as a phone number', () {
      for (final text in const [
        'Meeting moved to 2024 2025 2026',
        'The order number is 2024-2025',
        'Add 100 200 300 and 400',
        'I have 3 cats and 2 dogs',
        'The year 2024 was great',
      ]) {
        expect(scanner.scan(text), isEmpty, reason: text);
      }
    });

    test('still detects formatted phone numbers', () {
      for (final text in const [
        'Call +33 1 23 45 67 89',
        'Call +1 (415) 555-0132',
        'Call (415) 555-0132',
        'Call 415-555-0132',
        'Call 0555123456',
      ]) {
        expect(
          scanner.scan(text).map((finding) => finding.label),
          contains('Phone number'),
          reason: text,
        );
      }
    });

    test('masks the matched value', () {
      final findings = scanner.scan('My email is jane.doe@example.com.');
      final email = findings.firstWhere((f) => f.label == 'Email address');
      expect(email.maskedSample, startsWith('j'));
      expect(email.maskedSample, isNot(contains('jane.doe')));
      expect(email.maskedSample, contains('•'));
    });
  });

  group('SensitiveDataScanner.redact', () {
    test('masks an Arabic phone number and keeps the rest readable', () {
      expect(
        scanner.redact('رقم هاتفي 06631233'),
        'رقم هاتفي XXXXXXXX',
      );
      expect(
        scanner.redact('رقم هاتفي ٠٦٦٣١٢٣٣'),
        'رقم هاتفي XXXXXXXX',
        reason: 'Arabic-Indic digits are digits too',
      );
    });

    test('masks formatted phone numbers, emails and cards', () {
      expect(
        scanner.redact('Call me on +1 415 555-0132'),
        'Call me on ${'X' * 15}',
      );
      expect(
        scanner.redact('My email is jane@example.com'),
        'My email is ${'X' * 16}',
      );
      expect(
        scanner.redact('My card is 4111 1111 1111 1111'),
        'My card is ${'X' * 19}',
      );
    });

    test('masks the value after a credential keyword, not the keyword', () {
      expect(
        scanner.redact('The password is hunter2.'),
        'The password is XXXXXXX.',
      );
      expect(
        scanner.redact('كلمة المرور هي 1234'),
        'كلمة المرور هي XXXX',
      );
      // A keyword without a value hides nothing: the word is not the secret.
      expect(
        scanner.redact('I forgot my password yesterday'),
        'I forgot my password yesterday',
      );
    });

    test('masks a passport number and an SSN', () {
      expect(
        scanner.redact('My passport number is A1234567.'),
        'My passport number is XXXXXXXX.',
      );
      expect(
        scanner.redact('SSN 123-45-6789'),
        'SSN ${'X' * 11}',
      );
    });

    test('leaves benign text untouched', () {
      for (final text in const [
        'Please summarise the meeting notes.',
        'The order number is 2024-2025',
        'Meeting moved to 2024 2025 2026',
      ]) {
        expect(scanner.redact(text), text, reason: text);
      }
    });
  });

  group('GuardRules', () {
    test('blocks when a sensitive pattern is found', () {
      final decision = rules.evaluate('My number is 4155550132.');
      expect(decision.isBlocked, isTrue);
      expect(decision.decidedBy, 'rules');
      expect(decision.findings, isNotEmpty);
    });

    test('passes when nothing sensitive is found', () {
      final decision = rules.evaluate('What is the weather like today?');
      expect(decision.isBlocked, isFalse);
      expect(decision.decidedBy, 'rules');
    });

    test('a blocked decision carries the message with its values masked', () {
      final decision = rules.evaluate('My number is 4155550132.');
      expect(decision.isBlocked, isTrue);
      expect(decision.redactedText, 'My number is ${'X' * 10}.');
      expect(decision.redactedText, isNot(contains('4155550132')));
    });

    test('no masked copy when the message only names a category', () {
      final decision = rules.evaluate('I forgot my password yesterday');
      expect(decision.isBlocked, isTrue, reason: 'the keyword still blocks');
      expect(decision.redactedText, isNull);
    });
  });

  group('GuardVerdictParser (fail closed)', () {
    test('accepts SAFE, however the model phrases it', () {
      expect(GuardVerdictParser.parse('SAFE'), GuardVerdict.safe);
      expect(GuardVerdictParser.parse(' safe. '), GuardVerdict.safe);
      expect(GuardVerdictParser.parse('"Safe"'), GuardVerdict.safe);
      expect(
        GuardVerdictParser.parse('The transcript is SAFE.'),
        GuardVerdict.safe,
      );
    });

    test('blocks whenever BLOCKED appears, even next to SAFE', () {
      expect(GuardVerdictParser.parse('BLOCKED'), GuardVerdict.blocked);
      expect(GuardVerdictParser.parse('SAFE or BLOCKED'), GuardVerdict.blocked);
      expect(GuardVerdictParser.parse('not safe'), GuardVerdict.blocked);
      expect(GuardVerdictParser.parse('UNSAFE'), GuardVerdict.blocked);
      // "UNSAFE" must not be read as a SAFE word.
      expect(GuardVerdictParser.parse('unsafe'), GuardVerdict.blocked);
    });

    test('blocks an empty, truncated or undecided reply', () {
      expect(GuardVerdictParser.parse(''), GuardVerdict.blocked);
      expect(GuardVerdictParser.parse('   '), GuardVerdict.blocked);
      expect(GuardVerdictParser.parse('I cannot help'), GuardVerdict.blocked);
      expect(GuardVerdictParser.parse('The message'), GuardVerdict.blocked);
    });

    test('ignores a reasoning block and reads the answer after it', () {
      expect(
        GuardVerdictParser.parse(
          '<think>the user asks about the weather</think>SAFE',
        ),
        GuardVerdict.safe,
      );
      expect(
        GuardVerdictParser.parse('<think>no closing tag, cut off'),
        GuardVerdict.blocked,
      );
    });

    test('reads a sentence about personal data', () {
      expect(
        GuardVerdictParser.parse('The text does not contain personal data.'),
        GuardVerdict.safe,
      );
      expect(
        GuardVerdictParser.parse(
          'The text "hello" does not contain any personal data such as phone, '
          'email, ID, card, or password',
        ),
        GuardVerdict.safe,
      );
      expect(
        GuardVerdictParser.parse('It contains personal data (card number).'),
        GuardVerdict.blocked,
      );
      // A later leak wins over an earlier clearance.
      expect(
        GuardVerdictParser.parse(
          'The text does not contain personal data, but it contains a card '
          'number.',
        ),
        GuardVerdict.blocked,
      );
    });

    test('does not treat the word "sensitive" as a block on its own', () {
      // Regression: "\bSENSITIVE\b" used to block every reply that said
      // "does not contain sensitive data".
      expect(
        GuardVerdictParser.parse('The text does not contain sensitive data.'),
        GuardVerdict.safe,
      );
      expect(
        GuardVerdictParser.parse(
          'No sensitive personal information was found in the text.',
        ),
        GuardVerdict.safe,
      );
    });

    test('a stated block wins over a stated SAFE', () {
      expect(
        GuardVerdictParser.parse(
          'The answer is SAFE. The text contains personal data (card number).',
        ),
        GuardVerdict.blocked,
      );
    });

    test('reports whether a streaming reply is already decisive', () {
      expect(GuardVerdictParser.hasVerdict('SAF'), isFalse);
      expect(GuardVerdictParser.hasVerdict('SAFE'), isTrue);
      expect(GuardVerdictParser.hasVerdict('BLOCKED'), isTrue);
      expect(GuardVerdictParser.hasVerdict('<think>hmm'), isFalse);
    });
  });

  group('GuardService prompt', () {
    test('asks one plain question and keeps the transcript on its own line', () {
      final prompt = GuardService.buildPrompt('hello\nthere');
      expect(prompt, startsWith(GuardService.question));
      expect(prompt, endsWith('Text: hello there'));
      // The answer labels are deliberately absent: an echoed label blocked
      // benign messages.
      expect(prompt, isNot(contains('BLOCKED')));
      expect(prompt, isNot(contains('SAFE')));
    });

    test('caps the transcript length', () {
      final prompt = GuardService.buildPrompt('a' * 5000);
      expect(prompt.length, lessThan(GuardService.maxTranscriptChars + 1024));
      expect(prompt, contains('Text: ${'a' * 100}'));
    });
  });
}
