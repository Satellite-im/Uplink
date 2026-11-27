/// Things to do with what a message says, as small buttons under it (Matt, 2026-11-14, of the ideas to streamline
/// someone's day: "Turn texts into actions: a time becomes Add to calendar, an address Open in Maps, a tracking number
/// a live status, a code is copied", and "let's add all of the additional ones to a plugins"). A date or a time
/// becomes Add to calendar, with the day filled in; a street address, Open in Maps; a tracking number, Track, at its
/// carrier; a phone number written in the words, Call; a sign-in code, Copy. Everything is found on the phone, in the
/// words alone; the calendar and the map are Android's own, opened with the details for the person to save.
library;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../art/app_icon.dart';
import '../art/lucide.g.dart';
import '../art/lucide_more.dart';
import '../kit/settings_type.dart';
import '../sms.dart';
import '../ui/common.dart';
import 'codes.dart';
import 'plugin.dart';

/// One thing to do with a message.
@immutable
class MessageAction {
  const MessageAction(this.kind, this.label, this.value, {this.at, this.allDay = false});

  /// `event`, `map`, `track`, `call` or `code`.
  final String kind;

  /// What its button says: "Fri 7:00 PM", "Open in Maps".
  final String label;

  /// What it acts on: the address, the tracking link, the number, the code; the words for an event.
  final String value;
  final DateTime? at;
  final bool allDay;
}

const _months = ['jan', 'feb', 'mar', 'apr', 'may', 'jun', 'jul', 'aug', 'sep', 'oct', 'nov', 'dec'];
const _days = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];

/// The first day and time [text] speaks of, from [now]: "tomorrow at 9:30am", "Friday at 7", "Nov 20", "11/5 3pm",
/// "tonight at 8", "7:30 pm". A time alone needs am or pm, or "at"; a day alone is all day. Null where none is said.
({DateTime at, bool allDay})? whenIn(String text, DateTime now) {
  final s = text.toLowerCase();
  DateTime? day;
  // The day.
  final rel = RegExp(r'(?<![a-z])(today|tonight|tomorrow|tmrw|tmr)(?![a-z])').firstMatch(s);
  final wk = RegExp(r'(?<![a-z])(?:this |next |on )?(mon|tue|wed|thu|fri|sat|sun)[a-z]*\.?(?![a-z])').firstMatch(s);
  final md = RegExp(r'(?<![a-z])(jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\.? (\d{1,2})(?:st|nd|rd|th)?(?![\d])').firstMatch(s);
  final slash = RegExp(r'(?<![\d/])(\d{1,2})/(\d{1,2})(?:/(\d{2,4}))?(?![\d/])').firstMatch(s);
  final today = DateTime(now.year, now.month, now.day);
  if (rel != null) {
    day = rel.group(1)!.startsWith('t') && (rel.group(1) == 'today' || rel.group(1) == 'tonight') ? today : today.add(const Duration(days: 1));
  } else if (md != null) {
    final m = _months.indexOf(md.group(1)!.substring(0, 3)) + 1;
    final d = int.parse(md.group(2)!);
    if (d >= 1 && d <= 31) {
      day = DateTime(now.year, m, d);
      if (day.isBefore(today.subtract(const Duration(days: 7)))) day = DateTime(now.year + 1, m, d);
    }
  } else if (slash != null) {
    final m = int.parse(slash.group(1)!), d = int.parse(slash.group(2)!);
    if (m >= 1 && m <= 12 && d >= 1 && d <= 31) {
      final y = slash.group(3) == null ? now.year : (int.parse(slash.group(3)!) % 100) + 2000;
      day = DateTime(y, m, d);
      if (slash.group(3) == null && day.isBefore(today.subtract(const Duration(days: 7)))) day = DateTime(now.year + 1, m, d);
    }
  } else if (wk != null) {
    final want = _days.indexOf(wk.group(1)!) + 1;
    var ahead = (want - now.weekday) % 7;
    if (ahead == 0 || (wk.group(0)!.startsWith('next'))) ahead = ahead == 0 ? 7 : ahead;
    day = today.add(Duration(days: ahead));
  }
  // The time.
  int? hour, minute;
  final ampm = RegExp(r'(?<![\d:])(\d{1,2})(?::(\d{2}))? ?(am|pm|a\.m\.|p\.m\.)(?![a-z])').firstMatch(s);
  final at = RegExp(r'(?<![a-z])(?:at|@) (\d{1,2})(?::(\d{2}))?(?![\d:/])').firstMatch(s);
  final clock24 = RegExp(r'(?<![\d:])([01]?\d|2[0-3]):([0-5]\d)(?![\d:])').firstMatch(s);
  if (ampm != null) {
    hour = int.parse(ampm.group(1)!) % 12 + (ampm.group(3)!.startsWith('p') ? 12 : 0);
    minute = int.parse(ampm.group(2) ?? '0');
  } else if (at != null) {
    final h = int.parse(at.group(1)!);
    if (h >= 1 && h <= 12) {
      // "at 7" is the evening's seven, as is anything up to then; eight to eleven are the morning's unless the words
      // speak of the evening.
      final evening = rel?.group(1) == 'tonight' || RegExp(r'(?<![a-z])(?:tonight|evening|dinner|night|drinks|pm)(?![a-z])').hasMatch(s);
      hour = h < 8 || evening ? h % 12 + 12 : h;
      minute = int.parse(at.group(2) ?? '0');
    }
  } else if (clock24 != null && (day != null)) {
    hour = int.parse(clock24.group(1)!);
    minute = int.parse(clock24.group(2)!);
  }
  if (minute != null && minute > 59) return null;
  if (day == null && hour == null) return null;
  if (hour == null) return (at: day!, allDay: true);
  var when = DateTime((day ?? today).year, (day ?? today).month, (day ?? today).day, hour, minute ?? 0);
  // A time alone that has gone today is tomorrow's.
  if (day == null && when.isBefore(now)) when = when.add(const Duration(days: 1));
  return (at: when, allDay: false);
}

/// The first street address [text] gives: "1647 Winston Ct", "3916 Shakespeare Dr, Hickory NC".
String? addressIn(String text) {
  final m = RegExp(
    r'(?<![\w#])(\d{1,6} (?:[NSEW]\.? )?(?:[A-Za-z0-9.]+ ){0,4}(?:St|Street|Ave|Avenue|Rd|Road|Dr|Drive|Ln|Lane|Blvd|Boulevard|Ct|Court|Way|Pl|Place|Pkwy|Parkway|Hwy|Highway|Cir|Circle|Ter|Terrace|Trl|Trail)\.?)(?:,? (?:(?:Apt|Suite|Ste|Unit|#) ?[\w-]+,? )?([A-Z][a-zA-Z]+(?: [A-Z][a-zA-Z]+)?),? ?([A-Z]{2})?(?: (\d{5}))?)?(?![\w])',
  ).firstMatch(text);
  if (m == null) return null;
  return m.group(0)!.trim().replaceAll(RegExp(r'[,.]$'), '');
}

/// A tracking link for the first parcel number [text] gives: UPS's 1Z…, USPS's long numbers, FedEx's where the text
/// says FedEx.
({String carrier, String url})? trackingIn(String text) {
  final ups = RegExp(r'(?<![A-Z0-9])1Z[0-9A-Z]{16}(?![A-Z0-9])', caseSensitive: false).firstMatch(text);
  if (ups != null) return (carrier: 'UPS', url: 'https://www.ups.com/track?tracknum=${ups.group(0)!.toUpperCase()}');
  final usps = RegExp(r'(?<!\d)9[2-5]\d{18,24}(?!\d)').firstMatch(text.replaceAll(' ', ''));
  if (usps != null) return (carrier: 'USPS', url: 'https://tools.usps.com/go/TrackConfirmAction?tLabels=${usps.group(0)}');
  if (RegExp(r'fedex', caseSensitive: false).hasMatch(text)) {
    final fx = RegExp(r'(?<!\d)(\d{12}|\d{15}|\d{20})(?!\d)').firstMatch(text);
    if (fx != null) return (carrier: 'FedEx', url: 'https://www.fedex.com/fedextrack/?trknbr=${fx.group(1)}');
  }
  return null;
}

/// A phone number written in [text] (not the sender's own).
String? numberIn(String text) {
  final m = RegExp(r'(?<![\w/])(?:\+?1[ .-]?)?\(?(\d{3})\)?[ .-]?(\d{3})[ .-](\d{4})(?![\w/])').firstMatch(text);
  return m?.group(0)?.trim();
}

/// A time as a chip says it, on a twelve-hour clock: "3 PM", "3:30 PM".
String _clock(DateTime d) {
  final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
  return d.minute == 0 ? '$h ${d.hour < 12 ? 'AM' : 'PM'}' : '$h:${d.minute.toString().padLeft(2, '0')} ${d.hour < 12 ? 'AM' : 'PM'}';
}

const _week = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _mon = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// A day as a button says it: "Today 7 PM", "Fri 7 PM", "Nov 20".
String whenLabel(DateTime at, bool allDay, DateTime now) {
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(at.year, at.month, at.day);
  final diff = day.difference(today).inDays;
  final d = diff == 0 ? 'Today' : diff == 1 ? 'Tomorrow' : diff > 1 && diff < 7 ? _week[at.weekday - 1] : '${_mon[at.month - 1]} ${at.day}';
  return allDay ? d : '$d ${_clock(at)}';
}

/// The things to do with [text], in the order their buttons stand.
List<MessageAction> actionsIn(String text, DateTime now, {bool fromContact = true}) {
  final out = <MessageAction>[];
  final code = signInCode(text);
  if (code != null) out.add(MessageAction('code', 'Copy $code', code));
  final track = trackingIn(text);
  if (track != null) out.add(MessageAction('track', 'Track ${track.carrier}', track.url));
  final when = whenIn(text, now);
  // Today with no time ("tonight", "today") is no day worth a calendar entry.
  final vague = when != null && when.allDay && DateTime(when.at.year, when.at.month, when.at.day) == DateTime(now.year, now.month, now.day);
  if (when != null && code == null && !vague) out.add(MessageAction('event', whenLabel(when.at, when.allDay, now), text, at: when.at, allDay: when.allDay));
  final place = addressIn(text);
  if (place != null) out.add(MessageAction('map', 'Open in Maps', place));
  final number = numberIn(text);
  if (number != null && code == null && track == null) out.add(MessageAction('call', 'Call $number', number));
  return out;
}

class ActionsPlugin extends GhostPlugin {
  const ActionsPlugin({this.now});

  /// The clock (a test's).
  final DateTime Function()? now;

  @override
  String get id => 'actions';

  @override
  String get name => 'Quick actions';

  @override
  String get description => 'A date, an address, a tracking number or a phone number in a message gets a button: Add to calendar, Open in Maps, Track, Call.';

  @override
  LucideIcon get icon => Lucide.sparkles;

  // Its card and page on the Plugins page (Matt, 2026-11-17: "redo how the plugins look with their own dedicated plugins page
  // with a marketplace like look how ghostmd has").
  @override
  PluginShelf get shelf => PluginShelf.messages;

  @override
  String get tagline => 'A button under a message for a date, an address or a number in it.';

  @override
  List<String> get adds => const ['Add to calendar, for a day or a time', 'Open in Maps, for a street address', 'Track, for a tracking number', 'Call and Copy, for a phone number or a code'];

  @override
  List<PluginReach> get reaches => const [PluginReach(Lucide.messageSquare, 'The words of the message on the screen', 'Found on this phone. Nothing is sent anywhere.')];

  @override
  List<SlotFill> get slots => [
        Slots.underMessage.fill((context, place, prefs) {
          final found = actionsIn(place.facts.text, (now ?? DateTime.now)());
          // A computer has no calendar or map of the phone's: what it can do is copy and open links.
          final here = Sms.remote ? found.where((a) => a.kind == 'code' || a.kind == 'track').toList() : found;
          return here.isEmpty ? const [] : [ActionChips(actions: here)];
        }),
      ];

  @override
  PluginSettingsPage? get settingsPage => PluginSettingsPage(hue: 'cyan', intro: 'Buttons under a message for what it says.', summary: (prefs) => 'Calendar, Maps, tracking, calls');

  @override
  List<PluginSetting> get settings => const [
        PluginSetting.note(label: 'Add to calendar', hint: 'A day or a time: "Friday at 7", "tomorrow 9:30am", "Nov 20". The calendar opens with it filled in.', icon: Lucide.calendarDays),
        PluginSetting.note(label: 'Open in Maps', hint: 'A street address.', icon: LucideMore.target),
        PluginSetting.note(label: 'Track', hint: 'A UPS, USPS or FedEx tracking number: the carrier\'s page for it.', icon: LucideMore.package),
        PluginSetting.note(label: 'Call, Copy', hint: 'A phone number written in the words; a sign-in code.', icon: Lucide.phone),
        PluginSetting.note(label: 'On this phone only', hint: 'Found in the message\'s words, on the phone. Nothing is sent anywhere.', icon: Lucide.lock),
      ];
}

/// The buttons under a message.
class ActionChips extends StatelessWidget {
  const ActionChips({super.key, required this.actions});
  final List<MessageAction> actions;

  static LucideIcon _icon(String kind) => switch (kind) {
        'event' => Lucide.calendarPlus,
        'map' => LucideMore.target,
        'track' => LucideMore.package,
        'call' => Lucide.phone,
        _ => Lucide.copy,
      };

  /// A chip pressed: a code is copied; a parcel, a place, a number or a date is handed to the phone's own app for it.
  Future<void> _run(BuildContext context, MessageAction a) async {
    switch (a.kind) {
      case 'code':
        await Clipboard.setData(ClipboardData(text: a.value));
        if (context.mounted) toast(context, 'Copied ${a.value}');
      case 'track':
        await Sms.instance.openLink(a.value);
      case 'map':
        if (!await Sms.instance.openMap(a.value) && context.mounted) toast(context, 'No map app to open it');
      case 'call':
        await Sms.instance.dial(a.value);
      case 'event':
        final title = a.value.replaceAll('\n', ' ').trim();
        final ok = await Sms.instance.addEvent(title: title.length > 60 ? '${title.substring(0, 60)}…' : title, begin: a.at!, allDay: a.allDay, notes: a.value);
        if (!ok && context.mounted) toast(context, 'No calendar app to add it to');
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Wrap(spacing: t.space(2), runSpacing: t.space(1), children: [
      for (final a in actions)
        GlacierPressable(
          onPressed: () => _run(context, a),
          semanticLabel: a.kind == 'event' ? 'Add to calendar, ${a.label}' : a.label,
          builder: (context, state) => Container(
            padding: EdgeInsets.symmetric(horizontal: t.space(3), vertical: t.space(1) + 2),
            decoration: BoxDecoration(
              color: t.color(state.pressed ? 'app-paper-3' : 'app-paper-2'),
              borderRadius: BorderRadius.circular(t.radius('full')),
              border: Border.all(color: t.color('app-rule')),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              AppIcon(_icon(a.kind), size: 14, strokeWidth: 2.2, wash: false, color: t.color('app-ink-2')),
              SizedBox(width: t.space(1) + 2),
              Text(a.label, style: pageText(t, t.fontSize('xs'), weight: 'semibold', color: t.color('app-ink'))),
            ]),
          ),
        ),
    ]);
  }
}
