/// Exporting a conversation (GMFB-36, from the Uplink gap review: importing and exporting conversations was in Warp's
/// backlog, #373): its messages as a Markdown file, saved where the person says (a phone's Save to, a Mac's save panel,
/// Downloads elsewhere).
///
/// Markdown because it is plain text any app opens, and what the sister app Ghost.md keeps notes in: a heading with the
/// conversation's name and when it was exported, a heading for each day, and each message as "**Name** 14:05" over its
/// words, with any pictures or files named under it. Pictures and files themselves stay in the app.
///
/// Or, asked for (the ticket's "choice of format" and "with attachments"): as JSON, for another program to read
/// ([chatJson]); and either with its pictures and files, in a zip that holds the export and a "files" folder beside it,
/// each file linked from where its message names it ([writeExportZip]). A file that can't be read, or that would take
/// the zip past [exportFilesMost], is named as before and not linked.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';

import 'platform_info.dart';

import 'voice/hangout.dart';

/// One message as an export writes it, whatever kind of conversation it came from.
typedef ExportLine = ({DateTime at, String who, String text, List<String> files, String? replyTo, bool edited});

/// Where a message's file was put beside the export, as the export links it ("files/plan.pdf"): asked by the message's
/// place in the lines given and the file's place in its files. Null: only named.
typedef ExportLinks = String? Function(int line, int file);

/// One picture or file an export with attachments takes: whose it is ([line], [file], as [ExportLinks] counts), what
/// it is called, its size where that is known before it is read (0 where not), and how it is read: its path on this
/// device (a String), its bytes (a Uint8List), or null where it can't be had.
typedef ExportFile = ({int line, int file, String name, int size, Future<Object?> Function() read});

/// The most an export's pictures and files may come to, in bytes: what is past it is named and not packed.
const exportFilesMost = 1024 * 1024 * 1024;

/// [lines]' places, oldest first.
List<int> _oldestFirst(List<ExportLine> lines) => [for (var i = 0; i < lines.length; i++) i]..sort((a, b) {
    final by = lines[a].at.compareTo(lines[b].at);
    return by != 0 ? by : a.compareTo(b);
  });

/// [lines] as Markdown under [title], oldest first; [now] says when it was exported. [links]: where each file was put
/// beside the export, for one with its files.
String chatMarkdown(String title, List<ExportLine> lines, {DateTime? now, String? where, ExportLinks? links}) {
  final out = StringBuffer();
  final at = now ?? DateTime.now();
  out.writeln('# $title');
  out.writeln();
  out.writeln('Exported from Uplink on ${_day(at)} at ${_time(at)}${where == null ? '' : ' · $where'} · ${lines.length == 1 ? '1 message' : '${lines.length} messages'}');
  String? day;
  for (final i in _oldestFirst(lines)) {
    final l = lines[i];
    final d = _day(l.at);
    if (d != day) {
      day = d;
      out.writeln();
      out.writeln('## $d');
    }
    out.writeln();
    out.writeln('**${_escape(l.who)}** ${_time(l.at)}${l.edited ? ' (edited)' : ''}');
    if (l.replyTo != null && l.replyTo!.isNotEmpty) out.writeln('> ${l.replyTo!.replaceAll('\n', ' ')}');
    final words = l.text.trim();
    if (words.isNotEmpty) {
      // A line break kept as one: two spaces at a line's end.
      out.writeln(words.split('\n').join('  \n'));
    }
    for (var k = 0; k < l.files.length; k++) {
      final to = links?.call(i, k);
      out.writeln(to == null ? '- 📎 ${_escape(l.files[k])}' : '- 📎 [${_escape(l.files[k])}](${to.split('/').map(Uri.encodeComponent).join('/')})');
    }
  }
  return out.toString();
}

/// [lines] as JSON under [title], oldest first, for another program to read: what it is and when it was exported,
/// then each message with when (its own time, with no zone, as the Markdown says it), who, its words, and where it
/// has them what it answers, that it was edited, and its files by name (with where each was put beside the export,
/// for one with its files).
String chatJson(String title, List<ExportLine> lines, {DateTime? now, String? where, ExportLinks? links}) {
  final at = now ?? DateTime.now();
  return const JsonEncoder.withIndent('  ').convert({
    'app': 'Uplink',
    'format': 1,
    'title': title,
    'where': ?where,
    'exported': at.toIso8601String(),
    'messages': [
      for (final i in _oldestFirst(lines))
        {
          'at': lines[i].at.toIso8601String(),
          'who': lines[i].who,
          'text': lines[i].text,
          if (lines[i].replyTo != null && lines[i].replyTo!.isNotEmpty) 'replyTo': lines[i].replyTo,
          if (lines[i].edited) 'edited': true,
          if (lines[i].files.isNotEmpty)
            'files': [
              for (var k = 0; k < lines[i].files.length; k++) {'name': lines[i].files[k], 'path': ?links?.call(i, k)},
            ],
        },
    ],
  });
}

/// A space's chat as export lines: the chat and its threads, a thread's replies under a quote of where they hang.
List<ExportLine> spaceLines(HangoutRoom room, {String Function(String id)? nameOf}) => [
      for (final m in room.messages)
        (
          at: DateTime.fromMillisecondsSinceEpoch(m.at),
          who: m.from == room.me ? 'You' : (m.name.isNotEmpty ? m.name : (nameOf?.call(m.from) ?? 'Someone')),
          text: m.poll != null ? '📊 ${m.text}' : (m.sticker != null && m.text.isEmpty ? 'Sticker' : m.text),
          files: [for (final f in m.files) f.name],
          replyTo: m.reply == null ? null : '${m.thread != null ? 'In the thread on' : 'Replying to'} ${m.reply!.name}: ${m.reply!.text}',
          edited: m.edited != null,
        ),
    ];

/// A file name made from [title] for the export: what a file system takes, and the day. [ending]: "md", "json", or
/// "zip" for one with its files.
String exportName(String title, {DateTime? now, String ending = 'md'}) {
  final clean = _fileName(title);
  final d = now ?? DateTime.now();
  return '${clean.isEmpty ? 'Conversation' : (clean.length > 60 ? clean.substring(0, 60).trim() : clean)} ${_day(d)}.$ending';
}

/// [name] with what a file system won't take made spaces.
String _fileName(String name) => name.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();

/// [name] as a file is called in an export's "files" folder: what a file system takes, and not one of [taken] (two
/// pictures both called IMG_1.jpg are IMG_1.jpg and IMG_1 (2).jpg). Added to [taken].
String exportFileName(String name, Set<String> taken) {
  var clean = _fileName(name);
  if (clean.isEmpty || clean == '.' || clean == '..') clean = 'file';
  final dot = clean.lastIndexOf('.');
  var out = clean;
  for (var n = 2; !taken.add(out.toLowerCase()); n++) {
    out = dot > 0 ? '${clean.substring(0, dot)} ($n)${clean.substring(dot)}' : '$clean ($n)';
  }
  return out;
}

/// Writes an export with its pictures and files as a zip named [name], to a file of the app's own to hand to Save:
/// each of [files] that can be read under "files/", then the export itself, called [textName], as [text] writes it
/// once told where each file went. Its path, how many files it holds, and how many it could only name (not to be
/// had, or past [most] bytes in all).
Future<({String path, int packed, int named})> writeExportZip(String name, String textName, List<ExportFile> files, String Function(ExportLinks links) text, {int most = exportFilesMost}) async {
  final dir = await Directory.systemTemp.createTemp('ghost-export');
  final path = '${dir.path}${PlatformInfo.pathSeparator}$name';
  // Pictures, sound and video are packed already: stored as they are, which is quick.
  final zip = ZipFileEncoder()..create(path, level: ZipFileEncoder.store);
  final went = <(int, int), String>{};
  final taken = <String>{};
  var total = 0, named = 0;
  for (final f in files) {
    try {
      if (total + f.size > most) throw const FileSystemException('past the most an export takes');
      final got = await f.read();
      final size = switch (got) { final String p => await File(p).length(), final Uint8List b => b.length, _ => -1 };
      if (size < 0 || total + size > most) throw const FileSystemException('not to be had');
      final as = exportFileName(f.name, taken);
      if (got is String) {
        await zip.addFile(File(got), 'files/$as');
      } else {
        zip.addArchiveFile(ArchiveFile.bytes('files/$as', got as Uint8List));
      }
      total += size;
      went[(f.line, f.file)] = 'files/$as';
    } catch (_) {
      named++;
    }
  }
  zip.addArchiveFile(ArchiveFile.string(textName, text((line, file) => went[(line, file)])));
  await zip.close();
  return (path: path, packed: went.length, named: named);
}

/// Writes [markdown] to a file of the app's own to hand to Save: its path.
Future<String> writeExport(String markdown, String name) async {
  final dir = await Directory.systemTemp.createTemp('ghost-export');
  final f = File('${dir.path}${PlatformInfo.pathSeparator}$name');
  await f.writeAsString(markdown);
  return f.path;
}

// A number in two digits, a date as 2026-01-31, and a time as 09:05.
String _two(int n) => n.toString().padLeft(2, '0');
String _day(DateTime d) => '${d.year}-${_two(d.month)}-${_two(d.day)}';
String _time(DateTime d) => '${_two(d.hour)}:${_two(d.minute)}';

/// A name's Markdown marks made plain.
String _escape(String s) => s.replaceAllMapped(RegExp(r'([*_`\[\]#])'), (m) => '\\${m[1]}');
