import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/inbox/inbox.dart';
import 'package:ghost_messaging/plugins/networks.dart';
import 'package:ghost_messaging/plugins/plugin.dart';
import 'package:ghost_messaging/plugins/registry.dart';

/// Telegram and Signal are official; the rest are plugins, off until switched on (Matt, 2026-11-20: "only keep telegram
/// and signal as the official services ... Setup all these other services as plugins"). lib/inbox/inbox.dart.
class _Net extends InboxNetwork {
  _Net(this.id, {this.officialOverride = false, this.linkedOnStart = false, this.held});
  @override
  final String id;
  final bool officialOverride;

  /// What a saved session would do: on the one-time discovery start, a network already signed in comes up ready.
  final bool linkedOnStart;

  /// A network slow to start: its start ends when this does.
  final Completer<void>? held;

  int starts = 0;
  int signOuts = 0;
  InboxState _state = InboxState.signedOut;

  @override
  bool get official => officialOverride;
  @override
  String get name => id;
  @override
  InboxState get state => _state;
  @override
  String? get error => null;
  @override
  String? get account => null;
  @override
  List<InboxChat> get chats => const [];
  @override
  List<InboxMessage> messagesOf(String chatId) => const [];
  @override
  Future<void> load(String chatId, {bool older = false}) async {}
  @override
  Future<void> send(String chatId, String text) async {}
  @override
  Future<void> markRead(String chatId) async {}
  @override
  set watching(String? chatId) {}
  @override
  Future<void> start(AppState app) async {
    starts++;
    await held?.future;
    if (linkedOnStart) _state = InboxState.ready;
  }

  @override
  Future<void> signOut() async {
    signOuts++;
    _state = InboxState.signedOut;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (call) async => null));
  tearDown(() => Inbox.instance = null);

  // Matt, 2026-11-20: "I don't see instagram and others listed as plugins in the marketplace"; "i want all of them to
  // be in the marketplace" (lib/plugins/networks.dart).
  test('every network that is a plugin is a plugin in the Marketplace, on its own shelf, off until added', () {
    final ids = [for (final p in shippedPlugins.whereType<NetworkPlugin>()) p.network];
    expect(ids, ['whatsapp', 'matrix', 'teams', 'googlechat', 'messenger', 'instagram', 'discord', 'twitter', 'slack']);
    // Matt, 2026-11-21: "linked in keeps automatically signing our sessions out remove the plugin".
    expect(Inbox.instance.named('linkedin'), isNull);
    // Each names a network the app has, that is a plugin there and is offered.
    for (final p in networkPlugins) {
      final n = Inbox.instance.named(p.network);
      expect(n, isNotNull, reason: p.network);
      expect(n!.official, isFalse, reason: p.network);
      expect(n.soon, isFalse, reason: p.network);
      expect(n.name, p.name, reason: p.network);
      expect(p.shelf, PluginShelf.networks);
      expect(p.onByDefault, isFalse);
    }
    // And none that is a plugin and offered is left out.
    expect([for (final n in Inbox.instance.plugins) if (!n.soon) n.id]..sort(), [...ids]..sort());
    expect(shippedPlugins.map((p) => p.id).toSet(), hasLength(shippedPlugins.length), reason: 'no id twice');
  });

  test('adding one in the Marketplace is the network\'s own switch: it starts, and removing it signs out', () async {
    final wa = _Net('whatsapp'), ig = _Net('instagram');
    Inbox.instance = Inbox.of([wa, ig]);
    final app = AppState();
    await Inbox.instance.start(app);
    final starts = wa.starts;
    final registry = PluginRegistry(shippedPlugins);
    final store = AppStore(app);
    final plugin = networkPlugins.firstWhere((p) => p.network == 'whatsapp');
    expect(registry.isOn(plugin, store), isFalse);
    final stamp = app.pluginsStamp;
    registry.setOn(plugin, store, true);
    await pumpEventQueue();
    expect(registry.isOn(plugin, store), isTrue);
    expect(wa.enabled, isTrue, reason: 'Settings › Connections shows the same switch');
    expect(wa.starts, starts + 1);
    expect(app.pluginsStamp, greaterThan(stamp), reason: 'the Marketplace is drawn again');
    expect(registry.isOn(networkPlugins.firstWhere((p) => p.network == 'instagram'), store), isFalse);
    // Switched on in Settings › Connections, it is added here too.
    await Inbox.instance.enable(ig);
    expect(registry.isOn(networkPlugins.firstWhere((p) => p.network == 'instagram'), store), isTrue);
    // Removed: signed out where it was signed in, and off in both places.
    wa._state = InboxState.ready;
    registry.setOn(plugin, store, false);
    await pumpEventQueue();
    expect(wa.signOuts, 1);
    expect(wa.enabled, isFalse);
    expect(registry.isOn(plugin, store), isFalse);
    // A network this build has none of is never on, and adding it does nothing.
    const none = NetworkPlugin('nowhere', 'Nowhere', hue: 'blue');
    registry.setOn(none, store, true);
    expect(registry.isOn(none, store), isFalse);
  });


  test('official networks start; a fresh plugin is discovered once, settles off, and then stays off', () async {
    final tg = _Net('telegram', officialOverride: true);
    final wa = _Net('whatsapp');
    Inbox.instance = Inbox.of([tg, wa]);
    final app = AppState();

    await Inbox.instance.start(app);
    expect(tg.starts, 1, reason: 'Telegram is official: always started');
    expect(wa.starts, 1, reason: 'a plugin with no switch is started once to find a session');
    expect(app.choice('inbox_on_whatsapp', ''), 'off', reason: 'nothing was signed in, so it settles off');
    expect(wa.enabled, isFalse);

    await Inbox.instance.start(app);
    expect(wa.starts, 1, reason: 'off now: not started again');
    expect(tg.starts, 2);
  });

  test('a plugin already signed in is kept on across the upgrade', () async {
    final wa = _Net('whatsapp', linkedOnStart: true);
    Inbox.instance = Inbox.of([wa]);
    final app = AppState();
    await Inbox.instance.start(app);
    expect(wa.starts, 1);
    expect(app.choice('inbox_on_whatsapp', ''), 'on', reason: 'it was signed in, so the switch settles on');
    expect(wa.enabled, isTrue);

    await Inbox.instance.start(app);
    expect(wa.starts, 2, reason: 'on now: started every launch');
  });

  test('switching a plugin on starts it; off signs it out and keeps it from starting', () async {
    final wa = _Net('whatsapp');
    Inbox.instance = Inbox.of([wa]);
    final app = AppState();
    wa.listStore = app;
    app.set('inbox_on_whatsapp', 'off');

    await Inbox.instance.start(app);
    expect(wa.starts, 0, reason: 'off: never started');

    await Inbox.instance.enable(wa);
    expect(app.choice('inbox_on_whatsapp', ''), 'on');
    expect(wa.starts, 1);

    wa.setLinked();
    await Inbox.instance.disable(wa);
    expect(wa.signOuts, 1, reason: 'signed out on the way off');
    expect(app.choice('inbox_on_whatsapp', ''), 'off');
  });

  // Matt, 2026-11-21: "I keep getting recently added plugins dissapearing on my phone, I'll add instagram and linkedin
  // and then it will disapear after some time". Networks started one after another, and one had no choices to read
  // its switch from until its turn came: behind a network slow to start, the last ones showed as off.
  test('a network slow to start holds up no other, and a switch pressed meanwhile is kept', () async {
    final slow = Completer<void>();
    final tg = _Net('telegram', officialOverride: true, held: slow);
    final ig = _Net('instagram'), li = _Net('messenger', held: slow);
    Inbox.instance = Inbox.of([tg, ig, li]);
    final app = AppState()..set('inbox_on_instagram', 'on');
    final started = Inbox.instance.start(app);
    await pumpEventQueue();
    // Telegram hasn't started yet; Instagram, added before, is on and started all the same.
    expect(ig.enabled, isTrue);
    expect(ig.starts, 1);
    final registry = PluginRegistry(shippedPlugins);
    expect(registry.isOn(networkPlugins.firstWhere((p) => p.network == 'instagram'), AppStore(app)), isTrue);
    // Messenger is being looked at for the first time (unset), and is added while that is going on: it stays on.
    final messenger = networkPlugins.firstWhere((p) => p.network == 'messenger');
    registry.setOn(messenger, AppStore(app), true);
    await pumpEventQueue();
    expect(li.enabled, isTrue);
    slow.complete();
    await started;
    expect(app.choice('inbox_on_messenger', ''), 'on', reason: 'the first look settles off only what is still unset');
    expect(registry.isOn(messenger, AppStore(app)), isTrue);
  });

  test('official and plugins are told apart', () {
    final tg = _Net('telegram', officialOverride: true);
    final sg = _Net('signal', officialOverride: true);
    final wa = _Net('whatsapp');
    Inbox.instance = Inbox.of([tg, wa, sg]);
    expect(Inbox.instance.official.map((n) => n.id), ['telegram', 'signal']);
    expect(Inbox.instance.plugins.map((n) => n.id), ['whatsapp']);
  });
}

extension on _Net {
  void setLinked() => _state = InboxState.ready;
}
