// Uplink's Instagram helper (README.md, PROTOCOL.md). AGPL-3.0, as mautrix-meta, on whose instameow library
// it is built.
//
// Matt, 2026-11-20: "Let's do the feasible ones but skip X and google voice". It signs in to the person's Instagram
// account with the cookies of a browser signed in to instagram.com, behaves as the website does, and speaks JSON
// lines over standard input and output: the protocol all of Uplink's account helpers share (../ACCOUNT_HELPERS.md).
// Requests, each with an "id" its answer carries back:
//
//	{"id":1,"op":"status"}                                    → {"linked","connected","me","name","handle"}
//	{"id":2,"op":"sign_in","cookies":{"sessionid":"…",…}}     → {"me","name","handle"}, and the events "linked", "chat"…, "name"…
//	{"id":3,"op":"unlink"}                                    → null; everything forgotten
//	{"id":4,"op":"chats"}                                     → [<chat>…]: the first page of the inbox
//	{"id":5,"op":"history","chat":"…","before":"<message id>"} → {"messages":[…],"more":bool}, oldest first
//	{"id":6,"op":"send","to":"…","text":"…","quote":{"id":"…"}} → {"id","ts"}
//	{"id":7,"op":"send_media","to":"…","path":"…","mime":"…","name":"…","text":"…"} → {"id","ts"}
//	{"id":8,"op":"read","to":"…","upto":"<message id>"}       → null
//	{"id":9,"op":"react","to":"…","target":"…","emoji":"❤","remove":false} → null
//	{"id":10,"op":"delete","to":"…","target":"…"}             → null (your own message, unsent)
//	{"id":11,"op":"download","pointer":{"url":"…"},"path":"…"} → null once written
//	{"id":12,"op":"who","who":"<person id>"}                  → {"id","name","handle","avatar"}
//
// Answers: {"id":1,"ok":true,"result":…} or {"id":1,"ok":false,"error":"…"}. Events, unasked, each with "ev": ready,
// linked, unlinked, connected, disconnected, chat, message, edited, deleted, reaction, receipt, name.
package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/rs/zerolog"
)

// quote is the message a `send` answers, by its id.
type quote struct {
	ID string `json:"id"`
}

// request is one line from the app. "id" is always the request's own number; no other field at the top is called
// that, so `read` names the newest message read as "upto".
type request struct {
	ID      int64             `json:"id"`
	Op      string            `json:"op"`
	Cookies map[string]string `json:"cookies"`
	Chat    string            `json:"chat"`
	Before  string            `json:"before"`
	To      string            `json:"to"`
	Text    string            `json:"text"`
	Quote   *quote            `json:"quote"`
	Path    string            `json:"path"`
	Mime    string            `json:"mime"`
	Name    string            `json:"name"`
	Target  string            `json:"target"`
	Upto    string            `json:"upto"`
	Emoji   string            `json:"emoji"`
	Remove  bool              `json:"remove"`
	Pointer json.RawMessage   `json:"pointer"`
	Who     string            `json:"who"`
}

// dir is where the session, the log and people's pictures are kept (--dir). out is standard output, written one
// JSON line at a time under outLock. inflight counts the requests still being answered, waited for at exit.
var (
	dir     string
	log     zerolog.Logger
	out     = json.NewEncoder(os.Stdout)
	outLock sync.Mutex

	inflight sync.WaitGroup
)

// say writes [v] to standard output as one JSON line. Nothing else writes there.
func say(v any) {
	outLock.Lock()
	defer outLock.Unlock()
	_ = out.Encode(v)
}

// event says [name] with [fields] beside "ev".
func event(name string, fields map[string]any) {
	m := map[string]any{"ev": name}
	for k, v := range fields {
		m[k] = v
	}
	say(m)
}

// main takes up the kept session, if there is one, then answers the requests on standard input, each in its own
// goroutine, until Uplink closes it.
func main() {
	flag.StringVar(&dir, "dir", "", "where the Instagram session is kept")
	flag.Parse()
	if dir == "" {
		fmt.Fprintln(os.Stderr, "--dir is needed")
		os.Exit(2)
	}
	_ = os.MkdirAll(dir, 0o700)
	// The log goes to standard error (Uplink's developer log) and instagram.log beside the session; never stdout, and
	// at info level, where neither the library nor this helper writes what a message says.
	log = zerolog.New(zerolog.MultiLevelWriter(os.Stderr, logFile())).With().Timestamp().Logger().Level(zerolog.InfoLevel)
	out.SetEscapeHTML(false)

	s, err := loadSession(sessionPath())
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		log.Err(err).Msg("the kept session could not be read; starting signed out")
	}
	// Ready first, then the connection: the app hears whether a session is held at once, and "connected" (or
	// "unlinked", where Instagram no longer takes it) when Instagram has answered.
	event("ready", map[string]any{"linked": s != nil})
	if s != nil {
		resume(s)
	}

	// A request is one line, 8 MB at most.
	scan := bufio.NewScanner(os.Stdin)
	scan.Buffer(make([]byte, 1<<20), 8<<20)
	for scan.Scan() {
		r, err := parseRequest(scan.Bytes())
		if err != nil {
			continue
		}
		inflight.Add(1)
		go func() {
			defer inflight.Done()
			handle(r)
		}()
	}
	// Uplink closed its end: the app is quitting. What was asked is answered first, for a few seconds at most.
	waited := make(chan struct{})
	go func() {
		inflight.Wait()
		close(waited)
	}()
	select {
	case <-waited:
	case <-time.After(3 * time.Second):
	}
	shutdown()
}

// parseRequest reads one line as a request. A line that is not JSON, or names no op, is an error (and is skipped).
func parseRequest(line []byte) (request, error) {
	var r request
	err := json.Unmarshal(line, &r)
	if err == nil && r.Op == "" {
		err = errors.New("no op")
	}
	return r, err
}

// answer is the line that answers request [id]: its result, or what went wrong.
func answer(id int64, result any, err error) map[string]any {
	if err != nil {
		return map[string]any{"id": id, "ok": false, "error": err.Error()}
	}
	return map[string]any{"id": id, "ok": true, "result": result}
}

// handle does what [r] asks and says its answer, even where doing it panicked.
func handle(r request) {
	defer func() {
		// A shape of Instagram's the library did not expect must not take the helper down with the request.
		if v := recover(); v != nil {
			log.Error().Str("op", r.Op).Interface("panic", v).Msg("request failed badly")
			say(answer(r.ID, nil, errors.New("Instagram answered in a way this app did not expect")))
		}
	}()
	result, err := do(r)
	say(answer(r.ID, result, err))
}

// bg is a context with no end that carries the helper's log.
func bg() context.Context { return log.WithContext(context.Background()) }

// do runs one request, by its op, with two minutes to finish.
func do(r request) (any, error) {
	ctx, cancel := context.WithTimeout(bg(), 2*time.Minute)
	defer cancel()
	switch r.Op {
	case "status":
		return status(), nil
	case "sign_in":
		return signIn(ctx, r.Cookies)
	case "unlink":
		unlink()
		return nil, nil
	case "chats":
		return chats(ctx)
	case "history":
		return history(ctx, r.Chat, r.Before)
	case "send":
		quoted := ""
		if r.Quote != nil {
			quoted = r.Quote.ID
		}
		return send(ctx, r.To, r.Text, quoted)
	case "send_media":
		return sendMedia(ctx, r.To, r.Path, r.Mime, r.Name, r.Text)
	case "read":
		return nil, markRead(ctx, r.To, r.Upto)
	case "react":
		return nil, react(ctx, r.To, r.Target, r.Emoji, r.Remove)
	case "delete":
		return nil, unsend(ctx, r.To, r.Target)
	case "download":
		return nil, download(ctx, r.Pointer, r.Path)
	case "who":
		return who(ctx, r.Who)
	}
	return nil, fmt.Errorf("the Instagram helper does not know how to %q", r.Op)
}

// --- the session ----------------------------------------------------------------------------------------------------

// session is what the helper keeps between runs: the browser's cookies (which are the sign-in) and who they belong
// to. Nothing else is needed to connect again: each start loads Instagram's inbox page as a browser does.
type session struct {
	Cookies map[string]string `json:"cookies"`
	Me      string            `json:"me"`     // the id messages name the person by
	IGID    string            `json:"igid"`   // the profile's own id
	Name    string            `json:"name"`   // the shown name
	Handle  string            `json:"handle"` // the username
	Saved   int64             `json:"saved"`  // ms
}

// sessionPath is where the session is kept, in the helper's folder.
func sessionPath() string { return filepath.Join(dir, "session.json") }

// saveSession writes [s] where only the person can read it, whole or not at all.
func saveSession(path string, s *session) error {
	data, err := json.MarshalIndent(s, "", "  ")
	if err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err = os.WriteFile(tmp, data, 0o600); err != nil {
		return err
	}
	// WriteFile keeps an older file's mode; the session is the account, so make sure of it.
	if err = os.Chmod(tmp, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// loadSession reads a kept session; one without the cookies Instagram needs is no session.
func loadSession(path string) (*session, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var s session
	if err = json.Unmarshal(data, &s); err != nil {
		return nil, err
	}
	if len(missingCookies(s.Cookies)) > 0 {
		return nil, errors.New("the kept session has no cookies")
	}
	return &s, nil
}

// avatarDir is where people's pictures are kept once fetched.
func avatarDir() string { return filepath.Join(dir, "avatars") }

// logFile is instagram.log in the session's folder, begun afresh past a megabyte; standard error alone where it
// can't open.
func logFile() *os.File {
	path := filepath.Join(dir, "instagram.log")
	if st, err := os.Stat(path); err == nil && st.Size() > 1<<20 {
		_ = os.Remove(path)
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return os.Stderr
	}
	return f
}
