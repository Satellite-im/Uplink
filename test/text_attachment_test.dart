import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/sms.dart';
import 'package:ghost_messaging/ui/text_attachment.dart';

import 'support/list_harness.dart';

// Matt, 2026-11-25: "i got a text from Phill he sent an attachement but there is no way to preview it or download
// it". lib/ui/text_attachment.dart.

void main() {
  test('a file is named by its own name, or by its kind where it has none, and never by a path', () {
    expect(textFileName(const Attachment(id: 1, type: 'text/x-vcard', name: 'Phill.vcf')), 'Phill.vcf');
    expect(textFileName(const Attachment(id: 1, type: 'text/x-vCard')), 'Contact card.vcf');
    expect(textFileName(const Attachment(id: 1, type: 'application/pdf', name: 'menu')), 'menu.pdf');
    expect(textFileName(const Attachment(id: 1, type: 'application/pdf', name: '../../etc/passwd')), 'passwd.pdf');
    expect(textFileName(const Attachment(id: 1, type: 'application/x-something', name: '..')), 'File.bin');
    expect(textFileKind('text/calendar; charset=utf-8').label, 'Calendar invitation');
  });

  testWidgets('a press offers to open, save or share it, and it is read from the phone once', (tester) async {
    final dir = Directory.systemTemp.createTempSync('ghost-text-attachment');
    addTearDown(() => dir.deleteSync(recursive: true));
    var reads = 0;
    final sheet = await loadSheet(tester);
    await pumpScreen(
      tester,
      sheet,
      Center(
        child: TextAttachmentPill(
          attachment: const Attachment(id: 7, type: 'text/x-vcard', name: 'Phill.vcf'),
          ground: const Color(0xFFEEEEEE),
          ink: const Color(0xFF111111),
          folder: dir,
          read: (id) async {
            reads++;
            return Uint8List.fromList('BEGIN:VCARD\nFN:Phill\nEND:VCARD\n'.codeUnits);
          },
        ),
      ),
      AppState(),
      size: const Size(1000, 700),
      platform: 'desktop',
    );
    expect(find.text('Phill.vcf'), findsOneWidget);
    expect(find.textContaining('Contact card'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('text-file-7')));
    await settle(tester);
    expect(find.text('Save'), findsOneWidget);
    expect(find.text('Open'), findsOneWidget);
    expect(reads, 0, reason: 'not read until something is chosen');
  });
}
