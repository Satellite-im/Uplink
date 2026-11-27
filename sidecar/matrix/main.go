// Uplink's Matrix helper (README.md, PROTOCOL.md). MPL-2.0, as mautrix-go, on which it is built.
//
// It signs in to the person's Matrix account as a device of its own, as Element does, keeps the account's end-to-end
// encryption keys in its store, and speaks JSON lines over standard input and output. Requests, each with an "id" its
// answer carries back:
//
//	{"id":1,"op":"status"}                                                → {"logged_in","user_id","device_id","homeserver","name","verified"}
//	{"id":2,"op":"login_password","homeserver":"matrix.org","user":"@me:matrix.org","password":"…"} → the status, signed in
//	{"id":3,"op":"sso_url","homeserver":"matrix.org","redirect":"http://127.0.0.1:5123/"} → {"url","homeserver"}
//	{"id":4,"op":"login_token","token":"…"}                               → the status, signed in
//	{"id":5,"op":"verify_recovery_key","key":"EsT… …"}                    → {"verified":true,"backup_version":"…"}
//	{"id":6,"op":"rooms"}                                                 → [room…]
//	{"id":7,"op":"messages","room":"!r:s","from":"<token>","limit":30}    → {"messages":[…],"reactions":[…],"end":"<token>"}
//	{"id":8,"op":"send","room":"!r:s","text":"…","reply_to":"$e"}         → {"id":"$event"}
//	{"id":9,"op":"send_media","room":"!r:s","path":"…","mime":"…","name":"…","text":"…"} → {"id","media"}
//	{"id":10,"op":"read","room":"!r:s","event":"$e"}                       → null
//	{"id":11,"op":"react","room":"!r:s","event":"$e","emoji":"👍"}          → {"id":"$reaction"}
//	{"id":12,"op":"redact","room":"!r:s","event":"$e"}                     → null
//	{"id":13,"op":"download","mxc":"mxc://…","file":{…},"path":"…","thumb":false} → null once written
//	{"id":14,"op":"join","room":"!r:s"} / {"op":"leave","room":"!r:s"}    → null
//	{"id":15,"op":"logout"}                                               → null; everything forgotten
//
// Answers: {"id":1,"ok":true,"result":…} or {"id":1,"ok":false,"error":"…"}. Events, unasked, each with "ev": ready,
// synced, message, receipt, reaction, redacted, room, room_gone, logged_out.
package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"sync"

	"github.com/rs/zerolog"
)

// request is one line the app sends. Fields not used by an op are left empty.
type request struct {
	ID         int64           `json:"id"`
	Op         string          `json:"op"`
	Homeserver string          `json:"homeserver"`
	User       string          `json:"user"`
	Password   string          `json:"password"`
	Redirect   string          `json:"redirect"`
	Token      string          `json:"token"`
	Key        string          `json:"key"`
	Room       string          `json:"room"`
	From       string          `json:"from"`
	Limit      int             `json:"limit"`
	Text       string          `json:"text"`
	ReplyTo    string          `json:"reply_to"`
	Event      string          `json:"event"`
	Emoji      string          `json:"emoji"`
	Path       string          `json:"path"`
	Mime       string          `json:"mime"`
	Name       string          `json:"name"`
	MXC        string          `json:"mxc"`
	File       json.RawMessage `json:"file"`
	Thumb      bool            `json:"thumb"`
}

// dir is the --dir flag: where the session, the store, the rooms and the avatars are kept. out is standard output,
// one JSON object a line; outLock keeps lines whole when goroutines speak at once.
var (
	dir     string
	log     zerolog.Logger
	out     = json.NewEncoder(os.Stdout)
	outLock sync.Mutex
)

// say writes one line, an answer or an event, to standard output.
func say(v any) {
	outLock.Lock()
	defer outLock.Unlock()
	_ = out.Encode(v)
}

// emit says [name] with [fields] beside "ev".
func emit(name string, fields map[string]any) {
	m := map[string]any{"ev": name}
	for k, v := range fields {
		m[k] = v
	}
	say(m)
}

// main resumes a kept session, says "ready", then answers requests (each on a goroutine of its own) until standard
// input closes.
func main() {
	flag.StringVar(&dir, "dir", "", "where the Matrix store is kept")
	flag.Parse()
	if dir == "" {
		fmt.Fprintln(os.Stderr, "--dir is needed")
		os.Exit(2)
	}
	_ = os.MkdirAll(dir, 0o700)
	// mautrix's log goes to standard error, for Uplink's developer log; never standard output, which is the protocol's.
	log = zerolog.New(os.Stderr).With().Timestamp().Logger().Level(zerolog.InfoLevel)
	// The SSO address carries "&": kept as it is, not escaped for HTML.
	out.SetEscapeHTML(false)

	if s, err := readSession(); err == nil && s != nil {
		resumeOrRetry(s)
	}
	emit("ready", map[string]any{"logged_in": loggedIn(), "resuming": isResuming()})

	scan := bufio.NewScanner(os.Stdin)
	scan.Buffer(make([]byte, 1<<20), 8<<20)
	for scan.Scan() {
		r, err := parseRequest(scan.Bytes())
		if err != nil {
			continue
		}
		go handle(r)
	}
	// Uplink closed its end: the app is quitting.
	shutdown()
}

// parseRequest reads one line as a request. A line that is not JSON, or names no op, is an error (and is passed over).
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

// handle does one request and says its answer.
func handle(r request) {
	result, err := do(r)
	say(answer(r.ID, result, err))
}
