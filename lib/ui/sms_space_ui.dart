/// An SMS space's people by text (lib/circles/sms_space.dart; Matt, 2026-11-19: "a special space in the circle called a
/// "SMS Space" to text members"): who is in it by text, and, on the phone that texts for it, adding and taking out.
library;

import 'package:flutter/services.dart' show TextCapitalization, TextInputType;
import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../art/app_icon.dart';
import '../art/lucide.g.dart';
import '../circles/circles.dart';
import '../circles/sms_space.dart';
import '../kit/settings_kit.dart';
import '../me/me.dart';
import '../voice/channels.dart';
import '../voice/voice.dart';
import 'circles/new_circle.dart' show CirclePerson, circlePeople;
import 'common.dart';
import '../l10n/words.dart';

/// [space]'s entry in its circle, where it is an SMS space; null otherwise.
CircleSpace? smsSpaceOf(VoiceChannel space) {
  final c = Circles.instance.circleOf(space);
  final s = c?.space(space.seed);
  return s != null && smsTexterOf(s) != null ? s : null;
}

/// The page of an SMS space's people: each of the circle's members with how the space's messages reach them, and,
/// on the phone that texts for it, a name and number to add someone by text.
class TextedPeopleScreen extends StatefulWidget {
  const TextedPeopleScreen({super.key, required this.space});
  final VoiceChannel space;

  @override
  State<TextedPeopleScreen> createState() => _TextedPeopleScreenState();
}

class _TextedPeopleScreenState extends State<TextedPeopleScreen> {
  final _name = TextEditingController();
  final _number = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    _number.dispose();
    super.dispose();
  }

  /// Adds the name and number typed to those the space texts, and clears the fields once they are in.
  Future<void> _add() async {
    final ok = await SmsSpaces.instance.add(widget.space, _name.text, _number.text);
    if (!mounted) return;
    if (!ok) {
      toast(context, 'They couldn\'t be added: a number is needed, and once is enough.');
      return;
    }
    toast(context, '${_name.text.trim().isEmpty ? _number.text.trim() : _name.text.trim()} is texted now');
    _name.clear();
    _number.clear();
  }

  /// The circle's members, you first, each with how the space's messages reach them: the texter's phone sends them, a
  /// member the texter's phone knows the number of gets them by text, everyone else in the app. Only the texter's phone
  /// knows who is texted; another member sees only their own way in.
  List<({String id, String name, bool me, String? byText, String how})> _members() {
    final circle = Circles.instance.circleOf(widget.space);
    final s = smsSpaceOf(widget.space);
    final texter = s == null ? null : smsTexterOf(s);
    final mine = texter != null && texter == SmsSpaces.instance.me;
    final texted = {for (final p in SmsSpaces.instance.people(widget.space.seed)) if (p.member != null) p.member!: p.number};
    final myNumber = Me.instance.number ?? '';
    final people = circle == null ? const <CirclePerson>[] : circlePeople(circle);
    final out = <({String id, String name, bool me, String? byText, String how})>[];
    for (final p in [...people.where((p) => p.me), ...people.where((p) => !p.me)]) {
      if (p.me) {
        final how = mine
            ? (myNumber.isNotEmpty ? 'Your phone texts for this space from $myNumber. You see everything here.' : 'Your phone texts for this space. You see everything here.')
            : (myNumber.isNotEmpty ? '$myNumber is linked: its messages come to you by text, as well as here.' : 'In the app. Link your number in Settings › Me to get its messages by text too.');
        out.add((id: p.id, name: p.name, me: true, byText: myNumber.isEmpty ? null : myNumber, how: how));
      } else if (p.id == texter) {
        out.add((id: p.id, name: p.name, me: false, byText: null, how: 'Their phone texts for this space'));
      } else {
        final number = mine ? texted[p.id] : null;
        out.add((id: p.id, name: p.name, me: false, byText: number, how: number != null ? 'By text, $number, and in the app' : 'In the app'));
      }
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final s = smsSpaceOf(widget.space);
    final texter = s == null ? null : smsTexterOf(s);
    final mine = texter != null && texter == SmsSpaces.instance.me;
    return ListenableBuilder(
      listenable: SmsSpaces.instance,
      builder: (context, _) {
        final people = mine ? SmsSpaces.instance.people(widget.space.seed) : const <TextedPerson>[];
        return GhostPage(
          title: 'People by text',
          subtitle: widget.space.name,
          body: ListView(padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(2), t.space(4), t.space(8)), children: [
            SettingsCallout(
              child: Text(texter == null
                  ? 'This isn\'t an SMS space.'
                  : mine
                      ? 'Your phone texts for ${widget.space.name}: what is written here goes to each person below by text, from your number and on your plan, and what they text back comes in here. Keep Uplink running for it to carry on.'
                      : '${Voice.instance.nameOf(texter)}\'s phone texts for ${widget.space.name}: people without the app are in it by text, and what they send comes in marked 📱. Only that phone knows their numbers.'),
            ),
            // Everyone in the circle, you first, and how each gets the space's messages (Matt, 2026-11-19: "I created an
            // SMS space but I don't see a list of members including myself I should at the very least be included on
            // the text list since I have my phone number linked").
            if (texter != null) ...[
              SizedBox(height: t.space(5)),
              PaneSection(title: 'Members', children: [
                for (final m in _members())
                  SettingRow(
                    key: ValueKey('sms-member-${m.id}'),
                    icon: AppIcon(m.byText != null ? Lucide.smartphone : Lucide.messageSquare, size: 18),
                    label: m.me ? 'You' : m.name,
                    hint: Text(m.how),
                  ),
              ]),
            ],
            if (mine) ...[
              SizedBox(height: t.space(5)),
              PaneSection(title: 'In it by text', children: [
                if (people.isEmpty) const SettingRowBox(child: Tr('Nobody yet. Members whose number is linked to Uplink are added by themselves when they come in; add anyone else below. Each gets a text saying how it works and how to leave.')),
                for (final p in people)
                  SettingRow(
                    key: ValueKey('texted-${p.number}'),
                    icon: AppIcon(Lucide.smartphone, size: 18),
                    label: p.name,
                    // A member come in by themselves, or someone added here.
                    hint: Text(p.member != null ? '${p.number} · a member, by their linked number' : p.number),
                    onPress: () => showChoices(context, title: p.name, choices: [
                      Choice('Take out of the space', Lucide.userMinus, () => SmsSpaces.instance.remove(widget.space, p.number), danger: true),
                    ]),
                  ),
              ]),
              SizedBox(height: t.space(5)),
              PaneSection(title: 'Add someone by text', children: [
                SettingRowBox(child: GlacierInput(controller: _name, placeholder: 'Name'.t, ariaLabel: 'Their name', autoCapitalize: TextCapitalization.words, size: GlacierFieldSize.md)),
                SettingRowBox(child: GlacierInput(controller: _number, placeholder: 'Phone number'.t, ariaLabel: 'Their phone number', inputMode: TextInputType.phone, size: GlacierFieldSize.md)),
                SettingRow(key: const ValueKey('texted-add'), icon: AppIcon(Lucide.userPlus, size: 18), label: 'Add and text them', onPress: _add),
              ]),
            ],
          ]),
        );
      },
    );
  }
}
