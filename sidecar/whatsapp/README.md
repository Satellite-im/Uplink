# Uplink's WhatsApp helper

A small program Uplink runs beside itself (on the phone and on a computer) to reach the person's WhatsApp
account as a linked device, as WhatsApp Web does: linked once by a QR code (or an eight-letter code) in WhatsApp's
Linked devices, then recent history, messages, pictures and files, replies, reactions, deletes, read receipts, contacts,
groups and blocking.

**WhatsApp does not support this.** WhatsApp has no API for other apps and does not allow them; it may suspend or ban
accounts it finds using unofficial apps. Uplink says so, and asks the person to agree, before linking.

It is built on [whatsmeow](https://github.com/tulir/whatsmeow) by Tulir Asokan and contributors, under the Mozilla
Public License 2.0, and this helper's own source is under the same licence (LICENSE). It stores its keys in SQLite
through [mattn/go-sqlite3](https://github.com/mattn/go-sqlite3) (MIT, cgo).

Uplink itself is a separate program: it starts this one (`whatsapp-sidecar --dir <folder>`) and talks to it
over its standard input and output, one JSON object a line (PROTOCOL.md). The folder holds the SQLite store
(`whatsapp.db`, the device's keys, readable by the person alone), `whatsapp.log` and cached avatars.

Build (Go 1.26 or later, cgo): `tool/build-whatsappsidecar.sh mac` or `android` (the NDK's clang), or here

    CGO_ENABLED=1 go build -trimpath -ldflags=-s -o whatsapp-sidecar .

Test: `go test .`
