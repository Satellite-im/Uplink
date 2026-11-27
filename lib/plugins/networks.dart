/// The other networks as plugins in the Marketplace (Matt, 2026-11-20: "I don't see instagram and others listed as
/// plugins in the marketplace"; "i want all of them to be in the marketplace"): WhatsApp, Matrix, Microsoft Teams,
/// Google Chat, Messenger, Instagram, Discord, X and Slack, each a card with Add. (LinkedIn was one until 2026-11-21: lib/inbox/inbox.dart.)
///
/// Its switch is the network's own (lib/inbox/inbox.dart, `inbox_on_<id>`), the one Settings › Connections shows: added
/// here it is on there, and the other way round. Adding one starts it so it can be signed in to; removing it signs out.
/// Telegram and Signal are the app's own connections and are not here; Bluesky and Mastodon are not offered yet.
library;

import 'dart:async';

import '../art/app_icon.dart' show LucideIcon;
import '../art/lucide.g.dart';
import '../inbox/inbox.dart';
import 'plugin.dart';

/// One network's card in the Marketplace. It keeps no switch of its own ([OwnSwitch]): on is the network's own
/// switch, and turning it starts the network or signs it out.
class NetworkPlugin extends GhostPlugin implements OwnSwitch {
  const NetworkPlugin(this.network, this.name, {required this.hue, this.caution});

  /// The network's id (InboxNetwork.id).
  final String network;

  @override
  final String name;

  @override
  final String hue;

  /// What is said where the network allows no other apps; null where it does.
  final String? caution;

  /// The network in this build, or null where this build has none of that name.
  InboxNetwork? get connection => Inbox.instance.named(network);

  @override
  String get id => 'net$network';

  @override
  String get description => 'Your $name chats among your texts in Messages, each marked with its logo, read and answered here.';

  @override
  String get tagline => 'Your $name chats in Messages';

  @override
  LucideIcon get icon => Lucide.messageSquare;

  @override
  bool get onByDefault => false;

  @override
  PluginShelf get shelf => PluginShelf.networks;

  @override
  List<String> get adds => ['Your $name chats in Messages, marked with its logo', 'A $name page in Settings › Connections, to sign in and out'];

  @override
  List<PluginReach> get reaches => [
        PluginReach(Lucide.messageSquare, 'Your $name chats, on this device', 'They go between this device and $name only. Uplink\'s own server never sees them.'),
        PluginReach(Lucide.userRound, 'Your $name sign-in, kept on this device', 'Removing the plugin signs you out and forgets it.'),
        if (caution != null) PluginReach(Lucide.info, 'Not an official $name app', caution),
      ];

  @override
  bool get on => connection?.enabled ?? false;

  @override
  Future<void> turn(bool on) async {
    final n = connection;
    // Not started yet (nothing to keep the switch in), or not offered.
    if (n == null || n.soon || n.listStore == null) return;
    await (on ? Inbox.instance.enable(n) : Inbox.instance.disable(n));
  }
}

/// The caution for a network reached as its own website is, which allows no other apps.
const _unofficial = 'It signs in the way the network\'s own website does. The network doesn\'t allow other apps and may limit or close an account that uses one.';

/// Every network that is a plugin, in the order the Marketplace lists them.
const List<NetworkPlugin> networkPlugins = [
  NetworkPlugin('whatsapp', 'WhatsApp', hue: 'green', caution: _unofficial),
  NetworkPlugin('matrix', 'Matrix', hue: 'graphite'),
  NetworkPlugin('teams', 'Microsoft Teams', hue: 'indigo'),
  NetworkPlugin('googlechat', 'Google Chat', hue: 'mint'),
  NetworkPlugin('messenger', 'Messenger', hue: 'blue', caution: _unofficial),
  NetworkPlugin('instagram', 'Instagram', hue: 'magenta', caution: _unofficial),
  NetworkPlugin('discord', 'Discord', hue: 'indigo', caution: _unofficial),
  NetworkPlugin('twitter', 'X', hue: 'graphite', caution: _unofficial),
  NetworkPlugin('slack', 'Slack', hue: 'purple', caution: _unofficial),
];
