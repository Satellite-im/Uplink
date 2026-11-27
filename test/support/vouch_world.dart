import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:ghost_messaging/friends/buddies.dart';
import 'package:ghost_messaging/friends/vouches.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/packet.dart';

// For the vouches' tests (test/vouches_test.dart, test/vouches_screens_test.dart).

/// Installs that each hold their own key, reach each other sealed only where both hold the other as a friend, and
/// write down everything sent.
class VouchWorld {
  final Map<String, VouchPort> byId = {};
}

class VouchPort implements BuddiesPort, BuddiesSigner {
  VouchPort(this.world, this.name, {NetKeys? keys}) : keys = keys ?? NetKeys.generate() {
    world.byId[this.keys.id] = this;
  }

  final VouchWorld world;
  final String name;
  final NetKeys keys;
  String list = '[]';
  final sent = <({String to, Envelope envelope, bool sealed})>[];
  final _in = StreamController<({String from, Envelope envelope})>.broadcast();
  final _hellos = StreamController<({String from, Envelope envelope})>.broadcast();

  String get key => base64Encode(keys.public);

  /// The installs nothing sent reaches.
  final cut = <String>{};
  bool _holds(String id) => (jsonDecode(list) as List).any((b) => (b as Map)['i'] == id && b['s'] != 'blocked');

  @override
  Future<Uint8List> sign(List<int> message) async => NetCrypto.sign(keys, message);
  @override
  Future<({String id, String key})> me() async => (id: keys.id, key: key);
  @override
  String? get username => name;
  @override
  String get displayName => '';
  @override
  String get bio => '';
  @override
  Future<({String id, String key})?> whois(String username) async => null;
  @override
  Future<void> keep(String json) async => list = json;
  @override
  Future<String> kept() async => list;

  @override
  Future<bool> send(String id, Envelope envelope, {bool sealed = true}) async {
    sent.add((to: id, envelope: envelope, sealed: sealed));
    // Lost on the way to those [cut] names, as to someone who is away until it runs out.
    if (cut.contains(id)) return true;
    final to = world.byId[id];
    if (to == null || (sealed && (!_holds(id) || !to._holds(keys.id)))) return false;
    scheduleMicrotask(() => (sealed ? to._in : to._hellos).add((from: keys.id, envelope: envelope)));
    return true;
  }

  /// Hands [to] an envelope as if this install sent it, whatever it would send itself (a replay, a forgery).
  void deliver(VouchPort to, Envelope e) => scheduleMicrotask(() => to._in.add((from: keys.id, envelope: e)));

  @override
  Stream<({String from, Envelope envelope})> get received => _in.stream;
  @override
  Stream<({String from, Envelope envelope})> get greetings => _hellos.stream;
}

Buddy friendOf(VouchPort p) => Buddy(username: p.name, id: p.keys.id, key: p.key, state: 'yes', at: 1);

/// Makes each pair in [pairs] friends, then starts every one.
/// Each carries what it holds to friends [carryAfter] after it changes (none: as soon as the event queue turns).
Future<Map<VouchPort, Buddies>> makeFriends(List<(VouchPort, VouchPort)> pairs, {Map<VouchPort, Vouches>? stores, Duration carryAfter = Duration.zero}) async {
  final lists = <VouchPort, List<Buddy>>{};
  for (final (a, b) in pairs) {
    lists.putIfAbsent(a, () => []).add(friendOf(b));
    lists.putIfAbsent(b, () => []).add(friendOf(a));
  }
  final out = <VouchPort, Buddies>{};
  for (final e in lists.entries) {
    e.key.list = jsonEncode([for (final b in e.value) b.toJson()]);
    out[e.key] = Buddies(e.key, vouches: stores?[e.key], carryAfter: carryAfter);
    await out[e.key]!.start();
  }
  return out;
}

