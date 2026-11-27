/// Uplink's plugins: the contract (Matt, 2026-11-14: "prime the whole app to have plugin support for placing
/// UI elements and doing things like filtering out spam messages separating OTPs into their own section and more").
///
/// A plugin is a [GhostPlugin]: an id, a name, a line saying what it does and a switch (the Marketplace, kept with
/// the person's other choices). Switched off it adds nothing. Switched on it adds through four kinds of
/// extension point, each a plain value the app asks for and draws or acts on itself:
///
/// - [Classifier]: given a conversation or a message as [MessageFacts], the [Tag]s it deserves (`code`, `spam`).
/// - [ListSection]: a section of the list of conversations with a chip of its own, which takes the conversations
///   it wants out of the main list and says how its rows look ([RowLook]).
/// - [Slot]: a named place on a screen ([Slots]) for buttons and menu items ([PluginAction]) or widgets.
/// - [IncomingRule]: what to do with a message that has just come ([IncomingAction]).
/// - [TextRule]: what a message's words are shown as, in place of what they say: a translation ([ShownText]).
///
/// A screen asks the registry (registry.dart) what its plugins have for a place and draws that; a plugin is handed
/// facts and a [PluginHost] to ask things of, never a screen or its state. All but the widget slots is data in and
/// data out ([MessageFacts.toJson] is the shape of the data in), so that a plugin loaded from outside the app one
/// day, a script or a package, could meet the same contract: docs/RECORD.md says what that would still need.
library;

import '../local_ai.dart' show AiLine;
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import '../art/app_icon.dart';
import '../art/lucide.g.dart';
import '../sms.dart';
import '../voice/plugin_note.dart';

export '../voice/plugin_note.dart' show PluginChatNote;

// --- what a plugin is shown ------------------------------------------------------------------------------------------

/// A conversation by its last words, or one message, as a plugin is shown it: who it is from, what it says, and
/// whether the phone's contacts know them.
@immutable
class MessageFacts {
  const MessageFacts({required this.thread, required this.senders, required this.text, required this.contact, this.group = false, this.date, this.unread = false, this.muted = false, this.outgoing, this.id, this.network, this.encrypted = false, this.codeWaiting = false, this.contactByName = false});

  /// Whether this device can read the phone's contacts, which is how [contact] is worked out for its conversations and
  /// messages ([contactByName]): on a phone, Android's Contacts permission as the app last read it ([heardStatus]); on
  /// a computer, which can't ask the phone, once a conversation from it has a name at all. Without it no number has a
  /// name and everyone reads as not a contact, so a plugin from another developer sees nothing (lib/plugins/pack/
  /// format.dart packSees). The registry's switches carry it, so everything is classified again when it changes.
  static bool get contactsReadable => _contactsReadable ?? !Sms.remote;
  static set contactsReadable(bool readable) => _contactsReadable = readable;
  static bool? _contactsReadable;

  /// Back to as the app starts: a test's own setting forgotten.
  @visibleForTesting
  static void forgetContactsReadable() => _contactsReadable = null;

  /// The phone's permissions as just read: on a phone, whether it may read its contacts. A computer's own answer says
  /// nothing of its phone's, and is left out.
  static void heardStatus(SmsStatus status) {
    if (!Sms.remote) contactsReadable = status.contacts;
  }

  /// The conversation it is, or is in.
  final int thread;

  /// The numbers (or email addresses) of the other people in the conversation; of the one who sent it, for a
  /// message.
  final List<String> senders;
  final String text;

  /// One of [senders] is in the phone's contacts.
  final bool contact;

  /// The conversation has more than one other person in it.
  final bool group;
  final DateTime? date;
  final bool unread;

  /// The conversation is muted: its messages arrive without a notification.
  final bool muted;

  /// Whether the words are the person's own. Null where that is not known: the list of conversations holds a
  /// conversation's last words, not whose they are.
  final bool? outgoing;

  /// The message itself, for one message: what it is known by while the app is open ("sms:12", "telegram:10:4",
  /// "space:9f…"). Null for a conversation.
  final String? id;

  /// Where a message came by: 'sms' (a text, or one between friends), 'telegram', 'signal', 'space'. Null for a
  /// conversation of texts as the list holds it.
  final String? network;

  /// It came sealed by Uplink's own encryption, or the conversation's encryption is on (Message.encrypted,
  /// Conversation.encrypted): a plugin from another developer never sees it (lib/plugins/pack/format.dart packSees).
  final bool encrypted;

  /// A text with a sign-in code in it waits unread in the conversation under newer words that have none: a code, then
  /// "Never share this code" a moment later. Android's one notification for the conversation still holds the code, so a
  /// plugin from another developer neither sorts it nor marks it read nor takes its notification away until it is
  /// read (lib/plugins/pack/format.dart packMayAct; lib/plugins/list.dart learns it from the phone).
  final bool codeWaiting;

  /// [contact] was worked out from whether a sender has a name in the phone's contacts, as it is for the phone's own
  /// conversations and messages, so it holds only where those can be read ([contactsReadable]); false where the facts
  /// say who is a contact themselves (a test, Try it, the API's filters.classify).
  final bool contactByName;

  /// The same, with other words: a message's as a bubble shows them (without "(sent with Slam)").
  MessageFacts withText(String text) => MessageFacts(thread: thread, senders: senders, text: text, contact: contact, group: group, date: date, unread: unread, muted: muted, outgoing: outgoing, id: id, network: network, encrypted: encrypted, codeWaiting: codeWaiting, contactByName: contactByName);

  /// The same, a sign-in code waiting unread under its words ([codeWaiting]).
  MessageFacts withCodeWaiting() => MessageFacts(thread: thread, senders: senders, text: text, contact: contact, group: group, date: date, unread: unread, muted: muted, outgoing: outgoing, id: id, network: network, encrypted: encrypted, codeWaiting: true, contactByName: contactByName);

  /// A conversation as the list holds it: its people and its last words.
  factory MessageFacts.conversation(Conversation c) => MessageFacts(
        thread: c.id,
        senders: [for (final p in c.people) p.address],
        // What they last sent, where your own words are newer: a pitch answered "STOP" is still a pitch (Matt,
        // 2026-11-14: "Health insurance sales people are not getting caught by the sales filter").
        text: c.heard ?? c.snippet,
        contact: c.people.any(_known),
        group: c.group,
        date: c.date,
        unread: c.unread,
        muted: c.muted,
        // Whose words these are: heard is set only for a conversation with one person not in the contacts where
        // something came in (Store.kt fills it with the newest words that came in), so where it is set the words are
        // theirs. Elsewhere the row's words may be the person's own, and that isn't known.
        outgoing: c.heard != null ? false : null,
        encrypted: c.encrypted,
        contactByName: true,
      );

  /// One message of the conversation [thread], whose other people are [people].
  factory MessageFacts.message(Message m, {required int thread, required List<Person> people}) {
    final from = m.outgoing ? const <Person>[] : [for (final p in people) if (p.address == m.address) p];
    final sender = from.isNotEmpty ? from : (people.length == 1 ? people : const <Person>[]);
    return MessageFacts(
      thread: thread,
      senders: m.outgoing || m.address.isEmpty ? [for (final p in people) p.address] : [m.address],
      text: m.body,
      contact: sender.any(_known),
      group: people.length > 1,
      date: m.date,
      outgoing: m.outgoing,
      id: m.key,
      network: 'sms',
      encrypted: m.encrypted,
      contactByName: true,
    );
  }

  static bool _known(Person p) => p.name != null && p.name!.isNotEmpty;

  /// The same as plain values: what a plugin that is not compiled into the app would be handed.
  Map<String, Object?> toJson() => {
        'thread': thread,
        'senders': senders,
        'text': text,
        'contact': contact,
        'group': group,
        'date': date?.millisecondsSinceEpoch,
        'unread': unread,
        'muted': muted,
        'outgoing': outgoing,
        if (id != null) 'id': id,
        if (network != null) 'network': network,
        'encrypted': encrypted,
      };
}

/// What a classifier found: a name (`code`, `spam`) and what it has to say with it (the code itself, why the text
/// reads as spam).
@immutable
class Tag {
  const Tag(this.name, [this.detail]);
  final String name;
  final String? detail;

  @override
  String toString() => detail == null ? name : '$name ($detail)';
}

/// The tags every classifier gave one conversation or message. Where two give the same name, the first is kept.
@immutable
class TagSet {
  const TagSet._(this._found);

  factory TagSet(Iterable<Tag> found) {
    final by = <String, String?>{};
    for (final tag in found) {
      by.putIfAbsent(tag.name, () => tag.detail);
    }
    return by.isEmpty ? none : TagSet._(by);
  }

  static const none = TagSet._({});

  final Map<String, String?> _found;

  bool has(String name) => _found.containsKey(name);
  String? detail(String name) => _found[name];
  Iterable<String> get names => _found.keys;
  bool get isEmpty => _found.isEmpty;

  /// The same names with the same details.
  bool same(TagSet other) {
    if (_found.length != other._found.length) return false;
    for (final e in _found.entries) {
      if (!other._found.containsKey(e.key) || other._found[e.key] != e.value) return false;
    }
    return true;
  }

  @override
  String toString() => _found.isEmpty ? 'no tags' : [for (final e in _found.entries) Tag(e.key, e.value)].join(', ');
}

// --- (a) classifiers -------------------------------------------------------------------------------------------------

/// Says which tags a conversation or a message deserves. It is asked once for each and the answer is kept until the
/// words change (registry.dart, [TagStore]), so it must be cheap, must answer the same for the same facts, and is
/// given none of the person's choices: what depends on a choice belongs in [ListSection.takes], which is asked
/// every time.
typedef Classifier = List<Tag> Function(MessageFacts facts);

/// A classifier that is told the plugin's own choices: a filter whose strictness and words the person sets (Matt,
/// 2026-11-16: "detailed settings for the filtering with strictness settings and tweak options for everything").
/// What it said is kept as a [Classifier]'s is, and worked out again for every conversation when one of a plugin's
/// choices changes ([PluginRegistry.switches]).
typedef TunedClassifier = List<Tag> Function(MessageFacts facts, PluginPrefs prefs);

// --- what a plugin may ask of the app --------------------------------------------------------------------------------

/// A plugin's own choices, kept with the person's others under the plugin's name.
abstract interface class PluginPrefs {
  String? get(String key);
  void set(String key, String value);

  /// A switch: on unless it was switched off ([fallback] false: off unless switched on).
  bool flag(String key, {bool fallback = true});
  void setFlag(String key, bool on);

  /// Nothing chosen: every switch at its fallback, every choice unset. For a test, and a classifier asked outside
  /// the list.
  static const PluginPrefs none = _NoPrefs();
}

class _NoPrefs implements PluginPrefs {
  const _NoPrefs();
  @override
  String? get(String key) => null;
  @override
  void set(String key, String value) {}
  @override
  bool flag(String key, {bool fallback = true}) => fallback;
  @override
  void setFlag(String key, bool on) {}
}

/// A list of words or addresses kept in one choice, a line each; typed with commas or lines between them.
List<String> wordsOf(PluginPrefs prefs, String key) => [
      for (final w in (prefs.get(key) ?? '').split(RegExp(r'[\n,]')))
        if (w.trim().isNotEmpty) w.trim(),
    ];

/// What a plugin's action is handed to do its work with: the app's side of the contract. A screen that draws a
/// slot or a section gives one; a plugin never sees the screen.
abstract interface class PluginHost {
  /// The choices of the plugin whose action this is.
  PluginPrefs get prefs;

  /// Says [words] to the person, briefly.
  void say(String words);

  /// Puts [text] on the clipboard, and says [say] where given.
  void copy(String text, {String? say});

  /// Opens the conversation [thread].
  void open(int thread);

  Future<void> markRead(int thread);

  /// Files the conversation [thread] in the section [section], or in the main list where that is null, and it
  /// stays there whatever the classifiers say of it afterwards.
  void move(int thread, String? section);

  /// Writes [text] into the message being written. Only a conversation's composer does anything with it.
  void write(String text);

  /// Shows [page] over everything, on the app's outermost navigator: a sheet of the plugin's own (the Cleaner's).
  /// Only a screen with a context to show it from does anything with it.
  void present(WidgetBuilder page);

  /// Deletes the conversation [thread] from the phone, for every app. It cannot be taken back: a plugin asks the
  /// person first. Only the list does anything with it.
  Future<void> deleteThread(int thread);

  /// Reads the list again, after a plugin changed what is in it.
  Future<void> reload();
}

/// Something a plugin offers to do: a button in a header or a composer, a line in a menu, a row's own button. The
/// app draws it as the place it is in draws such things, and calls [run] when it is chosen.
@immutable
class PluginAction {
  const PluginAction({required this.label, required this.icon, required this.run, this.danger = false, this.quiet = false});
  final String label;
  final LucideIcon icon;
  final FutureOr<void> Function(PluginHost host) run;

  /// Drawn in red: it deletes, or cannot be taken back.
  final bool danger;

  /// Drawn small and faint: there when wanted, not asking to be pressed (the Cleaner's brush).
  final bool quiet;
}

// --- (b) sections of the list ----------------------------------------------------------------------------------------

/// How a section draws one of its conversations, where it is not as the main list does: said in words, and drawn by
/// the list (ui.dart, PluginRow).
@immutable
class RowLook {
  const RowLook({this.value, this.caption, this.end, this.word, this.tap, this.title, this.face});

  /// What the row is called, in place of who the conversation is with: the company a code is from, where its
  /// number says nothing.
  final String? title;

  /// What stands where the person's picture would: a company's own face.
  final RowFace? face;

  /// Drawn large where the last words would be, with the words small under it: a sign-in code.
  final String? value;

  /// A quiet line under the words: why the conversation is in this section.
  final String? caption;

  /// A button at the row's end.
  final PluginAction? end;

  /// A word to press after the caption.
  final PluginAction? word;

  /// What a tap on the row does, in place of opening the conversation (which its long press then offers).
  final PluginAction? tap;
}

/// A face for a row that is not a person's (ui.dart, BrandFace): a company's, by its name, its own colour and the
/// web address its logo is found by. Said in words, as the rest of a row's look is, and drawn by the list.
@immutable
class RowFace {
  const RowFace({required this.name, required this.color, this.domain, this.mark});

  /// The company's name: its first letter stands in the face where there is no logo to draw.
  final String name;

  /// Its own colour, as 0xRRGGBB.
  final int color;

  /// Its web address, where it is a company the app knows; null for anything else.
  final String? domain;

  /// Its mark, where the app has one: one path on a 24 by 24 square (company_marks.g.dart). Drawn on the colour
  /// in place of the letter.
  final String? mark;
}

/// A section of the list of conversations: a chip under the search field beside "Messages", and a list of its own
/// when the chip is chosen, the newest first. The chip is there only while the section has conversations.
@immutable
class ListSection {
  const ListSection({required this.id, required this.label, required this.icon, required this.takes, this.leavesMain = true, this.row, this.filter = false, this.hidden = false, this.always = false, this.alwaysWhen});

  /// Its tab is in the list's toggle even with nothing in it (Matt, 2026-11-19: "always show the codes tab even if we
  /// don't have any codes yet"); the others' tabs come with their first conversation.
  final bool always;

  /// Whether [always] holds now: Codes only while something here can bring a code (Matt, 2026-11-19: "only show codes
  /// if sms messages or other sources for codes are enabled"). Null: whenever [always] is set.
  final bool Function()? alwaysWhen;

  /// Its tab is shown with nothing in it, as things stand now.
  bool get alwaysNow => always && (alwaysWhen?.call() ?? true);

  /// A kind the list's filter shows or hides (lib/plugins/kinds.dart), not a tab of its own: its conversations stay
  /// in Messages while it is shown and leave it while it is hidden, and the filter can show it alone. Matt,
  /// 2026-11-14: "I'm thinking a filter dropdown where showing spam, political messages, and debt collectors are
  /// filtered out by default".
  final bool filter;

  /// A filter kind hidden from Messages until the person shows it.
  final bool hidden;

  /// Its name among every plugin's sections, and what a conversation is filed under ([PluginHost.move]).
  final String id;

  /// What its chip says.
  final String label;
  final LucideIcon icon;

  /// Whether the conversation belongs here, by its facts, its tags and the plugin's choices. Asked of every
  /// conversation the classifiers have looked at, so it is a few comparisons and nothing more. A conversation the
  /// person filed somewhere themselves is not asked about. Where two sections would take one conversation, the
  /// first has it: sections are asked in the order their plugins are listed.
  final bool Function(MessageFacts facts, TagSet tags, PluginPrefs prefs) takes;

  /// Its conversations leave the main list. False: they are shown in both.
  final bool leavesMain;

  /// How its rows look; null (or answering null) draws them as the main list does.
  final RowLook? Function(MessageFacts facts, TagSet tags, PluginPrefs prefs)? row;
}

// --- (c) places on the screens ---------------------------------------------------------------------------------------

/// A named place on a screen where plugins can put something. [P] is what the screen says about the place.
sealed class Slot<P> {
  const Slot(this.name);
  final String name;
}

/// A place for things to press: the app draws each [PluginAction] as that place draws its own (an icon in a header,
/// a line in a menu).
final class ActionSlot<P> extends Slot<P> {
  const ActionSlot(super.name);

  /// What a plugin puts here: asked each time the place is drawn, with where it is and the plugin's choices.
  SlotFill fill(List<PluginAction> Function(P place, PluginPrefs prefs) actions) => ActionFill<P>._(this, actions);
}

/// A place for widgets of the plugin's own.
final class WidgetSlot<P> extends Slot<P> {
  const WidgetSlot(super.name);

  SlotFill fill(List<Widget> Function(BuildContext context, P place, PluginPrefs prefs) widgets) => WidgetFill<P>._(this, widgets);
}

/// One plugin's contribution to one slot ([ActionSlot.fill], [WidgetSlot.fill]).
sealed class SlotFill {
  const SlotFill();
  Slot<Object?> get slot;
}

/// Buttons for an [ActionSlot], and below it widgets for a [WidgetSlot]: each built when its place is drawn.
final class ActionFill<P> extends SlotFill {
  const ActionFill._(this.slot, this.build);
  @override
  final ActionSlot<P> slot;
  final List<PluginAction> Function(P place, PluginPrefs prefs) build;
}

final class WidgetFill<P> extends SlotFill {
  const WidgetFill._(this.slot, this.build);
  @override
  final WidgetSlot<P> slot;
  final List<Widget> Function(BuildContext context, P place, PluginPrefs prefs) build;
}

/// The list of conversations: the section whose chip is chosen (null: the main list) and how many it shows, how many
/// are in each section and how many of them are unread, and a way to show one section.
@immutable
class ListPlace {
  const ListPlace({this.section, this.shown = 0, this.counts = const {}, this.unread = const {}, this.show, this.conversations = const [], this.groups = const []});
  final String? section;
  final int shown;

  /// How many conversations each section has, by its id.
  final Map<String, int> counts;

  /// The sections with something unread in them.
  final Set<String> unread;

  /// Shows a section (null: the main list); null where the list cannot.
  final void Function(String? section)? show;

  /// The conversations the list shows now, newest first, as facts and their tags.
  final List<ConversationPlace> conversations;

  /// Every conversation that is not archived, by what the list sorted it as: each section (Codes, Spam, each kind
  /// of text) and, last, Personal & other. Given to the header's buttons, for the Cleaner.
  final List<ListGroup> groups;
}

/// The conversations of one section of the list, or of none ([ListGroup.othersId]: Personal & other).
@immutable
class ListGroup {
  const ListGroup({required this.id, required this.label, required this.icon, required this.threads});
  final String id;
  final String label;
  final LucideIcon icon;
  final List<int> threads;

  static const othersId = '*other';
}

/// One conversation: its facts, its tags, and the section it is in (null: the main list).
@immutable
class ConversationPlace {
  const ConversationPlace(this.facts, this.tags, {this.section});
  final MessageFacts facts;
  final TagSet tags;
  final String? section;
}

/// The composer of a conversation: who it writes to, and what is written so far; the newest message from them, where
/// it is the newest of all (no reply yet); whether anyone in it is a contact, and whether it is a group.
@immutable
class ComposerPlace {
  const ComposerPlace({required this.thread, required this.senders, this.text = '', this.lastIn, this.lastOut, this.title = '', this.contact = true, this.group = false, this.count = 0, this.recent = const []});
  final int thread;
  final List<String> senders;
  final String text;
  final String? lastIn;

  /// The newest message where it is the person's own (they wrote last).
  final String? lastOut;

  /// What the conversation is called (its people's names).
  final String title;
  final bool contact;
  final bool group;

  /// How many messages the conversation holds as the screen has them.
  final int count;

  /// The conversation's newest messages with words, oldest first (at most a dozen), for the device's own model to
  /// read (lib/local_ai.dart): the Replies plugin's replies and summaries. Ours alone: a plugin from another developer
  /// is not given them.
  final List<AiLine> recent;
}

/// One message in a conversation.
@immutable
class MessagePlace {
  const MessagePlace(this.facts, this.tags);
  final MessageFacts facts;
  final TagSet tags;
}

/// A plugin's own card on Settings › Plugins.
@immutable
class SettingsPlace {
  const SettingsPlace();
}

/// A space's page, for what a plugin puts in its header ([Slots.spaceHeader]).
@immutable
class SpacePlace {
  const SpacePlace({required this.space, required this.spaceName, this.circle, this.voice = true, this.inCall = false});

  /// The space's seed.
  final String space;
  final String spaceName;

  /// The circle's seed, for a circle's space.
  final String? circle;

  /// It has a call (a voice space), and this device is in that call now.
  final bool voice;
  final bool inCall;
}

/// Someone in a call, as a plugin is shown them.
@immutable
class CallPerson {
  const CallPerson({required this.id, required this.name, this.me = false, this.muted = false});

  /// Their id in the call ('me' for this device).
  final String id;
  final String name;
  final bool me;
  final bool muted;
}

/// A call a space is in: which space and circle, and who is in it (Matt, 2026-11-19, of plugins that integrate with
/// circles: "I'd like to have a "record call" plugin").
@immutable
class CallPlace {
  const CallPlace({required this.space, required this.spaceName, this.circle, this.people = const []});

  /// The space's seed: what the call's rooms come from.
  final String space;
  final String spaceName;

  /// The circle's seed, for a circle's space; null for a space of one's own or a group's call.
  final String? circle;
  final List<CallPerson> people;
}

/// A circle, for its own menu.
@immutable
class CirclePlace {
  const CirclePlace({required this.circle, required this.name, this.canChange = false});
  final String circle;
  final String name;

  /// This device may change the circle (its owner or an admin): may turn its plugins on or off.
  final bool canChange;
}

/// Where a plugin may be on (Matt, 2026-11-19: "Some plugins should be serverside / cirlce side as well").
enum PluginScope {
  /// On this device, by its own switch: what every plugin is.
  device('On this device', 'You add it for yourself'),

  /// On for everyone in a circle, as the circle's owner or an admin says: kept in the circle's signed manifest, so
  /// every member's app does it in that circle's spaces without adding it themselves.
  circle('For a whole circle', 'A circle\'s owner or admins turn it on for everyone in it'),

  /// Run on the relay server as a member of the space, for what no phone can do alone (record while nobody has the
  /// app open, send an event's reminders on time). Such a member holds the space's key, so a space with one is not
  /// end-to-end encrypted against the server: always said where it is on.
  server('On the server', 'Runs on the relay server, which then holds the space\'s key');

  const PluginScope(this.label, this.hint);
  final String label;
  final String hint;
}

/// Every place there is. The ones in the list of conversations and in Settings are drawn (lib/ui/conversations.dart,
/// settings.dart here); the ones in a conversation are defined and wait for lib/ui/thread.dart to ask for them.
abstract final class Slots {
  /// Buttons in the list's header, before New message.
  static const listHeader = ActionSlot<ListPlace>('list.header');

  /// Between the search field and the list.
  static const aboveList = WidgetSlot<ListPlace>('list.above');

  /// Lines in the menu a conversation's long press brings up in the list.
  static const conversationMenu = ActionSlot<ConversationPlace>('list.conversation.menu');

  /// Buttons in a conversation's header, before Call.
  static const conversationHeader = ActionSlot<ConversationPlace>('conversation.header');

  /// Buttons in the composer's row, beside Stickers.
  static const composer = ActionSlot<ComposerPlace>('conversation.composer');

  /// Lines in the menu a message's long press brings up.
  static const messageMenu = ActionSlot<MessagePlace>('conversation.message.menu');

  /// Under a message in a conversation, as wide as its bubble may be: a card for a link it holds, things to do with
  /// what it says (Matt, 2026-11-14: "I also want smart embeds added to expand spotify links, youtube, etc").
  static const underMessage = WidgetSlot<MessagePlace>('conversation.message.under');

  /// Over a conversation's composer, under its newest message: replies to choose from, a word about who wrote.
  static const aboveComposer = WidgetSlot<ComposerPlace>('conversation.composer.above');

  /// Rows in the plugin's own card on Settings › Plugins, after its [GhostPlugin.settings].
  static const settings = WidgetSlot<SettingsPlace>('settings.plugin');

  /// Buttons in a call's menu, beside Invite and Devices: drawn by the call's page (lib/ui/space_designs).
  static const callControls = ActionSlot<CallPlace>('call.controls');

  /// Over a call's page, under its header, whatever its design: a line everyone must see (Recording).
  static const callBanner = WidgetSlot<CallPlace>('call.banner');

  /// Icons in a space's header, beside its settings (Matt, 2026-11-19: "add icons in the compose window or header
  /// depending on what makes sense for plugins like the recording plugin"): what a plugin does to the space or its
  /// call at a glance, a press away rather than in a menu. Keep to one or two; the call's menu has the rest.
  static const spaceHeader = ActionSlot<SpacePlace>('space.header');

  /// Lines in a circle's own menu (lib/ui/circles/circle_screen.dart).
  static const circleMenu = ActionSlot<CirclePlace>('circle.menu');

  static const List<Slot<Object?>> all = [listHeader, aboveList, conversationMenu, conversationHeader, composer, messageMenu, underMessage, aboveComposer, settings, callControls, callBanner, spaceHeader, circleMenu];
}

// --- (d) messages that have just come --------------------------------------------------------------------------------

/// What a plugin asks for when a message has just come.
sealed class IncomingAction {
  const IncomingAction();
}

/// The conversation is muted: what comes in it next arrives without a notification.
final class MuteNotification extends IncomingAction {
  const MuteNotification();
}

/// The conversation is marked as read, and its notification taken away.
final class MarkRead extends IncomingAction {
  const MarkRead();
}

/// The conversation is filed in [section], and stays there.
final class MoveToSection extends IncomingAction {
  const MoveToSection(this.section);
  final String section;
}

/// Asked once for each unread conversation as its newest message is first seen: its facts, its tags, the section it
/// is in (null: the main list) and the plugin's choices. It is decided here, in Dart, while the app is open: see
/// docs/RECORD.md for what Android's side would have to do for it to hold while the app is closed.
typedef IncomingRule = List<IncomingAction> Function(MessageFacts facts, TagSet tags, String? section, PluginPrefs prefs);

// --- (e) what a message's words are shown as -----------------------------------------------------------------------

/// What a plugin shows in place of a message's words (Matt, 2026-11-17: "add a translate plugin which can
/// automatically translate texts when detected from another language and show the original text dimmed in a card with
/// the translated text for the actual message bubble"): [text] in the bubble, and [original], the words as they came,
/// drawn by the app over the bubble, dimmed, in a card of its own headed by [note]. A tap on the card swaps the two
/// for that message; the app keeps which way round each is (shown_store.dart).
@immutable
class ShownText {
  const ShownText({required this.text, this.original, this.note, this.flipNote, this.showOriginal = 'Show original', this.showShown = 'Show translation', this.called = 'translation', this.busy = false, this.again})
      : later = false;

  /// Nothing to show yet, and asked again after [again]: an answer that may change on its own (the phone out of reach,
  /// a computer that has not heard yet what its phone can do, a translator let go mid-way). The words are shown as
  /// they are meanwhile, and the next plugin is asked. Without it such an answer was held as "nothing" for the session.
  const ShownText.later(Duration this.again)
      : text = '',
        original = null,
        note = null,
        flipNote = null,
        showOriginal = 'Show original',
        showShown = 'Show translation',
        called = 'translation',
        busy = false,
        later = true;

  /// What the bubble says.
  final String text;

  /// The words as they came, for the card; null for a card of [note] alone (still at work, [busy]).
  final String? original;

  /// The card's quiet heading: "Translated from Spanish", "Getting Spanish ready…".
  final String? note;

  /// The heading while the two are swapped ("Spanish, as sent"); [note] where null.
  final String? flipNote;

  /// What the word that swaps them says, each way round.
  final String showOriginal;
  final String showShown;

  /// What the plugin's words are called, where a line says what it holds (Dial-Up's transcript: "(translation)").
  final String called;

  /// Still at work: the card wears a small spinner by [note], and nothing can be swapped yet.
  final bool busy;

  /// Asked again after this long (a language being fetched); null: it holds until the words or the choices change.
  final Duration? again;

  /// [ShownText.later]: nothing shown, asked again after [again].
  final bool later;

  /// The same as plain values.
  Map<String, Object?> toJson() => {'text': text, 'original': original, 'note': note, 'busy': busy};

  bool same(ShownText? o) => o != null && o.text == text && o.original == original && o.note == note && o.flipNote == flipNote && o.busy == busy;
}

/// What the device said of a text it was asked to translate ([TextHost.translate]): [state] is 'done' (with [text]
/// and [from]), 'same' (already in a language the person reads), 'und' (not sure which), 'unsupported', 'fetching' (the
/// language's model is coming), 'waiting-wifi' (it waits for Wi-Fi), 'needs-model', 'unavailable' (no translation on
/// this device, or a paired phone too old to do it), 'offline' (the phone is out of reach) or 'failed'.
@immutable
class DeviceTranslation {
  const DeviceTranslation(this.state, {this.text, this.from});
  final String state;
  final String? text;

  /// The language it was in, as its base subtag ("es").
  final String? from;

  factory DeviceTranslation.from(Map? m) => m == null ? const DeviceTranslation('failed') : DeviceTranslation('${m['state'] ?? 'failed'}', text: m['text'] as String?, from: m['from'] as String?);
}

/// A language the device can translate, and whether its model is here.
@immutable
class DeviceLanguage {
  const DeviceLanguage(this.tag, {this.downloaded = false, this.fetching = false});
  final String tag;
  final bool downloaded;
  final bool fetching;
}

/// What a text rule may ask of the app: the language the person reads and the device's own translation, never a screen.
abstract interface class TextHost {
  /// The language the person reads, as its base subtag ("en"): the phone's (or the computer's) own.
  String get language;

  /// Whether this device can translate at all (an iPhone on its own cannot yet).
  bool get canTranslate;

  /// [text] in [to], unless it is in [to] or one of [known] already. [fetch] fetches a language's model where it is
  /// not here yet (on Wi-Fi alone where [wifiOnly]); nothing waits for it.
  Future<DeviceTranslation> translate(String text, {required String to, List<String> known = const [], bool fetch = true, bool wifiOnly = true});

  /// Every language the device has a model for, or could fetch.
  Future<List<DeviceLanguage>> languages();

  /// Fetches a language's model ([delete] false) or deletes it to give the room back.
  Future<bool> model(String tag, {bool delete = false, bool wifiOnly = true});
}

/// Asked for a message's words as they stand, once (and kept by the app until the words or the plugin's choices
/// change, or until [ShownText.again]). Null: shown as they are. Never asked of the person's own messages, nor of a
/// message being sent, a notice or one that could not be opened.
typedef TextRule = Future<ShownText?> Function(MessageFacts facts, PluginPrefs prefs, TextHost host);

// --- a plugin's own settings -----------------------------------------------------------------------------------------

/// One row of a plugin's card on Settings › Plugins, said in words: a switch kept in the plugin's choices, or a line
/// that explains. Anything else is a widget in [Slots.settings].
@immutable
class PluginSetting {
  /// A switch, kept under [key] in the plugin's choices.
  const PluginSetting.toggle({required String this.key, required this.label, this.hint, this.fallback = true, this.icon})
      : options = const [],
        choice = null,
        words = false,
        placeholder = null,
        heading = false;

  /// A line that says something and changes nothing.
  const PluginSetting.note({required this.label, this.hint, this.icon})
      : key = null,
        fallback = false,
        options = const [],
        choice = null,
        words = false,
        placeholder = null,
        heading = false;

  /// One of a few values, kept under [key]: a row for each, the chosen one marked ([choice] until one is chosen).
  const PluginSetting.choice({required String this.key, required this.label, this.hint, this.icon, required this.options, required String this.choice})
      : fallback = false,
        words = false,
        placeholder = null,
        heading = false;

  /// Words, phrases or addresses typed in a field, kept under [key] a line each ([wordsOf]).
  const PluginSetting.words({required String this.key, required this.label, this.hint, this.icon, this.placeholder})
      : fallback = false,
        options = const [],
        choice = null,
        words = true,
        heading = false;

  /// A heading that starts a card of its own: the rows after it, to the next heading, are under it.
  const PluginSetting.heading({required this.label, this.hint})
      : key = null,
        icon = null,
        fallback = false,
        options = const [],
        choice = null,
        words = false,
        placeholder = null,
        heading = true;

  final String? key;
  final String label;
  final String? hint;
  final bool fallback;
  final LucideIcon? icon;

  /// A choice's values and what each is called and does.
  final List<SettingOption> options;

  /// A choice's value until the person picks one.
  final String? choice;

  /// A field of words ([PluginSetting.words]).
  final bool words;
  final String? placeholder;
  final bool heading;

  /// A switch ([PluginSetting.toggle]).
  bool get toggle => key != null && options.isEmpty && !words;
}

/// One value of a [PluginSetting.choice].
@immutable
class SettingOption {
  const SettingOption(this.value, this.label, [this.hint]);
  final String value;
  final String label;
  final String? hint;
}

/// A section of its own in Settings for a plugin (Matt, 2026-11-14: "the plugins and all being able to make their
/// own setting sections"), for one with more to set than a card on Settings › Plugins is the place for. While the
/// plugin is on it is a row in Settings' list, under Plugins, that opens a page of the plugin's [GhostPlugin.settings]
/// and of what it puts in [Slots.settings]; its card on Settings › Plugins gives way to it.
@immutable
class PluginSettingsPage {
  const PluginSettingsPage({this.label, this.hue = 'rose', this.summary, this.intro});

  /// What the row and its page are called; the plugin's name where not given.
  final String? label;

  /// Its colour, by the names Settings' own sections use (amber, blue, coral, cyan, green, indigo, lime, magenta,
  /// mint, orange, purple, red, rose, slate, yellow, graphite).
  final String hue;

  /// The row's second line, from the plugin's choices as they stand.
  final String Function(PluginPrefs prefs)? summary;

  /// A line at the head of its page.
  final String? intro;
}

// --- how the Plugins page shows a plugin -----------------------------------------------------------------------------

/// The shelf a plugin stands on in the Plugins page (lib/ui/plugins_page/; Matt, 2026-11-17: "redo how the plugins
/// look with their own dedicated plugins page with a marketplace like look how ghostmd has"): the chips over its
/// cards. A shelf with no plugin on it has no chip.
enum PluginShelf {
  organise('Organise'),
  safety('Safety'),
  messages('Messages'),
  tools('Tools'),

  /// The other networks, each a plugin (lib/plugins/networks.dart).
  networks('Networks');

  const PluginShelf(this.label);
  final String label;
}

/// One line of what a plugin reads, keeps or sends, for its page's privacy card: "Your texts, read on this phone".
@immutable
class PluginReach {
  const PluginReach(this.icon, this.label, [this.hint]);
  final LucideIcon icon;
  final String label;
  final String? hint;
}

// --- the plugin ------------------------------------------------------------------------------------------------------

/// A plugin. The ones the app ships with are compiled in and listed in registry.dart.
/// How a plugin's note in a space's chat is drawn (Matt, 2026-11-19: "allow plugins to render messages like these as
/// cards with iconography and details"): its icon on its colour, a title, a line under it, and facts in a row.
@immutable
class PluginChatCard {
  const PluginChatCard({required this.icon, required this.title, this.detail = '', this.facts = const [], this.hue, this.alert = false});
  final LucideIcon icon;

  /// "Maya started recording".
  final String title;

  /// A line under it: "Only the voices of people who say yes are in it."
  final String detail;

  /// Short facts, each an icon and words: (clock, "12 min"), (users, "3 voices").
  final List<(LucideIcon, String)> facts;

  /// Its colour among Settings' hues; the plugin's own where null.
  final String? hue;

  /// Something going on now (a recording): its icon on red.
  final bool alert;
}

/// Where a plugin comes from, for the Marketplace's source line and badge (Matt, 2026-11-20: "I would like users to be
/// able to develop and submit their own plugins to our plugin marketplace").
enum PluginSource {
  /// Compiled into the app (shippedPlugins).
  builtIn,

  /// A pack from the Marketplace whose review signature this build checked (lib/plugins/pack/review.dart).
  reviewed,

  /// A pack loaded in Settings › Developer: not reviewed, and on only while developer mode is.
  dev,
}

/// A plugin whose switch is kept somewhere of its own, not under `plugin_<id>`: a network's, which Settings ›
/// Connections shows too (lib/plugins/networks.dart). [PluginRegistry.isOn] and [PluginRegistry.setOn] ask it.
abstract interface class OwnSwitch {
  bool get on;

  /// Switches it; done once what that takes is (a network signed out).
  Future<void> turn(bool on);
}

abstract class GhostPlugin {
  const GhostPlugin();

  /// [note], something this plugin said in a space's chat (lib/voice/plugin_note.dart), as a card; null to show its
  /// words as any message's are. [mine]: this device said it.
  PluginChatCard? card(PluginChatNote note, {required bool mine}) => null;

  /// Its name in the person's choices (`plugin_<id>`) and nowhere on the screen: lower-case letters and digits.
  String get id;

  /// What Settings › Plugins calls it.
  String get name;

  /// One line saying what it does.
  String get description;

  LucideIcon get icon => Lucide.puzzle;

  /// Whether it is on until the person says otherwise. One that hides messages should be chosen: off.
  bool get onByDefault => true;

  List<Classifier> get classifiers => const [];

  /// Classifiers told the plugin's own choices ([TunedClassifier]).
  List<TunedClassifier> get tuned => const [];
  List<ListSection> get sections => const [];
  List<SlotFill> get slots => const [];
  List<IncomingRule> get incoming => const [];
  List<PluginSetting> get settings => const [];

  /// What it shows in place of a message's words ([TextRule]): the first plugin to answer has the bubble.
  List<TextRule> get text => const [];

  /// A section of its own in Settings for those, in place of a card on Settings › Plugins; null for none.
  PluginSettingsPage? get settingsPage => null;

  // What the Plugins page shows of it (lib/ui/plugins_page/; Matt, 2026-11-17: "redo how the plugins look with their
  // own dedicated plugins page with a marketplace like look how ghostmd has"). Each has a plain default, so a plugin
  // that says nothing of these still has a card.

  /// Its colour on its tile, its card and its page, by the names Settings' sections use ([PluginSettingsPage.hue]):
  /// its own page's in Settings where it has one, so the two are one colour.
  String get hue => settingsPage?.hue ?? 'rose';

  /// The shelf it stands on.
  PluginShelf get shelf => PluginShelf.tools;

  /// The short line on its card, a few words; [description] where it says none.
  String get tagline => description;

  /// Its line on a featured card, which must be whole in three short lines: [tagline] where it says none.
  String get pitch => tagline;

  /// What it puts in the app once it is added, a line each: "A Codes tab in the list".
  List<String> get adds => const [];

  /// What it reads, keeps or sends, a line each, for the card on its page that says so. None: the page says it
  /// works on what is on the screen and sends nothing.
  List<PluginReach> get reaches => const [];

  /// Where it may be on ([PluginScope]): this device alone unless it says more. One that names [PluginScope.circle] is
  /// listed in Circle settings › Plugins, and in a circle's spaces is on as the circle says, not as this device's switch.
  Set<PluginScope> get scopes => const {PluginScope.device};

  // Where it comes from, and what the Marketplace shows of a plugin another developer made (lib/plugins/pack). The
  // app's own say nothing of these but their labels.

  /// Where it comes from.
  PluginSource get source => PluginSource.builtIn;

  /// The developer's username, without "@", for a pack; null for the app's own.
  String? get developer => null;

  /// Its version, for a pack ("1.2.0"); null for the app's own.
  String? get version => null;

  /// A square PNG to draw in place of [icon] on its tile, card and page; null draws [icon].
  Uint8List? get iconPng => null;

  /// Its store tags, from the label vocabulary (lib/plugins/pack/format.dart packLabels).
  List<String> get labels => const [];
}
