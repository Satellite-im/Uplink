import 'dart:async';

import 'package:flutter/services.dart';

import 'sms.dart';

/// One text of a conversation as the device's model reads it: the person's own or not, whose, the words, when.
typedef AiLine = ({bool mine, String who, String text, int at});

/// The small language model this device has of its own, for replies to choose from and summaries (Matt, 2026-11-26:
/// "add more intelligent auto replies using a very lightweight local AI that summarizes text and whatnot"). Nothing
/// is downloaded by us and nothing leaves the device:
///
/// - On an Android phone, replies by ML Kit's Smart Reply (android/.../SmartReplies.kt: a few megabytes inside the
///   app, on every phone, English only) and summaries by Gemini Nano where the phone has it (Summaries.kt).
/// - On a Mac or an iPhone, both by Apple Intelligence's own model (macos/Runner/LocalAi.swift, macOS and iOS 26 on,
///   where Apple Intelligence is on).
/// - Elsewhere (Windows, Linux, a browser, a device without one) nothing: [replies] and [summarize] answer null and
///   lib/plugins/replies.dart keeps to its own replies, worked out from the words.
///
/// Answers are kept by what was asked, so a conversation drawn again asks once.
class LocalAi {
  LocalAi._();
  static final LocalAi instance = LocalAi._();

  /// Stands in for the device in tests: each call by its method name and arguments.
  static Future<Object?> Function(String method, Map<String, Object?> args)? debugCalls;

  static const _apple = MethodChannel('ghost/local_ai');

  /// Null until asked; false where this device has no model to ask (so it is not asked again).
  bool? _here;

  final Map<String, Future<List<String>?>> _replies = {};
  final Map<String, Future<String?>> _summaries = {};
  static const _kept = 200;

  Future<Object?> _call(String method, Map<String, Object?> args) async {
    final test = debugCalls;
    if (test != null) return test(method, args);
    if (!Sms.remote) {
      // The Android phone's own channel.
      return switch (method) {
        'replies' => Sms.instance.smartReplies(args['messages'] as List),
        'summarize' => Sms.instance.summarize(args['text'] as String),
        _ => Sms.instance.summaryStatus(),
      };
    }
    if (_here == false) return null;
    try {
      final r = await _apple.invokeMethod<Object?>(method, args);
      _here = true;
      return r;
    } on MissingPluginException {
      _here = false;
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Where the model for summaries stands here: "available", "downloading", "downloadable" or "unavailable".
  Future<String> status() async => (await _call('status', const {})) as String? ?? 'unavailable';

  /// Up to three replies to the newest of [lines] (oldest first) by the device's model, or null where it has none:
  /// no model here, the newest is the person's own, a language it doesn't read, nothing that fits.
  Future<List<String>?> replies(List<AiLine> lines) {
    final talk = [for (final l in lines.length > 12 ? lines.sublist(lines.length - 12) : lines) if (l.text.trim().isNotEmpty) l];
    if (talk.isEmpty || talk.last.mine) return Future.value(null);
    final key = [for (final l in talk) '${l.mine ? 1 : 0}${l.who}\u0001${l.text}'].join('\u0000');
    return _keep(_replies, key, () async {
      final r = await _call('replies', {
        'messages': [for (final l in talk) {'mine': l.mine, 'who': l.who, 'text': l.text, 'at': l.at}],
      });
      final list = [for (final s in (r as List?) ?? const []) if (s is String && s.trim().isNotEmpty) s.trim()];
      return list.isEmpty ? null : list.take(3).toList();
    });
  }

  /// One sentence on what [text] says, by the device's model: a conversation's lines (`<name>: <words>`, [message]
  /// false) or one long message. Null where it can't say.
  Future<String?> summarize(String text, {bool message = false}) {
    if (text.trim().isEmpty) return Future.value(null);
    return _keep(_summaries, '${message ? 'm' : 'c'}$text', () async {
      final r = await _call('summarize', {'text': text, 'kind': message ? 'message' : 'conversation'});
      final s = (r as String?)?.trim();
      return s == null || s.isEmpty ? null : s;
    });
  }

  /// [make]'s answer kept under [key]; a failed one is dropped so it can be asked again.
  Future<T?> _keep<T>(Map<String, Future<T?>> kept, String key, Future<T?> Function() make) {
    final had = kept[key];
    if (had != null) return had;
    final f = make().catchError((Object _) => null);
    kept[key] = f;
    while (kept.length > _kept) {
      kept.remove(kept.keys.first);
    }
    return f;
  }

  /// Forgets what was kept, for tests.
  void debugReset() {
    _replies.clear();
    _summaries.clear();
    _here = null;
  }
}
