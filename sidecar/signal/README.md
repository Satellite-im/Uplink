# Uplink's Signal helper

A small program Uplink runs beside itself (on the phone and on a computer) to reach the person's Signal
account as a linked device, as Signal Desktop does: linked once by a QR code in Signal's Linked devices, then messages,
pictures, replies, reactions, deletes, read receipts, contacts and groups. Signal keeps no history for a new linked
device, so only what arrives from linking on is seen.

It is built on [signalmeow](https://github.com/mautrix/signal/tree/main/pkg/signalmeow) from mautrix-signal, by Tulir
Asokan, Scott Weber and contributors, and on Signal's [libsignal](https://github.com/signalapp/libsignal), and is under
the same licence, the GNU Affero General Public License v3. Its source, and any change made to signalmeow for it, is
published with every release of Uplink that ships it.

Uplink itself is a separate program: it starts this one (`signal-sidecar --dir <folder>`) and talks to it over
its standard input and output, one JSON object a line (PROTOCOL.md). Nothing of Uplink is linked into it. The
folder holds the SQLite store (`signal.db`, the device's keys, readable by the person alone) and cached avatars.

Build (Go 1.26 or later, cgo): first build libsignal's `libsignal_ffi.a` at the commit the module's libsignalgo header
matches (4beb029 for mautrix-signal v0.2610.0; `cargo build --release -p libsignal-ffi` in libsignal), then

    CGO_ENABLED=1 LIBRARY_PATH=<folder holding libsignal_ffi.a> go build -o signal-sidecar .
