//go:build cgo

package main

// With CGO (the phone's build, made with the NDK for Android's resolver) the encrypted chats' key store is SQLite
// through mattn/go-sqlite3, as the WhatsApp helper's is.

import _ "github.com/mattn/go-sqlite3"

// sqliteDriver is the name mattn/go-sqlite3 registers with database/sql.
const sqliteDriver = "sqlite3"

// sqliteURI is the address of the store at [path], with the settings spelled as mattn/go-sqlite3 reads them.
func sqliteURI(path string) string {
	return "file:" + path + "?_foreign_keys=on&_journal_mode=WAL&_busy_timeout=5000&_txlock=immediate"
}
