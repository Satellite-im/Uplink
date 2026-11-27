package main

// What the helper keeps between runs: session.json, readable by the person alone.

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
)

// session is what session.json holds: the browser's cookies (which are the sign-in), whose they are, and what a
// later start needs beside them.
type session struct {
	// Platform is the site the cookies are from: "messenger" (messenger.com) or "facebook" (facebook.com).
	Platform string            `json:"platform"`
	Cookies  map[string]string `json:"cookies"`
	// State is what messagix dumps of its connection (the page's settings and how far each table has been read).
	// It is kept as the protocol asks; every start still loads Messenger's page afresh, as opening the site does,
	// because that is what lists the chats.
	State  json.RawMessage `json:"state,omitempty"`
	Me     string          `json:"me"`
	Name   string          `json:"name"`
	Handle string          `json:"handle"`
	// WADevice is the number Meta gave this helper's device for end-to-end encrypted chats (its keys are in e2ee.db).
	WADevice uint16 `json:"wa_device,omitempty"`
	// Kinds is the kind of each thread met (Meta's thread type number), so a chat not listed this time is still
	// sent to the right way, encrypted or not.
	Kinds map[string]int64 `json:"kinds,omitempty"`
}

// sessionPath is where the session is kept in the helper's folder.
func sessionPath(dir string) string { return filepath.Join(dir, "session.json") }

// saveSession writes the session whole or not at all, never readable by anyone else even for a moment.
func saveSession(dir string, s *session) error {
	data, err := json.Marshal(s)
	if err != nil {
		return err
	}
	tmp := sessionPath(dir) + ".part"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return err
	}
	if err := os.Chmod(tmp, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, sessionPath(dir))
}

// loadSession is the session kept, or nil where there is none (or it cannot be read: then the person signs in again).
func loadSession(dir string) *session {
	data, err := os.ReadFile(sessionPath(dir))
	if err != nil {
		return nil
	}
	var s session
	if json.Unmarshal(data, &s) != nil || len(s.Cookies) == 0 {
		return nil
	}
	return &s
}

// dropSession removes the session file. None being there is no error.
func dropSession(dir string) error {
	err := os.Remove(sessionPath(dir))
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	return err
}
