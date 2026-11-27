import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../app_state.dart';
import 'voice.dart';

/// Discord servers linked into the Spaces tab (Matt, 2026-11-16: "get the ability to join discord voice channels and
/// have spaces emulated as voice chat channels from a discord server ... group all of a servers spaces under one group
/// and show members that are in a space proxied from discord").
///
/// The first step is presence: Uplink's Discord bot (messaging/discord/, on the box at gogho.st/discord) is added to
/// a server, someone with Manage Server types `/ghost link` there and enters the code it gives in the app, and from
/// then on the app shows that server's voice channels as a group of spaces, with who is in each, read from the bot
/// every few seconds. Pressing one joins it from the app: the bot joins that Discord channel and carries the sound and
/// the chat both ways (lib/ui/space_groups_ui.dart).
///
/// Each link is a token only this device holds (kept with its choices, `discord_links`); `/ghost unlink` on the server
/// takes them all away, and the server's group says so.
@immutable
class DiscordLink {
  const DiscordLink({required this.token, required this.guildId, required this.name, this.icon});
  final String token;
  final String guildId;
  final String name;
  final String? icon;

  /// The group this server is in the Spaces tab (SpaceGroups.fold uses it too).
  String get group => 'discord:$guildId';

  Map<String, Object?> toJson() => {'t': token, 'g': guildId, 'n': name, if (icon != null) 'i': icon};

  static DiscordLink? fromJson(Object? j) {
    if (j is! Map || j['t'] is! String || j['g'] is! String || j['n'] is! String) return null;
    return DiscordLink(token: j['t'] as String, guildId: j['g'] as String, name: j['n'] as String, icon: j['i'] as String?);
  }
}

/// Someone in a Discord voice channel, as the bot sees them.
@immutable
class DiscordMember {
  const DiscordMember({required this.id, required this.name, this.avatar, this.muted = false, this.deafened = false, this.video = false, this.streaming = false, this.bot = false});
  final String id;
  final String name;
  final String? avatar;
  final bool muted, deafened, video, streaming, bot;

  static DiscordMember? fromJson(Object? j) {
    if (j is! Map || j['id'] is! String || j['name'] is! String) return null;
    return DiscordMember(
      id: j['id'] as String,
      name: j['name'] as String,
      avatar: j['avatar'] as String?,
      muted: j['muted'] == true,
      deafened: j['deafened'] == true,
      video: j['video'] == true,
      streaming: j['streaming'] == true,
      bot: j['bot'] == true,
    );
  }
}

/// One of a server's voice (or stage) channels: a space in the server's group.
@immutable
class DiscordChannel {
  const DiscordChannel({required this.guildId, required this.id, required this.name, this.stage = false, this.position = 0, this.members = const [], this.bridged = false});
  final String guildId;
  final String id;
  final String name;
  final bool stage;
  final int position;
  final List<DiscordMember> members;

  /// The bridge is in it now: Uplink people are talking there through the bot.
  final bool bridged;

  /// Opens it in Discord (the app where installed, else the web).
  String get link => 'https://discord.com/channels/$guildId/$id';

  static DiscordChannel? fromJson(Object? j, String guildId) {
    if (j is! Map || j['id'] is! String || j['name'] is! String) return null;
    return DiscordChannel(
      guildId: guildId,
      id: j['id'] as String,
      name: j['name'] as String,
      stage: j['kind'] == 'stage',
      position: j['position'] is int ? j['position'] as int : 0,
      members: [for (final m in (j['members'] as List? ?? const [])) ?DiscordMember.fromJson(m)],
      bridged: j['bridged'] == true,
    );
  }
}

/// How a linked server stands, as last read.
@immutable
class DiscordState {
  const DiscordState({this.channels = const [], this.problem, this.at});
  final List<DiscordChannel> channels;

  /// Why it couldn't be read: 'not linked' (unlinked on the server), 'gone' (the bot was removed), or a failure.
  final String? problem;
  final DateTime? at;
}

/// The Discord servers linked on this device: keeps the links, reads each server's voice channels from the bot's
/// service, and asks the bot to bridge a channel when someone joins it from the app.
class DiscordServers extends ChangeNotifier {
  DiscordServers._();
  static final instance = DiscordServers._();

  /// Where the bot's service answers.
  static const defaultBase = 'https://gogho.st/discord';
  String base = defaultBase;

  /// Stands in for the network (a test's server).
  HttpClient Function() client = HttpClient.new;

  AppState? _app;
  List<DiscordLink> _links = const [];
  final Map<String, DiscordState> _states = {};
  Timer? _timer;

  List<DiscordLink> get links => _links;
  /// [l]'s server as last read; empty before the first read.
  DiscordState stateOf(DiscordLink l) => _states[l.token] ?? const DiscordState();

  /// Loads the links kept in [app]'s choices and begins reading their servers. Only the first call does anything.
  void start(AppState app) {
    if (_app != null) return;
    _app = app;
    try {
      _links = [for (final j in jsonDecode(app.choice('discord_links', '[]')) as List) ?DiscordLink.fromJson(j)];
    } catch (_) {}
    _poll();
    notifyListeners();
  }

  /// For a picture or a test: [links] linked with [states] as read, nothing fetched.
  @visibleForTesting
  void put(List<DiscordLink> links, Map<String, DiscordState> states) {
    _timer?.cancel();
    _timer = null;
    _links = links;
    _states
      ..clear()
      ..addAll(states);
    notifyListeners();
  }

  @visibleForTesting
  void reset() {
    _timer?.cancel();
    _timer = null;
    _app = null;
    _links = const [];
    _states.clear();
    base = defaultBase;
    client = HttpClient.new;
  }

  /// Saves the links and restarts the reading, since the set of servers changed.
  void _keep() {
    _app?.set('discord_links', jsonEncode([for (final l in _links) l.toJson()]));
    _poll();
    notifyListeners();
  }

  /// Read every linked server now and every 15 seconds while any is linked.
  void _poll() {
    _timer?.cancel();
    _timer = null;
    if (_links.isEmpty) return;
    unawaited(refresh());
    _timer = Timer.periodic(const Duration(seconds: 15), (_) => refresh());
  }

  /// One request to the bot's service. The answer's JSON (empty where it isn't JSON) with the HTTP status added as
  /// `_status`; throws only where the service can't be reached in time.
  Future<Map<String, dynamic>> _call(String method, String path, {Map<String, Object?>? body}) async {
    final http = client()..connectionTimeout = const Duration(seconds: 10);
    try {
      final req = method == 'POST' ? await http.postUrl(Uri.parse('$base$path')) : await http.getUrl(Uri.parse('$base$path'));
      if (body != null) {
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode(body));
      }
      final res = await req.close().timeout(const Duration(seconds: 15));
      final text = await res.transform(utf8.decoder).join().timeout(const Duration(seconds: 15));
      Map<String, dynamic> said;
      try {
        said = (jsonDecode(text) as Map).cast<String, dynamic>();
      } catch (_) {
        said = {};
      }
      said['_status'] = res.statusCode;
      return said;
    } finally {
      http.close(force: true);
    }
  }

  /// The bot's own invite: Uplink's Discord application (the one account linking uses), able only to see
  /// channels. Used where the service can't be asked.
  static const knownInvite = 'https://discord.com/oauth2/authorize?client_id=1571262060967366837&scope=bot%20applications.commands&permissions=1024';

  /// The link to add the bot to a server: as the service says, or the app's own where it can't be reached.
  Future<String> inviteUrl() async {
    try {
      final r = await _call('GET', '/invite');
      if (r['_status'] == 200 && r['url'] is String) return r['url'] as String;
    } catch (_) {}
    return knownInvite;
  }

  /// Links the server whose `/ghost link` gave [code]. Its name, or throws with words for the person.
  Future<String> claim(String code) async {
    final clean = code.trim().toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
    if (clean.length != 6) throw const DiscordProblem('A code is 6 letters and numbers.');
    final Map<String, dynamic> r;
    try {
      r = await _call('POST', '/claim', body: {'code': clean});
    } catch (_) {
      throw const DiscordProblem('The Discord bot couldn\'t be reached. Try again in a moment.');
    }
    // Only the bot's own answer means the code is wrong; any other "not found" is the web server, with the bot out of
    // reach (Matt, 2026-11-16: "it's saying invalid code even for valid codes", before gogho.st/discord reached it).
    if (r['_status'] == 404 && r['error'] == 'unknown code') throw const DiscordProblem('That code isn\'t right, or it has run out. Type /ghost link again for a new one.');
    if (r['_status'] == 410) throw const DiscordProblem('The bot isn\'t in that server any more. Add it again, then type /ghost link.');
    if (r['_status'] == 503) throw const DiscordProblem('The Discord bot is starting up. Try again in a moment.');
    // An answer with neither an error nor a token didn't come from the bot (a proxy's page, say).
    if (r['_status'] is int && r['error'] == null && r['token'] == null) throw const DiscordProblem('The Discord bot couldn\'t be reached. Try again in a moment.');
    if (r['_status'] == 429) throw const DiscordProblem('Too many tries. Wait a minute and try again.');
    final g = r['guild'];
    if (r['_status'] != 200 || r['token'] is! String || g is! Map || g['id'] is! String || g['name'] is! String) {
      throw const DiscordProblem('The Discord bot answered strangely. Try again.');
    }
    final link = DiscordLink(token: r['token'] as String, guildId: g['id'] as String, name: g['name'] as String, icon: g['icon'] as String?);
    // Linking a server again replaces its old link.
    _links = [for (final l in _links) if (l.guildId != link.guildId) l, link];
    _keep();
    return link.name;
  }

  /// Asks the bridge into [channel] (Matt, 2026-11-16: "I want the bot to connect and act as my voice"): the bot joins
  /// the Discord voice channel and a space of its own for it, and the space is given back to join like any. Throws with
  /// words for the person.
  Future<VoiceChannel> joinVoice(DiscordChannel channel) async {
    final link = _links.where((l) => l.guildId == channel.guildId).firstOrNull;
    if (link == null) throw const DiscordProblem('That server isn\'t linked any more.');
    final Map<String, dynamic> r;
    try {
      r = await _call('POST', '/voice/join', body: {'token': link.token, 'channel': channel.id});
    } catch (_) {
      throw const DiscordProblem('The Discord bot couldn\'t be reached. Try again in a moment.');
    }
    switch (r['_status']) {
      case 200:
        final seed = r['seed'];
        if (seed is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(seed)) throw const DiscordProblem('The Discord bot answered strangely. Try again.');
        return VoiceChannel(seed: seed, name: r['name'] is String ? r['name'] as String : channel.name, discord: '${channel.guildId}/${channel.id}');
      case 401:
        throw const DiscordProblem('This server was unlinked. Add it again with /ghost link.');
      case 403:
        final missing = (r['missing'] as List? ?? const []).join(', ');
        throw DiscordProblem('The bot isn\'t allowed to join that channel${missing.isEmpty ? '' : ' (it needs $missing)'}. Add it again with the new invite link, or give it those permissions.');
      case 404:
        throw const DiscordProblem('That channel isn\'t there any more.');
      case 410:
        throw const DiscordProblem('The bot isn\'t in that server any more. Add it again.');
      case 409:
        throw DiscordProblem(r['error'] == 'full'
            ? 'That channel is full.'
            : 'The bot is already carrying Uplink people in another channel of this server, and it can be in one at a time. Join that one, or try again when it\'s empty.');
      case 429:
        throw const DiscordProblem('Too many tries. Wait a minute and try again.');
      case 502:
        throw const DiscordProblem('The bot couldn\'t connect to Discord voice. Try again in a moment.');
      case 503:
        throw const DiscordProblem('The bot couldn\'t reach Uplink\'s relay. Try again in a moment.');
      default:
        throw const DiscordProblem('The Discord bot couldn\'t join right now. Try again in a moment.');
    }
  }

  /// Takes [link] off this device (the server keeps the bot; /ghost unlink there removes every device's link).
  void remove(DiscordLink link) {
    _links = [for (final l in _links) if (l.token != link.token) l];
    _states.remove(link.token);
    _keep();
  }

  /// Reads every linked server's voice channels and who is in them.
  Future<void> refresh() async {
    for (final l in [..._links]) {
      try {
        final r = await _call('GET', '/state?token=${Uri.encodeQueryComponent(l.token)}');
        final status = r['_status'];
        if (status == 200) {
          final channels = [for (final c in (r['channels'] as List? ?? const [])) ?DiscordChannel.fromJson(c, l.guildId)]..sort((a, b) => a.position.compareTo(b.position));
          _states[l.token] = DiscordState(channels: channels, at: DateTime.now());
          // A new name or picture for the server is kept.
          final g = r['guild'];
          if (g is Map && g['name'] is String && (g['name'] != l.name || g['icon'] != l.icon)) {
            _links = [for (final x in _links) x.token == l.token ? DiscordLink(token: x.token, guildId: x.guildId, name: g['name'] as String, icon: g['icon'] as String?) : x];
            _app?.set('discord_links', jsonEncode([for (final x in _links) x.toJson()]));
          }
        } else {
          // A failed read keeps the channels last seen and says why.
          _states[l.token] = DiscordState(channels: stateOf(l).channels, problem: status == 401 ? 'not linked' : status == 410 ? 'gone' : 'unreachable', at: stateOf(l).at);
        }
      } catch (_) {
        _states[l.token] = DiscordState(channels: stateOf(l).channels, problem: 'unreachable', at: stateOf(l).at);
      }
    }
    notifyListeners();
  }
}

/// Why linking a server didn't work, in words for the person.
class DiscordProblem implements Exception {
  const DiscordProblem(this.words);
  final String words;
  @override
  String toString() => words;
}
