<p align="center">
  <img src="site/icon.png" width="120" alt="Uplink's logo: a white speech bubble that reads UP LINK, on black">
</p>

<h1 align="center">Uplink</h1>

<p align="center">
  <b>Private text, voice and video. In full quality.</b><br>
  Your texts, your friends, your group calls and your other chat apps in one place, on your phone and your computer.
</p>

<p align="center">
  <a href="https://satellite.im/"><b>satellite.im</b></a> &nbsp;·&nbsp;
  <a href="#get-uplink">Download</a> &nbsp;·&nbsp;
  <a href="https://satellite.im/app/">Open in a browser</a> &nbsp;·&nbsp;
  <a href="https://satellite.im/docs/">Docs and help</a>
</p>

<p align="center">
  <img src="site/art/space/hero.webp" width="100%" alt="A dish on a ridge sends one thin beam of light up into the stars">
</p>

Uplink is a messenger for Android, Mac, Windows, Linux and the browser. It starts as your texting app, with every
conversation you already have, and adds what texts never had: chats and calls with friends that are sealed end to end,
group spaces you can drop into and talk, and your WhatsApp, Telegram, Signal and Discord chats in the same list as your
texts. It is free, it keeps itself up to date, and all of its source is here.

> **Uplink is in alpha.** It is released often and things still change.
> [Join the alpha](https://satellite.im/docs/alpha/) to try it early and tell us what breaks.

## Get Uplink

| On | How |
| --- | --- |
| **Android** | [Download the APK](https://satellite.im/ghost-messaging.apk) on your phone and open it. Allow your browser to install apps if Android asks. |
| **Mac** | [Download the disk image](https://satellite.im/ghost-messaging-mac.dmg), open it and drag Uplink to Applications. Signed, and checked by Apple. |
| **Windows** | [Download the installer](https://satellite.im/ghost-messaging-setup.exe) and run it. Then open Uplink from the Start menu. |
| **Linux** | A [.deb](https://satellite.im/ghost-messaging-linux.deb) for Ubuntu, Debian and their family, or a [.tar.gz](https://satellite.im/ghost-messaging-linux-x64.tar.gz) for any other: unpack it and run `ghost-messaging`. |
| **Browser** | [satellite.im/app](https://satellite.im/app/). Nothing to install. |
| **iPhone** | Not out yet. |

On Android, choose **Set as default SMS app**, or let Uplink work beside the texting app you have. On a computer,
pair it with your phone to have your texts there too: on the phone open **Settings › Computers** and scan the code the
computer shows. Every copy updates itself from then on, with no store in between. The
[install guide](https://satellite.im/docs/install/) has each step.

The downloads are still named `ghost-messaging`: Uplink was called Ghost Messaging until November 2026, and the files
and the names inside the source kept theirs so that nothing already installed would break.

## What it does

### One app instead of three

Your texts, your friends and your calls live together. Start in a chat, step into the group's space, turn video on,
and the conversation is still all in one place.

- **Messages.** Texts and picture messages, plus encrypted chats with friends on Uplink: reactions, effects,
  stickers, and groups with names and faces. Sent, delivered and read each have their tick.
- **Reactions that land.** A ❤️ from an iPhone or a Pixel sits on the message it was for, not in a line of its own.
- **Sorted for you.** One-time codes get a tab of their own with the company's logo, ready to copy. Sales and spam
  find theirs, so the people you talk to come first.
- **Friends by username.** Pick a username, add friends by theirs, and make groups you can call all at once.

### Talk like you're in the same room

Every group has a space that stays open, so talking is as easy as texting: see who is in, drop in, drop out.

- **Sound and picture.** 510 kb/s stereo, noise suppression that keeps fans, keyboards and traffic out (RNNoise and
  DeepFilterNet), a music mode, and video up to 4K. Share a whole screen or one window.
- **Join by link.** A space has a link anyone can open, in the app or straight from a browser, with a chat beside
  the call.
- **Yours to run.** Roles and moderators, and plugins that record a call, write it out, caption it live or let
  everyone watch a video together.

### Every chat app, beside your texts

Sign in once and your other chats join your texts in one list, newest first, each marked with its app: **WhatsApp,
Telegram, Signal, Discord, Messenger, Instagram, Slack, X, Matrix**, and RCS through Google Messages. Read them,
answer them and send pictures without switching apps.

Each network runs on your own device and talks straight to its own servers. Your chats, codes and sign-ins never pass
through ours. It is their messages only, not their calls, and not every network is on every computer yet (Telegram and
Signal aren't on Windows). iMessage is not available to apps other than Apple's own.
[How each one is linked](https://satellite.im/docs/networks/).

### On your computer

Uplink for Mac, Windows and Linux shows every conversation, sends texts through your phone (sealed between the two),
and joins calls and spaces itself. It also runs with no phone at all, signed in to your account.
[Pairing a computer](https://satellite.im/docs/pairing/).

### Private by default

- **Sealed end to end.** Chats between Uplink users, your computer's link to your phone, and calls are encrypted on
  the devices themselves. Our server passes them along and can't read them.
- **No account to make.** Your number stays on your phone. A username and linked accounts are yours to turn on, and
  to remove.
- **Texts stay texts.** SMS and picture messages go through your carrier as they always have. Nothing is copied to us.
- **Check it, or run it.** Every part is in this repository, and you can
  [run your own relay](https://satellite.im/docs/self-hosting/) and point the app at it.

[Privacy and safety, in full](https://satellite.im/docs/privacy/).

### Make it yours

- **Effects.** Balloons for "Happy birthday", confetti for "Congrats", lasers for "pew pew".
- **Looks.** Four of them, from Uplink's own to one drawn like an old adventure game, with texture packs, your
  bubble colours, chat backgrounds and emoji set (your phone's own, Noto, Twemoji, OpenMoji or a clean outline).
  [Looks, colours and fonts](https://satellite.im/docs/appearance/).
- **Plugins.** The [Marketplace](https://satellite.im/docs/plugins/) adds what you want and nothing you don't: a spam
  filter, translation, a soundboard, a voice changer, Spotify and Notion, and more. A plugin is a small file anyone
  can write: [build one](https://satellite.im/docs/build-a-plugin/).

## Open source

Uplink is open source so that anyone can check what it does with their messages. All of it is here: the phone app, the
Mac, Windows and Linux apps, the app in a browser, the relay server that carries sealed messages between devices, the
call's sound processing, and the helpers that speak to other chat networks.

- **Licence.** The GNU Affero General Public License v3 ([LICENSE](LICENSE)). Anyone who runs a changed copy for
  others to use, the relay included, owes those people its source. Third-party parts keep their own licences.
- **What is not here.** The keys releases are signed with, and the server's own credentials. A build made from this
  source is not signed as a release is, so it installs as a separate app.

## Build it

You need [Flutter](https://docs.flutter.dev/get-started/install) (stable, with Dart 3.11 or newer).

```sh
flutter pub get
flutter test                                                  # the app's tests
flutter build apk --release --target-platform android-arm64   # the phone app
flutter build macos                                           # the Mac app; or `flutter build windows`, `flutter build linux`
node tool/build-web.mjs                                       # the app in a browser, into build/web
(cd relay && dart test && dart run bin/relay.dart)            # the relay, at ws://127.0.0.1:8787
```

A few parts have build scripts of their own in [`tool/`](tool): the direct-link core (Rust, `build-p2p.sh`), the
helpers for other chat networks (Go, `build-*sidecar.sh`) and Telegram's library (`build-tdlib.sh`). The app builds
without them and leaves those features out.

| Where | What |
| --- | --- |
| [`lib/`](lib) | The app: one Flutter project for the phone, the computer and the browser. |
| `android/` `ios/` `macos/` `windows/` `linux/` `web/` | Each platform's own half: texts and notifications on Android, windows and updates on a computer. |
| [`relay/`](relay) | The relay server, in Dart's own library and nothing else. |
| [`native/`](native) | The call's sound processing, and the core of direct links between devices. |
| [`sidecar/`](sidecar) | The helpers that speak to other chat networks, each a small program of its own. |
| [`extension/`](extension) [`discord/`](discord) | The browser extension that shares your sign-ins with your devices, and the Discord bot. |
| [`packages/glacier/`](packages/glacier) | Glacier, the UI kit everything is drawn with. |
| [`site/`](site) [`docs-src/`](docs-src) | [satellite.im](https://satellite.im/) and its docs. The picture at the top of this page is the site's. |
| [`tool/`](tool) [`test/`](test) | Build and release scripts, and the tests. |
| [`docs/`](docs) | Design notes, and [the record](docs/RECORD.md) of every feature as it was built. |

## Run your own relay

The relay is a small server that passes sealed messages between devices. It can't read them, and you don't have to
use ours: [docs/SELF_HOSTING.md](docs/SELF_HOSTING.md) sets one up, with a container or without, and
[the guide on the site](https://satellite.im/docs/self-hosting/) shows how to point the app at it.

## Help and feedback

- **Using Uplink:** [satellite.im/docs](https://satellite.im/docs/).
- **Building on it:** the [developer docs](https://satellite.im/docs/developer/) cover how the app is built and both of
  its APIs.
- **Something wrong, or something missing?** Choose **Share feedback** in the app. It takes screenshots too.
