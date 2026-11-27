//go:build !cgo

package main

// Without CGO (the computers' builds) the store is modernc.org/sqlite, SQLite in pure Go.

import _ "modernc.org/sqlite"

const sqliteDriver = "sqlite"

// sqliteURI is the store's address for this driver, asking for what the phone's driver sets itself: foreign keys, WAL,
// writes that take their lock at once, and a five-second wait on a busy store.
func sqliteURI(path string) string {
	return "file:" + path + "?_pragma=foreign_keys(1)&_pragma=journal_mode(WAL)&_pragma=synchronous(NORMAL)&_pragma=busy_timeout(5000)&_txlock=immediate"
}
