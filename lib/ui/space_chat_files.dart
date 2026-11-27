/// Files, GIFs, stickers and voice messages in a space's chat (Matt, 2026-11-18: "I also want full support for uploading
/// attachements gifs stickers etc like we support in other chats"): who may send them, and how they are drawn.
///
/// - **Who may.** Whoever may write in the space ([HangoutRoom.mayWrite]: its roster's Send messages) and, in a circle,
///   whose circle roles let them write; a file needs the circle's Share files too ([spaceMayAttach]), a sticker only
///   writing. A Files space's own Add files is for its list, which a chat's files never go in.
/// - **Coming in.** A picture shows its small picture at once (it came in the message) and, where it is no bigger than
///   [autoFetchMost], brings the file itself down as it is drawn and shows that (a GIF moving); a tap opens it whole.
///   A video shows its frame with Play and opens in the app's player, played as it comes down; a voice message or any
///   other file is a chip with its mark, name and size that opens it as a Files space's file opens (Save, Share).
/// - **Going out.** [SpaceOutgoing]: the message as it will be, its pictures from the disk, with how far it has got,
///   or why it stopped and a try again.
library;

import 'dart:async';
import 'dart:io';
import '../platform_info.dart';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../art/app_icon.dart';
import '../art/lucide.g.dart';
import '../backgrounds.dart';
import '../circles/circles.dart' show Circles, CirclePerm;
import '../files/files_store.dart';
import '../kit/settings_type.dart';
import '../stickers.dart';
import '../voice/hangout.dart';
import '../voice/voice.dart' show VoiceChannel;
import '../kit/semantic_colors.dart';
import '../sms.dart' show Sms;
import 'common.dart';
import 'picture_overlay.dart';
import 'files_space/file_badge.dart';
import 'files_space/file_preview.dart' show openSpaceFile;

/// Whether this device may write in [room]'s chat: the space's roster, and in a circle its roles (CirclePerm.write).
bool spaceMayWrite(HangoutRoom room, {Circles? circles}) => room.mayWrite && (circles ?? Circles.instance).allows(room.channel, CirclePerm.write);

/// Whether this device may send files in [room]'s chat: whoever may write, and in a circle whose roles let them share
/// files (CirclePerm.files, on for everyone unless the owner took it off).
bool spaceMayAttach(HangoutRoom room, {Circles? circles}) => spaceMayWrite(room, circles: circles) && (circles ?? Circles.instance).allows(room.channel, CirclePerm.files);

/// A picture no bigger than this comes down by itself as it is drawn; a bigger one waits for a tap.
const autoFetchMost = 12 << 20;

/// Whether [f] is a picture the app draws itself: not an SVG, and a HEIC only where this device reads one (an Android
/// phone, an iPhone, a Mac: [FileKind.drawsAsPicture]). It was never a HEIC, so one was a file's chip in every chat and
/// "Open with" on its page, on the phones that took it (GMFB-60).
bool drawsPicture(SpaceFile f) => FileKind.drawsAsPicture(f.name, f.mime);

/// A message's files in its bubble's place: its pictures and videos as pictures (two across where there are several),
/// then a chip for each other file.
class SpaceChatFiles extends StatelessWidget {
  const SpaceChatFiles({super.key, required this.channel, required this.message, required this.maxWidth, required this.ground, required this.ink, this.mine = false, this.store, this.rim});
  final VoiceChannel channel;
  final HangoutMessage message;

  /// Your own: laid against the right, as your bubbles are.
  final bool mine;
  final double maxWidth;

  /// The bubble's colours, for a file's chip.
  final Color ground, ink;
  final Border? rim;
  final FilesStore? store;

  @override
  Widget build(BuildContext context) {
    // A page in a browser keeps no files and opens none yet (Files is not in a page: lib/web/app.dart): each file is
    // shown as what it is, a picture by the small picture that came in the message, and says where it opens.
    if (Sms.browser) return SpaceFilesNotHere(message: message, mine: mine, maxWidth: maxWidth, ground: ground, ink: ink, rim: rim);
    final t = context.tokens;
    final s = store ?? FilesStore.instance;
    final pictures = [for (final f in message.files) if (drawsPicture(f) || f.kind == FileKind.video) f];
    final others = [for (final f in message.files) if (!pictures.contains(f)) f];
    final gap = t.space(1);
    final round = BorderRadius.circular(lookCorner(t, '1rem', most: 1));
    final width = math.min(maxWidth, t.lenOf('17rem'));
    return Column(crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      if (pictures.length == 1)
        _Picture(channel: channel, file: pictures.first, store: s, width: width, height: _heightOf(pictures.first, width), radius: round)
      else if (pictures.length > 1)
        SizedBox(
          width: width,
          child: Wrap(spacing: gap, runSpacing: gap, children: [
            for (final f in pictures) _Picture(channel: channel, file: f, store: s, width: (width - gap) / 2, height: (width - gap) / 2, radius: round),
          ]),
        ),
      for (final f in others)
        Padding(
          padding: EdgeInsets.only(top: pictures.isEmpty && f == others.first ? 0 : gap),
          child: _FileChip(channel: channel, file: f, store: s, voice: message.voice, ground: ground, ink: ink, rim: rim, maxWidth: width),
        ),
    ]);
  }

  /// A lone picture as tall as its shape says, kept between half and one and a third of its width.
  static double _heightOf(SpaceFile f, double width) => f.width > 0 && f.height > 0 ? (width * f.height / f.width).clamp(width * 0.5, width * 1.34) : width * 0.75;
}

/// What a page in a browser shows of a message's files ([SpaceChatFiles]): a picture or video by the small picture
/// that came in the message, where it did, and every file as a chip with its mark, name and size, saying it opens on a
/// phone or a computer. Nothing is fetched or looked for on a disk, and a press says the same.
class SpaceFilesNotHere extends StatelessWidget {
  const SpaceFilesNotHere({super.key, required this.message, required this.maxWidth, required this.ground, required this.ink, this.mine = false, this.rim});
  final HangoutMessage message;
  final bool mine;
  final double maxWidth;
  final Color ground, ink;
  final Border? rim;

  static const words = 'Files can\'t be opened in a browser yet. This one opens in Uplink on a phone or a computer.';

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final width = math.min(maxWidth, t.lenOf('17rem'));
    final round = BorderRadius.circular(lookCorner(t, '1rem', most: 1));
    return Column(crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      for (final f in message.files)
        Padding(
          padding: EdgeInsets.only(top: f == message.files.first ? 0 : t.space(1)),
          child: GlacierPressable(
            key: ValueKey('space-file-not-here-${f.id}'),
            onPressed: () => toast(context, words),
            semanticLabel: '${message.voice ? 'Voice message' : f.name}, ${fileSize(f.size)}. Opens on a phone or a computer',
            builder: (context, state) => ConstrainedBox(
              constraints: BoxConstraints(maxWidth: width),
              child: Container(
                decoration: BoxDecoration(color: ground, border: rim, borderRadius: round),
                clipBehavior: Clip.antiAlias,
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
                  if ((drawsPicture(f) || f.kind == FileKind.video) && f.thumb != null)
                    Image.memory(f.thumb!, width: width, height: SpaceChatFiles._heightOf(f, width), fit: BoxFit.cover, gaplessPlayback: true, filterQuality: FilterQuality.medium, errorBuilder: (_, _, _) => const SizedBox.shrink()),
                  Padding(
                    padding: EdgeInsets.all(t.space(2)),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      FileBadge(kind: f.kind, size: 36),
                      SizedBox(width: t.space(2)),
                      Flexible(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                          Text(message.voice ? 'Voice message' : f.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('sm'), weight: 'semibold', color: ink)),
                          Text('${fileSize(f.size)} · opens on a phone or a computer', maxLines: 2, style: pageText(t, t.fontSize('xs'), color: ink.withValues(alpha: 0.7))),
                        ]),
                      ),
                    ]),
                  ),
                ]),
              ),
            ),
          ),
        ),
    ]);
  }
}

/// A picture, GIF or video in a message: its small picture at once, the file itself once it is here (a picture brought
/// down as it is drawn, where small enough), and a tap that opens it.
class _Picture extends StatefulWidget {
  const _Picture({required this.channel, required this.file, required this.store, required this.width, required this.height, required this.radius});
  final VoiceChannel channel;
  final SpaceFile file;
  final FilesStore store;
  final double width, height;
  final BorderRadius radius;

  @override
  State<_Picture> createState() => _PictureState();
}

class _PictureState extends State<_Picture> {
  String? _path;

  @override
  void initState() {
    super.initState();
    _bring();
  }

  @override
  void didUpdateWidget(_Picture old) {
    super.didUpdateWidget(old);
    if (old.file.id != widget.file.id) {
      _path = null;
      _bring();
    }
  }

  /// The picture's file: from the store's cache if it is there, else brought down, unless it is over [autoFetchMost].
  void _bring() {
    final f = widget.file;
    if (!drawsPicture(f)) return;
    _path = widget.store.cached(f);
    if (_path != null || f.size > autoFetchMost) return;
    // Brought down once and kept (FilesStore's cache): every later drawing has it from the disk. Out of reach, the small
    // picture stands, and a tap tries again in the preview.
    unawaited(widget.store.fetch(widget.channel, f).then((p) {
      if (mounted) setState(() => _path = p);
    }, onError: (Object _) {}));
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final f = widget.file;
    final px = (widget.width * MediaQuery.devicePixelRatioOf(context)).round().clamp(64, 2048);
    final thumb = f.thumb;
    final small = thumb == null
        ? Container(color: t.color('app-paper-2'), alignment: Alignment.center, child: FileBadge(kind: f.kind, size: math.min(48, widget.width * 0.4)))
        : Image.memory(thumb, width: widget.width, height: widget.height, fit: BoxFit.cover, gaplessPlayback: true, filterQuality: FilterQuality.medium);
    // The file itself, a GIF moving: Image.file plays every frame of one.
    final picture = _path == null ? small : Image.file(File(_path!), width: widget.width, height: widget.height, fit: BoxFit.cover, cacheWidth: px, gaplessPlayback: true, errorBuilder: (_, _, _) => small);
    final video = f.kind == FileKind.video;
    return Semantics(
      button: true,
      label: '${video ? 'Video' : 'Picture'} ${f.name}, ${fileSize(f.size)}',
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        // A picture or GIF full screen over everything, the chat under it (Matt, 2026-11-19: "when clicking a picture in
        // a chat, like in a circle make it a full screen overlay"); a video in the player, as before. The … has the
        // file's own page (Save, Share).
        onTap: () {
          if (video) return openSpaceFile(context, widget.channel, f, store: widget.store, chat: true);
          final have = _path ?? widget.store.cached(f);
          unawaited(showPictureOverlay(
            context,
            path: have,
            coming: have == null ? widget.store.fetch(widget.channel, f) : null,
            thumb: f.thumb,
            title: f.name,
            more: () => openSpaceFile(context, widget.channel, f, store: widget.store, chat: true),
          ));
        },
        child: ClipRRect(
          borderRadius: widget.radius,
          child: SizedBox(
            width: widget.width,
            height: widget.height,
            child: Stack(fit: StackFit.expand, children: [
              picture,
              if (video)
                Center(
                  child: Container(
                    key: const ValueKey('space-chat-play'),
                    width: 44,
                    height: 44,
                    decoration: const BoxDecoration(shape: BoxShape.circle, color: Color(0x8C000000)),
                    child: const Center(child: AppIcon(Lucide.play, size: 20, color: Color(0xFFFFFFFF))),
                  ),
                ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// A file that isn't drawn as a picture, or a voice message: its mark, name and size in a chip of the bubble's colours.
class _FileChip extends StatelessWidget {
  const _FileChip({required this.channel, required this.file, required this.store, required this.voice, required this.ground, required this.ink, required this.maxWidth, this.rim});
  final VoiceChannel channel;
  final SpaceFile file;
  final FilesStore store;
  final bool voice;
  final Color ground, ink;
  final Border? rim;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final f = file;
    final title = voice ? 'Voice message' : f.name;
    return GlacierPressable(
      onPressed: () => openSpaceFile(context, channel, f, store: store, chat: true),
      semanticLabel: '$title, ${fileSize(f.size)}. Open',
      builder: (context, state) => ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Container(
          padding: EdgeInsets.all(t.space(2)),
          decoration: BoxDecoration(color: ground, border: rim, borderRadius: BorderRadius.circular(lookCorner(t, '1rem', most: 1))),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (voice)
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(shape: BoxShape.circle, color: ink.withValues(alpha: 0.14)),
                child: Center(child: AppIcon(Lucide.play, size: 16, color: ink)),
              )
            else
              FileBadge(kind: f.kind, size: 36),
            SizedBox(width: t.space(2)),
            Flexible(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('sm'), weight: 'semibold', color: ink)),
                Text(voice ? fileSize(f.size) : '${f.kind.label} · ${fileSize(f.size)}', maxLines: 1, style: pageText(t, t.fontSize('xs'), color: ink.withValues(alpha: 0.7))),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

/// A sticker sent by its name, drawn from the app's own copy: as a conversation of texts draws one, small and on the
/// page with no bubble. One this app doesn't carry (a pack newer than it) says "Sticker".
class SpaceSticker extends StatelessWidget {
  const SpaceSticker({super.key, required this.name, required this.side});
  final String name;
  final double side;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return FutureBuilder<String?>(
      future: stickerAsset(name),
      builder: (context, snap) {
        final asset = snap.data;
        return SizedBox(
          width: side,
          height: side,
          child: asset != null
              ? Image.asset(asset, fit: BoxFit.contain, cacheWidth: (side * MediaQuery.devicePixelRatioOf(context)).round(), gaplessPlayback: true, filterQuality: FilterQuality.medium, semanticLabel: 'Sticker')
              : snap.connectionState == ConnectionState.done
              ? Center(child: Text('Sticker', style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-3'))))
              : null,
        );
      },
    );
  }
}

/// A message on its way: its pictures from this device and its files' chips, its words, and under them how far it has
/// got or, where it stopped, why, with Try again and Don't send.
class SpaceOutgoing extends StatelessWidget {
  const SpaceOutgoing({super.key, required this.message, required this.maxWidth, required this.ground, required this.ink, required this.onRetry, required this.onDiscard, this.rim});
  final OutgoingMessage message;
  final double maxWidth;
  final Color ground, ink;
  final Border? rim;
  final VoidCallback onRetry, onDiscard;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final o = message;
    final gap = t.space(1);
    final round = BorderRadius.circular(lookCorner(t, '1rem', most: 1));
    final width = math.min(maxWidth, t.lenOf('17rem'));
    final pictures = [for (final f in o.files) if (f.kind == FileKind.image || f.kind == FileKind.video) f];
    final others = [for (final f in o.files) if (!pictures.contains(f)) f];
    final side = pictures.length == 1 ? width : (width - gap) / 2;
    final waiting = o.files.map((f) => f.waiting).whereType<String>().firstOrNull;
    final why = o.error ?? o.files.map((f) => f.error).whereType<String>().firstOrNull;
    final pct = (o.progress * 100).round();
    return Opacity(
      opacity: o.failed ? 1 : 0.85,
      child: Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
        if (pictures.isNotEmpty)
          SizedBox(
            width: pictures.length == 1 ? width : width,
            child: Wrap(alignment: WrapAlignment.end, spacing: gap, runSpacing: gap, children: [
              for (final f in pictures)
                ClipRRect(
                  borderRadius: round,
                  child: Container(
                    width: side,
                    height: pictures.length == 1 ? width * 0.75 : side,
                    color: t.color('app-paper-2'),
                    alignment: Alignment.center,
                    child: f.kind == FileKind.image
                        ? Image.file(File(f.path), width: side, height: pictures.length == 1 ? width * 0.75 : side, fit: BoxFit.cover, cacheWidth: (side * MediaQuery.devicePixelRatioOf(context)).round().clamp(64, 1024), errorBuilder: (_, _, _) => FileBadge(kind: f.kind, size: 40))
                        : FileBadge(kind: f.kind, size: 40),
                  ),
                ),
            ]),
          ),
        for (final f in others)
          Padding(
            padding: EdgeInsets.only(top: gap),
            child: Container(
              constraints: BoxConstraints(maxWidth: width),
              padding: EdgeInsets.all(t.space(2)),
              decoration: BoxDecoration(color: ground, border: rim, borderRadius: round),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                FileBadge(kind: f.kind, size: 36),
                SizedBox(width: t.space(2)),
                Flexible(child: Text(o.voice ? 'Voice message' : f.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('sm'), weight: 'semibold', color: ink))),
              ]),
            ),
          ),
        if (o.text.isNotEmpty)
          Padding(
            padding: EdgeInsets.only(top: gap),
            child: Container(
              constraints: BoxConstraints(maxWidth: maxWidth),
              padding: EdgeInsets.symmetric(horizontal: t.space(3), vertical: t.space(2)),
              decoration: BoxDecoration(color: ground, border: rim, borderRadius: round),
              child: Text(o.text, style: pageText(t, t.fontSize('md'), color: ink, height: 1.3)),
            ),
          ),
        SizedBox(height: gap),
        if (!o.failed)
          SizedBox(
            width: math.min(width, t.lenOf('10rem')),
            child: GlacierProgressBar(value: o.progress * 100, indeterminate: waiting != null || pct == 0, ariaLabel: 'Sending'),
          ),
        Padding(
          padding: EdgeInsetsDirectional.only(top: 2, end: t.space(1)),
          child: o.failed
              ? Row(mainAxisSize: MainAxisSize.min, children: [
                  Flexible(child: Text('Not sent: ${why ?? 'it stopped'}', maxLines: 2, overflow: TextOverflow.ellipsis, textAlign: TextAlign.end, style: pageText(t, t.fontSize('xs'), color: t.danger))),
                  if (o.retryable) ...[SizedBox(width: t.space(1)), _Link(label: 'Try again', onPressed: onRetry, key: const ValueKey('space-outgoing-retry'))],
                  SizedBox(width: t.space(1)),
                  _Link(label: 'Don\'t send', onPressed: onDiscard),
                ])
              : Text(waiting != null ? 'Waiting: $waiting' : (pct == 0 ? 'Sending…' : 'Sending · $pct%'), style: pageText(t, t.fontSize('xs'), color: t.color('app-ink-3'))),
        ),
      ]),
    );
  }
}

/// Words to press under a message that has not gone: "Try again", "Don't send".
class _Link extends StatelessWidget {
  const _Link({super.key, required this.label, required this.onPressed});
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return GlacierPressable(
      onPressed: onPressed,
      semanticLabel: label,
      builder: (context, state) => Padding(
        padding: EdgeInsets.symmetric(vertical: t.space(1)),
        child: Text(label, style: pageText(t, t.fontSize('xs'), weight: 'semibold', color: t.color('app-accent'))),
      ),
    );
  }
}

/// The files chosen to go with the next message, over the composer, each with a way to take it off.
class SpacePickedStrip extends StatelessWidget {
  const SpacePickedStrip({super.key, required this.files, required this.onRemove});
  final List<({String path, bool owned})> files;
  final ValueChanged<({String path, bool owned})> onRemove;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final side = t.lenOf('4rem');
    return SizedBox(
      height: side + t.space(2),
      child: ListView(scrollDirection: Axis.horizontal, padding: EdgeInsetsDirectional.only(bottom: t.space(2), start: t.space(1)), children: [
        for (final p in files)
          Padding(
            padding: EdgeInsetsDirectional.only(end: t.space(2)),
            child: Builder(builder: (context) {
              final name = p.path.split(PlatformInfo.pathSeparator).last.split('/').last;
              final kind = FileKind.of(name, FileKind.mimeOf(name));
              return Stack(children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(t.radius('md')),
                  child: kind == FileKind.image
                      ? Image.file(File(p.path), width: side, height: side, fit: BoxFit.cover, cacheWidth: (side * MediaQuery.devicePixelRatioOf(context)).round(), errorBuilder: (_, _, _) => _named(t, side, kind, name))
                      : _named(t, side, kind, name),
                ),
                PositionedDirectional(top: 0, end: 0, child: IconTap(icon: Lucide.x, label: 'Take off $name', size: 14, box: t.lenOf('1.5rem'), onPressed: () => onRemove(p))),
              ]);
            }),
          ),
      ]),
    );
  }

  /// A square for a file that is not drawn as a picture: its kind's badge over its name.
  Widget _named(Tokens t, double side, FileKind kind, String name) => Container(
        width: side,
        height: side,
        color: t.color('app-paper-2'),
        padding: EdgeInsets.all(t.space(1)),
        alignment: Alignment.center,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          FileBadge(kind: kind, size: 24),
          Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('xs'), color: t.color('app-ink-3'))),
        ]),
      );
}
