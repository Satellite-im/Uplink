# Uplink's Matrix helper

A small program Uplink runs beside itself (on the phone and on a computer) to reach the person's Matrix
account as a device of its own, as Element does: signed in with the browser (single sign-on, which is how matrix.org
signs people in since it moved to Matrix Authentication Service) or with a password where the server takes one, then
direct messages and group rooms, replies, reactions, deletes, read receipts, pictures and files, and invites.

Most Matrix direct messages are end-to-end encrypted. The helper is a full encryption device: it keeps its own keys,
decrypts what arrives and encrypts what it sends. New messages decrypt once the person's other devices share their keys
with it, as they do with any new device. With the person's recovery key (Element's Security Key) it also unlocks the
account's secret storage: it signs itself with the account's cross-signing keys, so other devices trust it, and brings
down the key backup, so messages from before it was signed in decrypt too.

Messages go between this device and the person's own Matrix server only. Uplink's servers never see them.

It is built on [mautrix-go](https://github.com/mautrix/go) by Tulir Asokan and contributors (MPL-2.0), with its pure-Go
Olm and Megolm (`goolm`), so no C library is needed for the encryption. LICENSE lists everything it uses.

Uplink starts it (`matrix-sidecar --dir <folder>`) and talks to it over its standard input and output, one JSON
object a line (PROTOCOL.md). The folder holds:

- `session.json`: the homeserver, user id, device id and access token, and the key the store's secrets are encrypted
  with; readable by the person alone.
- `matrix.db`: SQLite, holding the device's encryption keys, each room's state and the sync position.
- `rooms.json`: each room's name, picture, unread count and last message, as syncs told them.
- `avatars/`: small pictures of rooms and people.

Build (Go 1.26 or later): `tool/build-matrixsidecar.sh [mac|android|windows|all]`, or by hand

    CGO_ENABLED=0 go build -tags goolm -trimpath -ldflags=-s -o matrix-sidecar .

The phone's copy is built with the Android NDK's compiler (CGO on) so it looks names up with Android's own resolver;
the computers' are pure Go. Test with `CGO_ENABLED=0 go test -tags goolm .` (and `CGO_ENABLED=1` for the phone's driver).
