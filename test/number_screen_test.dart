import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/me/me.dart';
import 'package:ghost_messaging/sms.dart';
import 'package:ghost_messaging/ui/me.dart';

import 'support/list_harness.dart';

/// Settings › Me › Number: the page that texts a code and takes it back (Matt, 2026-11-14: "send the text code to
/// a number to verify so it can't be spoofed"). The relay server is stood in for by [Me.asking], and the phone's
/// texts by the channel: what is held to here is what the page asks, and which arriving text it reads a code from.
/// The server's own rules are relay/test/handles_test.dart's, and the two together test/me_test.dart's.
void main() {
  const number = '+15550100199';
  const ours = 'Your Uplink verification code is: 482913';

  /// What the server was asked, in order.
  final asked = <Map<String, Object?>>[];

  /// The texts on the phone, by conversation.
  final texts = <int, List<Map<String, Object?>>>{};

  /// Where set, the server's answer to "text" waits for it: a text can arrive before the answer does.
  Completer<void>? hold;
  var nextId = 1;

  Map<String, Object?> text(String body, {bool outgoing = false, Duration ago = Duration.zero}) => {
        'id': nextId++,
        'kind': 'sms',
        'address': '22395',
        'body': body,
        'date': DateTime.now().subtract(ago).millisecondsSinceEpoch,
        'outgoing': outgoing,
      };

  Future<Map<String, dynamic>> server(Map<String, Object?> what) async {
    asked.add(what);
    switch (what['dir']) {
      case 'text':
        if (hold != null) await hold!.future;
        return {'dir': 'text', 'p': 'phone', 'handle': what['handle']};
      case 'code':
        if (what['code'] != '482913') throw MeError('That is not the code. Look at the text again, or ask for a new one.');
        Me.instance.seed(links: {'phone': what['handle'] as String});
        return {'dir': 'linked', 'p': 'phone', 'handle': what['handle']};
    }
    return {};
  }

  setUp(() {
    asked.clear();
    texts.clear();
    hold = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (call) async {
      final args = (call.arguments as Map?) ?? const {};
      if (call.method == 'messages') return texts[(args['thread'] as num).toInt()] ?? const <Map<String, Object?>>[];
      return null;
    });
    Me.instance.seed(ready: true, links: {}, ways: const {'phone': 'text'});
    Me.instance.asking = server;
  });

  tearDown(() {
    Me.instance.asking = null;
    Me.instance.seed(ready: false, links: {}, ways: {});
  });

  /// A text arrives in [thread], as Android says it to the app.
  Future<void> arrive(WidgetTester tester, int thread, Map<String, Object?> message) async {
    (texts[thread] ??= []).insert(0, message);
    Sms.instance.changes.add(thread);
    await settle(tester);
  }

  Future<void> open(WidgetTester tester, {String own = '5550100199'}) async {
    final sheet = await loadSheet(tester);
    await pumpScreen(tester, sheet, NumberScreen(own: own), AppState());
  }

  Future<void> press(WidgetTester tester, String label) async {
    await tester.tap(find.text(label));
    await settle(tester);
  }

  /// Lets a toast go, so no timer of its is left as the test ends.
  Future<void> rest(WidgetTester tester) => tester.pump(const Duration(seconds: 7));

  testWidgets('the phone\'s own number is filled in; one that is not whole is not sent anywhere', (tester) async {
    await open(tester);
    expect(find.text('+1 (555) 010-0199'), findsOneWidget);
    await tester.enterText(find.byType(EditableText).first, '555 0199');
    await press(tester, 'Text me a code');
    expect(find.textContaining('doesn\'t look like a whole phone number'), findsOneWidget);
    expect(asked, isEmpty);
    expect(find.text('Check the code'), findsNothing);
  });

  testWidgets('the code is read from our text as it arrives, and checked without a press', (tester) async {
    await open(tester);
    await press(tester, 'Text me a code');
    expect(asked.single, {'dir': 'text', 'p': 'phone', 'handle': number});
    expect(find.textContaining('Texted to +1 (555) 010-0199'), findsOneWidget);

    await arrive(tester, 7, text(ours));
    expect(asked.last, {'dir': 'code', 'p': 'phone', 'handle': number, 'code': '482913'});
    expect(Me.instance.number, number);
    await rest(tester);
  });

  testWidgets('another company\'s code, an old text and one of our own sending are never read as the code', (tester) async {
    await open(tester);
    // Before anything is asked for, nothing that arrives is looked at.
    await arrive(tester, 7, text(ours, ago: const Duration(seconds: 2)));
    expect(asked, isEmpty);

    await press(tester, 'Text me a code');
    await arrive(tester, 9, text('Your Coinbase verification code is 771204. Do not share it.'));
    // Our own text from before the asking, seen again as its conversation changes: not this asking's.
    await arrive(tester, 7, text('Your Uplink verification code is: 111222', ago: const Duration(minutes: 5)));
    await arrive(tester, 4, text(ours, outgoing: true));
    // "Some conversation changed", with no word on which: nothing is read.
    Sms.instance.changes.add(-1);
    await settle(tester);
    expect(asked.length, 1, reason: 'only the text was asked for: no code went to the server');
    expect(tester.widget<EditableText>(find.byType(EditableText).at(1)).controller.text, isEmpty);
    expect(Me.instance.number, isNull);
  });

  testWidgets('a text that arrives before the server\'s answer is still used', (tester) async {
    hold = Completer<void>();
    await open(tester);
    await tester.tap(find.text('Text me a code'));
    await tester.pump();
    expect(find.text('Sending…'), findsOneWidget);
    await arrive(tester, 7, text(ours));
    expect(asked.length, 1, reason: 'nothing is tried until the server says the text was sent');

    hold!.complete();
    await settle(tester);
    expect(asked.last, {'dir': 'code', 'p': 'phone', 'handle': number, 'code': '482913'});
    expect(Me.instance.number, number);
    await rest(tester);
  });

  testWidgets('a wrong code says what the server said; the code can be sent again, and a changed number starts over', (tester) async {
    await open(tester);
    await press(tester, 'Text me a code');
    await press(tester, 'Check the code');
    expect(find.text('Type the code from the text.'), findsOneWidget);
    expect(asked.length, 1);

    await tester.enterText(find.byType(EditableText).at(1), '000 000');
    await press(tester, 'Check the code');
    expect(asked.last['code'], '000000');
    expect(find.textContaining('That is not the code'), findsOneWidget);
    expect(Me.instance.number, isNull);

    await press(tester, 'Send it again');
    expect(asked.last, {'dir': 'text', 'p': 'phone', 'handle': number});
    expect(find.textContaining('That is not the code'), findsNothing);

    // Another number typed: the code that was sent is no longer what is waited for.
    await tester.enterText(find.byType(EditableText).first, '555 010 0142');
    await settle(tester);
    expect(find.text('Check the code'), findsNothing);
    await arrive(tester, 7, text(ours));
    expect(asked.where((a) => a['dir'] == 'code').length, 1);
    await press(tester, 'Text me a code');
    expect(asked.last, {'dir': 'text', 'p': 'phone', 'handle': '+15550100142'});
  });

  testWidgets('with no texting service on the server the page says so, and nothing can be sent', (tester) async {
    Me.instance.seed(ways: const {'github': 'proof'});
    await open(tester);
    expect(find.textContaining('isn\'t set up on the relay server yet'), findsOneWidget);
    // The row is there to say why, and is not a button.
    await tester.tap(find.text('Text me a code'), warnIfMissed: false);
    await settle(tester);
    expect(asked, isEmpty);
    // The server says it can, later: the row comes alive without the page being opened again.
    Me.instance.seed(ways: const {'phone': 'text'});
    await settle(tester);
    expect(find.textContaining('isn\'t set up on the relay server yet'), findsNothing);
    await press(tester, 'Text me a code');
    expect(asked.single['dir'], 'text');
  });
}
