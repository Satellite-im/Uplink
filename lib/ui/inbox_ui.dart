import 'dart:async';
import 'blocking.dart';
import 'dart:io';
import '../platform_info.dart';



import 'package:flutter/services.dart' show Clipboard, ClipboardData, HapticFeedback, TextCapitalization, TextInputAction, TextInputType, rootBundle;
import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../voice/voice_changer.dart';
import '../app_state.dart';
import '../art/app_icon.dart';
import '../art/lucide.g.dart';
import '../art/lucide_more.dart';
import '../backgrounds.dart';
import '../inbox/bluesky.dart';
import '../inbox/alerts.dart';
import '../inbox/inbox.dart';
import '../inbox/mastodon.dart';
import '../desktop/ui/qr.dart';
import '../inbox/signal.dart';
import '../inbox/teams.dart';
import '../inbox/google_chat.dart';
import '../inbox/whatsapp.dart';
import '../inbox/matrix.dart';
import '../net/pair_room.dart';
import '../inbox/telegram.dart';
import '../kit/settings_kit.dart';
import '../kit/settings_type.dart';
import '../me/me.dart' as me;
import '../me/me.dart' show Me;
import '../mentions.dart' show Mention;
import '../sms.dart';
import '../links.dart' show MessageLink;
import '../plugins/codes.dart' show signInCode;
import '../plugins/embeds.dart' show EmbedCard, EmbedsPlugin;
import '../plugins/plugin.dart' show MessageFacts;
import '../plugins/registry.dart' show AppStore, PluginRegistry;
import 'chat_rail.dart';
import 'chat_rows.dart';
import 'common.dart';
import 'skeleton.dart';
import 'window_title.dart';
import 'picture_overlay.dart';
import 'emoji_picker.dart';
import 'emoji_suggestions.dart';
import 'mention_field.dart' show mentionStyle;
import 'profile_card.dart';
import 'composer_box.dart';
import 'poof.dart';
import 'sticker_picker.dart' show pickSticker;
import 'reaction_stickers.dart';
import 'video_screen.dart';
import 'voice.dart' show VoiceRecorder, micRefusedWords, voiceProblem;
import 'conversations.dart' show ConversationRow;
import 'group_drawer.dart' show showGroupDrawer;
import 'flat_line.dart';
import 'thread.dart' show LinkedText;
import 'me.dart' show NetworkMark;
import '../inbox/account_helper.dart';
import 'inbox_signin_helper.dart';
import 'settings.dart';
import 'shell.dart';
import '../kit/semantic_colors.dart';
import 'dialup/bevel.dart' show DialupColors, isDialup;
import 'message_line.dart';
import 'translated_card.dart';
import 'jump_to_latest.dart';
import 'inbox_signin_teams.dart';
import 'inbox_signin_google_chat.dart';
import 'inbox_signin_whatsapp.dart' show WhatsAppLinkScreen;
import 'inbox_signin_matrix.dart';
import 'paste_images.dart';
import 'schedule_ui.dart';
import '../scheduled.dart' show ScheduleTarget;
import '../kit/picture_decode.dart';
import '../plugins/plugin_sync.dart';
import '../l10n/words.dart';

/// The screens of the inbox of other networks (lib/inbox): a chat's row in the list, the chat itself, signing in, and
/// the sections of Settings for each network.

/// The list's tab for [network] (lib/ui/conversations.dart).
String inboxTab(InboxNetwork network) => '*inbox-${network.id}';

/// The network a tab of the list is, or null for any other tab.
InboxNetwork? inboxOfTab(String? tab) => tab != null && tab.startsWith('*inbox-') ? Inbox.instance.named(tab.substring(7)) : null;

/// A network's logo, as Settings › Me draws it.
Widget inboxMark(InboxNetwork network, {double size = 18, bool badge = false}) => NetworkMark(
      me.networks.where((n) => n.id == network.id).firstOrNull ?? me.Network(network.id, network.name, 'blue', network.name[0], signIn: false),
      size: size,
      badge: badge,
    );

/// One chat in the list: drawn as a conversation is, so the tab reads like the rest of the app.
class InboxChatRow extends StatelessWidget {
  const InboxChatRow({super.key, required this.chat, required this.onPress, this.onLongPress, this.selected = false});
  final InboxChat chat;
  final VoidCallback onPress;
  final VoidCallback? onLongPress;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final c = Conversation(
      // The row draws from the conversation alone; the id is only for keys.
      id: -(chat.id.hashCode & 0x3fffffff) - 1,
      date: chat.date,
      people: [Person(address: '${chat.network}:${chat.id}', name: chat.title, photo: chat.avatar)],
      snippet: chat.lastFromMe && chat.snippet.isNotEmpty ? 'You: ${chat.snippet}' : chat.snippet,
      unread: chat.unread > 0,
      error: false,
      archived: false,
    );
    final network = Inbox.instance.named(chat.network);
    // Its network's mark on the corner of the face, so a Telegram or Bluesky chat among the texts says what it is.
    return ConversationRow(conversation: c, selected: selected, onPress: onPress, onLongPress: onLongPress ?? onPress, badge: network == null ? null : inboxMark(network, size: 20, badge: true));
  }
}

/// The sign-in code [chat]'s last message is, where it is from the network's own account or a bot (Telegram's codes
/// come from 777000): it goes to the Codes tab with texted codes (lib/plugins/codes.dart's rules).
String? inboxCode(InboxChat chat) => chat.service && !chat.lastFromMe ? signInCode(chat.snippet) : null;

/// A chat slid all the way: deleted on its network once asked (Matt, 2026-11-15: "if possible proxy the archive and
/// delete messages too"). A group is left as it goes.
void confirmInboxDelete(BuildContext context, InboxNetwork network, InboxChat chat, {bool slid = false}) {
  final app = AppState.of(context);
  void delete() => network.deleteChat(chat.id);
  if (slid && deleteAskOff(app)) return delete();
  showChoices(context, title: chat.group ? 'Leave ${chat.title} and delete it on ${network.name}?' : 'Delete this chat on ${network.name}? This can\'t be undone.', choices: [
    Choice(chat.group ? 'Leave and delete' : 'Delete', Lucide.trash2, delete, danger: true),
    if (slid) dontAskAgainChoice(app, delete),
  ]);
}

/// Whether a conversation slid all the way is deleted without asking (Matt, 2026-11-16: "Add a "don't ask again" on
/// the confirmation for sliding to delete message groups"): chosen once on the question, undone in Settings › Writing.
/// A delete from a conversation's menu still asks.
bool deleteAskOff(AppState app) => !app.flag('delete_ask', fallback: true);

/// The question's second choice: deletes, and from then on a slide deletes at once.
Choice dontAskAgainChoice(AppState app, VoidCallback delete) => Choice('Delete, and don\'t ask again', Lucide.trash2, () {
      app.setFlag('delete_ask', false);
      delete();
    }, danger: true, hint: 'Sliding deletes straight away. Ask again in Settings › Writing.');

/// Opens [chat] in the pane beside the list, or over it on a phone.
void openInboxChat(BuildContext context, InboxNetwork network, InboxChat chat) {
  final page = InboxChatScreen(network: network, chatId: chat.id, fallback: chat);
  final shell = AppShell.maybeOf(context);
  if (shell != null) {
    shell.show(page, showing: 'inbox:${network.id}:${chat.id}');
  } else {
    push<void>(context, (_) => page);
  }
}

/// A chat on another network: its messages, and a line to answer in. Sent from here, a message goes as the network's own
/// app would send it. With one person its messages are bubbles; a group's (a Slack channel, a Telegram group) are lines
/// on the page as a circle's are (lib/ui/flat_line.dart; Matt, 2026-11-25: "For channels on slack and other groups please
/// use the same chat UI without the bubbles we use with text channels on circles").
class InboxChatScreen extends StatefulWidget {
  const InboxChatScreen({super.key, required this.network, required this.chatId, this.fallback});
  final InboxNetwork network;
  final String chatId;

  /// The chat as it was opened: its name and face until the network lists it (a chat begun from Contacts with
  /// someone never written to before is in the network's list only from its first message).
  final InboxChat? fallback;

  @override
  State<InboxChatScreen> createState() => _InboxChatScreenState();
}

class _InboxChatScreenState extends State<InboxChatScreen> with WidgetsBindingObserver {
  /// The network has answered for this chat's messages once: until then an empty chat is not known to be empty.
  bool _asked = false;

  final _text = TextEditingController();
  /// The chat's list, starting where the chat was left (lib/ui/jump_to_latest.dart; Matt, 2026-11-17: "remember the
  /// scroll position when switching between chats").
  String get _spot => 'inbox:${widget.network.id}:${widget.chatId}';
  late final ScrollController _scroll = ScrollMemory.controllerFor(() => _spot);
  bool _loadingOlder = false;

  InboxNetwork get _n => widget.network;

  /// Unread as the chat was opened, and the message the New messages divider stands above (a group's): found once,
  /// the first time its messages are there, and kept while the chat is open.
  int _unreadAtOpen = 0;
  String? _firstNewId;
  bool _newFound = false;

  /// The [_unreadAtOpen]th newest message from someone else, in [list] (newest first).
  String? _findFirstNew(List<InboxMessage> list) {
    if (_unreadAtOpen <= 0) return null;
    var seen = 0;
    for (final m in list) {
      if (m.mine) continue;
      if (++seen == _unreadAtOpen) return m.id;
    }
    // Fewer of theirs held than were unread: the oldest held.
    return list.lastWhere((m) => !m.mine, orElse: () => list.last).id;
  }

  @override
  void initState() {
    super.initState();
    _n.watching = widget.chatId;
    InboxAlerts.showing = '${_n.id}:${widget.chatId}';
    // How many were unread as it was opened, before they are marked read: where the New messages divider goes.
    _unreadAtOpen = (_n.chats.where((c) => c.id == widget.chatId).firstOrNull ?? widget.fallback)?.unread ?? 0;
    _n.load(widget.chatId).then((_) => _n.markRead(widget.chatId)).whenComplete(() {
      if (mounted) setState(() => _asked = true);
    });
    _n.addListener(_changed);
    _scroll.addListener(_nearTop);
    // The composer lays itself out by whether there are words (lib/ui/composer_box.dart).
    _text.addListener(_typed);
    _shortcodes = EmojiShortcodeSuggester(_text, app: () => mounted ? AppState.maybeOf(context) : null);
    WidgetsBinding.instance.addObserver(this);
  }

  /// The emoji a ":jo" being written finds, over the box, and a whole ":joy:" put in as 😂 (lib/ui/emoji_suggestions.dart;
  /// GMFB-22, Matt, Mac 0.12.6: "typing :joy: or something should expand the emoji to the joy emoji and auto suggest
  /// with a popup"). Its list has the keys first while it is open, so Enter there picks rather than sends.
  late final EmojiShortcodeSuggester _shortcodes;
  late final _focus = FocusNode(onKeyEvent: (node, e) => _shortcodes.key(e) ?? KeyEventResult.ignored);
  final _field = GlobalKey<EditableTextState>();
  Offset? _fieldDown;

  /// Back in the app with the cursor still in the field: the keys come back with it, as a conversation of texts does
  /// (lib/ui/thread.dart). Android hides the keyboard on leaving but the field keeps its focus, and asking for focus it
  /// already has does nothing (Matt, 2026-11-16: "Tabbing out and into thr app doesnt clear the focus on the signal
  /// convo so the keyboard can't be toggled open").
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _focus.hasFocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _field.currentState?.requestKeyboard());
    }
  }

  /// A press on the field: focus, and the keyboard asked for even where the field has focus already.
  void _keys() {
    _focus.requestFocus();
    _field.currentState?.requestKeyboard();
  }
  bool _wasTyping = false;

  /// Files to go with the next message, by their paths on this device (Matt, 2026-11-15: "Is it possible to send and
  /// receive attachments through telegram too?"), and the voice message being recorded: its most seconds.
  final List<String> _files = [];
  int? _recording;
  bool _sendingFiles = false;

  /// A sticker, sent as the picture it is (Matt, 2026-11-17: "Make sure we support the same functionality for each of
  /// them as well"): the app's own sticker, copied out and sent as a file, as Telegram and Signal take any picture.
  Future<void> _sticker() async {
    final asset = await pickSticker(context);
    if (asset == null || !mounted) return;
    HapticFeedback.lightImpact();
    try {
      final data = await rootBundle.load(asset);
      final dir = await Directory.systemTemp.createTemp('ghost-sticker');
      final file = File('${dir.path}/${asset.split('/').last}');
      await file.writeAsBytes(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
      await _n.sendFiles(widget.chatId, [file.path], sticker: true);
    } catch (e) {
      if (mounted) toast(context, 'Couldn\'t send the sticker: $e', tone: GlacierToastTone.danger);
    }
  }

  /// A picture pasted into the field (PasteImages), kept as one added with + is.
  Future<void> _pasted(String path) async {
    try {
      final kept = await Sms.instance.cacheCopy(path);
      if (mounted && _files.length < 10) setState(() => _files.add(kept));
    } catch (e) {
      if (mounted) toast(context, 'Couldn\'t add that picture: $e', tone: GlacierToastTone.danger);
    }
  }

  /// Files picked with +: each copied into the app's cache, ten waiting at most.
  Future<void> _attach() async {
    final picked = await Sms.instance.pickFiles();
    for (final p in picked.take(10 - _files.length)) {
      try {
        final path = await Sms.instance.cacheCopy(p);
        if (mounted) setState(() => _files.add(path));
      } catch (e) {
        if (mounted) toast(context, 'Couldn\'t add that file: $e', tone: GlacierToastTone.danger);
      }
    }
  }

  /// Starts a voice message; [_recording] then holds the most seconds it may run.
  Future<void> _record() async {
    try {
      final limit = await Sms.instance.startVoice(file: true);
      if (!mounted) return;
      if (limit == null) {
        toast(context, micRefusedWords(), tone: GlacierToastTone.danger);
        return;
      }
      HapticFeedback.lightImpact();
      setState(() => _recording = limit);
    } catch (e) {
      if (mounted) toast(context, voiceProblem(e), tone: GlacierToastTone.danger);
    }
  }

  Future<void> _sendVoice() async {
    setState(() => _recording = null);
    try {
      // In another voice, where Voice changer is on (lib/voice/voice_changer.dart): never as it was, should that fail.
      final changing = VoiceChanger.instance.active;
      if (changing && mounted) toast(context, 'Changing your voice…');
      final path = await VoiceChanger.instance.forSending(await Sms.instance.finishVoice());
      await _n.sendFiles(widget.chatId, [path], voice: true);
    } catch (e) {
      if (mounted) toast(context, 'Couldn\'t send the voice message: ${voiceProblem(e)}', tone: GlacierToastTone.danger);
    }
  }

  void _discardVoice() {
    Sms.instance.cancelVoice().catchError((_) {});
    setState(() => _recording = null);
  }
  void _typed() {
    final typing = _text.text.isNotEmpty;
    if (typing != _wasTyping && mounted) setState(() => _wasTyping = typing);
  }

  /// What an edited message said before: the original, and any wording between it and now, each copied with a press.
  /// Edited before this device saw it, there is nothing to show: the network keeps no earlier words.
  void _showOriginal(InboxMessage m) {
    if (m.versions.isEmpty) {
      showChoices(context, title: 'Edited before Uplink saw it. ${_n.name} doesn\'t keep what it said first.', choices: const []);
      return;
    }
    void copy(String text) {
      Clipboard.setData(ClipboardData(text: text));
      toast(context, 'Copied');
    }

    showChoices(context, title: 'First sent as:\n${m.original}', choices: [
      Choice('Copy original', Lucide.copy, () => copy(m.original!)),
      // Edited more than once: each wording on the way, oldest first.
      for (final (i, v) in m.versions.skip(1).indexed) Choice(v, Lucide.clock, () => copy(v), hint: 'Edit ${i + 1} · press to copy'),
    ]);
  }

  /// A message pressed and held: react, reply, copy, see what it said before, translate, or delete it, for this
  /// account or, where the network allows, for everyone (Matt, 2026-11-15: "if possible proxy the archive and delete
  /// messages too").
  void _messageMenu(InboxMessage m) {
    HapticFeedback.mediumImpact();
    // Deleted at once, nothing asked, with a puff (Matt, 2026-11-15: "Don't ask for confirmation when deleting a message
    // and show a poof animation when one is deleted").
    final mine = {for (final r in m.reactions) if (r.mine) r.emoji};
    showChoices(context, header: _n.canReact && m.state != 'sending'
        ? InboxReactionRow(
            choices: _n.reactionChoices,
            mine: mine,
            onPick: (emoji) {
              Navigator.of(context, rootNavigator: true).pop();
              _react(m, emoji);
            },
          )
        : null, choices: [
      if (_n.canReply && m.state != 'sending') Choice('Reply', LucideMore.reply, () => _startReply(m)),
      if (m.text.isNotEmpty) Choice('Copy', Lucide.copy, () => Clipboard.setData(ClipboardData(text: m.text))),
      if (m.edited) Choice('Show original', Lucide.clock, () => _showOriginal(m)),
      // The Translate plugin's lines, while it is on (lib/ui/translated_card.dart).
      ...translateChoices(context, inboxFacts(_n, widget.chatId, m)),
      if (_n.canDeleteForEveryone(widget.chatId, m)) Choice('Delete for everyone', Lucide.trash2, () => setState(() => _poofing[m.id] = true), danger: true),
      Choice(m.mine && _n.canDeleteForEveryone(widget.chatId, m) ? 'Delete for me' : 'Delete', Lucide.trash2, () => setState(() => _poofing[m.id] = false), danger: true),
    ]);
  }

  /// Messages going in a puff, each with whether it goes for everyone; deleted once it has gone off.
  final Map<String, bool> _poofing = {};

  int _seen = 0;
  void _changed() {
    // Read as it arrives, while the chat is open.
    final count = _n.messagesOf(widget.chatId).length;
    if (count != _seen) {
      _seen = count;
      _n.markRead(widget.chatId);
    }
  }

  /// Scrolled to within 400 px of the oldest message held: asks the network for older ones, where it has any.
  void _nearTop() {
    if (_loadingOlder || !_scroll.hasClients) return;
    if (_scroll.position.pixels < _scroll.position.maxScrollExtent - 400) return;
    final more = switch (_n) { Bluesky b => b.hasOlder(widget.chatId), Telegram t => t.hasOlder(widget.chatId), AccountHelper h => h.hasOlder(widget.chatId), _ => false };
    if (!more) return;
    _loadingOlder = true;
    _n.load(widget.chatId, older: true).whenComplete(() => _loadingOlder = false);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _n.removeListener(_changed);
    _n.watching = null;
    if (InboxAlerts.showing == '${_n.id}:${widget.chatId}') InboxAlerts.showing = null;
    _text.removeListener(_typed);
    _shortcodes.dispose();
    _text.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// The message being answered, while a reply is being written (Matt, 2026-11-17: "Id like to be able to reply to
  /// messages as well as react to telegram and signal messages").
  InboxMessage? _replying;

  /// Puts [emoji] on [m], or takes it off where it is mine already.
  Future<void> _react(InboxMessage m, String emoji) async {
    final remove = m.reactions.any((r) => r.mine && r.emoji == emoji);
    try {
      await _n.react(widget.chatId, m.id, emoji, remove: remove);
    } catch (e) {
      if (mounted) toast(context, 'Couldn\'t react: ${'$e'.replaceFirst(RegExp(r'^(Bad state|StateError|Unsupported operation): '), '')}', tone: GlacierToastTone.danger);
    }
  }

  void _startReply(InboxMessage m) {
    setState(() => _replying = m);
    _focus.requestFocus();
  }

  /// Sends what is waiting: the files with the words as their caption, else the words, as a reply where one is being
  /// written.
  Future<void> _send() async {
    final text = _text.text;
    final replying = _replying;
    if (_files.isNotEmpty) {
      if (_sendingFiles) return;
      final files = List<String>.of(_files);
      setState(() {
        _files.clear();
        _sendingFiles = true;
      });
      _text.clear();
      try {
        await _n.sendFiles(widget.chatId, files, caption: text);
      } finally {
        if (mounted) setState(() => _sendingFiles = false);
      }
      return;
    }
    if (text.trim().isEmpty) return;
    _text.clear();
    if (replying != null) {
      setState(() => _replying = null);
      await _n.reply(widget.chatId, replying.id, text);
      return;
    }
    await _n.send(widget.chatId, text);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final app = AppState.of(context);
    return ListenableBuilder(
      listenable: _n,
      builder: (context, _) {
        final chat = _n.chats.where((c) => c.id == widget.chatId).firstOrNull ?? widget.fallback;
        final list = _n.shownMessages(widget.chatId).reversed.toList();
        if (!_newFound && list.isNotEmpty) {
          _newFound = true;
          _firstNewId = _findFirstNew(list);
        }
        final group = chat?.group ?? false;
        final newAt = group ? _firstNewId : null;
        // Which person here is oneself, as the network knows them: the face by one's own lines, and who a mention means.
        final myId = group ? list.where((m) => m.mine && m.senderId.isNotEmpty).firstOrNull?.senderId ?? '' : '';
        final (mineBg, mineInk) = myBubble(t, app);
        // The window is named for the chat while it is open (lib/ui/window_title.dart).
        return WindowTitle(name: chat?.title ?? _n.name, child: GhostPage(
          title: chat?.title ?? _n.name,
          // Laid out as a conversation of texts' header is (lib/ui/thread.dart): the face, the name, a line under it;
          // the network's logo on the face's corner is the one difference (Matt, 2026-11-15: "Use the same header
          // layout for telegram chats that we use for normal messages only difference should be the telegram icon").
          // A group's drawer from a long press on its name (Matt, 2026-11-16: "Add them to a drawer when pressing and
          // holding on the group name"): its details, people and rules, changed on the network itself.
          titleWidget: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onLongPress: chat?.group == true
                ? () {
                    HapticFeedback.mediumImpact();
                    showGroupDrawer(context, _n, widget.chatId);
                  }
                // One to one: Block or Unblock, on the network itself (lib/ui/blocking.dart).
                : chat != null && !chat.service && _n.canBlock
                    ? () {
                        HapticFeedback.mediumImpact();
                        showPersonBlock(context, BlockTarget.network(_n, widget.chatId, chat.title));
                      }
                    : null,
            child: Row(children: [
            SizedBox.square(
              dimension: t.lenOf('2.1rem'),
              child: Stack(clipBehavior: Clip.none, children: [
                Avatar(people: [Person(address: '${_n.id}:${widget.chatId}', name: chat?.title ?? _n.name, photo: chat?.avatar)], size: t.lenOf('2.1rem')),
                PositionedDirectional(
                  end: -3,
                  bottom: -3,
                  child: Container(
                    padding: const EdgeInsets.all(1.5),
                    decoration: BoxDecoration(shape: BoxShape.circle, color: t.color('glacier-bg')),
                    child: inboxMark(_n, size: 14, badge: true),
                  ),
                ),
              ]),
            ),
            SizedBox(width: t.space(2)),
            Expanded(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(chat?.title ?? _n.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('md'), weight: 'semibold')),
                // One to one: whether they are on now, or when they were, where the network says (Telegram does).
                ListenableBuilder(
                  listenable: _n.presenceChanges,
                  builder: (context, _) {
                    final seen = chat?.group == true ? null : _n.presenceOf(widget.chatId)?.words();
                    return Text(chat?.group == true ? '${_n.name} group' : (seen == null ? _n.name : '${_n.name} · $seen'), maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('xs'), color: t.color('app-ink-3')));
                  },
                ),
              ]),
            ),
          ])),
          footer: Padding(
            // The page (GhostPage's footer) leaves the screen's foot under it already, as a conversation of texts.
            padding: composerFootPadding(t),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (_n.error != null)
                Padding(
                  padding: EdgeInsets.only(bottom: t.space(2)),
                  child: Text(_n.error!, style: pageText(t, t.fontSize('xs'), color: t.danger)),
                ),
              // The same box as a conversation of texts (lib/ui/composer_box.dart; Matt, 2026-11-15: "Also use the same
              // composer for telegram"): words alone here, so no + or microphone, and Send at its end.
              Builder(builder: (context) {
                final style = composerTextStyle(t);
                final strut = composerStrutStyle(t);
                final enterSends = app.enterSends;
                // Laid out as a conversation of texts is (Matt, 2026-11-15: "The compose window should also use the exact same
                // layout as messages"): + at its start, the microphone while it is empty, Send once there is something.
                final files = _n.canSendFiles;
                final canSend = (_text.text.trim().isNotEmpty || _files.isNotEmpty) && !_sendingFiles;
                // The phone's microphone, or a computer's own (GMFB-32).
                final voice = files && Sms.canRecordVoice;
                if (_recording != null) {
                  return VoiceRecorder(limit: _recording!, onDiscard: _discardVoice, onSend: _sendVoice, note: VoiceChanger.instance.note, carrier: false);
                }
                // The same buttons in the same places as every other conversation (lib/ui/composer_box.dart), each
                // greyed out where this network can't do it.
                final ScheduleTarget schedule = (kind: 'inbox', target: '${_n.id}:${widget.chatId}', who: chat?.title ?? _n.name);
                final buttons = composerButtons(
                  t,
                  hasSomething: _text.text.isNotEmpty || _files.isNotEmpty,
                  onAttach: files && _files.length < 10 ? _attach : null,
                  onSticker: files && _files.isEmpty && !_sendingFiles ? _sticker : null,
                  onRecord: voice && _files.isEmpty ? _record : null,
                  onSend: canSend ? _send : null,
                  emoji: Sms.remote,
                  // The app's own picker (lib/ui/emoji_picker.dart), into the box where the cursor is.
                  onEmoji: () async {
                    await showEmojiPicker(context, onPick: (e) => insertEmoji(_text, e));
                    if (mounted) _focus.requestFocus();
                  },
                  // Send later (lib/ui/schedule_ui.dart): words alone, as a new message in this chat.
                  onSendMenu: () {
                    if (_files.isNotEmpty) {
                      toast(context, 'Files can\'t be scheduled yet. Send them now, or schedule the words alone.');
                      return;
                    }
                    openSendMenu(context, to: schedule, text: _text.text, onScheduled: () {
                      _text.clear();
                      setState(() => _replying = null);
                    });
                  },
                );
                return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  if (_replying != null)
                    InboxReplyBar(
                      to: _replying!.mine ? 'yourself' : (_replying!.sender.isNotEmpty ? _replying!.sender : (chat?.title ?? _n.name)),
                      text: _replying!.text.isNotEmpty ? _replying!.text : (_replying!.media.isNotEmpty ? 'A picture or file' : ''),
                      onClose: () => setState(() => _replying = null),
                    ),
                  EmojiSuggestions(suggester: _shortcodes),
                  if (_files.isNotEmpty) _FilesStrip(files: _files, onRemove: (f) => setState(() => _files.remove(f))),
                  ScheduledStrip(to: schedule),
                  ComposerBox(
                  typing: _text.text.isNotEmpty,
                  plus: buttons.plus,
                  ends: buttons.ends,
                  below: buttons.below,
                  // A finger down and up close by, as a conversation of texts reads it (lib/ui/thread.dart): a tap
                  // gesture here loses to the field's own, so a press on a field with focus would ask for nothing.
                  field: Listener(
                    behavior: HitTestBehavior.translucent,
                    onPointerDown: (e) => _fieldDown = e.position,
                    onPointerUp: (e) {
                      final down = _fieldDown;
                      _fieldDown = null;
                      if (down != null && (e.position - down).distance < 18) _keys();
                    },
                    child: ConstrainedBox(
                      constraints: BoxConstraints(minHeight: t.lenOf('2.25rem')),
                      child: Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: Padding(
                          padding: EdgeInsets.symmetric(vertical: t.lenOf('0.3rem')),
                          child: Stack(children: [
                            if (_text.text.isEmpty)
                              IgnorePointer(child: Text('Message on ${_n.name}', style: style.copyWith(color: composerTokens(t).color('app-ink-3')), strutStyle: strut, textHeightBehavior: composerLeading)),
                            // A picture pasted on a computer goes with the message, as one added with + does
                            // (lib/ui/paste_images.dart; Matt, 2026-11-20: "pasting a screenshot into the compose bar
                            // isn't adding attachements").
                            PasteImages(
                              focusNode: _focus,
                              enabled: files && _files.length < 10,
                              onImage: _pasted,
                              child: EditableText(
                              key: _field,
                              controller: _text,
                              focusNode: _focus,
                              style: style,
                              strutStyle: strut,
                              textHeightBehavior: composerLeading,
                              cursorColor: composerTokens(t).color('app-ink'),
                              backgroundCursorColor: composerTokens(t).color('app-ink-3'),
                              minLines: 1,
                              maxLines: 6,
                              keyboardType: enterSends ? TextInputType.text : TextInputType.multiline,
                              textInputAction: enterSends ? TextInputAction.send : TextInputAction.newline,
                              onSubmitted: (_) => _send(),
                              onEditingComplete: enterSends ? () {} : null,
                              textCapitalization: TextCapitalization.sentences,
                            )),
                          ]),
                        ),
                      ),
                    ),
                  ),
                ),
                ]);
              }),
            ]),
          ),
          body: list.isEmpty && !_asked && _n.state == InboxState.ready
              // Its messages in bones until the network has answered once: "No messages yet" was said at once, of
              // every chat, before anything had been asked (lib/ui/skeleton.dart).
              ? SkeletonChat(label: 'Loading messages…', flat: group)
              : list.isEmpty
              ? Center(child: Text(_n.state == InboxState.ready ? 'No messages yet' : 'Not signed in to ${_n.name}', style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-3'))))
              // Dial-Up writes the chat as a chat room's transcript (lib/ui/message_line.dart), as it does texts.
              // The down arrow over the list's foot, back to the newest message (Matt, 2026-11-17: "add a down arrow that
              // pops up when we enter a chat and we're not scrolled to the bottom or after we scroll up a certain amount").
              : JumpToLatest(
                  controller: _scroll,
                  chat: _spot,
                  incoming: list.where((m) => !m.mine).map((m) => m.id),
                  // Left of the map's gutter, level with the bubbles' edge: at the list's own edge it stood over the
                  // map's foot and took the presses meant for its lowest lines.
                  inset: isDialup(context) ? const EdgeInsets.only(right: 14, bottom: 12) : EdgeInsets.only(right: ChatRail.gutter, bottom: t.space(3)),
                  child: isDialup(context)
              ? _transcript(chat, list)
              // The chat's map in the gutter at its right (lib/ui/chat_rail.dart).
              : ChatRail(
                  controller: _scroll,
                  chat: _spot,
                  marks: [
                    for (final m in list)
                      RailMark(
                        at: m.date.millisecondsSinceEpoch,
                        who: m.mine ? 'me' : (m.senderId.isNotEmpty ? m.senderId : m.sender),
                        mine: m.mine,
                        name: m.mine ? 'You' : (m.sender.isNotEmpty ? m.sender : (chat?.title ?? '')),
                        text: m.event ? '' : m.text,
                        quiet: m.event,
                      ),
                  ],
                  // In a group everyone's own face, as by their lines.
                  face: group ? (who, name, mine, size) => InboxFace(network: _n, id: mine ? myId : (list.any((m) => m.senderId == who) ? who : ''), name: name, mine: mine, size: size) : null,
                  // The list that can go straight to a row (lib/ui/chat_rows.dart).
                  child: ChatListView.builder(
                  controller: _scroll,
                  reverse: true,
                  padding: EdgeInsetsDirectional.fromSTEB(t.space(3), t.space(2), ChatRail.gutter, t.space(2)),
                  chat: _spot,
                  idOf: (i) => list[i].id,
                  itemCount: list.length,
                  itemBuilder: (context, i) {
                    final m = list[i];
                    final older = i + 1 < list.length ? list[i + 1] : null;
                    final newer = i > 0 ? list[i - 1] : null;
                    // Something that happened (a join, a pin) ends a run of bubbles, as a day's turn does.
                    final firstOfRun = older == null || older.event || older.mine != m.mine || older.sender != m.sender || m.date.difference(older.date).inMinutes > 10;
                    final lastOfRun = newer == null || newer.event || newer.mine != m.mine || newer.sender != m.sender || newer.date.difference(m.date).inMinutes > 10;
                    final newDay = older == null || older.date.day != m.date.day || older.date.month != m.date.month || older.date.year != m.date.year;
                    // A group's runs are a circle's: someone else, another day, something that happened, a pause of five
                    // minutes or the New messages line, and the face, name and time are shown again.
                    final newRun = newDay || older.event || _whoOf(older) != _whoOf(m) || FlatLine.apart(older.date, m.date) || m.id == newAt;
                    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      if (newDay && group)
                        DayTurn(dayHeading(m.date))
                      else if (newDay)
                        Padding(
                          padding: EdgeInsets.symmetric(vertical: t.space(3)),
                          child: Text(dayHeading(m.date), textAlign: TextAlign.center, style: pageText(t, t.fontSize('xs'), weight: 'semibold', color: t.color('app-ink-3'))),
                        ),
                      if (m.id == newAt) const NewMessagesDivider(key: ValueKey('new-messages')),
                      // Something that happened, not something said: a small line across the middle, as Telegram draws
                      // its own (Matt, 2026-11-17: "A bunch of telegram messages are just showing as \"Message\"").
                      if (m.event)
                        Padding(
                          key: ValueKey('event-${m.id}'),
                          padding: EdgeInsets.symmetric(horizontal: t.space(6), vertical: t.space(1) + 2),
                          child: Text(m.text, textAlign: TextAlign.center, style: pageText(t, t.fontSize('xs'), weight: 'medium', color: t.color('app-ink-3'))),
                        )
                      else
                      Poof(
                        key: ValueKey('poof-${m.id}'),
                        gone: _poofing.containsKey(m.id),
                        side: m.mine && !group ? AxisDirection.right : AxisDirection.left,
                        onDone: () => _n.deleteMessage(widget.chatId, m.id, forEveryone: _poofing.remove(m.id) ?? false),
                        child: group
                            ? _InboxLine(key: ValueKey(m.id), network: _n, chatId: widget.chatId, message: m, first: newRun, myId: myId, onMenu: () => _messageMenu(m), onReact: (emoji) => _react(m, emoji), onEditedTap: () => _showOriginal(m))
                            : GestureDetector(
                        onLongPress: () => _messageMenu(m),
                        child: _InboxBubble(key: ValueKey(m.id), network: _n, chatId: widget.chatId, message: m, first: firstOfRun, last: lastOfRun, mineBg: mineBg, mineInk: mineInk, onReactionsTap: () => _messageMenu(m), onEditedTap: () => _showOriginal(m)),
                      )),
                    ]);
                  },
                ),
                ),
                ),
        ));
      },
    );
  }
}

extension on _InboxChatScreenState {
  /// The chat as Dial-Up writes it: "Name: words" lines in one white well, the day's turn and where the chat starts
  /// said by the room's Host, and pictures, files and link cards under the line they came with (lib/ui/message_line.dart).
  Widget _transcript(InboxChat? chat, List<InboxMessage> list) {
    final group = chat?.group ?? false;
    final more = switch (_n) { Bluesky b => b.hasOlder(widget.chatId), Telegram t => t.hasOlder(widget.chatId), AccountHelper h => h.hasOlder(widget.chatId), _ => false };
    return Transcript(
      child: ListView.builder(
        controller: _scroll,
        reverse: true,
        padding: const EdgeInsets.symmetric(vertical: 4),
        itemCount: list.length,
        itemBuilder: (context, i) {
          // The well's own colours (a look may write its chat on another ground than its pages': `.parchment`).
          final c = DialupColors.of(context.tokens);
          final m = list[i];
          final older = i + 1 < list.length ? list[i + 1] : null;
          final newer = i > 0 ? list[i - 1] : null;
          final lastOfRun = newer == null || newer.mine != m.mine || newer.sender != m.sender || newer.date.difference(m.date).inMinutes > 10;
          final newDay = older == null || older.date.day != m.date.day || older.date.month != m.date.month || older.date.year != m.date.year;
          final failed = m.state == 'failed';
          final who = m.mine ? 'You' : (group ? _nameIn(m) : (chat?.title ?? _n.name));
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (older == null && !more) ...[
              HostLine('*** You are in "${chat?.title ?? _n.name}". ***'),
              // Signal seals every chat end to end; the other networks' chats are not, so they say nothing.
              if (_n.id == 'signal') const HostLine('Messages here are sealed end to end.'),
            ],
            if (newDay) HostLine.day(m.date),
            if (m.event) HostLine('*** ${m.text} ***') else
            Poof(
              key: ValueKey('poof-${m.id}'),
              gone: _poofing.containsKey(m.id),
              side: m.mine ? AxisDirection.right : AxisDirection.left,
              onDone: () => _n.deleteMessage(widget.chatId, m.id, forEveryone: _poofing.remove(m.id) ?? false),
              child: ShownWords(
                key: ValueKey(m.id),
                facts: inboxFacts(_n, widget.chatId, m),
                builder: (_, shown) => MessageLine(
                name: who,
                nameColor: m.mine ? c.nameMine : (group ? c.nameFor(m.sender) : c.nameTheirs),
                mine: m.mine,
                body: shown?.bubble ?? m.text,
                // A group's lines as a circle's are: a mention or a name pressed for its profile card, and an edit said.
                mentions: group ? _mentionsIn(m, shown?.bubble ?? m.text) : const [],
                mentionStyle: mentionStyle(context.tokens, on: c.ink),
                onMention: group ? (x) => showProfile(context, subjectOfMention(x.id, words: (shown?.bubble ?? m.text).substring(x.start, x.end), network: _n)) : null,
                onNameTap: !group || m.mine || m.senderId.isEmpty || !_n.hasProfiles ? null : () => showProfile(context, ProfileSubject.on(_n, id: m.senderId, name: m.sender)),
                edited: group && m.edited ? 'Edited' : null,
                onEditedTap: () => _showOriginal(m),
                original: shown == null ? null : OriginalLine(view: shown),
                media: [for (final x in m.media) InboxMediaView(network: _n, media: x, ink: c.ink)],
                under: _linkCards(context, m.text),
                status: failed ? 'Not sent' : (m.state == 'sending' ? 'Sending…' : (lastOfRun ? clock(m.date) : null)),
                failed: failed,
                faded: m.state == 'sending',
                onLongPress: (_) => _messageMenu(m),
              )),
            ),
          ]);
        },
      ),
    );
  }
}

/// The Link previews plugin's cards for the links in [text] (lib/plugins/embeds.dart), while it is on: two at most.
List<Widget> _linkCards(BuildContext context, String text) {
  if (text.isEmpty) return const [];
  final registry = PluginRegistry.instance;
  final plugin = registry.plugins.whereType<EmbedsPlugin>().firstOrNull;
  if (plugin == null) return const [];
  final store = AppStore(AppState.of(context));
  if (!registry.isOn(plugin, store)) return const [];
  final others = registry.prefsOf(plugin, store).flag('others');
  final links = MessageLink.find(text).map((l) => l.address).toSet().take(2);
  final t = context.tokens;
  return [for (final url in links) Padding(padding: EdgeInsets.only(top: t.space(1)), child: EmbedCard(url: url, others: others))];
}

/// The facts a plugin that shows a message's words otherwise is asked by (the Translate plugin, lib/plugins/translate.dart;
/// Matt, 2026-11-17: "add a translate plugin which can automatically translate texts when detected from another
/// language"): none for the person's own, or one still going.
MessageFacts? inboxFacts(InboxNetwork network, String chatId, InboxMessage m) {
  if (m.mine || m.state == 'sending' || m.state == 'failed' || m.text.trim().isEmpty) return null;
  return MessageFacts(thread: -1, senders: [m.sender], text: m.text, contact: false, outgoing: false, date: m.date, id: '${network.id}:$chatId:${m.id}', network: network.id);
}

/// Who wrote [m], by anything that tells one writer from another.
String _whoOf(InboxMessage m) => m.mine ? 'me' : (m.senderId.isNotEmpty ? m.senderId : m.sender);

/// Who wrote [m] in a group, as its line says it: "You" for yourself, as in a circle.
String _nameIn(InboxMessage m) => m.mine ? 'You' : (m.sender.isEmpty ? 'Someone' : m.sender);

/// Someone's face in a group on another network: the picture the network has of them, else their initials on their
/// colour. Your own is the network's picture of you where it is held, else your profile's, as in a circle.
class InboxFace extends StatelessWidget {
  const InboxFace({super.key, required this.network, required this.id, required this.name, required this.mine, required this.size});
  final InboxNetwork network;

  /// The network's own id for them; '' where not known.
  final String id;
  final String name;
  final bool mine;
  final double size;

  @override
  Widget build(BuildContext context) {
    final photo = id.isEmpty ? null : network.faceOf(id);
    Widget face(String? name) => Avatar(people: [Person(address: '${network.id}:${id.isEmpty ? name : id}', name: name, photo: photo)], size: size, presence: !mine);
    if (!mine) return face(name);
    return ListenableBuilder(
      listenable: Me.instance,
      builder: (context, _) {
        final own = Me.instance.shownName.isNotEmpty ? Me.instance.shownName : (network.account ?? '').replaceFirst('@', '');
        return (photo == null ? faceOfPicture(context, Me.instance.pictureSharp, size) : null) ?? face(own.isEmpty ? 'You' : own);
      },
    );
  }
}

/// [m]'s words, with their links and mentions pressable, in a bubble or on the page.
class _InboxWords extends StatelessWidget {
  const _InboxWords({required this.network, required this.message, required this.text, required this.ink, required this.style, this.mentionOn, this.after = const []});
  final InboxNetwork network;
  final InboxMessage message;

  /// The words shown: the message's own, or a plugin's in their place.
  final String text;
  final Color ink;
  final TextStyle style;

  /// The ink a mention is drawn in on a bubble of one's own colour.
  final Color? mentionOn;
  final List<InlineSpan> after;

  @override
  Widget build(BuildContext context) => LinkedText(
        text,
        ink: ink,
        style: style,
        after: after,
        // Who an "@" means, as the network said (or the "@username" written, where it said nothing or the words shown are a
        // translation), pressed for their profile (Matt, 2026-11-19: "when clicking on a @mention anywhere including signal
        // and telegram chats show this profile popup").
        mentions: _mentionsIn(message, text),
        mentionStyle: mentionStyle(context.tokens, on: mentionOn),
        onMention: (x) => showProfile(context, subjectOfMention(x.id, words: text.substring(x.start, x.end), network: network)),
      );
}

List<Mention> _mentionsIn(InboxMessage m, String text) => text == m.text && m.mentions.isNotEmpty ? inboxMentions(m) : handleMentions(text);

/// One message of a group on another network, as a channel's line: the same line a circle's chat is drawn with
/// (lib/ui/flat_line.dart), with what a network's message has in it.
class _InboxLine extends StatelessWidget {
  const _InboxLine({super.key, required this.network, required this.chatId, required this.message, required this.first, required this.myId, required this.onMenu, required this.onReact, required this.onEditedTap});
  final InboxNetwork network;
  final String chatId;
  final InboxMessage message;

  /// The first of a run from one person.
  final bool first;

  /// Oneself, as the network knows them; '' where not known.
  final String myId;

  /// Pressed and held, or with a mouse's other button; the plus after its reactions.
  final VoidCallback onMenu;

  /// One of its reactions pressed: yours goes on, or off.
  final ValueChanged<String> onReact;

  /// A press on "(edited)": what it said before.
  final VoidCallback onEditedTap;

  /// Someone else's message that mentions you: by your id on the network, or the username the account here goes by.
  bool get _mentionsMe {
    if (message.mine) return false;
    final account = (network.account ?? '').toLowerCase();
    bool me(String id) => id.startsWith('n:') ? myId.isNotEmpty && id == 'n:$myId' : account.startsWith('@') && id == 'u:${account.substring(1)}';
    return _mentionsIn(message, message.text).any((x) => me(x.id.startsWith('u:') ? x.id.toLowerCase() : x.id));
  }

  @override
  Widget build(BuildContext context) => ShownWords(facts: inboxFacts(network, chatId, message), builder: _build);

  Widget _build(BuildContext context, ShownView? shown) {
    final t = context.tokens;
    final m = message;
    final going = m.state == 'sending', failed = m.state == 'failed';
    final react = network.canReact && !going && !failed;
    final name = _nameIn(m);
    // A card where the network says something of its people (InboxNetwork.hasProfiles); elsewhere a press does nothing.
    final who = m.mine || m.senderId.isEmpty || !network.hasProfiles ? null : ProfileSubject.on(network, id: m.senderId, name: m.sender);
    return FlatLine(
      name: name,
      at: m.date,
      first: first,
      face: (size) => InboxFace(network: network, id: m.mine ? myId : m.senderId, name: name, mine: m.mine, size: size),
      mentionsMe: _mentionsMe,
      onMenu: onMenu,
      onPerson: who == null ? null : () => showProfile(context, who),
      reactions: [for (final r in m.reactions) (emoji: r.emoji, count: r.count, mine: r.mine)],
      reactionsKey: ValueKey('reactions-${m.id}'),
      onReact: react ? onReact : null,
      onAddReaction: react ? onMenu : null,
      body: (context, maxWidth) => Opacity(opacity: going ? 0.6 : 1, child: _body(context, shown, maxWidth)),
      foot: !going && !failed
          ? null
          : Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(failed ? 'Not sent' : 'Sending…', style: pageText(t, t.fontSize('xs'), color: failed ? t.danger : t.color('app-ink-3'))),
            ),
    );
  }

  /// What it says: the message it answers, what came with it, its words, and the cards of their links.
  Widget _body(BuildContext context, ShownView? shown, double maxWidth) {
    final t = context.tokens;
    final m = message;
    final ink = t.color('app-ink');
    final text = shown?.bubble ?? m.text;
    final style = pageText(t, t.fontSize('md'), color: ink, height: 1.4);
    final edited = m.edited ? editedMark(style, ink, key: ValueKey('edited-${m.id}'), onTap: onEditedTap) : null;
    final quoted = (m.replyText ?? '').trim();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      if (m.replyTo != null)
        Padding(
          padding: EdgeInsets.only(bottom: t.space(1)),
          child: FlatQuote(key: ValueKey('inbox-quote-${m.id}'), who: m.replySender ?? '', text: quoted.isEmpty ? 'A message' : quoted, ink: ink),
        ),
      for (final (i, x) in m.media.indexed)
        Padding(
          padding: EdgeInsets.only(bottom: i + 1 < m.media.length || text.isNotEmpty ? t.space(1) : 0),
          child: InboxMediaView(network: network, media: x, ink: ink, card: true),
        ),
      // The words as they came, dimmed, over a translation.
      if (shown != null) OriginalCard(view: shown, maxWidth: maxWidth),
      if (text.isNotEmpty)
        _InboxWords(network: network, message: m, text: text, ink: ink, style: style, after: [?edited])
      else if (edited != null)
        Text.rich(TextSpan(children: [edited]), style: style),
      // A card for each link, while Link previews is on.
      ..._linkCards(context, m.text),
    ]);
  }
}

/// One message of a chat with one person as a bubble: its words, what came with it, its reactions and how its sending
/// went.
class _InboxBubble extends StatelessWidget {
  const _InboxBubble({super.key, required this.network, required this.chatId, required this.message, required this.first, required this.last, required this.mineBg, required this.mineInk, this.onReactionsTap, this.onEditedTap});

  /// A press on "Edited": what it said before.
  final VoidCallback? onEditedTap;

  /// A press on its reactions: the message's menu, to add one or take yours off.
  final VoidCallback? onReactionsTap;
  final InboxNetwork network;
  final String chatId;
  final InboxMessage message;
  final bool first, last;
  final Color mineBg, mineInk;

  @override
  Widget build(BuildContext context) => ShownWords(facts: inboxFacts(network, chatId, message), builder: _build);

  /// The bubble, saying [shown]'s words where a plugin shows them otherwise, with the words as they came in a card over it.
  Widget _build(BuildContext context, ShownView? shown) {
    final t = context.tokens;
    final m = message;
    final text = shown?.bubble ?? m.text;
    final maxWidth = MediaQuery.sizeOf(context).width * 0.75;
    final round = Radius.circular(lookCorner(t, '1.125rem', most: 1));
    final tight = Radius.circular(lookCorner(t, '0.375rem', most: 1));
    final failed = m.state == 'failed';
    return Padding(
      padding: EdgeInsets.only(top: first ? t.space(2) : 2),
      child: Column(crossAxisAlignment: m.mine ? CrossAxisAlignment.end : CrossAxisAlignment.start, children: [
        // The words as they came, dimmed, over a translated bubble.
        if (shown != null) OriginalCard(view: shown, maxWidth: maxWidth, mine: m.mine),
        // Its reactions over the bubble's lower edge, as under a text (lib/ui/thread.dart).
        _withReactions(context, m, onReactionsTap,
        // A sticker alone, no words and nothing quoted, is drawn on its own: no bubble behind its see-through parts.
        isStickerAlone(m) ? Opacity(opacity: m.state == 'sending' ? 0.6 : 1, child: InboxMediaView(network: network, media: m.media.single, ink: m.mine ? mineInk : t.color('app-ink'))) :
        ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: Opacity(
            opacity: m.state == 'sending' ? 0.6 : 1,
            child: Container(
              padding: EdgeInsets.symmetric(horizontal: t.space(3), vertical: t.space(2)),
              decoration: BoxDecoration(
                // The conversation's own colours (lib/backgrounds.dart): a white bubble on the light page has a line round it.
                color: m.mine ? mineBg : theirBubble(t, onBackground: false),
                border: !m.mine ? theirRim(t) : bubbleNeedsRim(mineBg, t.color('glacier-bg')) ? Border.all(color: t.color('app-ink-4'), width: 1) : null,
                borderRadius: BorderRadius.only(
                  topLeft: !m.mine && !first ? tight : round,
                  bottomLeft: !m.mine && !last ? tight : round,
                  topRight: m.mine && !first ? tight : round,
                  bottomRight: m.mine && !last ? tight : round,
                ),
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                // The message it answers, quoted at its head.
                if (m.replyTo != null) InboxQuote(sender: m.replySender, text: m.replyText, ink: m.mine ? mineInk : t.color('app-ink')),
                for (final x in m.media) Padding(padding: EdgeInsets.only(bottom: text.isEmpty ? 0 : t.space(2)), child: InboxMediaView(network: network, media: x, ink: m.mine ? mineInk : t.color('app-ink'))),
                // Links underlined and opened by a press, as in a conversation of texts (Matt, 2026-11-16: "links are
                // not expanding or clickable on telegram and signal chats").
                if (text.isNotEmpty)
                  _InboxWords(
                    network: network,
                    message: m,
                    text: text,
                    ink: m.mine ? mineInk : t.color('app-ink'),
                    style: pageText(t, t.fontSize('md'), color: m.mine ? mineInk : t.color('app-ink'), height: 1.3),
                    mentionOn: m.mine ? mineInk : null,
                  ),
              ]),
            ),
          ),
        )),
        // And a card for each, while Link previews is on: the plugin's own, as under a text.
        ..._linkCards(context, m.text),
        // Changed since it was sent, said under it as under a text (lib/ui/thread.dart); a press shows the original.
        if (m.edited)
          GestureDetector(
            key: ValueKey('edited-${m.id}'),
            onTap: onEditedTap,
            child: Padding(
              padding: EdgeInsetsDirectional.only(top: 3, start: t.space(2), end: t.space(2)),
              child: Text('Edited', style: pageText(t, t.fontSize('xs'), weight: 'medium', color: t.color('app-ink-3'))),
            ),
          ),
        if (last || failed)
          Padding(
            padding: EdgeInsetsDirectional.only(top: 2, start: t.space(2), end: t.space(2)),
            child: Text(
              failed ? 'Not sent' : (m.state == 'sending' ? 'Sending…' : clock(m.date)),
              style: pageText(t, t.fontSize('xs'), color: failed ? t.danger : t.color('app-ink-3')),
            ),
          ),
      ]),
    );
  }
}

/// What the list's tab shows where a network has no chats.
Widget inboxEmpty(BuildContext context, InboxNetwork network) {
  final t = context.tokens;
  return Padding(
    padding: EdgeInsets.all(t.space(6)),
    child: SettingsEmpty(
      icon: inboxMark(network, size: 28),
      title: network.state == InboxState.ready ? 'No chats yet' : 'Not signed in to ${network.name}',
      body: Text(network.state == InboxState.ready ? 'Chats on ${network.name} appear here as they come.' : 'Sign in from Settings › ${network.name}.'),
    ),
  );
}

// --- signing in ------------------------------------------------------------------------------------------------------

Widget _icon(LucideIcon icon) => AppIcon(icon, size: 18);

/// Signing in to Bluesky: a handle and an app password that may read direct messages.
class BlueskySignInScreen extends StatefulWidget {
  const BlueskySignInScreen({super.key, required this.network});
  final Bluesky network;

  @override
  State<BlueskySignInScreen> createState() => _BlueskySignInScreenState();
}

class _BlueskySignInScreenState extends State<BlueskySignInScreen> {
  final _handle = TextEditingController();
  final _password = TextEditingController();

  @override
  void dispose() {
    _handle.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _go() async {
    if (_handle.text.trim().isEmpty || _password.text.trim().isEmpty) return;
    await widget.network.signIn(_handle.text, _password.text);
    if (!mounted) return;
    if (widget.network.state == InboxState.ready) {
      _password.clear();
      toast(context, 'Signed in to Bluesky as @${widget.network.account}');
      Navigator.of(context).maybePop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final n = widget.network;
    return ListenableBuilder(
      listenable: n,
      builder: (context, _) {
        final busy = n.state == InboxState.signingIn;
        return GhostPage(
          title: 'Sign in to Bluesky',
          body: SettingsPaneScope(
            finder: SettingsFinder(),
            child: ListView(
              padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(2), t.space(4), t.space(8) + MediaQuery.paddingOf(context).bottom),
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              children: [
                PaneSection(
                  title: 'Your account',
                  description: const Tr(
                      'Use an app password, not your account\'s password. Make one in Bluesky: Settings › Privacy and security › App passwords › Add, with "Allow access to your direct messages" ticked. It can be taken back there at any time.'),
                  footer: n.error == null ? null : Text(n.error!, style: TextStyle(color: t.danger)),
                  children: [
                    SettingRowBox(
                      child: GlacierInput(controller: _handle, placeholder: 'you.bsky.social'.t, ariaLabel: 'Your handle', autoCorrect: false, autoFocus: true, size: GlacierFieldSize.md),
                    ),
                    SettingRowBox(
                      child: GlacierInput(controller: _password, type: GlacierInputType.password, placeholder: 'xxxx-xxxx-xxxx-xxxx'.t, ariaLabel: 'App password', autoCorrect: false, size: GlacierFieldSize.md, onSubmitted: (_) => _go()),
                    ),
                    SettingRow(icon: _icon(Lucide.arrowRight), label: busy ? 'Signing in…' : 'Sign in', disabled: busy, onPress: _go),
                  ],
                ),
                SizedBox(height: t.space(4)),
                const SettingsFootnote(child: Tr('Your messages go between this device and Bluesky. Uplink\'s own server never sees them, and the app password itself isn\'t kept: only the session Bluesky gives back.')),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Linking Signal: the QR code Signal on the person's phone scans (Settings › Linked devices › Link new device). On a
/// computer it is drawn here; on the phone, which cannot scan its own screen, it is drawn on another screen too, by
/// the link to Uplink's pairing page (the same sealed room the Google Messages QR code uses), or the address copied.
class SignalLinkScreen extends StatefulWidget {
  const SignalLinkScreen({super.key, required this.network});
  final Signal network;

  @override
  State<SignalLinkScreen> createState() => _SignalLinkScreenState();
}

class _SignalLinkScreenState extends State<SignalLinkScreen> {
  /// The code on another screen, on the phone (lib/net/pair_room.dart).
  final _room = PairRoom();

  @override
  void initState() {
    super.initState();
    widget.network.begin();
    widget.network.addListener(_changed);
  }

  Future<void> _elsewhere() async {
    if (!_room.open && !await _room.openRoom(onCame: () => _showCode())) {
      // Nothing would reach the page (GMFB-15): say so rather than share a link that draws nothing.
      if (mounted) toast(context, 'Uplink\'s relay can\'t be reached right now, so the code can\'t go to another screen. Check Settings › Network.', tone: GlacierToastTone.danger);
      return;
    }
    _showCode();
    final link = _room.link;
    if (link != null && mounted) await Sms.instance.shareText('Link Signal to Uplink', link);
    if (mounted) setState(() {});
  }

  void _showCode() {
    final qr = widget.network.qr;
    if (qr != null && _room.open) _room.showCode(qr);
  }

  void _changed() {
    _showCode();
    if (widget.network.state == InboxState.ready && _room.open) _room.done();
    if (widget.network.state == InboxState.ready && mounted) {
      toast(context, 'Signal linked${widget.network.account == null ? '' : ' as ${widget.network.account}'}');
      Navigator.of(context).maybePop();
    }
  }

  @override
  void dispose() {
    widget.network.removeListener(_changed);
    _room.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final n = widget.network;
    return ListenableBuilder(
      listenable: n,
      builder: (context, _) {
        final qr = n.qr;
        return GhostPage(
          title: 'Link Signal',
          body: SettingsPaneScope(
            finder: SettingsFinder(),
            child: ListView(
              padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(2), t.space(4), t.space(8) + MediaQuery.paddingOf(context).bottom),
              children: [
                PaneSection(
                  title: 'Scan this with Signal',
                  description: const Tr('In Signal on your phone: Settings › Linked devices › Link new device, then point it at this code. Uplink becomes another of your devices, as Signal Desktop is. Messages from now on come here; Signal keeps no older ones for a new device.'),
                  footer: n.error == null ? null : Text(n.error!, style: TextStyle(color: t.danger)),
                  children: [
                    SettingRowBox(
                      child: Padding(
                        padding: EdgeInsets.all(t.space(3)),
                        child: Center(
                          child: qr == null
                              ? const GhostSpinner(size: 24, label: 'Asking Signal for a code…')
                              : Container(color: const Color(0xFFFFFFFF), padding: EdgeInsets.all(t.space(2)), child: QrView(data: qr, size: 220)),
                        ),
                      ),
                    ),
                    if (qr != null && PlatformInfo.isAndroid)
                      SettingRow(
                        icon: _icon(Lucide.share2),
                        label: 'Show it on another screen',
                        hint: Text(_room.open
                            ? 'Open ${_room.link} on a computer or tablet: the code is drawn there, and changes there as it does here. Scan it with Signal on this phone.'
                            : 'This phone can\'t scan its own screen: a link opens the code on any other screen, sealed so only that page can read it.'),
                        onPress: _elsewhere,
                      ),
                    SettingRow(icon: _icon(Lucide.rotateCcw), label: 'A new code', onPress: n.begin),
                  ],
                ),
                SizedBox(height: t.space(4)),
                const SettingsFootnote(child: Tr('Signal has no API for other apps: Uplink links the way Signal Desktop does, through the open-source mautrix-signal (GNU AGPL). Your messages go between this device and Signal only, never through Uplink\'s servers.')),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Signing in to Mastodon: the server, its own page to approve Uplink on, and the code that page shows.
class MastodonSignInScreen extends StatefulWidget {
  const MastodonSignInScreen({super.key, required this.network});
  final Mastodon network;

  @override
  State<MastodonSignInScreen> createState() => _MastodonSignInScreenState();
}

class _MastodonSignInScreenState extends State<MastodonSignInScreen> {
  final _server = TextEditingController();
  final _code = TextEditingController();
  String? _page;

  @override
  void dispose() {
    _server.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _begin() async {
    if (_server.text.trim().isEmpty) return;
    final page = await widget.network.begin(_server.text);
    if (page == null || !mounted) return;
    setState(() => _page = page);
    await Sms.instance.openLink(page);
  }

  Future<void> _finish() async {
    if (_code.text.trim().isEmpty) return;
    await widget.network.sendCode(_code.text);
    if (!mounted || widget.network.state != InboxState.ready) return;
    toast(context, 'Signed in to Mastodon as ${widget.network.account}');
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final n = widget.network;
    return ListenableBuilder(
      listenable: n,
      builder: (context, _) => GhostPage(
        title: 'Sign in to Mastodon',
        body: SettingsPaneScope(
          finder: SettingsFinder(),
          child: ListView(
            padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(2), t.space(4), t.space(8) + MediaQuery.paddingOf(context).bottom),
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            children: [
              PaneSection(
                title: _page == null ? 'Your server' : 'The code',
                description: Text(_page == null
                    ? 'The server your account is on, or your whole address (@you@mastodon.social). Its own page opens to let Uplink read and send your direct messages.'
                    : 'Approve Uplink on the page that opened, then paste the code it shows here.'),
                footer: n.error == null ? null : Text(n.error!, style: TextStyle(color: t.danger)),
                children: [
                  if (_page == null) ...[
                    SettingRowBox(child: GlacierInput(controller: _server, placeholder: 'mastodon.social'.t, ariaLabel: 'Your server', autoCorrect: false, autoFocus: true, size: GlacierFieldSize.md, onSubmitted: (_) => _begin())),
                    SettingRow(icon: _icon(Lucide.arrowRight), label: n.state == InboxState.signingIn ? 'Opening…' : 'Continue', onPress: _begin),
                  ] else ...[
                    SettingRowBox(child: GlacierInput(controller: _code, placeholder: 'The code from the page'.t, ariaLabel: 'The code', autoCorrect: false, autoFocus: true, size: GlacierFieldSize.md, onSubmitted: (_) => _finish())),
                    SettingRow(icon: _icon(Lucide.arrowRight), label: 'Sign in', onPress: _finish),
                    SettingRow(icon: _icon(Lucide.externalLink), label: 'Open the page again', onPress: () => Sms.instance.openLink(_page!)),
                  ],
                ],
              ),
              SizedBox(height: t.space(4)),
              const SettingsFootnote(child: Tr('Your messages go between this device and your Mastodon server. Uplink\'s own server never sees them; only the token your server gives back is kept.')),
            ],
          ),
        ),
      ),
    );
  }
}

/// Signing in to Telegram: the phone number, the code Telegram sends, and the two-step password where there is one.
class TelegramSignInScreen extends StatefulWidget {
  const TelegramSignInScreen({super.key, required this.network});
  final Telegram network;

  @override
  State<TelegramSignInScreen> createState() => _TelegramSignInScreenState();
}

class _TelegramSignInScreenState extends State<TelegramSignInScreen> {
  final _field = TextEditingController();
  InboxStep _shown = InboxStep.none;
  bool _busy = false;

  // On a computer paired with a phone signed in to Telegram, the phone signs it in (Matt, 2026-11-16: "Build the Telegram
  // phone sign-in approval"): the phone's own session approves this computer's login link (lib/inbox/telegram.dart).
  bool? _phoneReady;
  String? _phoneAccount;
  String? _phoneError;
  bool _askingPhone = false;

  @override
  void initState() {
    super.initState();
    widget.network.begin();
    widget.network.addListener(_changed);
    if (Sms.remote) _phoneStatus();
  }

  /// Asks the paired phone whether it is signed in to Telegram, and as whom.
  Future<void> _phoneStatus() async {
    try {
      final s = await Sms.instance.telegram({'dir': 'status'});
      if (!mounted) return;
      setState(() {
        _phoneReady = s['ready'] == true;
        _phoneAccount = s['account'] as String?;
      });
    } catch (_) {
      if (mounted) setState(() => _phoneReady = false);
    }
  }

  /// The phone approves this computer: a login link from Telegram, sent to the phone, approved with its session.
  Future<void> _byPhone() async {
    if (_askingPhone) return;
    setState(() {
      _askingPhone = true;
      _phoneError = null;
    });
    try {
      final link = await widget.network.askLoginLink();
      await Sms.instance.telegram({'dir': 'approve', 'link': link});
      // Telegram now says this device is signed in (or asks its two-step password here): _changed carries on.
    } catch (e) {
      if (mounted) setState(() => _phoneError = _words(e));
    } finally {
      if (mounted) setState(() => _askingPhone = false);
    }
  }

  /// An error's words as a person reads them: a phone's refusal comes as "PlatformException(failed, words, …)".
  static String _words(Object e) {
    final m = RegExp(r'^PlatformException\([^,]*, (.*?), .*\)$', dotAll: true).firstMatch('$e');
    final w = m?.group(1) ?? '$e';
    return w.startsWith('Bad state: ') ? w.substring(11) : w;
  }

  /// Telegram moved on: each step starts with an empty field, and once signed in the screen says so and leaves.
  void _changed() {
    final n = widget.network;
    if (n.step != _shown) {
      _shown = n.step;
      _field.clear();
    }
    if (n.state == InboxState.ready && mounted) {
      toast(context, 'Signed in to Telegram${n.account == null ? '' : ' as ${n.account}'}');
      Navigator.of(context).maybePop();
    }
  }

  @override
  void dispose() {
    widget.network.removeListener(_changed);
    _field.dispose();
    super.dispose();
  }

  /// Hands the field to Telegram as what its step asks for: the phone number, the code, or the two-step password.
  Future<void> _go() async {
    final n = widget.network;
    final v = _field.text;
    if (v.trim().isEmpty) return;
    setState(() => _busy = true);
    switch (n.step) {
      case InboxStep.phone || InboxStep.elsewhere:
        await n.sendPhone(v);
      case InboxStep.code:
        await n.sendCode(v);
      case InboxStep.password:
        await n.sendPassword(v);
      default:
        break;
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final n = widget.network;
    return ListenableBuilder(
      listenable: n,
      builder: (context, _) {
        final (title, about, placeholder, type, action) = switch (n.step) {
          InboxStep.phone || InboxStep.elsewhere => ('Your phone number', 'The number of your Telegram account, with its country code. Telegram sends a code to your Telegram app, or texts it.', '+1 555 010 0199', GlacierInputType.tel, 'Send the code'),
          InboxStep.code => ('The code', 'Telegram sent a code to ${n.codeWhere ?? 'you'}.', '12345', GlacierInputType.number, 'Sign in'),
          InboxStep.password => ('Your password', 'This account has a two-step password${n.passwordHint == null ? '' : ' (hint: ${n.passwordHint})'}.', 'Password', GlacierInputType.password, 'Sign in'),
          _ => ('', '', '', GlacierInputType.text, ''),
        };
        return GhostPage(
          title: 'Sign in to Telegram',
          body: SettingsPaneScope(
            finder: SettingsFinder(),
            child: ListView(
              padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(2), t.space(4), t.space(8) + MediaQuery.paddingOf(context).bottom),
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              children: [
                if (n.state == InboxState.unavailable)
                  SettingsCallout(child: Text(n.error ?? 'Telegram isn\'t in this build of the app.'))
                else if (n.step == InboxStep.none)
                  Padding(padding: EdgeInsets.all(t.space(8)), child: const Center(child: GhostSpinner(size: 26, label: 'Starting Telegram…')))
                else ...[
                  // Signed in by the phone, where this computer is paired with one signed in to Telegram.
                  if (Sms.remote && _phoneReady == true && (n.step == InboxStep.phone || n.step == InboxStep.elsewhere)) ...[
                    PaneSection(
                      title: 'Sign in with your phone',
                      description: Text('Your phone is signed in to Telegram${_phoneAccount == null ? '' : ' as $_phoneAccount'}. It approves this computer, and this computer gets a session of its own: no number, no code.'),
                      footer: _phoneError == null ? null : Text(_phoneError!, style: TextStyle(color: t.danger)),
                      children: [
                        SettingRow(
                          icon: _icon(Lucide.smartphone),
                          label: _askingPhone ? 'Waiting for your phone…' : 'Approve on my phone',
                          disabled: _askingPhone,
                          onPress: _byPhone,
                        ),
                      ],
                    ),
                    SizedBox(height: t.space(6)),
                  ],
                  PaneSection(
                    key: ValueKey(n.step == InboxStep.elsewhere ? InboxStep.phone : n.step),
                    title: Sms.remote && _phoneReady == true && (n.step == InboxStep.phone || n.step == InboxStep.elsewhere) ? 'Or with your number' : title,
                    description: Text(about),
                    footer: n.error == null ? null : Text(n.error!, style: TextStyle(color: t.danger)),
                    children: [
                      SettingRowBox(child: GlacierInput(controller: _field, type: type, placeholder: placeholder, ariaLabel: title, autoCorrect: false, autoFocus: true, size: GlacierFieldSize.md, onSubmitted: (_) => _go())),
                      SettingRow(icon: _icon(n.step == InboxStep.phone || n.step == InboxStep.elsewhere ? Lucide.messageSquare : Lucide.arrowRight), label: _busy ? 'One moment…' : action, disabled: _busy, onPress: _go),
                    ],
                  ),
                ],
                SizedBox(height: t.space(4)),
                const SettingsFootnote(child: Tr('Uplink signs in as a Telegram app of its own, on this device. Your chats go between it and Telegram; Uplink\'s own server never sees them. Sign out here, or end the session in Telegram › Settings › Devices.')),
              ],
            ),
          ),
        );
      },
    );
  }
}

// --- Settings --------------------------------------------------------------------------------------------------------

/// Settings › Connections, and each network's own page under it (Matt, 2026-11-17: "move the connections to it's own sub
/// setting, label it as such and put connecting to telegram etc all under that page so as to not crowd the main
/// settings page there shuld be a sub section to pick and modify each one"): one row in Settings' list, a page of the
/// networks, connected ones first, and each network's page (who is signed in, signing in or out) opened from its row.
/// The networks' pages are no longer rows of Settings' list; they are still opened by their ids and found by search.
List<SettingsSection> inboxSettingsSections() => [
      SettingsSection(
        id: 'connections',
        label: 'Connections',
        icon: _icon(Lucide.link),
        hue: 'cyan',
        group: 'me',
        summary: (_) {
          final on = [for (final n in Inbox.instance.networks) if (!n.soon && n.state == InboxState.ready) n.name];
          return on.isEmpty ? 'Telegram, Signal and more' : on.join(', ');
        },
        page: (context, m) => _connections(context),
      ),
      for (final n in Inbox.instance.networks)
        SettingsSection(
          id: 'inbox-${n.id}',
          label: n.name,
          icon: inboxMark(n),
          hue: switch (n.id) { 'telegram' => 'cyan', 'mastodon' => 'purple', 'signal' => 'indigo', 'teams' => 'magenta', 'whatsapp' => 'green', 'matrix' => 'graphite', 'googlechat' => 'mint', 'instagram' => 'rose', 'messenger' => 'blue', 'linkedin' => 'indigo', 'discord' => 'indigo', 'twitter' => 'graphite', 'slack' => 'purple', _ => 'blue' },
          group: 'me',
          listed: false,
          summary: (_) => _summary(n),
          page: (context, m) => _pane(context, n),
        ),
    ];

/// The Connections page: Telegram and Signal (the official networks) first, then plugins — the other networks, off
/// until switched on (Matt, 2026-11-20: "only keep telegram and signal as the official services ... Setup all these
/// other services as plugins"). Each row shows where it stands and opens its own page.
List<Widget> _connections(BuildContext context) => [
      ListenableBuilder(
        listenable: Listenable.merge([Inbox.instance.switches, ...Inbox.instance.networks]),
        builder: (context, _) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: _connectionsBody(context)),
      ),
    ];

/// The page's sections, as things stand now: the official networks signed in to (or signing in), the official ones that
/// are not, the plugins, and those still to come.
List<Widget> _connectionsBody(BuildContext context) {
  final officials = Inbox.instance.official;
  final plugins = Inbox.instance.plugins;
  final on = [for (final n in officials) if (n.state == InboxState.ready || n.state == InboxState.signingIn) n];
  final off = [for (final n in officials) if (!on.contains(n)) n];
  final pluginRows = [for (final n in plugins) if (!n.soon) n];
  final soon = [for (final n in plugins) if (n.soon) n];
  Widget row(InboxNetwork n, {String? hint}) => SettingRow(
        key: ValueKey('connection-${n.id}'),
        icon: inboxMark(n),
        label: n.name,
        hint: Text(hint ?? _summary(n)),
        onPress: () => push<void>(context, (_) => SettingsSectionScreen('inbox-${n.id}')),
      );
  const intro = Tr('Your chats on other networks among your texts in Messages, each marked with its logo. Uplink signs in to each as an app of its own, on this device; its own server never sees your chats.');
  const pluginIntro = Tr('Beyond Telegram and Signal, Uplink can bring in other networks as plugins. These aren\'t official Uplink connections — each signs in the way that network\'s own website or app does, and some don\'t allow other apps at all. Switch one on to connect it.');
  return [
    if (on.isNotEmpty) PaneSection(title: 'Connected', description: intro, children: [for (final n in on) row(n)]),
    if (off.isNotEmpty) PaneSection(title: on.isEmpty ? 'Official networks' : 'Add a connection', description: on.isEmpty ? intro : null, children: [for (final n in off) row(n)]),
    if (pluginRows.isNotEmpty)
      PaneSection(title: 'Plugins', description: pluginIntro, children: [for (final n in pluginRows) row(n, hint: n.enabled ? _summary(n) : 'Off')]),
    if (soon.isNotEmpty) PaneSection(title: 'Coming soon', children: [for (final n in soon) row(n)]),
  ];
}

/// Where a network stands, in a few words: the line under its name on the Connections page.
String _summary(InboxNetwork n) => n.soon ? 'Coming soon' : switch (n.state) {
      InboxState.ready => 'Signed in${n.account == null ? '' : ' as ${n.account}'}',
      InboxState.signingIn => 'Signing in…',
      InboxState.signedOut => 'Not signed in',
      InboxState.unavailable => 'Not in this build',
    };

/// One network's own page ([_paneBody]), drawn again whenever the network or the plugins' switches change.
List<Widget> _pane(BuildContext context, InboxNetwork n) => [
      ListenableBuilder(
        listenable: Listenable.merge([Inbox.instance.switches, n]),
        builder: (context, _) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: _paneBody(context, n)),
      ),
    ];

/// Switches a plugin network off: signs out first where it is signed in, asked for.
Future<void> turnOffNetwork(BuildContext context, InboxNetwork n) async {
  if (n.state != InboxState.ready && n.state != InboxState.signingIn) {
    // Off on the account's other devices too (GMFB-9; one signed in there stays signed in: lib/plugins/plugin_sync.dart).
    PluginSync.instance.switched('net${n.id}', false);
    await Inbox.instance.disable(n);
    return;
  }
  await showChoices(context, title: 'Turn off ${n.name}?', choices: [
    Choice('Turn off and sign out', Lucide.logOut, () {
      ScrollMemory.forgetAll('inbox:${n.id}:');
      PluginSync.instance.switched('net${n.id}', false);
      Inbox.instance.disable(n);
    }, danger: true, hint: 'You can switch it on and sign in again any time.'),
  ]);
}

List<Widget> _paneBody(BuildContext context, InboxNetwork n) {
  void signIn() {
    final page = switch (n) { Telegram tg => TelegramSignInScreen(network: tg), Bluesky b => BlueskySignInScreen(network: b), Mastodon m => MastodonSignInScreen(network: m), Signal sg => SignalLinkScreen(network: sg), Teams tm => TeamsSignInScreen(network: tm), GoogleChat gc => GoogleChatSignInScreen(network: gc), WhatsApp wa => WhatsAppLinkScreen(network: wa), Matrix mx => MatrixSignInScreen(network: mx), AccountHelper h => HelperSignInScreen(network: h), _ => null };
    if (page != null) push<void>(context, (_) => page);
  }

  // A plugin (every network but Telegram and Signal) is off until switched on here, and not signed in to until it is.
  // One not in this build shows why instead of a switch it can't honour.
  final plugin = !n.official && !n.soon;
  final showToggle = plugin && n.state != InboxState.unavailable;
  final showMain = !plugin || n.enabled || n.state == InboxState.unavailable;
  return [
    if (showToggle)
      PaneSection(
        title: 'Plugin',
        description: Text('${n.name} is a plugin, not an official Uplink connection. Switch it on to connect it; switch it off and it is signed out and left alone.'),
        children: [
          SettingRow(
            key: const ValueKey('plugin-switch'),
            icon: _icon(Lucide.puzzle),
            label: 'Use ${n.name}',
            control: GlacierSwitch(checked: n.enabled, ariaLabel: 'Use ${n.name}', onCheckedChange: (want) {
              if (!want) return unawaited(turnOffNetwork(context, n));
              // On on the account's other devices too, where it offers its sign-in (GMFB-9: lib/plugins/plugin_sync.dart).
              PluginSync.instance.switched('net${n.id}', true);
              unawaited(Inbox.instance.enable(n));
            }),
          ),
        ],
      ),
    if (showMain)
    PaneSection(
      title: n.name,
      description: Text('Your ${n.name} chats among your texts in Messages, marked with its logo, read and answered here. They go between this device and ${n.name} only.'),
      footer: n.error == null || n.state == InboxState.ready ? null : Text(n.error!),
      children: [
        // WhatsApp allows no other apps (Matt, 2026-11-17: "warn the user that it's unsupported by whatsapp").
        if (n is WhatsApp) SettingsCallout(child: Text(whatsAppWarning)),
        // Nor do Messenger, Instagram or LinkedIn (lib/inbox/account_helper.dart): the same is said of each.
        if (n is AccountHelper) SettingsCallout(child: Text(n.service.warning)),
        if (n.soon)
          SettingRow(icon: _icon(Lucide.info), label: 'Coming soon', hint: Text('${n.name} chats aren\'t offered yet.'), disabled: true)
        else if (n.state == InboxState.ready) ...[
          SettingRow(icon: _icon(Lucide.userRound), label: n.account ?? 'Signed in', hint: Text('${n.chats.length} chat${n.chats.length == 1 ? '' : 's'}')),
          SettingRow(
            icon: _icon(Lucide.logOut),
            label: 'Sign out',
            onPress: () => showChoices(context, title: 'Sign out of ${n.name}?', choices: [
              // Its chats' kept spots go with it: signed in again, perhaps as someone else, the same ids may name other chats.
              Choice('Sign out', Lucide.logOut, () {
                ScrollMemory.forgetAll('inbox:${n.id}:');
                n.signOut();
              }, danger: true),
            ]),
          ),
        ] else if (n.state == InboxState.unavailable)
          SettingRow(icon: _icon(Lucide.info), label: 'Not in this build', hint: Text(n.error ?? '${n.name} isn\'t set up in this build of the app.'), disabled: true)
        else
          SettingRow(icon: _icon(Lucide.arrowRight), label: n.state == InboxState.signingIn ? 'Carry on signing in' : 'Sign in', onPress: signIn),
      ],
    ),
  ];
}

/// A network's card on its plugin's page in the Marketplace (lib/plugins/networks.dart): where it stands, and the way
/// to its own page in Settings › Connections to sign in or out.
Widget networkPluginCard(BuildContext context, InboxNetwork n) => ListenableBuilder(
      listenable: Listenable.merge([Inbox.instance.switches, n]),
      builder: (context, _) => PaneSection(
        title: 'Connection',
        children: [
          SettingRow(
            key: ValueKey('plugin-connection-${n.id}'),
            icon: inboxMark(n),
            label: switch (n.state) { InboxState.ready => n.account ?? 'Signed in', InboxState.signingIn => 'Carry on signing in', InboxState.unavailable => 'Not in this build', InboxState.signedOut => 'Sign in to ${n.name}' },
            hint: Text(n.state == InboxState.unavailable ? (n.error ?? '${n.name} isn\'t set up in this build of the app.') : _summary(n)),
            disabled: n.state == InboxState.unavailable,
            onPress: n.state == InboxState.unavailable ? null : () => push<void>(context, (_) => SettingsSectionScreen('inbox-${n.id}')),
          ),
        ],
      ),
    );

/// Puts the networks' sections into Settings, and redraws it as they change.
void addInboxSettings() => SettingsSources.add(inboxSettingsSections, watch: [Inbox.instance.switches, ...Inbox.instance.networks]);



/// The files waiting to go with the next message, above the composer: each with a way to take it off.
class _FilesStrip extends StatelessWidget {
  const _FilesStrip({required this.files, required this.onRemove});
  final List<String> files;
  final ValueChanged<String> onRemove;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final side = t.lenOf('4rem');
    return SizedBox(
      height: side + t.space(2),
      child: ListView(scrollDirection: Axis.horizontal, padding: EdgeInsetsDirectional.only(bottom: t.space(2), start: t.space(1)), children: [
        for (final f in files)
          Padding(
            padding: EdgeInsetsDirectional.only(end: t.space(2)),
            child: Stack(children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(t.radius('md')),
                child: Telegram.kindOf(f) == 'photo'
                    ? Image.file(File(f), width: side, height: side, fit: BoxFit.cover, cacheWidth: faceDecodeWidth(context, side))
                    : Container(
                        width: side,
                        height: side,
                        color: t.color('app-paper-2'),
                        padding: EdgeInsets.all(t.space(1)),
                        alignment: Alignment.center,
                        child: Column(mainAxisSize: MainAxisSize.min, children: [
                          AppIcon(Telegram.kindOf(f) == 'video' ? Lucide.play : Lucide.file, size: 18),
                          Text(f.split('/').last, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('xs'), color: t.color('app-ink-3'))),
                        ]),
                      ),
              ),
              PositionedDirectional(top: 0, end: 0, child: IconTap(icon: Lucide.x, label: 'Take off ${f.split('/').last}', size: 14, box: t.lenOf('1.5rem'), onPressed: () => onRemove(f))),
            ]),
          ),
      ]),
    );
  }
}

/// A picture, video, sound or file in a chat's bubble: a picture drawn (brought down as it is first drawn), a video's
/// picture with Play, a sound or file as its name; a tap opens it full screen, in Uplink's player, or in the app that
/// reads it.
class InboxMediaView extends StatelessWidget {
  const InboxMediaView({super.key, required this.network, required this.media, required this.ink, this.card = false});

  /// A sound or a file on a card of its own, as a circle's are (lib/ui/space_chat_files.dart): on the page, with no
  /// bubble round it.
  final bool card;
  final InboxNetwork network;
  final InboxMedia media;
  final Color ink;

  Future<void> _open(BuildContext context) async {
    // A video or a sound opens at once and waits for its file there, with a spinner (Matt, 2026-11-17: "The app has
    // gotten pretty laggy, especially when opening videos and exiting them").
    if (media.kind == 'video' || media.kind == 'audio') {
      final known = media.path;
      await Navigator.of(context, rootNavigator: true).push(videoRoute(VideoScreen.coming(file: known != null ? Future.value(known) : network.fileOf(media.fileId), title: media.name ?? network.name)));
      return;
    }
    final path = media.path ?? await network.fileOf(media.fileId);
    if (path == null || !context.mounted) return;
    switch (media.kind) {
      case 'photo' || 'sticker':
        // The same full-screen overlay as a picture in a space's chat (lib/ui/picture_overlay.dart).
        await showPictureOverlay(context, path: path, title: media.name);
      default:
        await Sms.instance.openFile(path, name: media.name);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final width = t.lenOf('15rem');
    final ratio = media.width > 0 && media.height > 0 ? (media.width / media.height).clamp(0.5, 2.0) : 4 / 3;
    Widget picture(String? path, int? id) {
      if (path == null && id != null) network.wantFile(id);
      return SizedBox(
        width: width,
        height: width / ratio,
        child: path == null ? const SkeletonPicture() : Image.file(File(path), fit: BoxFit.cover, gaplessPlayback: true, cacheWidth: fillDecodeWidth(context, width * 2)),
      );
    }

    Widget file() => Row(mainAxisSize: MainAxisSize.min, children: [
        AppIcon(media.kind == 'audio' ? Lucide.play : Lucide.file, size: 20, color: ink),
        SizedBox(width: t.space(2)),
        Flexible(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(media.name ?? (media.kind == 'audio' ? 'Sound' : 'File'), maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('sm'), weight: 'semibold', color: ink)),
            Text([if (media.duration > 0) _clock(media.duration), if (media.size > 0) _bytes(media.size)].join(' · '), style: pageText(t, t.fontSize('xs'), color: ink.withValues(alpha: 0.7))),
          ]),
        ),
      ]);

    final Widget body = switch (media.kind) {
      'photo' => ClipRRect(borderRadius: BorderRadius.circular(t.radius('md')), child: picture(media.path, media.fileId)),
      // A sticker as it is: its own size, its see-through parts showing the chat behind it, nothing round it.
      'sticker' => InboxSticker(network: network, media: media),
      'video' => ClipRRect(
          borderRadius: BorderRadius.circular(t.radius('md')),
          child: Stack(alignment: Alignment.center, children: [
            media.thumbId == null ? Container(width: width, height: width / ratio, color: const Color(0xFF111111)) : picture(media.thumbPath, media.thumbId),
            Container(
              padding: EdgeInsets.all(t.space(3)),
              decoration: const BoxDecoration(shape: BoxShape.circle, color: Color(0x99000000)),
              child: const AppIcon(Lucide.play, size: 22, color: Color(0xFFFFFFFF)),
            ),
            if (media.duration > 0)
              PositionedDirectional(end: t.space(2), bottom: t.space(2), child: Text(_clock(media.duration), style: pageText(t, t.fontSize('xs'), weight: 'semibold', color: const Color(0xFFFFFFFF)))),
          ]),
        ),
      _ => card
          ? Container(
              padding: EdgeInsets.symmetric(horizontal: t.space(3), vertical: t.space(2)),
              decoration: BoxDecoration(color: theirBubble(t, onBackground: false), border: theirRim(t), borderRadius: BorderRadius.circular(lookCorner(t, '1rem', most: 1))),
              child: file(),
            )
          : file(),
    };
    return GlacierPressable(onPressed: () => _open(context), semanticLabel: 'Open ${media.name ?? media.kind}', builder: (context, _) => body);
  }

  static String _clock(int s) => '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  static String _bytes(int b) => b >= 1 << 20 ? '${(b / (1 << 20)).toStringAsFixed(1)} MB' : '${(b / 1024).ceil()} KB';
}

/// [m] is a sticker and nothing else: drawn with no bubble round it.
bool isStickerAlone(InboxMessage m) => m.media.length == 1 && m.media.single.kind == 'sticker' && m.text.trim().isEmpty && m.replyTo == null;

/// A sticker in a chat (Matt, 2026-11-20: "stickers in telegram chat and others render inside chat bubbles instead of
/// transparent backgrounds when sent and when recieved"): at most 9rem a side in its own shape, contained, nothing
/// behind it; a soft square while it comes down.
class InboxSticker extends StatelessWidget {
  const InboxSticker({super.key, required this.network, required this.media});
  final InboxNetwork network;
  final InboxMedia media;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final most = t.lenOf('9rem');
    final ratio = media.width > 0 && media.height > 0 ? (media.width / media.height).clamp(0.5, 2.0) : 1.0;
    final w = ratio >= 1 ? most : most * ratio, h = ratio >= 1 ? most / ratio : most;
    final path = media.path;
    if (path == null) network.wantFile(media.fileId);
    return SizedBox(
      width: w,
      height: h,
      child: path == null
          ? SkeletonPicture(radius: t.radius('lg'))
          : Image.file(File(path), fit: BoxFit.contain, gaplessPlayback: true, cacheWidth: fillDecodeWidth(context, w * 2)),
    );
  }
}

/// [bubble] with [m]'s reactions stuck on it, as a text's are (lib/ui/reaction_stickers.dart).
Widget _withReactions(BuildContext context, InboxMessage m, VoidCallback? onTap, Widget bubble) => m.reactions.isEmpty
    ? bubble
    : ReactionStickers(bubble: bubble, seed: '${m.date.millisecondsSinceEpoch}:${m.id}', kinds: [for (final r in m.reactions) (emoji: r.emoji, count: r.count)], onTap: onTap);

/// The reactions offered over a network message's menu; yours ringed, and a press on one takes it off.
class InboxReactionRow extends StatelessWidget {
  const InboxReactionRow({super.key, required this.choices, required this.mine, required this.onPick});
  final List<String> choices;
  final Set<String> mine;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final side = t.lenOf('2.75rem');
    return Padding(
      padding: EdgeInsetsDirectional.fromSTEB(t.space(3), t.space(3), t.space(3), t.space(1)),
      child: Wrap(spacing: t.space(1), runSpacing: t.space(1), alignment: WrapAlignment.center, children: [
        for (final e in choices)
          GlacierPressable(
            onPressed: () => onPick(e),
            semanticLabel: mine.contains(e) ? 'Take off $e' : 'React $e',
            builder: (context, state) => Container(
              width: side,
              height: side,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: state.pressed ? t.color('app-paper-3') : null,
                border: mine.contains(e) ? Border.all(color: t.color('app-accent'), width: 2) : null,
              ),
              child: Text(e, style: pageText(t, t.lenOf('1.45rem'), height: 1.1)),
            ),
          ),
      ]),
    );
  }
}

/// The message a reply answers, at the head of its bubble: who said it and the start of what they said.
class InboxQuote extends StatelessWidget {
  const InboxQuote({super.key, this.sender, this.text, required this.ink});
  final String? sender;
  final String? text;
  final Color ink;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Container(
      margin: EdgeInsets.only(bottom: t.space(2)),
      padding: EdgeInsetsDirectional.fromSTEB(t.space(2), t.space(1), t.space(2), t.space(1)),
      decoration: BoxDecoration(
        color: ink.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(t.lenOf('0.5rem')),
        border: Border(left: BorderSide(color: ink.withValues(alpha: 0.5), width: 3)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        if (sender != null && sender!.isNotEmpty) Text(sender!, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('xs'), weight: 'semibold', color: ink)),
        Text((text ?? '').trim().isEmpty ? 'A message' : text!.trim(), maxLines: 2, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('sm'), color: ink.withValues(alpha: 0.8))),
      ]),
    );
  }
}

/// Over the message box while a reply is written: whom it answers and what, and a way to stop replying.
class InboxReplyBar extends StatelessWidget {
  const InboxReplyBar({super.key, required this.to, required this.text, required this.onClose});
  final String to;
  final String text;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      padding: EdgeInsets.only(bottom: t.space(2)),
      child: Row(children: [
        AppIcon(LucideMore.reply, size: 16, color: t.color('app-accent')),
        SizedBox(width: t.space(2)),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text('Replying to $to', maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('xs'), weight: 'semibold', color: t.color('app-accent'))),
            if (text.isNotEmpty) Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-3'))),
          ]),
        ),
        IconTap(icon: Lucide.x, label: 'Stop replying', size: 18, onPressed: onClose),
      ]),
    );
  }
}
