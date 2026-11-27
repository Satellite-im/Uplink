import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../art/app_icon.dart';
import '../art/lucide.g.dart';
import '../friends/friends.dart';
import '../friends/groups.dart';
import '../kit/settings_type.dart';
import '../sms.dart';
import 'common.dart';
import 'shell.dart';
import '../l10n/words.dart';

/// A new group of friends (Matt, 2026-11-14: "expand on the ability to create, name and manage groups like
/// telegram"): its name, and which friends are in it. Made, it opens as its own conversation, with whoever made it
/// as its admin (lib/friends/groups.dart). Reached from the address book, where there is a friend to put in one.
class NewGroupScreen extends StatefulWidget {
  const NewGroupScreen({super.key});

  @override
  State<NewGroupScreen> createState() => _NewGroupState();
}

class _NewGroupState extends State<NewGroupScreen> {
  final _name = TextEditingController();
  final _chosen = <String>{};
  bool _making = false;

  @override
  void initState() {
    super.initState();
    Friends.instance.addListener(_changed);
  }

  @override
  void dispose() {
    Friends.instance.removeListener(_changed);
    _name.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  /// Makes the group of the friends chosen and opens its conversation.
  Future<void> _make() async {
    if (_chosen.isEmpty || _making) return;
    setState(() => _making = true);
    try {
      final group = await Groups.instance.create(_name.text, _chosen.toList());
      if (!mounted) return;
      // Its conversation takes this page's place.
      final shell = AppShell.maybeOf(context);
      final people = [for (final m in group.others) m.person];
      if (shell != null) {
        shell.openThread(group.thread, people);
      } else {
        Navigator.of(context).maybePop();
      }
    } catch (e) {
      if (mounted) {
        setState(() => _making = false);
        toast(context, e is StateError ? e.message : 'Couldn\'t make the group', tone: GlacierToastTone.danger);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final friends = Friends.instance.friends;
    final ready = _chosen.isNotEmpty && !_making;
    return GhostPage(
      title: 'New group',
      back: true,
      actions: [
        Padding(
          padding: EdgeInsetsDirectional.only(end: t.space(2)),
          child: GlacierPressable(
            onPressed: ready ? _make : null,
            semanticLabel: 'Create group',
            builder: (context, state) => Container(
              padding: EdgeInsets.symmetric(horizontal: t.space(4), vertical: t.space(2)),
              decoration: BoxDecoration(color: t.color(ready ? 'app-ink' : 'app-paper-3'), borderRadius: BorderRadius.circular(t.lenOf('1.2rem'))),
              child: Text('Create', style: pageText(t, t.fontSize('sm'), weight: 'semibold', color: t.color(ready ? 'app-paper' : 'app-ink-3'))),
            ),
          ),
        ),
      ],
      body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: EdgeInsetsDirectional.fromSTEB(t.space(4), 0, t.space(4), t.space(3)),
          child: GlacierInput(controller: _name, placeholder: 'Group name'.t, ariaLabel: 'Group name', size: GlacierFieldSize.md),
        ),
        Padding(
          padding: EdgeInsetsDirectional.fromSTEB(t.space(4), 0, t.space(4), t.space(2)),
          child: Text(
            _chosen.isEmpty ? 'Choose who is in it. A group is made of friends, and you can add more later.' : '${_chosen.length} chosen. You will be its admin.',
            style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-3')),
          ),
        ),
        Expanded(
          child: ListView(
            padding: EdgeInsets.only(bottom: t.space(6)),
            children: [
              for (final f in friends)
                _FriendRow(
                  person: f.person ?? Person(address: f.address),
                  chosen: _chosen.contains(f.address),
                  onPressed: () => setState(() => _chosen.contains(f.address) ? _chosen.remove(f.address) : _chosen.add(f.address)),
                ),
            ],
          ),
        ),
      ]),
    );
  }
}

/// A friend to put in the group: their face and name, pressed to choose them or not.
class _FriendRow extends StatelessWidget {
  const _FriendRow({required this.person, required this.chosen, required this.onPressed});
  final Person person;
  final bool chosen;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return GlacierPressable(
      onPressed: onPressed,
      semanticLabel: '${person.label}, ${chosen ? 'chosen' : 'not chosen'}',
      builder: (context, state) => ColoredBox(
        color: state.pressed || state.hovered ? t.color('app-paper-2') : const Color(0x00000000),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: t.space(4), vertical: t.space(2) + 2),
          child: Row(children: [
            Avatar(people: [person], size: t.lenOf('2.5rem')),
            SizedBox(width: t.space(3)),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(person.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('md'), weight: 'medium')),
                if (person.name != null) Text(person.address, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-3'))),
              ]),
            ),
            // A ring, filled with a tick once chosen.
            Container(
              width: t.lenOf('1.5rem'),
              height: t.lenOf('1.5rem'),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: chosen ? t.color('app-ink') : const Color(0x00000000),
                border: Border.all(color: t.color(chosen ? 'app-ink' : 'app-ink-4'), width: 1.5),
              ),
              child: chosen ? Center(child: AppIcon(Lucide.check, size: 14, strokeWidth: 3, wash: false, color: t.color('app-paper'))) : null,
            ),
          ]),
        ),
      ),
    );
  }
}
