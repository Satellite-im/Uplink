// An Uplink account's screens drawn in every look (test/themes_test.dart): making one (the password, the words to write
// down, checking them), signing in (username and password, the texted code, the recovery words) and the devices signed
// in. Matt, 2026-11-17: "We need to have a way to login to existing accounts. We might need to add password based
// authentication as well as SMS verification for verified numbers"; "i also want accounts to be generated based on
// ethereum type addresses with a recovery seed we can back up".
import 'package:flutter/widgets.dart' show Size;
import 'package:ghost_messaging/account/account.dart';
import 'package:ghost_messaging/account/account_crypto.dart';
import 'package:ghost_messaging/ui/account_screens.dart';
import 'package:ghost_messaging/ui/settings.dart' show SettingsSectionScreen;

import 'themes_test.dart' show ThemeScreen;

// Made from fixed bytes, so every picture shows the same twelve words (and a valid checksum).
final _words = AccountCrypto.wordsOf(List.generate(16, (i) => (i * 37 + 11) & 0xff));
final _draft = AccountDraft(_words, '0x9858EfFD232B4033E47d90003D41EC34EcaEda94');

const _devices = [
  AccountDevice(id: 'a', name: 'Android phone · Fold', platform: 'android', since: '2026-11-17', seen: '2026-11-17', here: true),
  AccountDevice(id: 'b', name: 'Mac · studio', platform: 'macos', since: '2026-11-17', seen: '2026-11-16'),
  AccountDevice(id: 'c', name: 'iPhone', platform: 'ios', since: '2026-11-12', seen: '2026-11-12'),
];

final accountThemeScreens = <ThemeScreen>[
  ThemeScreen('account-create', () => CreateAccountScreen(draft: _draft)),
  ThemeScreen('account-words', () => CreateAccountScreen(draft: _draft, step: CreateStep.words)),
  ThemeScreen('account-confirm', () => CreateAccountScreen(draft: _draft, step: CreateStep.confirm)),
  ThemeScreen('account-confirm-typed', () => CreateAccountScreen(draft: _draft, step: CreateStep.confirm, typed: true)),
  ThemeScreen('account-done', () => CreateAccountScreen(draft: _draft, step: CreateStep.done)),
  ThemeScreen('account-signin', () => const SignInScreen()),
  ThemeScreen('account-signin-code', () => const SignInScreen(needsCode: true)),
  ThemeScreen('account-signin-words', () => const SignInScreen(words: true)),
  ThemeScreen('account-show-words', () => ShowWordsScreen(words: _words)),
  ThemeScreen('account-devices', () => const DevicesScreen(devices: _devices)),
  // Settings › Me with no account (the two ways in) and signed in to one (its address, with a copy button).
  ThemeScreen('account-me', () => const SettingsSectionScreen('me'), size: const Size(412, 1500)),
  ThemeScreen('account-me-signed-in', () => const SettingsSectionScreen('me'), size: const Size(412, 1500), before: () => Account.instance.store.set('acct_address', _draft.address), after: () => Account.instance.store.set('acct_address', '')),
];
