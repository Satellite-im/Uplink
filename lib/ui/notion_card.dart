/// A Notion link in a circle's chat, opened out under its message (lib/plugins/notion.dart): a page as its title,
/// what its database says of it and how it begins; a database as a board, a column for each status with its first
/// few rows. Drawn in bones while Notion is asked, and as a line saying why where it could not be read. A press
/// opens it in Notion.
library;

import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../art/app_icon.dart';
import '../art/lucide.g.dart';
import '../backgrounds.dart' show lookCorner;
import '../kit/settings_type.dart';
import '../notion/notion.dart';
import '../plugins/notion.dart';
import '../sms.dart';
import '../voice/voice.dart' show VoiceChannel;
import 'skeleton.dart';

/// The cards for the Notion links in [text], written in [space]: none where the space's circle has no Notion, and
/// none for words with no Notion link in them.
List<Widget> notionCardsUnder(BuildContext context, VoiceChannel space, String text, {double maxWidth = 420}) {
  if (text.isEmpty || !text.contains('notion.')) return const [];
  final reader = NotionCircle.readerFor(space);
  if (reader == null) return const [];
  final t = context.tokens;
  return [
    for (final link in NotionLink.allIn(text))
      Padding(padding: EdgeInsets.only(top: t.space(1) + 2), child: NotionLinkCard(key: ValueKey('notion-${link.id}'), reader: reader, link: link, maxWidth: maxWidth)),
  ];
}

class NotionLinkCard extends StatefulWidget {
  const NotionLinkCard({super.key, required this.reader, required this.link, this.maxWidth = 420});
  final Notion reader;
  final NotionLink link;
  final double maxWidth;

  @override
  State<NotionLinkCard> createState() => _NotionLinkCardState();
}

class _NotionLinkCardState extends State<NotionLinkCard> {
  NotionCard? _card;
  NotionError? _error;

  @override
  void initState() {
    super.initState();
    _card = widget.reader.kept(widget.link);
    if (_card == null) _read();
  }

  @override
  void didUpdateWidget(NotionLinkCard old) {
    super.didUpdateWidget(old);
    if (old.link.id != widget.link.id || !identical(old.reader, widget.reader)) {
      _card = widget.reader.kept(widget.link);
      _error = null;
      if (_card == null) _read();
    }
  }

  Future<void> _read({bool fresh = false}) async {
    final link = widget.link, reader = widget.reader;
    try {
      final card = await reader.card(link, fresh: fresh);
      if (mounted && link.id == widget.link.id) setState(() { _card = card; _error = null; });
    } on NotionError catch (e) {
      if (mounted && link.id == widget.link.id) setState(() => _error = e);
    }
  }

  void _open() => Sms.instance.openLink(_card?.url ?? widget.link.url);

  /// Notion's own names for its colours, as marks on a card.
  static Color _hue(Tokens t, String? colour) => t.colorOf(switch (colour) {
        'blue' => '#3b82f6',
        'green' => '#22a565',
        'yellow' => '#d9a514',
        'orange' => '#e08a1e',
        'red' => '#d9534f',
        'purple' => '#8a5cf6',
        'pink' => '#d6579b',
        'brown' => '#9a6b4f',
        _ => '#8a8a8a',
      });

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final card = _card, error = _error;
    final Widget inside;
    if (card != null) {
      inside = card.isBoard ? _board(t, card) : _page(t, card);
    } else if (error != null) {
      inside = Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        AppIcon(Lucide.fileText, size: 16, color: t.color('app-ink-3'), wash: false),
        SizedBox(width: t.space(2)),
        Expanded(child: Text(error.words, style: pageText(t, t.fontSize('xs'), color: t.color('app-ink-3'), height: 1.35))),
      ]);
    } else {
      inside = const SkeletonLines(label: 'Reading Notion…', most: 3, padding: EdgeInsets.zero, shrink: true);
    }
    return GlacierPressable(
      onPressed: _open,
      semanticLabel: card == null ? 'Notion link' : 'Notion: ${card.title}. Open in Notion',
      builder: (context, state) => Container(
        key: const ValueKey('notion-card'),
        constraints: BoxConstraints(maxWidth: widget.maxWidth),
        padding: EdgeInsets.all(t.space(3)),
        decoration: BoxDecoration(
          color: t.color(state.hovered || state.pressed ? 'app-paper-3' : 'app-paper-2'),
          borderRadius: BorderRadius.circular(lookCorner(t, '0.85rem')),
          border: Border.all(color: t.color('app-rule'), width: 1),
        ),
        child: inside,
      ),
    );
  }

  Widget _head(Tokens t, NotionCard card, {String? trailing}) => Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        if (card.icon != null) Padding(padding: EdgeInsetsDirectional.only(end: t.space(2)), child: Text(card.icon!, style: TextStyle(fontSize: t.fontSize('md'))))
        else Padding(padding: EdgeInsetsDirectional.only(end: t.space(2)), child: AppIcon(card.isBoard ? Lucide.squareKanban : Lucide.fileText, size: 16, color: t.color('app-ink-2'), wash: false)),
        Expanded(child: Text(card.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('sm'), weight: 'semibold', color: t.color('app-ink')))),
        if (trailing != null) Padding(padding: EdgeInsetsDirectional.only(start: t.space(2)), child: Text(trailing, style: pageText(t, t.fontSize('xs'), color: t.color('app-ink-3')))),
      ]);

  Widget _source(Tokens t) => Padding(
        padding: EdgeInsets.only(top: t.space(2)),
        child: Text('Notion', style: pageText(t, t.fontSize('xs'), weight: 'medium', color: t.color('app-ink-3'))),
      );

  Widget _page(Tokens t, NotionCard card) => Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        _head(t, card),
        if (card.facts.isNotEmpty)
          Padding(
            padding: EdgeInsets.only(top: t.space(2)),
            child: Wrap(spacing: t.space(2), runSpacing: t.space(1), children: [
              for (final f in card.facts)
                Container(
                  padding: EdgeInsets.symmetric(horizontal: t.space(2), vertical: 2),
                  decoration: BoxDecoration(
                    color: f.colour == null ? t.color('app-paper') : _hue(t, f.colour).withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(lookCorner(t, '0.5rem')),
                  ),
                  child: Text.rich(
                    TextSpan(children: [
                      TextSpan(text: '${f.name}  ', style: pageText(t, t.fontSize('xs'), color: t.color('app-ink-3'))),
                      TextSpan(text: f.value),
                    ]),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: pageText(t, t.fontSize('xs'), weight: 'medium', color: t.color('app-ink')),
                  ),
                ),
            ]),
          ),
        if (card.excerpt.isNotEmpty)
          Padding(
            padding: EdgeInsets.only(top: t.space(2)),
            child: Text(card.excerpt, maxLines: 4, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('xs'), color: t.color('app-ink-2'), height: 1.4)),
          ),
        _source(t),
      ]);

  /// The most of a column's rows drawn, and the most columns before the board scrolls sideways.
  static const _rowsShown = 4;

  Widget _board(Tokens t, NotionCard card) {
    final columns = card.columns!;
    final count = '${card.count}${card.more ? '+' : ''} ${card.count == 1 && !card.more ? 'page' : 'pages'}';
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      _head(t, card, trailing: count),
      if (columns.isEmpty)
        Padding(padding: EdgeInsets.only(top: t.space(2)), child: Text('Nothing in it yet', style: pageText(t, t.fontSize('xs'), color: t.color('app-ink-3'))))
      else
        Padding(
          padding: EdgeInsets.only(top: t.space(2)),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              for (final (i, c) in columns.indexed)
                Container(
                  key: ValueKey('notion-column-${c.name}'),
                  width: 168,
                  margin: EdgeInsetsDirectional.only(end: i == columns.length - 1 ? 0 : t.space(2)),
                  padding: EdgeInsets.all(t.space(2)),
                  decoration: BoxDecoration(color: t.color('app-paper'), borderRadius: BorderRadius.circular(lookCorner(t, '0.6rem'))),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                    Row(children: [
                      Container(width: 8, height: 8, decoration: BoxDecoration(color: _hue(t, c.colour), shape: BoxShape.circle)),
                      SizedBox(width: t.space(1) + 2),
                      Expanded(child: Text(c.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('xs'), weight: 'semibold', color: t.color('app-ink')))),
                      Text('${c.rows.length}', style: pageText(t, t.fontSize('xs'), color: t.color('app-ink-3'))),
                    ]),
                    for (final r in c.rows.take(_rowsShown))
                      Padding(
                        padding: EdgeInsets.only(top: t.space(1) + 2),
                        child: Text('${r.icon == null ? '' : '${r.icon} '}${r.title}', maxLines: 2, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('xs'), color: t.color('app-ink-2'), height: 1.3)),
                      ),
                    if (c.rows.length > _rowsShown)
                      Padding(
                        padding: EdgeInsets.only(top: t.space(1) + 2),
                        child: Text('and ${c.rows.length - _rowsShown} more', style: pageText(t, t.fontSize('xs'), color: t.color('app-ink-3'))),
                      ),
                  ]),
                ),
            ]),
          ),
        ),
      _source(t),
    ]);
  }
}
