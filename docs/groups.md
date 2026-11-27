# Groups of friends

Matt, 2026-11-14: "expand on the ability to create, name and manage groups like telegram". Friends are
[friends.md](friends.md); the routes everything here goes by are [network.md](network.md).

| Part | Where | What |
| --- | --- | --- |
| Groups | `lib/friends/groups.dart` | Making one, changing it, leaving, sending and receiving, on the app's routes |
| The phone's half | `android/…/Groups.kt`, `E2e.kt` (`pairKey`) | The records, a group's conversation, its members as people the routes reach, what is written in it |
| The screens | `lib/ui/new_group.dart`, `thread.dart`, `chat_settings.dart`, `contacts.dart` | New group, the group's conversation, its name, members and admins |

## What a group is

A name, members, and admins, held on each member's phone. One person makes it out of their friends and is its first
admin. It is **not a group text**: nothing in it is ever an MMS, and its conversation on the phone is its own, never
an existing group text's with the same people.

- A **member** is known by the name of their key (the routes' name for a phone), with the key itself and their
  number. An **admin** names the group, adds a friend of theirs, takes a member out, and makes another member an
  admin. Anyone leaves when they like. Where the last admin leaves, the member whose name sorts first becomes one,
  which every phone works out alike. Fifty members at most.
- **Two members need not be friends.** Each has the other's key from the group, which came from an admin both had,
  and their two phones make a pair's key from it as two who exchanged keys by text do (`Groups.peers`,
  `E2e.pairKey`). So the trust is: a member is whoever an admin says they are.

## How it is told

Envelopes of kind `group`, each naming the group (`g`, 32 hex digits made by whoever made it), sealed with the pair's
key, by a route that costs nothing:

- `state`: the whole group as it now is (`s`: name, members as `{i, k, a}`, admins, and `v`, a count that goes up by
  one each change). From an admin. It is how a group is joined, renamed, and how members are added and taken out
  and admins made. A phone that has the group takes a state only from an admin in the group as it holds it, and only
  one with a higher count. A phone that has not (or has left) takes one only from **a friend** who is an admin of
  it and has it among the members: nobody is put in a group by a stranger. Someone taken out is told the state they
  are missing from, and their phone marks the group left.
- `text`: words (`t`), from a member, one envelope to each of the others.
- `leave`: from a member who is going.

What the relay server keeps for a member who is away is followed by the wake (friends.md), as a friend's is.

## Its conversation

One of the phone's own, so the list, search, notifications, mute, pin and archive work with nothing new:

- A conversation is told apart by who it is with. A group's is with an address that is nobody's
  (`Groups.address`: the group's id with its digits written as letters, at `group.ghost-sms.com`), so it stays the
  same conversation as members come and go. Who is in it, and its name, are read from the group's record wherever
  the phone would have read them from the conversation (`Store.conversationsPage`, `Store.threadPeople`).
- What is written is kept as a group message is, with who it came from, marked as having gone by the routes (the
  globe); lines about the group itself ("Ann added Dan", "You named the group …") are kept where they happened and
  drawn as lines. Unlike a friend's words, a group's are kept as they are written, as any group text on the phone
  is.
- **Words only**, with reactions and edits (which are words). No pictures, stickers or voice messages yet, and no
  falling back to a text: with no route up the conversation says there is no connection and keeps what was typed.

## The screens

- **New group**, at the top of the address book where there is a friend to put in one: a name, the friends to
  choose from, Create. It opens as its conversation.
- **The conversation**: its name, "3 members", the lines about it, a field for words. Left or taken out of, it says
  so where the field was.
- **Its settings**: for an admin, the name everyone sees; the members with who is an admin; a member's row (for an
  admin) offers Make admin and Remove from group; Add people lists the admin's friends who are not in it; Leave
  group. A group text keeps its own name field, which only its phone sees.

## Not yet, and what to know

- Nothing is offered until a relay server answers (friends.md): New group stands where there are friends.
- **From a paired computer** a group is read, not written to: its conversation says "Write in this group from your
  phone for now."
- A member's first words can be missed by someone who has only just been told of the group: the routes take
  nothing from a name they do not know, and a phone learns a group's members a moment after the state arrives. It
  matters where both were kept for someone away and arrive together. Holding such a packet for a few seconds
  belongs in `lib/net/switchboard.dart`, which is the phone session's.
- Two admins changing the group at the same moment: the second to arrive with the same count is not taken.
- Tried with stand-in phones (`test/groups_test.dart`), on the screens (`test/shots/15-groups-*`), and what the
  header of friends.md's last section says of two emulators. Not on real phones.
