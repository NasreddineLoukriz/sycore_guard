import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sycore_guard/src/chat/chat_message.dart';
import 'package:sycore_guard/src/guard/guard_logic.dart';
import 'package:sycore_guard/src/ui/message_bubble.dart';

void main() {
  Widget wrap(ChatMessage message) => MaterialApp(
    home: Scaffold(body: MessageBubble(message: message)),
  );

  testWidgets('renders a user message', (tester) async {
    await tester.pumpWidget(
      wrap(const ChatMessage(sender: ChatSender.user, text: 'Hello guard')),
    );

    expect(find.text('Hello guard'), findsOneWidget);
    expect(find.text('BLOCKED'), findsNothing);
  });

  testWidgets('renders a blocked verdict with its findings', (tester) async {
    await tester.pumpWidget(
      wrap(
        const ChatMessage(
          sender: ChatSender.assistant,
          text: 'This message looks like it contains sensitive data.',
          decision: GuardDecision(
            verdict: GuardVerdict.blocked,
            reason: 'Sensitive data detected.',
            decidedBy: 'rules',
            findings: [
              SensitiveFinding(label: 'Phone number', maskedSample: '+•••'),
            ],
          ),
        ),
      ),
    );

    expect(find.text('BLOCKED'), findsOneWidget);
    expect(find.text('Phone number'), findsOneWidget);
    expect(find.textContaining('on-device rules'), findsOneWidget);
  });

  testWidgets('renders the masked message for a rules block', (tester) async {
    await tester.pumpWidget(
      wrap(
        const ChatMessage(
          sender: ChatSender.assistant,
          text: 'This message contains sensitive data. Here it is masked:',
          decision: GuardDecision(
            verdict: GuardVerdict.blocked,
            reason: 'Sensitive data detected.',
            decidedBy: 'rules',
            redactedText: 'رقم هاتفي XXXXXXXX',
          ),
        ),
      ),
    );

    expect(find.text('Message after masking'), findsOneWidget);
    expect(find.text('رقم هاتفي XXXXXXXX'), findsOneWidget);
  });

  testWidgets('renders a safe verdict without findings', (tester) async {
    await tester.pumpWidget(
      wrap(
        const ChatMessage(
          sender: ChatSender.assistant,
          text: 'No sensitive data detected.',
          decision: GuardDecision(
            verdict: GuardVerdict.safe,
            reason: 'No sensitive data.',
            decidedBy: 'model',
          ),
        ),
      ),
    );

    expect(find.text('SAFE'), findsOneWidget);
    expect(find.text('Checked by the on-device model'), findsOneWidget);
    expect(find.byType(Chip), findsNothing);
  });

  testWidgets('renders an uncertain model verdict as a block', (tester) async {
    await tester.pumpWidget(
      wrap(
        const ChatMessage(
          sender: ChatSender.assistant,
          text: 'The model could not confirm this message is safe.',
          decision: GuardDecision(
            verdict: GuardVerdict.blocked,
            reason: 'The on-device model did not reach a clear answer.',
            decidedBy: 'model-uncertain',
          ),
        ),
      ),
    );

    expect(find.text('BLOCKED'), findsOneWidget);
    expect(find.textContaining('could not reach a verdict'), findsOneWidget);
  });

  testWidgets('renders a system notice', (tester) async {
    await tester.pumpWidget(
      wrap(
        const ChatMessage(sender: ChatSender.system, text: 'Voice is optional'),
      ),
    );

    expect(find.text('Voice is optional'), findsOneWidget);
  });
}
