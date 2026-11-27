/// What the name watch found, in words (lib/net/name_watch.dart): on a friend's card, in Settings › Routes, and said at
/// once from the app's frame. Calm, in the screens' own ink: almost always the reason is an ordinary one, and the words
/// name it (the review, 2026-11-23, M1 and M2).
library;

import '../net/name_watch.dart';

/// A friend's username now names another account on the relay: on their card, whole.
String friendNameChangedWords(String username, String who) => '${friendNameChangedLabel(username)}. ${friendNameChangedHint(who)}';

/// The same, as a row's label and its line under it.
String friendNameChangedLabel(String username) => '@$username now belongs to another account on the relay';
String friendNameChangedHint(String who) {
  final first = who.startsWith('@') ? who : who.split(' ').first;
  return 'If $first changed or gave up their username, that\'s why. You\'re still talking to the $who you added.';
}

/// This person's own username, as the relay in use answers for it (a [NameChange] of one of the own kinds).
String ownNameWords(NameChange c) => switch (c.kind) {
      NameKind.old => '@${c.username} is still held by this device\'s old key',
      NameKind.contradicts => 'The relay says @${c.username} is yours, yet gives it to another account when others ask',
      _ => '@${c.username} now belongs to another account on this relay',
    };

/// The line under [ownNameWords]: the ordinary reason for each kind, and what can be done.
String ownNameHint(NameChange c) => switch (c.kind) {
      NameKind.old => 'It stays with the key this device had before you made a new one, and can\'t be moved to this key. To have a username on this key, choose one in Profile.',
      NameKind.changed => 'Your key holds a different username on this relay now: you may have changed it on another of your devices.',
      NameKind.contradicts => 'Nothing you did causes that. Friends who add you by your add-me link get your key whatever the relay says.',
      _ => 'That happens when you gave it up or changed it on another of your devices, made a new key, or use another relay.',
    };

/// A friend's app saw the relay give this person's username to another account.
String toldWords(String who, String username) => '$who\'s app saw the relay give your username @$username to another account';
const toldHint = 'If you changed or gave it up, or made a new key, that\'s why.';

/// What is said at once, from the app's frame, of a [NameChange] about this person's own username; [who] is the friend
/// whose app saw it, for one told.
String nameNoticeWords(NameChange c, {String? who}) => c.kind == NameKind.told
    ? '${toldWords(who ?? 'A friend', c.username)}. Settings › Routes says why that can happen.'
    : '${ownNameWords(c)}. Settings › Routes says more.';
