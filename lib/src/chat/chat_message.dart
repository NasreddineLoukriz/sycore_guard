import '../guard/guard_logic.dart';

/// Who produced a chat entry.
enum ChatSender { user, assistant, system }

/// One entry in the on-device chat.
///
/// Assistant entries may carry the [GuardDecision] that produced them; system
/// entries are status/error notices rendered as a small centred pill.
class ChatMessage {
  const ChatMessage({required this.sender, required this.text, this.decision});

  final ChatSender sender;
  final String text;
  final GuardDecision? decision;

  bool get isUser => sender == ChatSender.user;
  bool get isSystem => sender == ChatSender.system;
}
