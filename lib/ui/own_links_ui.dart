import 'dart:async';

import 'package:flutter/services.dart' show Clipboard, ClipboardData, TextCapitalization;
import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../art/app_icon.dart';
import '../art/lucide.g.dart';
import '../friends/buddies.dart';
import '../kit/semantic_colors.dart';
import '../kit/settings_kit.dart';
import '../kit/settings_type.dart';
import '../me/me.dart';
import '../me/own_links.dart';
import '../sms.dart' show Sms;
import 'common.dart';

// Links of your own on your profile (GMFB-34: "Linked accounts shown on the profile (self-declared links)";
// lib/me/own_links.dart): typed on the profile page, shown on your card to friends as what you say, and opened only on
// a press that shows the whole address first.

/// What a card says over someone's own links: whose word they are.
String ownLinksWords(String name, {bool mine = false}) => mine ? 'Your friends see these as what you say. Nothing checks them.' : '$name says these are theirs. Nothing checks them.';

/// Profile › Links: the links you typed, each removed on a press, and the two fields to add one.
class OwnLinksSection extends StatefulWidget {
  const OwnLinksSection({super.key});

  @override
  State<OwnLinksSection> createState() => _OwnLinksSectionState();
}

class _OwnLinksSectionState extends State<OwnLinksSection> {
  final _label = TextEditingController();
  final _address = TextEditingController();
  String? _problem;

  @override
  void dispose() {
    _label.dispose();
    _address.dispose();
    super.dispose();
  }

  void _keep(List<OwnLink> links) {
    Me.instance.setOwnLinks(links);
    Buddies.instance.shareProfile();
  }

  void _add() {
    final me = Me.instance;
    final label = OwnLink.tidyLabel(_label.text), address = OwnLink.tidyAddress(_address.text);
    final had = me.ownLinks;
    final problem = had.length >= OwnLink.most
        ? 'A profile has ${OwnLink.most} links at most.'
        : (had.any((l) => l.address == address) ? 'That link is on your profile already.' : OwnLink.problemOf(label, address));
    if (problem != null) {
      setState(() => _problem = problem);
      return;
    }
    _keep([...had, OwnLink(label, address)]);
    _label.clear();
    _address.clear();
    setState(() => _problem = null);
    toast(context, 'Added. Your friends will see it.');
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final me = Me.instance;
    Widget field(TextEditingController c, String placeholder, String label, {Key? key, ValueChanged<String>? onSubmitted, TextCapitalization caps = TextCapitalization.none}) => SettingRowBox(
          child: GlacierInput(key: key, controller: c, placeholder: placeholder, ariaLabel: label, autoCorrect: false, autoCapitalize: caps, size: GlacierFieldSize.md, onSubmitted: onSubmitted),
        );
    return ListenableBuilder(
      listenable: me,
      builder: (context, _) {
        final links = me.ownLinks;
        return PaneSection(
          title: 'Links',
          description: Text('Up to ${OwnLink.most} links of your own, like a website or a page of yours somewhere. Friends see them on your profile card as what you say: nothing checks them.'),
          footer: _problem == null ? null : Text(_problem!, key: const ValueKey('own-links-problem'), style: TextStyle(color: t.danger)),
          children: [
            for (final (i, l) in links.indexed)
              SettingRow(
                key: ValueKey('own-link-$i'),
                icon: AppIcon(Lucide.link, size: 18),
                label: l.label,
                hint: Text(l.short),
                onPress: () => showChoices(context, title: '${l.label}\n${l.address}', choices: [
                  Choice('Remove this link', Lucide.trash2, () => _keep([for (final x in me.ownLinks) if (x != l) x]), danger: true),
                ]),
              ),
            if (links.length < OwnLink.most) ...[
              field(_label, 'A name, like Website', 'Link name', key: const ValueKey('own-link-label'), caps: TextCapitalization.sentences),
              field(_address, 'https://', 'Link address', key: const ValueKey('own-link-address'), onSubmitted: (_) => _add()),
              SettingRow(key: const ValueKey('own-link-add'), icon: AppIcon(Lucide.plus, size: 18), label: 'Add this link', onPress: _add),
            ],
          ],
        );
      },
    );
  }
}

/// Asks before [link] is opened, showing where it goes in full: whose word it is ([name]), then Open and Copy.
Future<void> askOpenOwnLink(BuildContext context, OwnLink link, String name, {bool mine = false}) => showChoices(
      context,
      title: '${mine ? 'Your link' : '$name says this is theirs'}. It goes to:\n${link.address}',
      choices: [
        Choice('Open ${link.host}', Lucide.externalLink, () => unawaited(Sms.instance.openLink(link.address)), hint: 'In your browser'),
        Choice('Copy the address', Lucide.copy, () {
          unawaited(Clipboard.setData(ClipboardData(text: link.address)));
          toast(context, 'Copied');
        }),
      ],
    );

/// Someone's own links on their card, under Elsewhere: whose word they are, then each by its name with where it goes,
/// opened only on a press and a yes ([askOpenOwnLink]).
class OwnLinksList extends StatelessWidget {
  const OwnLinksList({super.key, required this.links, required this.name, this.mine = false});
  final List<OwnLink> links;
  final String name;
  final bool mine;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Column(key: const ValueKey('profile-own-links'), crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      Padding(
        padding: EdgeInsets.only(top: t.space(1)),
        child: Text(ownLinksWords(name, mine: mine), style: pageText(t, t.fontSize('xs'), color: t.color('app-ink-3'), height: 1.4)),
      ),
      for (final (i, l) in links.indexed)
        GlacierPressable(
          key: ValueKey('profile-own-link-$i'),
          onPressed: () => unawaited(askOpenOwnLink(context, l, name, mine: mine)),
          semanticLabel: '${l.label}: ${l.short}. ${mine ? 'Your link' : '$name says this is theirs'}',
          builder: (context, state) => GlacierFocusRing(
            visible: state.focused,
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: t.space(1)),
              child: Row(children: [
                SizedBox(width: t.lenOf('5.5rem'), child: Text(l.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-3')))),
                Expanded(child: Text(l.short, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('sm'), weight: 'medium', color: t.color(state.hovered || state.pressed ? 'app-ink-2' : 'app-ink')))),
                AppIcon(Lucide.externalLink, size: 14, color: t.color('app-ink-3')),
              ]),
            ),
          ),
        ),
    ]);
  }
}
