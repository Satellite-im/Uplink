# Uplink's Google Messages sidecar

A small program the Uplink desktop app (Mac, Windows) runs beside itself to reach the person's Google
Messages the way messages.google.com does: paired once by a QR code in Google Messages on the phone, then the
conversations, their messages and pictures, sending, reactions and read marks.

It is built on [libgm](https://github.com/mautrix/gmessages/tree/main/pkg/libgm) from mautrix-gmessages, by Tulir
Asokan and contributors, and is under the same licence, the GNU Affero General Public License v3 (LICENSE). Its
source, and any change made to libgm for it, is published with every release of Uplink that ships it.

Uplink itself is a separate program: it starts this one and talks to it over its standard input and output,
one JSON object a line (see main.go for the requests and the events). Nothing of Uplink is linked into it.

The session (the keys from pairing) is kept in the folder Uplink gives it (`--dir`), readable by the person alone.
Everything stays on the computer: nothing is sent anywhere but to Google, as messages.google.com does.

Build: `go build -o gmsidecar .` (Go 1.26 or later).
