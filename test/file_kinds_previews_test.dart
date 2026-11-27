import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/desktop/desk_voice.dart';
import 'package:ghost_messaging/files/file_kinds.dart';
import 'package:ghost_messaging/sms.dart';
import 'package:ghost_messaging/ui/text_attachment.dart';

/// GMFB-60 (Matt, Android, 0.12.25): ".oog files don't load an audio preview and .heic files don't render an image
/// preview". What is drawn as a picture and what is played as sound, wherever a chat shows a file.
void main() {
  final had = readsHeic;
  tearDown(() => readsHeic = had);

  test('a HEIC is drawn as a picture where the device reads one, and is a file elsewhere; an SVG never', () {
    readsHeic = () => true; // an Android phone, an iPhone, a Mac
    expect(FileKind.drawsAsPicture('IMG_0042.HEIC'), isTrue);
    expect(FileKind.drawsAsPicture('IMG_0042.heif', 'image/heif'), isTrue);
    expect(FileKind.drawsAsPicture('photo', 'image/heic'), isTrue, reason: 'by its type where the name has no ending');
    readsHeic = () => false; // Windows, Linux, a browser
    expect(FileKind.drawsAsPicture('IMG_0042.HEIC'), isFalse);
    expect(FileKind.drawsAsPicture('IMG_0042.heif'), isFalse);
    expect(FileKind.drawsAsPicture('photo', 'image/heic'), isFalse);
    for (final reads in [true, false]) {
      readsHeic = () => reads;
      expect(FileKind.drawsAsPicture('beach.jpg'), isTrue);
      expect(FileKind.drawsAsPicture('beach.webp', 'application/octet-stream'), isTrue);
      expect(FileKind.drawsAsPicture('logo.svg', 'image/svg+xml'), isFalse);
      expect(FileKind.drawsAsPicture('logo', 'image/svg+xml'), isFalse);
      expect(FileKind.drawsAsPicture('song.ogg'), isFalse);
      expect(FileKind.drawsAsPicture('plan.pdf'), isFalse);
    }
    expect(FileKind.of('IMG_0042.HEIC'), FileKind.image, reason: 'a picture by kind either way: its badge and the Pictures filter');
  });

  test('Ogg sound is sound by every ending it goes by, with a type a player is told', () {
    for (final name in ['clip.ogg', 'clip.oga', 'clip.opus', 'CLIP.OGG']) {
      expect(FileKind.of(name), FileKind.audio, reason: name);
      expect(FileKind.of(name).previews, isTrue, reason: name);
    }
    expect(FileKind.mimeOf('clip.ogg'), 'audio/ogg');
    expect(FileKind.mimeOf('clip.oga'), 'audio/ogg');
    expect(FileKind.mimeOf('clip.opus'), 'audio/opus');
    expect(FileKind.mimeOf('photo.heif'), 'image/heif');
  });

  test('a part of a text whose type says nothing is what its name says: sound gets a player, a picture is drawn', () {
    readsHeic = () => true;
    expect(const Attachment(id: 1, type: 'application/octet-stream', name: 'clip.ogg').isAudio, isTrue);
    expect(const Attachment(id: 1, type: '', name: 'note.opus').isAudio, isTrue);
    expect(const Attachment(id: 1, type: 'application/x-ogg').isAudio, isTrue);
    expect(const Attachment(id: 1, type: 'application/octet-stream', name: 'IMG_0042.heic').isImage, isTrue);
    expect(const Attachment(id: 1, type: 'application/octet-stream', name: 'beach.jpg').isImage, isTrue);
    readsHeic = () => false;
    expect(const Attachment(id: 1, type: 'application/octet-stream', name: 'IMG_0042.heic').isImage, isFalse, reason: 'a file\'s row where it can\'t be read');
    // A type that says what it is is believed over the name, and other files stay files.
    expect(const Attachment(id: 1, type: 'application/pdf', name: 'clip.ogg').isAudio, isFalse);
    expect(const Attachment(id: 1, type: 'text/x-vcard', name: 'photo.jpg').isImage, isFalse);
    expect(const Attachment(id: 1, type: 'application/octet-stream', name: 'menu.pdf').isAudio, isFalse);
    expect(const Attachment(id: 1, type: 'application/octet-stream', name: 'menu.pdf').isImage, isFalse);
    expect(const Attachment(id: 1, type: 'application/octet-stream').isAudio, isFalse);
    // A picture shown as its file is kept under an ending another app knows.
    expect(textFileName(const Attachment(id: 1, type: 'image/heic')), 'Picture.heic');
    expect(textFileName(const Attachment(id: 1, type: 'image/heic', name: 'IMG_0042.HEIC')), 'IMG_0042.HEIC');
  });

  group('how long an Ogg sound runs (oggMillis)', () {
    /// One Ogg page: its 27 bytes with [granule] (the samples so far), one length, and [packet].
    Uint8List page(int granule, List<int> packet, {bool none = false}) {
      final b = BytesBuilder()..add('OggS'.codeUnits)..add([0, 0]);
      final g = ByteData(8);
      if (none) {
        g..setUint32(0, 0xffffffff, Endian.little)..setUint32(4, 0xffffffff, Endian.little);
      } else {
        g..setUint32(0, granule & 0xffffffff, Endian.little)..setUint32(4, granule >> 32, Endian.little);
      }
      b..add(g.buffer.asUint8List())..add(List.filled(12, 0))..add([1, packet.length])..add(packet);
      return b.toBytes();
    }

    List<int> opusHead(int skip) => [...'OpusHead'.codeUnits, 1, 1, skip & 0xff, skip >> 8, 0x80, 0xbb, 0, 0, 0, 0, 0, ...List.filled(12, 0)];
    List<int> vorbisHead(int rate) => [1, ...'vorbis'.codeUnits, 0, 0, 0, 0, 2, rate & 0xff, (rate >> 8) & 0xff, (rate >> 16) & 0xff, 0, ...List.filled(14, 0)];
    Uint8List file(List<Uint8List> pages) => Uint8List.fromList([for (final p in pages) ...p]);

    test('Opus counts 48000 to the second, less what it skips; Vorbis its own rate', () {
      final opus = file([page(0, opusHead(312)), page(0, List.filled(40, 7)), page(48000 * 7 + 312, List.filled(200, 9))]);
      expect(isOgg(opus), isTrue);
      expect(oggMillis(opus), 7000);
      final vorbis = file([page(0, vorbisHead(44100)), page(44100, List.filled(100, 3)), page(44100 * 3 + 22050, List.filled(100, 3))]);
      expect(oggMillis(vorbis), 3500);
      // A last page that ends no packet has no count: the one before it says.
      expect(oggMillis(file([page(0, opusHead(0)), page(48000 * 2, List.filled(50, 1)), page(0, List.filled(50, 1), none: true)])), 2000);
    });

    test('anything else says nothing', () {
      expect(isOgg(Uint8List.fromList('ftypM4A '.codeUnits)), isFalse);
      expect(oggMillis(Uint8List(0)), 0);
      expect(oggMillis(Uint8List.fromList('OggS'.codeUnits)), 0, reason: 'cut short');
      expect(oggMillis(file([page(0, [...'Speex   '.codeUnits, ...List.filled(30, 0)]), page(16000, List.filled(20, 1))])), 0, reason: 'neither Vorbis nor Opus');
      expect(oggMillis(file([page(0, opusHead(0))])), 0, reason: 'no sound after its first page');
    });
  });
}
