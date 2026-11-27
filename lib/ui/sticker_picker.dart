import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../app_state.dart';
import '../kit/settings_type.dart';
import '../stickers.dart';
import '../kit/semantic_colors.dart';

/// The stickers, in a sheet rising from the conversation's foot (Matt, 2026-11-13: "generate 4 sticker packs using
/// our ghost mascot"): the packs across the top, the chosen pack's stickers under them. A tap on a sticker sends it,
/// so this answers with the sticker's asset, or with nothing where the sheet was put away.
///
/// [encrypted]: the conversation is an encrypted one. A sticker goes as a picture message, which is not sealed, and
/// the sheet says so before one is sent.
Future<String?> pickSticker(BuildContext context, {bool encrypted = false}) {
  return Navigator.of(context).push<String>(PageRouteBuilder<String>(
    opaque: false,
    barrierDismissible: true,
    barrierColor: context.tokens.sheetScrim,
    transitionDuration: const Duration(milliseconds: 220),
    reverseTransitionDuration: const Duration(milliseconds: 180),
    pageBuilder: (context, _, _) => StickerSheet(encrypted: encrypted),
    transitionsBuilder: (context, a, _, child) => SlideTransition(
      position: Tween(begin: const Offset(0, 1), end: Offset.zero).animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic)),
      child: child,
    ),
  ));
}

/// The stickers as a sheet from the foot of the screen: a tab for each pack over the pack chosen.
class StickerSheet extends StatefulWidget {
  const StickerSheet({super.key, this.encrypted = false, this.packs});
  final bool encrypted;

  /// The packs to show, where they are already in hand (the screen pictures test); else read from what is bundled.
  final List<StickerPack>? packs;

  @override
  State<StickerSheet> createState() => _StickerSheetState();
}

class _StickerSheetState extends State<StickerSheet> {
  List<StickerPack>? _packs;
  String? _pack;

  /// Each pack's tab, to bring the chosen one into view where the row slides.
  final _tabs = <String, GlobalKey>{};
  bool _broughtIntoView = false;

  @override
  void initState() {
    super.initState();
    _packs = widget.packs;
    if (_packs == null) {
      stickerPacks().then((p) {
        if (mounted) setState(() => _packs = p);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final app = AppState.of(context);
    final pad = MediaQuery.paddingOf(context);
    final screen = MediaQuery.sizeOf(context);
    final packs = _packs;
    // The pack last used is the one it opens on.
    final wanted = _pack ?? app.choice('sticker_pack', '');
    final pack = packs == null || packs.isEmpty ? null : packs.firstWhere((p) => p.id == wanted, orElse: () => packs.first);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return Align(
      alignment: Alignment.bottomCenter,
      child: Padding(
        padding: EdgeInsetsDirectional.fromSTEB(t.space(3), 0, t.space(3), pad.bottom + t.space(3)),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(t.radius('xl')),
          child: ColoredBox(
            color: t.color('app-paper-2'),
            child: ConstrainedBox(
              // Wide enough to read on an unfolded phone without being a wall of ghosts.
              constraints: BoxConstraints(maxWidth: t.lenOf('34rem'), maxHeight: (screen.height * 0.52).clamp(280.0, 460.0)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                // The packs: each a tab, named, with its first sticker for a face. Up to four share the sheet's width,
                // so all are in reach on the narrowest screen; more than that and the row slides.
                Padding(
                  padding: EdgeInsetsDirectional.fromSTEB(t.space(3), t.space(3), t.space(3), t.space(1)),
                  child: LayoutBuilder(builder: (context, box) {
                    final all = packs ?? const <StickerPack>[];
                    final gap = t.lenOf('0.4rem');
                    final sliding = all.length > 4;
                    Widget tab(StickerPack p) => GlacierPressable(
                          onPressed: () {
                            // A tab half off the edge slides into view as it is chosen.
                            setState(() {
                              _pack = p.id;
                              _broughtIntoView = false;
                            });
                            app.set('sticker_pack', p.id);
                          },
                          semanticLabel: '${p.name} stickers',
                          builder: (context, state) {
                            final on = p.id == pack?.id;
                            return Container(
                              height: t.lenOf('2.4rem'),
                              padding: EdgeInsets.symmetric(horizontal: t.lenOf(sliding ? '0.7rem' : '0.4rem')),
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: on ? t.color('app-ink') : (state.pressed ? t.color('app-paper-3') : const Color(0x00000000)),
                                borderRadius: BorderRadius.circular(t.lenOf('1.2rem')),
                                border: Border.all(color: on ? t.color('app-ink') : t.color('app-rule')),
                              ),
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Row(mainAxisSize: MainAxisSize.min, children: [
                                  Image.asset(p.stickers.first, width: t.lenOf('1.5rem'), height: t.lenOf('1.5rem'), cacheWidth: (t.lenOf('1.5rem') * dpr).round()),
                                  SizedBox(width: t.space(1)),
                                  Text(p.name, style: pageText(t, t.fontSize('sm'), weight: 'semibold', color: on ? t.color('app-paper') : t.color('app-ink'))),
                                ]),
                              ),
                            );
                          },
                        );
                    if (!sliding) {
                      return Row(children: [
                        for (final (i, p) in all.indexed) ...[if (i > 0) SizedBox(width: gap), Expanded(child: tab(p))],
                      ]);
                    }
                    // The pack it opens on is brought into view, once: the last one used may be off to the right.
                    if (!_broughtIntoView && pack != null) {
                      _broughtIntoView = true;
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        final there = _tabs[pack.id]?.currentContext;
                        if (there != null) Scrollable.ensureVisible(there, alignment: 0.5);
                      });
                    }
                    return SizedBox(
                      width: box.maxWidth,
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(children: [
                          for (final (i, p) in all.indexed) ...[
                            if (i > 0) SizedBox(width: gap),
                            KeyedSubtree(key: _tabs.putIfAbsent(p.id, GlobalKey.new), child: tab(p)),
                          ],
                        ]),
                      ),
                    );
                  }),
                ),
                if (widget.encrypted)
                  Padding(
                    padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(1), t.space(4), 0),
                    child: Text('Stickers go as picture messages, which aren\'t encrypted.', style: pageText(t, t.fontSize('xs'), color: t.color('app-ink-3'))),
                  ),
                Expanded(
                  child: pack == null
                      ? Center(child: Text(packs == null ? '' : 'No stickers in this copy of the app.', style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-3'))))
                      : GridView.builder(
                          key: ValueKey(pack.id),
                          padding: EdgeInsetsDirectional.fromSTEB(t.space(3), t.space(2), t.space(3), t.space(3)),
                          gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: t.lenOf('6rem'), mainAxisSpacing: t.space(1), crossAxisSpacing: t.space(1)),
                          itemCount: pack.stickers.length,
                          itemBuilder: (context, i) {
                            final asset = pack.stickers[i];
                            return GlacierPressable(
                              onPressed: () => Navigator.of(context).pop(asset),
                              semanticLabel: '${pack.name} sticker ${i + 1}',
                              builder: (context, state) => AnimatedScale(
                                scale: state.pressed ? 0.9 : 1,
                                duration: const Duration(milliseconds: 110),
                                child: Container(
                                  decoration: BoxDecoration(color: state.pressed ? t.color('app-paper-3') : const Color(0x00000000), borderRadius: BorderRadius.circular(t.radius('md'))),
                                  padding: EdgeInsets.all(t.lenOf('0.2rem')),
                                  child: Image.asset(asset, cacheWidth: (t.lenOf('6rem') * dpr).round(), filterQuality: FilterQuality.medium),
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
