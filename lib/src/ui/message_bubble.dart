import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../chat/chat_message.dart';

/// Renders one chat entry: user bubble (right), assistant bubble (left) or a
/// small system notice.
///
/// Kept free of plugins so it can be exercised by widget tests.
class MessageBubble extends StatelessWidget {
  const MessageBubble({required this.message, super.key});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    if (message.isSystem) return _SystemNotice(text: message.text);
    if (message.isUser) return _UserBubble(text: message.text);
    return _AssistantBubble(message: message);
  }
}

class _UserBubble extends StatelessWidget {
  const _UserBubble({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.82,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: theme.colorScheme.primary,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(18),
            topRight: Radius.circular(18),
            bottomLeft: Radius.circular(18),
            bottomRight: Radius.circular(4),
          ),
        ),
        child: SelectableText(
          text,
          style: TextStyle(color: theme.colorScheme.onPrimary, fontSize: 15),
        ),
      ),
    );
  }
}

class _AssistantBubble extends StatelessWidget {
  const _AssistantBubble({required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final decision = message.decision;
    final blocked = decision?.isBlocked ?? false;
    final masked = decision?.redactedText;
    final accent = decision == null
        ? theme.colorScheme.outlineVariant
        : (blocked ? Colors.red : Colors.green);

    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.86,
        ),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: decision == null
              ? theme.colorScheme.surfaceContainerHighest
              : (blocked ? Colors.red.shade50 : Colors.green.shade50),
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(18),
            topRight: Radius.circular(18),
            bottomLeft: Radius.circular(4),
            bottomRight: Radius.circular(18),
          ),
          border: decision == null ? null : Border.all(color: accent),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (decision != null) ...[
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    blocked ? Icons.shield : Icons.verified_user,
                    size: 20,
                    color: accent,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    blocked ? 'BLOCKED' : 'SAFE',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                      color: accent,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
            ],
            SelectableText(message.text, style: const TextStyle(fontSize: 15)),
            if (masked != null) ...[
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: accent),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Message after masking',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: accent,
                      ),
                    ),
                    const SizedBox(height: 4),
                    SelectableText(
                      masked,
                      style: const TextStyle(fontSize: 15, height: 1.4),
                    ),
                  ],
                ),
              ),
            ],
            if (decision != null && decision.reason.isNotEmpty) ...[
              const SizedBox(height: 8),
              SelectableText(
                decision.reason,
                style: TextStyle(fontSize: 12, color: Colors.grey.shade800),
              ),
            ],
            if (kDebugMode && (decision?.rawReply ?? '').isNotEmpty) ...[
              const SizedBox(height: 4),
              SelectableText(
                'Model said: "${decision!.rawReply}"',
                style: TextStyle(
                  fontSize: 11,
                  color: Colors.grey.shade600,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ],
            if (decision != null && decision.findings.isNotEmpty) ...[
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final finding in decision.findings)
                    Chip(
                      avatar: Icon(
                        Icons.warning_amber,
                        size: 16,
                        color: accent,
                      ),
                      label: Text(finding.label),
                      labelStyle: const TextStyle(fontSize: 12),
                      visualDensity: VisualDensity.compact,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      backgroundColor: Colors.white,
                    ),
                ],
              ),
            ],
            if (decision != null) ...[
              const SizedBox(height: 8),
              Text(
                switch (decision.decidedBy) {
                  'rules' => 'Checked by on-device rules',
                  'model' => 'Checked by the on-device model',
                  'model-error' => 'The on-device model could not run',
                  _ => 'The on-device model could not reach a verdict',
                },
                style: TextStyle(
                  fontSize: 11,
                  color: Colors.grey.shade700,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SystemNotice extends StatelessWidget {
  const _SystemNotice({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          text,
          style: theme.textTheme.bodySmall,
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}
