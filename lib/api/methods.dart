/// The API's methods (lib/api/api.dart): the app's texts and conversations, its settings and plugins, the other
/// networks (Telegram, Signal), friends on our own system and the relay server's hub, and what is on the screen.
library;

import 'dart:convert';
import '../platform_info.dart';

import '../app_state.dart';
import '../friends/buddies.dart';
import '../inbox/inbox.dart';
import '../me/me.dart';
import '../net/net.dart';
import '../plugins/pack/pack.dart' show DevSource, InstalledPlugins, PackIssue, packAppStoreBuild, parsePack, registryIdOf;
import '../plugins/plugin.dart';
import '../plugins/registry.dart';
import '../presence.dart';
import '../sms.dart';
import '../ui/common.dart' show toast;
import '../ui/inbox_ui.dart' show InboxChatScreen;
import '../ui/settings_panes.dart' show appVersion;
import '../ui/shell.dart';
import 'api.dart';

// --- what the methods answer with ------------------------------------------------------------------------------------

// A person, a conversation of texts and one of its messages, another network's chat and one of its messages, and
// someone's presence, each as JSON. The field names are the API's, so changing one changes what clients read.
Map<String, Object?> personJson(Person p) => {'address': p.address, 'name': p.name};

Map<String, Object?> conversationJson(Conversation c) => {
      'thread': c.id,
      'date': c.date,
      'people': [for (final p in c.people) personJson(p)],
      'snippet': c.snippet,
      'unread': c.unread,
      'archived': c.archived,
      'pinned': c.pinned,
      'muted': c.muted,
      'error': c.error,
      'group': c.group,
    };

Map<String, Object?> messageJson(Message m) => {
      'id': m.id,
      'kind': m.kind,
      'address': m.address,
      'body': m.body,
      'date': m.date,
      'outgoing': m.outgoing,
      'state': m.state,
      'read': m.read,
      'attachments': [for (final a in m.attachments) {'id': a.id, 'type': a.type, 'name': a.name}],
      if (m.why != null) 'why': m.why,
      if (m.via != null) 'via': m.via,
      if (m.reactions.isNotEmpty) 'reactions': m.reactions,
    };

Map<String, Object?> chatJson(InboxChat c) => {
      'network': c.network,
      'chat': c.id,
      'title': c.title,
      'date': c.date,
      'snippet': c.snippet,
      'unread': c.unread,
      'group': c.group,
      'muted': c.muted,
      'lastFromMe': c.lastFromMe,
      'stranger': c.stranger,
    };

Map<String, Object?> inboxMessageJson(InboxMessage m) => {
      'id': m.id,
      'text': m.text,
      'date': m.date,
      'mine': m.mine,
      'sender': m.sender,
      'state': m.state,
      'media': [for (final x in m.media) {'kind': x.kind, 'fileId': x.fileId, 'name': x.name}],
      'reactions': [for (final r in m.reactions) {'emoji': r.emoji, 'count': r.count, 'mine': r.mine}],
      if (m.replyTo != null) 'replyTo': m.replyTo,
    };

Map<String, Object?>? presenceJson(InboxPresence? p) => p == null ? null : {'network': p.network, 'online': p.online, 'lastSeen': p.lastSeen, 'words': p.words()};

// --- small helpers ---------------------------------------------------------------------------------------------------

// A parameter read as a whole number or as words; one missing, with no fallback, is a bad_params error.
int _int(Map<String, Object?> p, String k, [int? fallback]) => (p[k] as num?)?.toInt() ?? fallback ?? (throw ApiError('bad_params', '"$k" is needed'));
String _str(Map<String, Object?> p, String k) => (p[k] as String?) ?? (throw ApiError('bad_params', '"$k" is needed'));

/// The network a call names in "network", which must be signed in: an [ApiError] where it isn't one or isn't.
InboxNetwork _network(Map<String, Object?> p) {
  final id = _str(p, 'network');
  final n = Inbox.instance.named(id);
  if (n == null) throw ApiError('not_found', 'No network called "$id". networks.list gives them.');
  if (n.state != InboxState.ready) throw ApiError('failed', '${n.name} is not signed in.');
  return n;
}

/// The app's shell, for the methods that change what is on the screen; fails while no screen is open.
AppShellState _shell() => AppShellState.live ?? (throw const ApiError('failed', 'The app\'s screens are not open.'));

/// The id a plugin's file gives itself, where it is readable at all: what an answer about a broken one names.
String? _packIdIn(Object? pack, Object? text) {
  try {
    final json = pack ?? jsonDecode(text as String);
    final id = json is Map ? json['id'] : null;
    return id is String ? id : null;
  } catch (_) {
    return null;
  }
}

/// Plugins in development are loaded and removed in developer mode only, as Settings › Developer has them.
void _devModeOn(AppState app) {
  if (!app.flag('dev_mode', fallback: false)) throw const ApiError('failed', 'Turn on developer mode first: tap Settings › About › Version twelve times.');
}

// Parameters that several methods take.
const _thread = ApiParam('thread', 'int', 'The conversation\'s number (conversations.list gives them).', required: true, example: 4);
const _netParam = ApiParam('network', 'string', 'telegram or signal.', required: true, example: 'telegram');
const _chatParam = ApiParam('chat', 'string', 'The chat\'s id on that network (networks.chats gives them).', required: true, example: '123456789');

/// Every method, for the app [app].
List<ApiMethod> appMethods(AppState app) {
  final store = AppStore(app);
  final plugins = PluginRegistry.instance;
  GhostPlugin plugin(String id) => plugins.plugins.where((x) => x.id == id).firstOrNull ?? (throw ApiError('not_found', 'No plugin called "$id". plugins.list gives them.'));

  return [
    // --- the app -----------------------------------------------------------------------------------------------------
    ApiMethod(
      name: 'app.info',
      summary: 'The app\'s version, the device, whether it is the default texting app, and who is signed in where.',
      returns: '{"version", "platform", "defaultSms", "username", "networks": [...]}',
      run: (_) async {
        final status = await Sms.instance.status();
        return {
          'version': appVersion,
          'platform': PlatformInfo.operatingSystem,
          'osVersion': PlatformInfo.operatingSystemVersion,
          'defaultSms': status.usable,
          'username': Me.instance.username,
          'networks': [for (final n in Inbox.instance.networks) if (!n.soon) {'id': n.id, 'name': n.name, 'state': n.state.name, 'account': n.account}],
        };
      },
    ),
    ApiMethod(
      name: 'app.prefs.get',
      summary: 'The person\'s choices as the app keeps them: one by its key, or all whose keys start with a prefix (all of them with none given).',
      params: const [ApiParam('key', 'string', 'One choice\'s key.', example: 'theme'), ApiParam('prefix', 'string', 'All choices starting with this.', example: 'plugin_')],
      returns: '{"key": "value", ...}',
      example: const {'prefix': 'plugin_spam'},
      run: (p) async {
        final key = p['key'] as String?;
        if (key != null) return {key: app.choice(key, '')};
        return app.withPrefix((p['prefix'] as String?) ?? '');
      },
    ),
    ApiMethod(
      name: 'app.prefs.set',
      summary: 'Sets one of the person\'s choices, as Settings would. Some take effect only once the screen they belong to is opened again.',
      params: const [ApiParam('key', 'string', 'The choice\'s key.', required: true, example: 'sounds'), ApiParam('value', 'string', 'Its value: on/off for a switch.', required: true, example: 'on')],
      danger: true,
      example: const {'key': 'sounds', 'value': 'on'},
      run: (p) async {
        app.set(_str(p, 'key'), _str(p, 'value'));
        return null;
      },
    ),
    ApiMethod(
      name: 'app.log',
      summary: 'The newest lines of the Developer log (Settings › Developer).',
      params: const [ApiParam('limit', 'int', 'How many lines, newest first.', example: 50)],
      returns: '["line", ...]',
      run: (p) async {
        final (lines, _) = await Sms.instance.devLogRead(appVersion);
        final limit = _int(p, 'limit', 100);
        return lines.reversed.take(limit).toList();
      },
    ),
    ApiMethod(
      name: 'app.update',
      summary: 'Where the app\'s own update stands: the version installed, any newer one, and whether it is downloading.',
      returns: 'object',
      run: (_) async {
        final u = await Sms.instance.update();
        return {'phase': u.phase, 'current': u.current, 'available': u.available, 'progress': u.progress, 'error': u.error, 'auto': u.auto, 'source': u.source};
      },
    ),

    // --- conversations of texts --------------------------------------------------------------------------------------
    ApiMethod(
      name: 'conversations.list',
      summary: 'Conversations of texts (and RCS beside Google Messages), newest first, a page at a time.',
      params: const [ApiParam('limit', 'int', 'How many (default 50).', example: 20), ApiParam('offset', 'int', 'Where to start: the "next" a page gave.', example: 0), ApiParam('archived', 'bool', 'The archived ones instead.')],
      returns: '{"items": [conversation...], "next": int|null}',
      example: const {'limit': 10},
      run: (p) async {
        final page = await Sms.instance.conversationsPage(limit: _int(p, 'limit', 50), offset: _int(p, 'offset', 0), archived: p['archived'] == true);
        return {'items': [for (final c in page.items) conversationJson(c)], 'next': page.next};
      },
    ),
    ApiMethod(name: 'conversations.get', summary: 'One conversation by its number.', params: const [_thread], returns: 'conversation | null', example: const {'thread': 4}, run: (p) async {
      final c = await Sms.instance.conversation(_int(p, 'thread'));
      return c == null ? null : conversationJson(c);
    }),
    ApiMethod(
      name: 'conversations.messages',
      summary: 'A conversation\'s messages, newest first: texts, picture messages and RCS, with their state and attachments.',
      params: const [_thread, ApiParam('limit', 'int', 'How many (default 100).', example: 30)],
      returns: '[message...]',
      example: const {'thread': 4, 'limit': 20},
      run: (p) async => [for (final m in await Sms.instance.messages(_int(p, 'thread'), limit: _int(p, 'limit', 100))) messageJson(m)],
    ),
    ApiMethod(
      name: 'conversations.threadFor',
      summary: 'The conversation\'s number for these people, made if there is none yet.',
      params: const [ApiParam('addresses', 'list', 'Phone numbers.', required: true, example: ['+15555550100'])],
      returns: 'int',
      run: (p) async => Sms.instance.threadFor([for (final a in p['addresses'] as List) '$a']),
    ),
    ApiMethod(name: 'conversations.markRead', summary: 'Marks a conversation read (in Google Messages too, beside it).', params: const [_thread], run: (p) async {
      await Sms.instance.markRead(_int(p, 'thread'));
      return null;
    }),
    ApiMethod(
      name: 'conversations.archive',
      summary: 'Archives a conversation, or brings it back.',
      params: const [_thread, ApiParam('archived', 'bool', 'true to archive, false to bring back.', required: true, example: true)],
      run: (p) async {
        await Sms.instance.archive(_int(p, 'thread'), p['archived'] == true);
        return null;
      },
    ),
    for (final flag in const ['pinned', 'muted'])
      ApiMethod(
        name: 'conversations.${flag == 'pinned' ? 'pin' : 'mute'}',
        summary: flag == 'pinned' ? 'Pins a conversation to the top of the list, or unpins it.' : 'Mutes a conversation\'s notifications, or unmutes them.',
        params: [_thread, ApiParam('on', 'bool', 'true or false.', required: true, example: true)],
        run: (p) async {
          await Sms.instance.threadFlag(flag, _int(p, 'thread'), p['on'] == true);
          return null;
        },
      ),
    ApiMethod(
      name: 'conversations.rename',
      summary: 'Names a group conversation here (empty takes the name away).',
      params: const [_thread, ApiParam('name', 'string', 'The name.', required: true, example: 'Weekend crew')],
      run: (p) async {
        await Sms.instance.setThreadName(_int(p, 'thread'), _str(p, 'name'));
        return null;
      },
    ),
    ApiMethod(
      name: 'conversations.draft',
      summary: 'What is half written in a conversation; with "text", sets it.',
      params: const [_thread, ApiParam('text', 'string', 'A new draft (empty clears it).')],
      returns: 'string | null',
      run: (p) async {
        final thread = _int(p, 'thread');
        if (p['text'] is String) await Sms.instance.setDraft(thread, p['text'] as String);
        return Sms.instance.draft(thread);
      },
    ),
    ApiMethod(name: 'conversations.delete', summary: 'Deletes a conversation from the phone, for every app. It cannot be undone.', params: const [_thread], danger: true, run: (p) async {
      await Sms.instance.deleteThread(_int(p, 'thread'));
      return null;
    }),

    // --- sending -----------------------------------------------------------------------------------------------------
    ApiMethod(
      name: 'messages.send',
      summary: 'Sends a text to these people, as the app would (RCS beside Google Messages where the conversation is RCS).',
      params: const [ApiParam('addresses', 'list', 'Phone numbers.', required: true, example: ['+15555550100']), ApiParam('body', 'string', 'The words.', required: true, example: 'Sent from the API')],
      returns: 'int: the conversation\'s number',
      danger: true,
      run: (p) async => Sms.instance.send([for (final a in p['addresses'] as List) '$a'], _str(p, 'body')),
    ),
    ApiMethod(
      name: 'messages.delete',
      summary: 'Deletes one message from the phone by its kind and id (as conversations.messages gives them).',
      params: const [ApiParam('kind', 'string', 'sms, mms or rcs.', required: true, example: 'sms'), ApiParam('id', 'int', 'Its id.', required: true, example: 1234)],
      danger: true,
      run: (p) async {
        await Sms.instance.deleteMessage(Message(id: _int(p, 'id'), kind: _str(p, 'kind'), address: '', body: '', date: DateTime.now(), outgoing: false, state: 'sent'));
        return null;
      },
    ),

    // --- contacts ----------------------------------------------------------------------------------------------------
    ApiMethod(name: 'contacts.get', summary: 'Who a number is, as the phone\'s contacts have them.', params: const [ApiParam('address', 'string', 'A phone number.', required: true, example: '+15555550100')], returns: 'person', run: (p) async => personJson(await Sms.instance.contact(_str(p, 'address')))),
    ApiMethod(
      name: 'presence.get',
      summary: 'Whether someone is on now, and where, or when they were last seen: a number, a friend\'s @username, or network:id (Telegram).',
      params: const [ApiParam('address', 'string', 'A phone number, @username, or telegram:<user id>.', required: true, example: '@friend')],
      returns: '{"network", "online", "lastSeen", "words"} | null',
      run: (p) async => presenceJson(Presence.of(_str(p, 'address'))),
    ),

    // --- plugins and the filters -------------------------------------------------------------------------------------
    ApiMethod(
      name: 'plugins.list',
      summary: 'Every plugin, whether it is on, and its own choices: the built-in ones and those from the Marketplace and in development (whose ids start with x).',
      returns: '[{"id", "name", "description", "on", "prefs", "source": "builtIn"|"reviewed"|"dev", "version"}...]',
      run: (_) async => [
        for (final x in plugins.plugins) {'id': x.id, 'name': x.name, 'description': x.description, 'on': plugins.isOn(x, store), 'prefs': app.withPrefix('plugin_${x.id}_'), 'source': x.source.name, 'version': x.version},
      ],
    ),
    ApiMethod(
      name: 'plugins.set',
      summary: 'Turns a plugin on or off.',
      params: const [ApiParam('id', 'string', 'The plugin\'s id.', required: true, example: 'spam'), ApiParam('on', 'bool', 'true or false.', required: true, example: true)],
      run: (p) async {
        plugins.setOn(plugin(_str(p, 'id')), store, p['on'] == true);
        return null;
      },
    ),
    ApiMethod(
      name: 'plugins.pref',
      summary: 'One of a plugin\'s own choices (the spam filter\'s strictness, a sign on or off); with "value", sets it.',
      params: const [ApiParam('id', 'string', 'The plugin\'s id.', required: true, example: 'spam'), ApiParam('key', 'string', 'The choice.', required: true, example: 'level'), ApiParam('value', 'string', 'A new value.')],
      returns: 'string | null',
      example: const {'id': 'spam', 'key': 'level'},
      run: (p) async {
        final prefs = plugins.prefsOf(plugin(_str(p, 'id')), store);
        if (p['value'] is String) prefs.set(_str(p, 'key'), p['value'] as String);
        return prefs.get(_str(p, 'key'));
      },
    ),
    ApiMethod(
      name: 'filters.classify',
      summary: 'What the filters make of a text from someone: its tags (spam, its kind) and the section it would go to.',
      params: const [
        ApiParam('text', 'string', 'The words.', required: true, example: 'Your package could not be delivered. Reschedule: bit.ly/3xYz'),
        ApiParam('from', 'string', 'Who sent it.', example: '+15555550100'),
        ApiParam('contact', 'bool', 'Whether they are in your contacts.'),
      ],
      returns: '{"tags": {"name": "detail"}, "section": string|null}',
      example: const {'text': 'Congratulations! You\'ve won a gift card. Claim now: http://prize.example/win'},
      run: (p) async {
        // A text someone sent (outgoing: false), so plugins from other developers see it as they would theirs.
        final facts = MessageFacts(thread: 0, senders: [(p['from'] as String?) ?? '+15555550100'], text: _str(p, 'text'), contact: p['contact'] == true, outgoing: false);
        final tags = plugins.classify(facts, store);
        return {'tags': {for (final n in tags.names) n: tags.detail(n)}, 'section': plugins.sectionOf(facts, tags, store)?.id};
      },
    ),
    // Loading a plugin being made, as Settings › Developer › Plugins in development does (Matt, 2026-11-20: "please add a
    // developer setting for users to be able to manually upload plugins for development testing"). Never in an App
    // Store build, which has no plugins in development.
    if (!packAppStoreBuild) ...[
      ApiMethod(
        name: 'plugins.devInstall',
        summary: 'Loads a plugin you are making (a ghost-plugin/1 file) on this phone, unreviewed, as Settings › Developer › Plugins in development does. Developer mode only. dryRun checks it without loading it.',
        params: const [
          ApiParam('pack', 'object', 'The plugin file\'s JSON. Give this or text.'),
          ApiParam('text', 'string', 'The plugin file\'s words, as they are on disk. Give this or pack.'),
          ApiParam('on', 'bool', 'Switch it on once loaded: only where you agreed on the phone to everything it can do already (false where not given).'),
          ApiParam('dryRun', 'bool', 'Only check it: what is wrong with it, if anything.'),
        ],
        returns: '{"ok": bool, "id": "bills", "plugin": "xbills", "on": bool, "needs": "consent on the phone" (where on was asked and could not be), "issues": [{"code", "path", "message", "severity"}...]}',
        danger: true,
        run: (p) async {
          _devModeOn(app);
          final pack = p['pack'], text = p['text'];
          if (pack == null && text == null) throw const ApiError('bad_params', 'Give the plugin as pack (its JSON) or text (its words).');
          final bytes = text is String ? utf8.encode(text) : utf8.encode(jsonEncode(pack));
          List<Map<String, Object?>> issues(List<PackIssue> all) => [for (final i in all) i.toJson()];
          if (p['dryRun'] == true) {
            final parse = parsePack(bytes, appVersion: appVersion);
            final id = parse.pack?.id;
            return {'ok': parse.ok, 'id': id, 'plugin': id == null ? null : registryIdOf(id), 'on': false, 'issues': issues(parse.issues)};
          }
          final wanted = p['on'] == true;
          final installed = InstalledPlugins.instance;
          final outcome = await installed.loadDev(bytes, const DevSource('api'), on: wanted);
          // An invalid pack is not an error: what is wrong with it is the answer. Refused outright (developer mode,
          // the caps), it is.
          if (!outcome.ok && outcome.code != 'invalid') throw ApiError('failed', outcome.message);
          final plugin = outcome.plugin;
          final on = plugin != null && plugins.isOn(plugin, store);
          final id = plugin?.id.substring(1) ?? _packIdIn(pack, text);
          return {
            'ok': outcome.ok,
            'id': id,
            'plugin': id == null ? null : registryIdOf(id),
            'on': on,
            if (wanted && plugin != null && !on) 'needs': 'consent on the phone',
            'issues': issues(outcome.issues),
          };
        },
      ),
      ApiMethod(
        name: 'plugins.devRemove',
        summary: 'Removes a plugin in development from this phone.',
        params: const [ApiParam('id', 'string', 'Its id, as in its file.', required: true, example: 'bills')],
        danger: true,
        run: (p) async {
          _devModeOn(app);
          final id = _str(p, 'id');
          final installed = InstalledPlugins.instance;
          if (installed.devOf(id) == null) throw ApiError('not_found', 'No plugin in development called "$id". plugins.list gives them, without their x.');
          final outcome = await installed.removeDev(id);
          if (!outcome.ok) throw ApiError('failed', outcome.message);
          return null;
        },
      ),
    ],

    // --- Telegram, Signal and the rest -------------------------------------------------------------------------------
    ApiMethod(name: 'networks.list', summary: 'The other networks: whether each is signed in, and as whom.', returns: '[{"id", "name", "state", "account", "chats"}...]', run: (_) async => [
          for (final n in Inbox.instance.networks) if (!n.soon) {'id': n.id, 'name': n.name, 'state': n.state.name, 'account': n.account, 'chats': n.state == InboxState.ready ? n.chats.length : 0},
        ]),
    ApiMethod(name: 'networks.chats', summary: 'A network\'s chats, newest first.', params: const [_netParam, ApiParam('limit', 'int', 'How many (default 50).')], returns: '[chat...]', example: const {'network': 'telegram', 'limit': 10}, run: (p) async {
      final n = _network(p);
      return [for (final c in n.shownChats.take(_int(p, 'limit', 50))) chatJson(c)];
    }),
    ApiMethod(name: 'networks.messages', summary: 'A chat\'s messages as held, oldest first; loaded from the network first.', params: const [_netParam, _chatParam], returns: '[message...]', run: (p) async {
      final n = _network(p);
      final chat = _str(p, 'chat');
      await n.load(chat);
      return [for (final m in n.messagesOf(chat)) inboxMessageJson(m)];
    }),
    ApiMethod(name: 'networks.send', summary: 'Sends words in a chat on that network.', params: const [_netParam, _chatParam, ApiParam('text', 'string', 'The words.', required: true, example: 'Sent from the API')], danger: true, run: (p) async {
      await _network(p).send(_str(p, 'chat'), _str(p, 'text'));
      return null;
    }),
    ApiMethod(
      name: 'networks.reply',
      summary: 'Sends words as a reply quoting one of the chat\'s messages.',
      params: const [_netParam, _chatParam, ApiParam('message', 'string', 'The id of the message answered.', required: true), ApiParam('text', 'string', 'The words.', required: true)],
      danger: true,
      run: (p) async {
        await _network(p).reply(_str(p, 'chat'), _str(p, 'message'), _str(p, 'text'));
        return null;
      },
    ),
    ApiMethod(
      name: 'networks.react',
      summary: 'Puts a reaction on a message, or takes it off.',
      params: const [_netParam, _chatParam, ApiParam('message', 'string', 'The message\'s id.', required: true), ApiParam('emoji', 'string', 'The reaction.', required: true, example: '👍'), ApiParam('remove', 'bool', 'Take it off instead.')],
      run: (p) async {
        await _network(p).react(_str(p, 'chat'), _str(p, 'message'), _str(p, 'emoji'), remove: p['remove'] == true);
        return null;
      },
    ),
    ApiMethod(name: 'networks.markRead', summary: 'Marks a chat read on its network.', params: const [_netParam, _chatParam], run: (p) async {
      await _network(p).markRead(_str(p, 'chat'));
      return null;
    }),
    ApiMethod(name: 'networks.group', summary: 'A group in full: its name, description, timer, people and rules, and what you may change.', params: const [_netParam, _chatParam], returns: 'object | null', run: (p) async {
      final g = await _network(p).groupDetails(_str(p, 'chat'));
      if (g == null) return null;
      return {
        'title': g.title,
        'description': g.description,
        'timer': g.timer,
        'people': [for (final x in g.people) {'id': x.id, 'name': x.name, 'number': x.number, 'admin': x.admin, 'owner': x.owner, 'me': x.me}],
        'admin': g.admin,
        'announcementsOnly': g.announcementsOnly,
        'editInfoAdminsOnly': g.editInfoAdminsOnly,
        'addPeopleAdminsOnly': g.addPeopleAdminsOnly,
        'inviteLink': g.inviteLink,
        'can': {'editInfo': g.canEditInfo, 'addPeople': g.canAddPeople, 'removePeople': g.canRemovePeople, 'setAdmins': g.canSetAdmins, 'changeRules': g.canChangeRules},
      };
    }),
    ApiMethod(
      name: 'networks.changeGroup',
      summary: 'Changes a group on its network: any of title, description, timer (seconds), add, remove, admin, unadmin (lists of ids), announcementsOnly.',
      params: const [_netParam, _chatParam, ApiParam('change', 'object', 'What to change.', required: true, example: {'title': 'New name'})],
      danger: true,
      run: (p) async {
        final c = (p['change'] as Map).cast<String, Object?>();
        List<String> ids(String k) => [for (final x in (c[k] as List?) ?? const []) '$x'];
        await _network(p).changeGroup(
          _str(p, 'chat'),
          GroupChange(
            title: c['title'] as String?,
            description: c['description'] as String?,
            timer: (c['timer'] as num?)?.toInt(),
            add: ids('add'),
            remove: ids('remove'),
            admin: ids('admin'),
            unadmin: ids('unadmin'),
            announcementsOnly: c['announcementsOnly'] as bool?,
          ),
        );
        return null;
      },
    ),

    // --- our own system: friends and the relay server's hub ----------------------------------------------------------
    ApiMethod(name: 'friends.list', summary: 'Friends by username, those who asked you, and those you asked; with whether each is on.', returns: '[{"username", "name", "state", "presence"}...]', run: (_) async => [
          // Each by its own install's name: never another entry under the same username (found in review, 2026-11-23).
          for (final b in Buddies.instance.all) {'username': b.username, 'name': b.name, 'state': b.state, 'presence': presenceJson(Presence.ofId(b.id))},
        ]),
    ApiMethod(
      name: 'net.status',
      summary: 'The app\'s routes to other installs: this install\'s name, the relay server it uses, how each route stands, and who it can reach.',
      returns: 'object',
      run: (_) async {
        final net = Net.instance;
        return {
          'id': net.id,
          'hub': net.hubUrl,
          'hubState': net.hub?.state.value.name,
          'routes': [for (final c in net.board?.carriers ?? const []) {'id': c.id, 'state': c.state.value.name}],
          // Each one's presence by its own install's name, not by the address the routes hold it under, which may be a
          // group's word for it (found in review, 2026-11-23).
          'peers': [for (final x in net.people) {'id': x.id, 'name': x.name, 'address': x.address, 'presence': presenceJson(Presence.ofId(x.id))}],
          'error': net.error,
        };
      },
    ),

    // --- what is on the screen ---------------------------------------------------------------------------------------
    ApiMethod(name: 'ui.openConversation', summary: 'Opens a conversation of texts on the screen.', params: const [_thread], run: (p) async {
      final thread = _int(p, 'thread');
      final c = await Sms.instance.conversation(thread);
      _shell().openThread(thread, c?.people ?? const []);
      return null;
    }),
    ApiMethod(name: 'ui.openChat', summary: 'Opens a Telegram or Signal chat on the screen.', params: const [_netParam, _chatParam], run: (p) async {
      final n = _network(p);
      final chat = _str(p, 'chat');
      _shell().show(InboxChatScreen(network: n, chatId: chat), showing: 'inbox:${n.id}:$chat');
      return null;
    }),
    ApiMethod(
      name: 'ui.openSettings',
      summary: 'Opens Settings, at one of its sections where given (messages, sounds, developer, api, ...). plugins and plugin-<id> open the Marketplace instead.',
      params: const [ApiParam('section', 'string', 'A section\'s id.', example: 'api')],
      run: (p) async {
        _shell().settings(p['section'] as String?);
        return null;
      },
    ),
    ApiMethod(name: 'ui.compose', summary: 'Opens New message, with words already written where given.', params: const [ApiParam('body', 'string', 'Words to start with.')], run: (p) async {
      _shell().compose(body: p['body'] as String?);
      return null;
    }),
    ApiMethod(name: 'ui.home', summary: 'Closes what is open and goes back to the list of conversations.', run: (_) async {
      final s = _shell();
      s.close();
      s.go('messages');
      return null;
    }),
    ApiMethod(name: 'ui.toast', summary: 'Shows a short note at the foot of the screen.', params: const [ApiParam('text', 'string', 'The words.', required: true, example: 'Hello from the API')], run: (p) async {
      final s = _shell();
      if (!s.mounted) throw const ApiError('failed', 'The app\'s screens are not open.');
      toast(s.context, _str(p, 'text'));
      return null;
    }),
  ];
}
