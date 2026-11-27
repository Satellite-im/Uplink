import 'sms.dart';

/// What an edit sends, when it is sent: SMS can't change a text on the other person's phone, so the new words go as a
/// follow-up text after this.
const correctionPrefix = 'Correction: ';

/// The follow-up text for a message edited to say [body].
String correctionText(String body) => '$correctionPrefix$body';

/// What [foldCorrections] makes of a conversation.
class EditFold {
  const EditFold({required this.messages, required this.corrected});

  /// The messages to draw, newest first, less the corrections that belong to an edited message.
  final List<Message> messages;

  /// The edited messages ([Message.key]) whose correction was sent.
  final Set<String> corrected;
}

/// Hides your "Correction: …" texts that say what an earlier edited message of yours now says: the edited bubble
/// already shows it, and says "correction sent". A correction whose message has since been edited again, or
/// deleted, stays a bubble, because it is still a text the other person has.
EditFold foldCorrections(List<Message> newestFirst) {
  final hidden = <String>{};
  final corrected = <String>{};
  for (var i = 0; i < newestFirst.length; i++) {
    final c = newestFirst[i];
    if (!c.outgoing || !c.body.startsWith(correctionPrefix)) continue;
    final said = c.body.substring(correctionPrefix.length).trim();
    for (var j = i + 1; j < newestFirst.length; j++) {
      final m = newestFirst[j];
      if (m.outgoing && m.edited && !corrected.contains(m.key) && m.body.trim() == said) {
        hidden.add(c.key);
        corrected.add(m.key);
        break;
      }
    }
  }
  return EditFold(messages: [for (final m in newestFirst) if (!hidden.contains(m.key)) m], corrected: corrected);
}
