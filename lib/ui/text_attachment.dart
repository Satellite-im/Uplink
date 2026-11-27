/// A file that came with a text and is not a picture, a video or a sound: a contact's card, a PDF, a calendar
/// invitation (Matt, 2026-11-25: "i got a text from Phill he sent an attachement but there is no way to preview it or
/// download it"). It was drawn as its name in a pill that did nothing. Now a press reads it from the phone
/// ([Sms.part]) into a file of the app's own and offers what this device can do with it: open it in whichever app
/// reads its kind, save it, share it (lib/files/file_platform.dart).
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../art/app_icon.dart';
import '../art/lucide.g.dart';
import '../backgrounds.dart' show lookCorner;
import '../platform_info.dart';
import '../files/file_platform.dart';
import '../kit/settings_type.dart';
import '../sms.dart';
import 'common.dart';

/// What a file of [type] is called where it has no name, and the ending its file goes by.
({String label, String ending}) textFileKind(String type) => switch (type.toLowerCase().split(';').first.trim()) {
      'text/x-vcard' || 'text/vcard' || 'text/directory' => (label: 'Contact card', ending: 'vcf'),
      'text/calendar' || 'text/x-vcalendar' => (label: 'Calendar invitation', ending: 'ics'),
      'application/pdf' => (label: 'PDF', ending: 'pdf'),
      'text/plain' => (label: 'Text file', ending: 'txt'),
      'application/zip' => (label: 'Zip file', ending: 'zip'),
      // A picture this device can't draw, shown as its file (GMFB-60): kept under an ending another app knows it by.
      'image/heic' || 'image/heif' => (label: 'Picture', ending: 'heic'),
      'image/svg+xml' => (label: 'Picture', ending: 'svg'),
      'application/msword' => (label: 'Word document', ending: 'doc'),
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document' => (label: 'Word document', ending: 'docx'),
      'application/vnd.ms-excel' => (label: 'Spreadsheet', ending: 'xls'),
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' => (label: 'Spreadsheet', ending: 'xlsx'),
      _ => (label: 'File', ending: 'bin'),
    };

/// The name [a]'s file is kept and saved under: its own, with nothing of a path in it, or its kind's.
String textFileName(Attachment a) {
  final kind = textFileKind(a.type);
  final own = (a.name ?? '').split(RegExp(r'[/\\]')).last.replaceAll(RegExp(r'[\x00-\x1f:*?"<>|]'), '').trim();
  if (own.isEmpty || own == '.' || own == '..') return '${kind.label}.${kind.ending}';
  return own.contains('.') ? own : '$own.${kind.ending}';
}

class TextAttachmentPill extends StatefulWidget {
  const TextAttachmentPill({super.key, required this.attachment, required this.ground, required this.ink, this.read, this.folder});
  final Attachment attachment;
  final Color ground;
  final Color ink;

  /// Reads the file's bytes; the phone's own otherwise ([Sms.part]). Given by a test.
  final Future<Uint8List?> Function(int id)? read;

  /// Where its file is kept; the device's folder for passing files otherwise. Given by a test.
  final Directory? folder;

  @override
  State<TextAttachmentPill> createState() => _TextAttachmentPillState();
}

class _TextAttachmentPillState extends State<TextAttachmentPill> {
  bool _busy = false;

  Attachment get _a => widget.attachment;

  /// The file on this device, read from the phone the first time; null where it could not be had.
  Future<String?> _file() async {
    try {
      final dir = Directory('${(widget.folder ?? Directory.systemTemp).path}${PlatformInfo.pathSeparator}ghost-text-files${PlatformInfo.pathSeparator}${_a.id}');
      final file = File('${dir.path}${PlatformInfo.pathSeparator}${textFileName(_a)}');
      if (await file.exists() && await file.length() > 0) return file.path;
      final bytes = await (widget.read ?? Sms.instance.part)(_a.id);
      if (bytes == null || bytes.isEmpty) return null;
      await dir.create(recursive: true);
      await file.writeAsBytes(bytes, flush: true);
      return file.path;
    } catch (_) {
      return null;
    }
  }

  Future<void> _with(Future<void> Function(String path, String name) then) async {
    if (_busy) return;
    setState(() => _busy = true);
    final path = await _file();
    if (!mounted) return;
    setState(() => _busy = false);
    if (path == null) return toast(context, 'That file could not be read from the phone.', tone: GlacierToastTone.danger);
    await then(path, textFileName(_a));
  }

  void _press() {
    final name = textFileName(_a);
    final opens = FilePlatform.canOpen && !FilePlatform.runsCode(name);
    showChoices(context, title: name, choices: [
      if (opens) Choice('Open', Lucide.externalLink, () => _with((path, name) => FilePlatform.open(path, name)), hint: 'In the app that reads it'),
      if (FilePlatform.canSave)
        Choice('Save', Lucide.download, () => _with((path, name) async {
              final said = await FilePlatform.save(path, name, _a.type);
              if (said != null && mounted) toast(context, said);
            })),
      if (FilePlatform.canShare) Choice('Share', Lucide.share2, () => _with((path, name) => FilePlatform.share(path, name, _a.type))),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final kind = textFileKind(_a.type);
    final named = (_a.name ?? '').trim();
    final ink = widget.ink;
    return GlacierPressable(
      key: ValueKey('text-file-${_a.id}'),
      onPressed: _press,
      semanticLabel: '${named.isEmpty ? kind.label : named}. Open, save or share',
      builder: (context, state) => Container(
        margin: EdgeInsets.only(bottom: t.space(1)),
        padding: EdgeInsets.symmetric(horizontal: t.space(3), vertical: t.space(2)),
        decoration: BoxDecoration(color: widget.ground, borderRadius: BorderRadius.circular(lookCorner(t, '1rem', most: 1))),
        child: Opacity(
          opacity: state.pressed ? 0.7 : 1,
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            SizedBox.square(dimension: 22, child: Center(child: _busy ? const GhostSpinner(size: 16) : AppIcon(kind.ending == 'vcf' ? Lucide.contactRound : Lucide.file, size: 20, color: ink, wash: false))),
            SizedBox(width: t.space(2)),
            Flexible(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Text(named.isEmpty ? kind.label : named, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('sm'), weight: 'semibold', color: ink)),
                Text(named.isEmpty || kind.label == 'File' ? 'Tap to open or save' : '${kind.label} · Tap to open or save', maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('xs'), color: ink.withValues(alpha: 0.7))),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}
