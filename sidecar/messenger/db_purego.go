//go:build !cgo

package main

// Without CGO (the computers' builds) the encrypted chats' key store is modernc.org/sqlite, SQLite in pure Go.

import _ "modernc.org/sqlite"

// sqliteDriver is the name modernc.org/sqlite registers with database/sql.
const sqliteDriver = "sqlite"

// sqliteURI is the address of the store at [path], with the settings spelled as modernc.org/sqlite reads them.
func sqliteURI(path string) string {
	return "file:" + path + "?_pragma=foreign_keys(1)&_pragma=journal_mode(WAL)&_pragma=synchronous(NORMAL)&_pragma=busy_timeout(5000)&_txlock=immediate"
}
