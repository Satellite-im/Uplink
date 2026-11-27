import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/kit/settings_css.dart';
import 'package:ghost_messaging/main.dart' show InkOverrides;
import 'package:ghost_messaging/looks.dart';
import 'package:glacier/glacier.dart';

/// A phone made up for a test of the list of conversations with plugins (test/plugins_list_test.dart and the
/// plugins' own tests): the channel answered from [conversations], what the screens asked of it kept in [asked],
/// what they put on the clipboard in [copied], and the person's choices as they would be kept.
class ListPhone {
  ListPhone(this.conversations);

  /// As Android hands them over: `id`, `date`, `people`, `snippet`, `unread`, `archived`, `muted`.
  final List<Map<String, Object?>> conversations;
  final asked = <String>[];

  /// The conversations asked for one by one (`conversation`), and how many times each lot of the list was asked for
  /// (`conversationsPage`, by the row it starts at).
  final alone = <int>[];
  final lots = <int>[];

  /// Each conversation's messages, as `messages` gives them (newest first); none where it is not here.
  final messages = <int, List<Map<String, Object?>>>{};
  final copied = <String>[];
  final prefs = <String, String>{};

  /// The phone's contacts, as searchContacts gives them: `address`, `name`, `photo`, `label`.
  final contacts = <Map<String, String?>>[];

  /// The conversations asked for by address (threadFor), each given a thread number.
  final threads = <String>[];

  static Map<String, Object?> person(String address, [String? name]) => {'address': address, 'name': name, 'photo': null};

  /// A conversation with one person, [minutes] old.
  static Map<String, Object?> conversation(int id, String address, String snippet, {String? name, int minutes = 1, bool unread = false, bool archived = false, bool muted = false}) => {
        'id': id,
        'date': DateTime.now().subtract(Duration(minutes: minutes)).millisecondsSinceEpoch,
        'people': [person(address, name)],
        'snippet': snippet,
        'unread': unread,
        'error': false,
        'archived': archived,
        'muted': muted,
      };

  Map<String, Object?> _one(int id) => conversations.firstWhere((c) => c['id'] == id);

  void install() {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied.add(((call.arguments as Map)['text'] as String?) ?? '');
      return null;
    });
    messenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (call) async {
      final args = (call.arguments as Map?) ?? const {};
      switch (call.method) {
        case 'conversationsPage':
          if (args['archived'] == true) return {'items': conversations.where((c) => c['archived'] == true).toList(), 'next': null};
          lots.add((args['offset'] as num?)?.toInt() ?? 0);
          final from = ((args['offset'] as num?)?.toInt() ?? 0).clamp(0, conversations.length);
          final limit = (args['limit'] as num?)?.toInt() ?? 0;
          final to = limit == 0 ? conversations.length : (from + limit).clamp(0, conversations.length);
          return {'items': conversations.sublist(from, to), 'next': to < conversations.length ? to : null};
        case 'conversation':
          final id = (args['thread'] as num).toInt();
          alone.add(id);
          return conversations.where((c) => c['id'] == id).firstOrNull;
        case 'messages':
          return messages[(args['thread'] as num).toInt()] ?? const [];
        case 'archivedCount':
          return conversations.where((c) => c['archived'] == true).length;
        case 'markRead':
          asked.add('markRead ${args['thread']}');
          _one((args['thread'] as num).toInt())['unread'] = false;
          return null;
        case 'threadFlag':
          asked.add('${args['name']} ${args['thread']} ${args['on']}');
          if (args['name'] == 'muted') _one((args['thread'] as num).toInt())['muted'] = args['on'] == true;
          return null;
        case 'setPref':
          prefs[args['key'] as String] = args['value'] as String;
          return null;
        case 'prefs':
          return prefs;
        case 'status':
          return {'isDefault': true, 'contacts': true, 'notifications': true, 'phone': true};
        case 'arriving':
          return <String, Object?>{};
        case 'searchContacts':
          final q = '${args['query'] ?? ''}'.toLowerCase();
          return [for (final c in contacts) if (q.isEmpty || (c['name'] ?? '').toLowerCase().contains(q) || (c['address'] ?? '').contains(q)) c];
        case 'threadFor':
          threads.add('${(args['addresses'] as List?)?.join(',')}');
          return 900 + threads.length;
        default:
          return null;
      }
    });
  }
}

/// The app's stylesheets, read once for a test.
Future<TokenSheet> loadSheet(WidgetTester tester) async {
  final sheet = (await tester.runAsync(() => loadTokenSheet(more: const ['assets/css/ink.css', 'assets/css/app.css'])))!;
  installSettingsStyles(sheet);
  return sheet;
}

/// Draws [screen] as the app would, on a phone's screen, with [state] for the person's choices.
Future<void> pumpScreen(WidgetTester tester, TokenSheet sheet, Widget screen, AppState state, {Size size = const Size(412, 892), String platform = 'mobile'}) async {
  tester.view.physicalSize = size * 2.0;
  tester.view.devicePixelRatio = 2.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(AppScope(
    state: state,
    child: WidgetsApp(
      color: const Color(0xFF4F5BD5),
      debugShowCheckedModeBanner: false,
      pageRouteBuilder: <T>(RouteSettings s, WidgetBuilder b) => PageRouteBuilder<T>(settings: s, pageBuilder: (c, _, _) => b(c)),
      builder: (context, child) => GlacierTheme(
        sheet: sheet,
        attrs: {'theme': 'light', ...ghostAttrs(state, platform)},
        child: InkOverrides(child: GlacierToastProvider(child: child!)),
      ),
      home: screen,
    ),
  ));
  await settle(tester);
}

/// Lets what was asked of the phone come back and be drawn.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}
