/// The Export conversation rows' work (GMFB-36; lib/export_chat.dart): the messages read, written as Markdown or as
/// JSON, alone or in a zip with their pictures and files, as the person chooses, and saved where they say.
library;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../art/lucide.g.dart';
import '../export_chat.dart';
import '../files/file_platform.dart';
import '../files/files_store.dart';
import '../sms.dart';
import '../voice/channels.dart';
import '../voice/hangout.dart';
import 'common.dart';

/// The most messages of a conversation of texts an export reads.
const exportMost = 20000;

/// Exports the conversation of texts (or with a friend) [thread], called [title], with [people] in it.
Future<void> exportTexts(BuildContext context, int thread, String title, List<Person> people) async {
  final byAddress = {for (final p in people) p.address: p.label};
  final List<Message> all;
  try {
    all = await Sms.instance.messages(thread, limit: exportMost);
  } catch (e) {
    if (context.mounted) toast(context, 'The messages couldn\'t be read: $e', tone: GlacierToastTone.danger);
    return;
  }
  final kept = [for (final m in all) if (m.notice == null) m];
  // A picture or file with no name of its own goes by its kind: "attachment 12.jpeg".
  String nameOf(Attachment a) => a.name ?? 'attachment ${a.id}.${a.type.split('/').last.split(';').first}';
  final lines = <ExportLine>[
    for (final m in kept)
      (
        at: m.date,
        who: m.outgoing ? 'You' : (byAddress[m.address] ?? (people.length == 1 ? people.first.label : m.address)),
        text: m.body,
        files: [for (final a in m.attachments) a.name ?? a.type],
        replyTo: null,
        edited: m.edited,
      ),
  ];
  if (!context.mounted) return;
  // Each picture and file is read from the phone as it is packed (Sms.part).
  await _choose(context, title, lines, [
    for (var i = 0; i < kept.length; i++)
      for (var k = 0; k < kept[i].attachments.length; k++)
        (line: i, file: k, name: nameOf(kept[i].attachments[k]), size: 0, read: () => Sms.instance.part(kept[i].attachments[k].id)),
  ]);
}

/// Exports [room]'s chat, its threads among it.
Future<void> exportSpace(BuildContext context, HangoutRoom room) {
  final messages = room.messages;
  // A file is on this device already, or is brought down from the space as it is packed (FilesStore.fetch).
  return _choose(context, room.channel.name, spaceLines(room, nameOf: Voice.instance.nameOf), where: 'a space', [
    for (var i = 0; i < messages.length; i++)
      for (var k = 0; k < messages[i].files.length; k++)
        (line: i, file: k, name: messages[i].files[k].name, size: messages[i].files[k].size, read: () => FilesStore.instance.fetch(room.channel, messages[i].files[k])),
  ]);
}

/// Asks how [lines] are to be exported (the ticket's choice of format, and "with attachments"): Markdown, as ever, or
/// JSON, and where any message has [files] and this is not a browser, either with them in a zip. Says so instead
/// where there is nothing to export or the device can't save files.
Future<void> _choose(BuildContext context, String title, List<ExportLine> lines, List<ExportFile> files, {String? where}) async {
  if (lines.isEmpty) {
    toast(context, 'There\'s nothing to export yet');
    return;
  }
  if (!FilePlatform.canSave) {
    toast(context, 'This device can\'t save files yet');
    return;
  }
  final withFiles = files.isNotEmpty && !kIsWeb;
  final count = files.length == 1 ? '1 picture or file' : '${files.length} pictures and files';
  await showChoices(context, title: 'Export $title', choices: [
    Choice('Markdown', Lucide.fileText, () => _save(context, title, lines, where: where), hint: 'One file of plain text any app opens.'),
    if (withFiles) Choice('Markdown, with pictures and files', Lucide.folder, () => _save(context, title, lines, where: where, files: files), hint: 'A zip: the Markdown, and $count beside it.'),
    Choice('JSON', Lucide.braces, () => _save(context, title, lines, where: where, json: true), hint: 'One file for another program to read.'),
    if (withFiles) Choice('JSON, with pictures and files', Lucide.folder, () => _save(context, title, lines, where: where, json: true, files: files), hint: 'A zip: the JSON, and $count beside it.'),
  ]);
}

/// Writes [lines] as Markdown (or [json]) to a file named from [title], or with [files] to a zip of it and them, and
/// hands it to this device's way of saving, then says how many messages went, and how many files with them.
Future<void> _save(BuildContext context, String title, List<ExportLine> lines, {String? where, bool json = false, List<ExportFile>? files}) async {
  final ending = json ? 'json' : 'md';
  String text([ExportLinks? links]) => json ? chatJson(title, lines, where: where, links: links) : chatMarkdown(title, lines, where: where, links: links);
  final said = lines.length == 1 ? '1 message' : '${lines.length} messages';
  try {
    if (files == null) {
      final name = exportName(title, ending: ending);
      final path = await writeExport(text(), name);
      final done = await FilePlatform.save(path, name, json ? 'application/json' : 'text/markdown');
      if (context.mounted && done != null) toast(context, '$done: $said');
      return;
    }
    // Reading them can take a while: said first.
    toast(context, 'Getting ${files.length == 1 ? 'its picture or file' : 'its ${files.length} pictures and files'}…');
    final name = exportName(title, ending: 'zip');
    final zip = await writeExportZip(name, exportName(title, ending: ending), files, text);
    final done = await FilePlatform.save(zip.path, name, 'application/zip');
    if (context.mounted && done != null) {
      toast(context, '$done: $said, ${zip.packed == 1 ? '1 file' : '${zip.packed} files'}${zip.named == 0 ? '' : '. ${zip.named} couldn\'t be read and ${zip.named == 1 ? 'is' : 'are'} only named'}');
    }
  } catch (e) {
    if (context.mounted) toast(context, 'Couldn\'t export: $e', tone: GlacierToastTone.danger);
  }
}
