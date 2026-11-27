# Friends

Matt, 2026-11-14: "Add a friend system that allows users to talk without using SMS or MMS but still validate
accounts by telephone numbers for now. If both users chatting are on ghost messenger show an 'add friend' button".

| Part | Where | What |
| --- | --- | --- |
| Friends | `lib/friends/friends.dart` | Asking, answering, sending and receiving, on the app's routes (`lib/net`, [network.md](network.md)) |
| The phone's half | `android/…/Friends.kt`, `E2e.kt` (`friend`, `setFriend`) | Where two stand, a friend's words kept with the phone's messages, the wake |
| The screens | `lib/ui/thread.dart`, `chat_settings.dart`, `contacts.dart` | Add friend, a request each way, "Friend · encrypted", the Friends row, a mark in Contacts |

## Who can be a friend

Someone encryption is on with. The two phones exchanged keys by text, and that is what proved each number to the
other: there is no account, no sign-up and no code sent by a server. Where they stand is kept on the phone's
encryption record for that person (`friend`: nothing, `want`, `asked`, `invited`, `yes`), so it ends when encryption
with them is turned off, and with a key of theirs that is not the one it was made with.

## Becoming friends

- The conversation offers **Add friend** where both phones have the app (encryption on, or their hello seen and
  nothing exchanged yet) and nothing has been said about being friends. It stands where the offer of encryption
  stood, which adding a friend turns on: with no keys exchanged this phone's goes first, by text (`want`), and the
  asking follows when theirs is here.
- Asking and answering are envelopes of kind `friend` over the routes, sealed: `ask`, `yes`, `no`, `end`. Asked by
  hand, one may go as a data text where the relay server is not reached. Two who ask each other are friends at once.
  A request never answered is said again as the app opens, by a route that costs nothing.
- **Nothing is offered until a relay server is known to answer** (`Friends.available`): a route that costs nothing is
  up, or one has been before on this phone, or the conversation's look (`Friends.look`, as it opens with someone who
  has the app, at most every ten minutes) found one answering at the relay server's address. Ours answers at
  `wss://ghost-sms.com/hub` since 2026-11-14 04:35 UTC (network.md), so the first release that carries friends
  offers them wherever both phones have the app; 0.7.4 was cut before they landed and does not.

## What friends write

- Words alone, to one friend, with a route that costs nothing up: an envelope of kind `text`. Pictures, stickers,
  voice messages, reactions and anything to a group still go as they did.
- It is **kept with the phone's own messages** on both phones (a row among the texts, sealed as an encrypted text
  is), so the conversation, the list, search, notifications and a paired computer show it with nothing new to read.
  Which rows went this way is remembered apart (the newest 4000), and they wear a globe beside the lock.
- Sending: "sending" as it is handed over, "delivered" when their app says it has it, however late. Where no route
  takes it, it is taken back and goes as the encrypted text it would have been. Nothing is lost for want of a relay.
- **A friend whose app is closed.** The relay server keeps it (seven days). One data text follows, in the clear,
  with nothing in it (`wake`; at most every ten minutes a person): their phone, knowing it for one without the app's
  screens (`Friends.isWake`), says "New message. Open Uplink to read it." in that conversation's
  notification, and the message takes its place when the app opens and fetches it.

## Not yet

- From a paired computer what is written to a friend goes as a text: the routes are the phone's Dart side, which a
  computer does not reach. The computer shows where the two stand and the globe on what went by the internet.
- Pictures and the rest between friends; groups of friends; showing the words in the wake's notification (the phone
  would fetch from the relay server without its screens).
- **Not run between two real phones.** `test/friends_test.dart` (two installs standing in), `FriendsTest.kt` (the
  wake), and the screens' pictures (`test/shots/13-friends-*.png`). A data text crossing between two phones has not
  been seen at all (network.md).
