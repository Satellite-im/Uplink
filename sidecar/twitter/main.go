// Uplink's X helper (README.md, PROTOCOL.md). AGPL-3.0, as mautrix-twitter, on whose twittermeow package it
// is built.
//
// It signs in to X as the person, with the cookies of a browser signed in to their account and their X Chat
// passcode, behaves as x.com's Messages page does, and speaks JSON lines over standard input and output: the
// protocol all of Uplink's account helpers share (../ACCOUNT_HELPERS.md). Requests, each with an "id" its answer
// carries back:
//
//	{"id":1,"op":"status"}                                                        → {"linked","connected","me","name","handle"}
//	{"id":2,"op":"sign_in","cookies":{"auth_token":"…","ct0":"…"},"passcode":"1234"} → {"me","name","handle"}, and the event "linked"
//	{"id":3,"op":"unlink"}                                                        → null; everything kept is forgotten
//	{"id":4,"op":"chats"}                                                         → [<chat>…], the newest chats
//	{"id":5,"op":"history","chat":"…","before":"<message id>"}                    → {"messages":[…],"more":bool}, oldest first
//	{"id":6,"op":"send","to":"…","text":"…","quote":{"id"}}                       → {"id":"<message id>","ts":…}
//	{"id":7,"op":"send_media","to":"…","path":"…","mime":"…","name":"…","text":"…"} → {"id","ts"}
//	{"id":8,"op":"read","to":"…","upto":"<message id>"}                           → null
//	{"id":9,"op":"react","to":"…","target":"…","emoji":"👍","remove":false}       → null
//	{"id":10,"op":"delete","to":"…","target":"…"}                                 → null (your own message, taken back for everyone)
//	{"id":11,"op":"download","pointer":{…},"path":"…"}                            → null once written
//	{"id":12,"op":"who","who":"…"}                                                → {"id","name","handle","avatar"}
//
// Answers: {"id":1,"ok":true,"result":…} or {"id":1,"ok":false,"error":"…"}. Events, unasked, each with "ev": ready,
// linked, unlinked, connected, disconnected, chat, message, edited, deleted, reaction, receipt, name.
package main

import (
	"bufio"
	"bytes"
	"cmp"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"image"
	_ "image/gif"
	_ "image/jpeg"
	_ "image/png"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/google/uuid"
	"github.com/rs/zerolog"
	"go.mau.fi/util/ptr"
	"go.mau.fi/util/variationselector"

	"go.mau.fi/mautrix-twitter/pkg/twittermeow"
	xcookies "go.mau.fi/mautrix-twitter/pkg/twittermeow/cookies"
	"go.mau.fi/mautrix-twitter/pkg/twittermeow/crypto"
	"go.mau.fi/mautrix-twitter/pkg/twittermeow/data/payload"
	"go.mau.fi/mautrix-twitter/pkg/twittermeow/data/response"
	"go.mau.fi/mautrix-twitter/pkg/twittermeow/data/types"
	"go.mau.fi/mautrix-twitter/pkg/twittermeow/methods"
)

const (
	// historyEvents is how many of X's events a page of history asks for. Reactions, edits and read marks are events
	// too, so a page holds at most this many messages.
	historyEvents = 50
	// maxSeqAll stands for "from the newest": X pages history down from a sequence id, and this is the largest.
	maxSeqAll = "9223372036854775807"
	// maxUpload is the largest file sent: the file is read whole, sealed and sent in one piece.
	maxUpload = 100 << 20
)

// quote is the message a `send` answers: its id, and what the app knows of it.
type quote struct {
	ID string `json:"id"`
	// What the quoted message was, for a quote of a message this run has not seen. Optional: the helper remembers
	// every message it has passed on since it started.
	Author string `json:"author"`
	Text   string `json:"text"`
	TS     int64  `json:"ts"`
}

// request is one line read from standard input. Each op reads the fields it needs and leaves the rest.
type request struct {
	ID      int64             `json:"id"`
	Op      string            `json:"op"`
	Cookies map[string]string `json:"cookies"`
	// `sign_in`: the person's 4-digit X Chat passcode, which opens the keys of their encrypted chats. X's own; not
	// in the shared protocol (PROTOCOL.md).
	Passcode string `json:"passcode"`
	Chat     string `json:"chat"`
	Before   string `json:"before"`
	// Taken and not needed: X pages history by message id.
	BeforeTS int64           `json:"before_ts"`
	To       string          `json:"to"`
	Upto     string          `json:"upto"`
	Text     string          `json:"text"`
	Quote    *quote          `json:"quote"`
	Path     string          `json:"path"`
	Mime     string          `json:"mime"`
	Name     string          `json:"name"`
	Target   string          `json:"target"`
	Emoji    string          `json:"emoji"`
	Remove   bool            `json:"remove"`
	Pointer  json.RawMessage `json:"pointer"`
	Who      string          `json:"who"`
}

// account is one signed-in session: the library's client, the key store and who it is.
type account struct {
	cli    *twittermeow.Client
	keys   *keyStore
	me     string // the person's X user id
	name   string
	handle string
	// The client has loaded x.com's messages page this run (sign-in does it); start then need not again.
	loaded bool

	// The live connection's context, ended with the session.
	live context.Context
	stop context.CancelFunc

	// One listing of the inbox at a time.
	syncLock sync.Mutex

	// How far this run has got: the newest X Chat sequence id passed on.
	stateLock sync.Mutex
	maxSeq    string

	// What session.json was last written with, to tell when it needs writing again. One write at a time.
	saveLock   sync.Mutex
	savedCooks map[string]string
	savedSeq   string
}

var (
	// Where the session file, the log and the cached avatars are kept (--dir).
	dir     string
	log     zerolog.Logger
	out     = json.NewEncoder(os.Stdout)
	outLock sync.Mutex

	// mu guards the session in use and whether its live connection is up.
	mu        sync.Mutex
	acct      *account
	connected bool
	// One sign-in or sign-out at a time.
	signLock sync.Mutex
	// The requests still being answered, which main waits for (briefly) when Uplink closes its end.
	inflight sync.WaitGroup
)

// say writes [v] to standard output as one JSON line. Nothing else writes there, and outLock keeps each line whole.
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

// main opens the kept session, if there is one, says `ready`, then answers the requests on standard input, each in
// its own goroutine, until Uplink closes it.
func main() {
	flag.StringVar(&dir, "dir", "", "where the X session is kept")
	flag.Parse()
	if dir == "" {
		fmt.Fprintln(os.Stderr, "--dir is needed")
		os.Exit(2)
	}
	_ = os.MkdirAll(dir, 0o700)
	// The log goes to standard error (Uplink's developer log) and twitter.log beside the session; never stdout.
	log = zerolog.New(zerolog.MultiLevelWriter(os.Stderr, logFile())).With().Timestamp().Logger().Level(zerolog.InfoLevel)
	out.SetEscapeHTML(false)

	var a *account
	if s := loadSession(sessionPath()); s != nil {
		a = newAccount(*s, nil)
		mu.Lock()
		acct = a
		mu.Unlock()
	}
	event("ready", map[string]any{"linked": a != nil})
	if a != nil {
		start(a)
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
		if a := current(); a != nil {
			a.keepState(true)
			a.stop()
			a.cli.Disconnect()
		}
		close(waited)
	}()
	select {
	case <-waited:
	case <-time.After(3 * time.Second):
	}
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

// handle does what [r] asks and says its answer.
func handle(r request) {
	result, err := do(r)
	say(answer(r.ID, result, err))
}

// bg is a context with no end that carries the helper's log.
func bg() context.Context { return log.WithContext(context.Background()) }

// libLog is the library's own log: warnings and worse only. Its debug lines carry request bodies.
func libLog() zerolog.Logger {
	return log.With().Str("component", "twittermeow").Logger().Level(zerolog.WarnLevel)
}

// --- the session ----------------------------------------------------------------------------------------------------

var errNotLinked = errors.New("not signed in to X")

// current is the session in use; nil when nobody is signed in.
func current() *account {
	mu.Lock()
	defer mu.Unlock()
	return acct
}

// newAccount makes the library's client for a session (or takes [cli], already signed in). Nothing is asked of X yet.
func newAccount(s session, cli *twittermeow.Client) *account {
	ks := newKeyStore(s)
	a := &account{keys: ks, me: s.Me, name: s.Name, handle: s.Handle, maxSeq: s.MaxSeq, savedSeq: s.MaxSeq}
	a.savedCooks = map[string]string{}
	for k, v := range s.Cookies {
		a.savedCooks[k] = v
	}
	if cli == nil {
		jar := map[string]string{}
		for k, v := range s.Cookies {
			jar[k] = v
		}
		cli = twittermeow.NewClient(xcookies.NewCookies(jar), ks, libLog())
	} else {
		cli.SetKeyStore(ks)
		a.loaded = true
	}
	cli.Logger = libLog()
	cli.SetCurrentUserID(s.Me)
	a.cli = cli
	a.live, a.stop = context.WithCancel(bg())
	ks.changed = a.persist
	cli.SetXChatEventHandler(a.onEvent)
	cli.SetXChatConnectHandler(a.onConnect)
	return a
}

// start checks the session by loading x.com's messages page, lists the newest chats (said as `chat` events), then
// opens X Chat's live connection.
func start(a *account) {
	go func() {
		ctx := a.live
		if !a.loaded {
			for wait := 10 * time.Second; ; wait = min(wait*2, 10*time.Minute) {
				_, err := a.cli.LoadMessagesPage(ctx)
				if err == nil {
					break
				}
				if ctx.Err() != nil {
					return
				}
				log.Warn().Err(err).Msg("load the messages page")
				if rejected(err) {
					ended(a, err)
					return
				}
				select {
				case <-ctx.Done():
					return
				case <-time.After(wait):
				}
			}
		}
		a.syncChats(ctx)
		if current() != a || ctx.Err() != nil {
			return
		}
		if err := a.cli.StartXChatWebsocket(ctx); err != nil && ctx.Err() == nil {
			log.Err(err).Msg("open the live connection")
		}
		// The cookies X turns over, and how far the live stream has got, are kept now and then.
		tick := time.NewTicker(time.Minute)
		defer tick.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-tick.C:
				a.keepState(false)
			}
		}
	}()
}

// setConnected notes whether [a]'s live connection is up, and says `connected` or `disconnected` when that changes.
// A session that is no longer the one in use is not listened to.
func setConnected(a *account, now bool) {
	mu.Lock()
	if acct != a || connected == now {
		mu.Unlock()
		return
	}
	connected = now
	mu.Unlock()
	if now {
		event("connected", nil)
	} else {
		event("disconnected", nil)
	}
}

// drop lets go of [a], if it is still the session: its connection closed, what was remembered of it forgotten.
func drop(a *account) bool {
	mu.Lock()
	if acct != a {
		mu.Unlock()
		return false
	}
	acct = nil
	wasConnected := connected
	connected = false
	mu.Unlock()
	a.stop()
	// In the background: the live connection's own goroutine may be the caller, and closing waits for it.
	go a.cli.Disconnect()
	seen.reset()
	if wasConnected {
		event("disconnected", nil)
	}
	return true
}

// ended is X turning the session away: everything is forgotten and the app told, to ask for a new sign-in.
func ended(a *account, err error) {
	if !drop(a) {
		return
	}
	log.Warn().Err(err).Msg("X ended the session")
	forgetFiles()
	event("unlinked", map[string]any{"error": endedWords(err)})
}

// forgetFiles removes what is kept on disk of a session: the session file (and a half-written one) and the avatars.
func forgetFiles() {
	_ = os.Remove(sessionPath())
	_ = os.Remove(sessionPath() + ".new")
	_ = os.RemoveAll(avatarDir())
}

// getMaxSeq is how far this run has got: the newest sequence id noted.
func (a *account) getMaxSeq() string {
	a.stateLock.Lock()
	defer a.stateLock.Unlock()
	return a.maxSeq
}

// noteSeq moves how far this run has got forward to [seq], never back.
func (a *account) noteSeq(seq string) {
	if !isDigits(seq) {
		return
	}
	a.stateLock.Lock()
	defer a.stateLock.Unlock()
	if compareSeq(seq, a.maxSeq) > 0 {
		a.maxSeq = seq
	}
}

// persist writes the session file from what the account holds now. It is called when a key or token arrives.
func (a *account) persist() {
	a.saveLock.Lock()
	defer a.saveLock.Unlock()
	if current() != a {
		return
	}
	s := session{Me: a.me, Name: a.name, Handle: a.handle, Cookies: cookieMap(a.cli.GetCookieString()), MaxSeq: a.getMaxSeq()}
	a.keys.fill(&s)
	if err := saveSession(sessionPath(), s); err != nil {
		log.Err(err).Msg("keep the session")
		return
	}
	a.savedCooks, a.savedSeq = s.Cookies, s.MaxSeq
}

// keepState writes the session again when X has changed a cookie (it turns ct0 over now and then), or the live
// stream has moved on and [always] or a minute has passed.
func (a *account) keepState(always bool) {
	a.noteSeq(a.cli.GetXChatProcessor().MaxHandledSequenceID())
	a.saveLock.Lock()
	changed := !sameCookies(cookieMap(a.cli.GetCookieString()), a.savedCooks) || a.getMaxSeq() != a.savedSeq
	a.saveLock.Unlock()
	if changed || always {
		a.persist()
	}
}

// identity is who is signed in: what `sign_in` answers and the `linked` event carries.
func (a *account) identity() map[string]any {
	return map[string]any{"me": a.me, "name": a.name, "handle": a.handle}
}

// status answers `status`: whether anyone is signed in, whether the live connection is up, and who it is.
func status() map[string]any {
	mu.Lock()
	defer mu.Unlock()
	if acct == nil {
		return map[string]any{"linked": false, "connected": false, "me": "", "name": "", "handle": ""}
	}
	return map[string]any{"linked": true, "connected": connected, "me": acct.me, "name": acct.name, "handle": acct.handle}
}

// signIn takes the browser's cookies, loads x.com's messages page with them (which is also the check that X takes
// them), opens the X Chat keys with the passcode, keeps the session and connects.
func signIn(ctx context.Context, cookies map[string]string, passcode string) (any, error) {
	signLock.Lock()
	defer signLock.Unlock()
	clean, err := cleanCookies(cookies)
	if err != nil {
		return nil, err
	}
	passcode = strings.TrimSpace(passcode)
	if passcode == "" {
		return nil, errors.New(wordsNeedPasscode)
	}
	if !passcodeOK(passcode) {
		return nil, errors.New("The X Chat passcode is four digits.")
	}
	log.Info().Strs("cookies", cookieNames(clean)).Msg("sign in")
	cli := twittermeow.NewClient(xcookies.NewCookies(clean), nil, libLog())
	profile, err := cli.LoadMessagesPage(ctx)
	if err != nil {
		log.Warn().Err(err).Msg("sign in")
		return nil, signInWords(err)
	}
	me := strings.TrimSpace(cmp.Or(profile.ID, cli.GetCurrentUserID()))
	if me == "" {
		return nil, errors.New("X did not say which account these cookies are for: copy the twid cookie too, and try again.")
	}
	cli.SetCurrentUserID(me)
	keys, err := recoverKeys(ctx, cli, me, passcode, libLog())
	if err != nil {
		log.Warn().Err(err).Msg("open the X Chat keys")
		return nil, err
	}
	s := session{Me: me, Name: profile.Name, Handle: profile.ScreenName, Cookies: cookieMap(cli.GetCookieString()), Keys: keys}
	if old := current(); old != nil {
		drop(old)
	}
	if err := saveSession(sessionPath(), s); err != nil {
		log.Err(err).Msg("save session")
		return nil, errors.New("the sign-in could not be kept on this device: " + err.Error())
	}
	a := newAccount(s, cli)
	seen.meet(person{ID: me, Name: s.Name, Handle: s.Handle, Pic: profile.AvatarURL})
	mu.Lock()
	acct = a
	mu.Unlock()
	event("linked", a.identity())
	start(a)
	return a.identity(), nil
}

// unlink forgets the session here. X is not told: its sign-out would end the browser's session too, since the
// cookies are the browser's own.
func unlink() {
	signLock.Lock()
	defer signLock.Unlock()
	if a := current(); a != nil {
		drop(a)
	}
	forgetFiles()
}

// --- requests -------------------------------------------------------------------------------------------------------

// do answers one request within a time limit: a minute, or nearly three for a sign-in or a file. An op that needs a
// session fails without one, and a failure that means X turned the session away ends it (see ended).
func do(r request) (any, error) {
	limit := 60 * time.Second
	if r.Op == "download" || r.Op == "send_media" || r.Op == "sign_in" {
		limit = 170 * time.Second
	}
	ctx, cancel := context.WithTimeout(bg(), limit)
	defer cancel()
	if r.Op != "status" {
		began := time.Now()
		log.Info().Str("op", r.Op).Int64("req", r.ID).Msg("asked")
		defer func() { log.Info().Str("op", r.Op).Int64("req", r.ID).Dur("took", time.Since(began)).Msg("answered") }()
	}
	switch r.Op {
	case "status":
		return status(), nil
	case "sign_in":
		return signIn(ctx, r.Cookies, r.Passcode)
	case "unlink":
		unlink()
		return nil, nil
	}
	if !knownOp(r.Op) {
		return nil, fmt.Errorf("the X helper does not know %q", r.Op)
	}
	a := current()
	if a == nil {
		return nil, errNotLinked
	}
	result, err := a.do(ctx, r)
	if err != nil {
		log.Warn().Err(err).Str("op", r.Op).Int64("req", r.ID).Msg("failed")
		if rejected(err) {
			ended(a, err)
		}
		return nil, plain(err)
	}
	return result, nil
}

// knownOp is whether [op] is one of the ops that need a session: those the account's do answers.
func knownOp(op string) bool {
	switch op {
	case "chats", "history", "send", "send_media", "read", "react", "delete", "download", "who":
		return true
	}
	return false
}

// do runs an op that needs the session. A message's own id (a UUID) is made here, so a file sent with it is
// uploaded under the same id.
func (a *account) do(ctx context.Context, r request) (any, error) {
	switch r.Op {
	case "chats":
		return a.chats(ctx)
	case "history":
		return a.history(ctx, r.Chat, r.Before)
	case "send":
		return a.send(ctx, r, uuid.NewString(), nil)
	case "send_media":
		id := uuid.NewString()
		att, err := a.upload(ctx, r, id)
		if err != nil {
			return nil, err
		}
		return a.send(ctx, r, id, att)
	case "read":
		return nil, a.read(ctx, r.To, r.Upto)
	case "react":
		return nil, a.react(ctx, r.To, r.Target, r.Emoji, r.Remove)
	case "delete":
		return nil, a.unsend(ctx, r.To, r.Target)
	case "download":
		return nil, a.download(ctx, r.Pointer, r.Path)
	case "who":
		return a.who(ctx, r.Who)
	}
	return nil, fmt.Errorf("the X helper does not know %q", r.Op)
}

// --- what this run has seen -----------------------------------------------------------------------------------------

// X's events lean on what its website already holds: a reply wants the quoted message's sender and words, a read mark
// a message id. So the helper remembers, in memory only and for this run, the chats, people and newest messages that
// have passed through it.

// chatNote is what is remembered of a chat.
type chatNote struct {
	group bool
	// A message request not yet answered: answering it accepts it, as the website's reply box does.
	pending bool
	// The newest message id of the chat this run has seen.
	newest string
}

// msgNote is what is remembered of a message: enough to quote it in a reply.
type msgNote struct {
	chat string
	from string
	text string
	ts   int64
	// The sender's own id for the message (a UUID), which a reply names beside the sequence id.
	clientID string
}

// msgNotes is how many messages are remembered before the oldest are let go.
const msgNotes = 5000

// memory is what this run has seen, by id. Its lock guards every field. order is the remembered message ids, oldest
// first: which to let go past msgNotes.
type memory struct {
	sync.Mutex
	chats  map[string]chatNote
	msgs   map[string]msgNote
	order  []string
	people map[string]person
	// What the last `name` event said of each person, so the same thing is not said twice.
	said map[string]string
}

var seen = newMemory()

func newMemory() *memory {
	return &memory{chats: map[string]chatNote{}, msgs: map[string]msgNote{}, people: map[string]person{}, said: map[string]string{}}
}

// reset forgets everything: the session it was seen through is gone.
func (m *memory) reset() {
	m.Lock()
	defer m.Unlock()
	m.chats, m.msgs, m.order = map[string]chatNote{}, map[string]msgNote{}, nil
	m.people, m.said = map[string]person{}, map[string]string{}
}

func (m *memory) chat(id string) (chatNote, bool) {
	m.Lock()
	defer m.Unlock()
	n, ok := m.chats[id]
	return n, ok
}

// noteChat remembers a chat, keeping the newest message id already known of it where that one is later.
func (m *memory) noteChat(id string, n chatNote) {
	m.Lock()
	defer m.Unlock()
	if old, ok := m.chats[id]; ok && compareSeq(old.newest, n.newest) > 0 {
		n.newest = old.newest
	}
	m.chats[id] = n
}

func (m *memory) msg(id string) (msgNote, bool) {
	m.Lock()
	defer m.Unlock()
	n, ok := m.msgs[id]
	return n, ok
}

// noteMsg remembers a message, and says whether it was new to this run.
func (m *memory) noteMsg(id string, n msgNote) bool {
	if id == "" {
		return false
	}
	m.Lock()
	defer m.Unlock()
	_, had := m.msgs[id]
	m.msgs[id] = n
	if !had {
		m.order = append(m.order, id)
		if len(m.order) > msgNotes {
			delete(m.msgs, m.order[0])
			m.order = m.order[1:]
		}
	}
	if c, ok := m.chats[n.chat]; ok && isDigits(id) && compareSeq(id, c.newest) > 0 {
		c.newest = id
		m.chats[n.chat] = c
	}
	return !had
}

// meet remembers a person, keeping what is already known where this sighting has nothing.
func (m *memory) meet(p person) {
	if p.ID == "" {
		return
	}
	m.Lock()
	defer m.Unlock()
	if old, ok := m.people[p.ID]; ok {
		p = merge(old, p)
	}
	m.people[p.ID] = p
}

func (m *memory) person(id string) (person, bool) {
	m.Lock()
	defer m.Unlock()
	p, ok := m.people[id]
	return p, ok
}

// known is what is known of [p], it included; [p] itself where nothing is.
func (m *memory) known(p person) person {
	if old, ok := m.person(p.ID); ok {
		return merge(old, p)
	}
	return p
}

// newsOf is whether [p] differs from what was last said of them, noting it as said.
func (m *memory) newsOf(p person) bool {
	sig := p.Name + "\n" + p.Handle + "\n" + p.Pic
	m.Lock()
	defer m.Unlock()
	if m.said[p.ID] == sig {
		return false
	}
	m.said[p.ID] = sig
	return true
}

// nameOf is what to call the person [id]: their name, else their handle, "" where this run has not met them.
func nameOf(id string) string {
	p, _ := seen.person(id)
	return cmp.Or(p.Name, p.Handle)
}

// learnPeople asks X for the people of [ids] that this run does not yet know by name.
func (a *account) learnPeople(ctx context.Context, ids []string) {
	var missing []string
	done := map[string]bool{}
	for _, id := range ids {
		if id == "" || done[id] {
			continue
		}
		done[id] = true
		if p, ok := seen.person(id); !ok || p.Handle == "" || p.Name == "" {
			missing = append(missing, id)
		}
	}
	for len(missing) > 0 {
		batch := missing[:min(len(missing), 100)]
		missing = missing[len(batch):]
		resp, err := a.cli.GetUsersByIdsForXChat(ctx, payload.NewGetUsersByIdsForXChatVariables(batch))
		if err != nil {
			log.Warn().Err(err).Int("people", len(batch)).Msg("look people up")
			return
		}
		for _, r := range resp.Data.GetMemberResults.Results {
			if r.MemberResults != nil {
				seen.meet(personOfResult(*r.MemberResults))
			}
		}
	}
}

// --- avatars --------------------------------------------------------------------------------------------------------

// avatarDir is where people's pictures are kept once fetched.
func avatarDir() string { return filepath.Join(dir, "avatars") }

// nullable is [s], or JSON's null where it is empty.
func nullable(s string) any {
	if s == "" {
		return nil
	}
	return s
}

// avatarName names a person's cached picture: X gives a new address when the picture changes.
func avatarName(who person) string {
	sum := sha256.Sum256([]byte(who.ID + "\n" + avatarURL(who.Pic)))
	return hex.EncodeToString(sum[:12])
}

// publicPicture is whether [u] is one of X's public picture addresses, which need no cookies.
func publicPicture(u string) bool {
	p, err := url.Parse(u)
	return err == nil && p.Scheme == "https" && (p.Host == "pbs.twimg.com" || p.Host == "abs.twimg.com")
}

// avatar is a person's picture as a file under avatars/, fetched once; "" where there is none or it can't be had.
func (a *account) avatar(ctx context.Context, who person) string {
	src := avatarURL(who.Pic)
	if who.ID == "" || !publicPicture(src) {
		return ""
	}
	p := filepath.Join(avatarDir(), avatarName(who))
	if _, err := os.Stat(p); err == nil {
		return p
	}
	ctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, src, nil)
	if err != nil {
		return ""
	}
	req.Header.Set("User-Agent", a.cli.GetUserAgent())
	req.Header.Set("Accept", "image/*")
	resp, err := a.cli.HTTP.Do(req)
	if err != nil {
		return ""
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, 4<<20+1))
	if err != nil || resp.StatusCode != http.StatusOK || len(data) == 0 || len(data) > 4<<20 {
		return ""
	}
	_ = os.MkdirAll(avatarDir(), 0o700)
	if os.WriteFile(p, data, 0o600) != nil {
		return ""
	}
	return p
}

// sayName tells the app of someone met in a message, once for each thing known of them.
func (a *account) sayName(who person) {
	if who.ID == "" {
		return
	}
	if p, ok := seen.person(who.ID); !ok || p.Name == "" {
		a.learnPeople(bg(), []string{who.ID})
	}
	who = seen.known(who)
	if who.Name == "" && who.Handle == "" || !seen.newsOf(who) {
		return
	}
	event("name", map[string]any{"id": who.ID, "name": who.Name, "handle": who.Handle, "avatar": nullable(a.avatar(bg(), who))})
}

// who answers `who`: the person with an X user id, asked of X where this run does not know them.
func (a *account) who(ctx context.Context, id string) (any, error) {
	id = strings.TrimSpace(id)
	if id == "" {
		return nil, errors.New("no one was asked for")
	}
	if !isDigits(id) {
		return nil, errors.New("that is not an X user id")
	}
	a.learnPeople(ctx, []string{id})
	who, ok := seen.person(id)
	if !ok || who.Name == "" && who.Handle == "" {
		return nil, errors.New("X did not say who that is")
	}
	return map[string]any{"id": who.ID, "name": who.Name, "handle": who.Handle, "avatar": nullable(a.avatar(ctx, who))}, nil
}

// --- chats ----------------------------------------------------------------------------------------------------------

// collectKey is the context key a collector travels under: onEvent hands the events of a context that carries one
// to it, and says nothing to the app.
type collectKey struct{}

// collector gathers what the events listed with a chat say of it, as the library hands them over: the newest
// message, the others' messages and the person's own read mark.
type collector struct {
	sync.Mutex
	me     string
	latest *types.Message
	others []string
	myRead string
	newest string
}

// add takes one of the chat's events: a message or a read mark. Anything else is passed over.
func (c *collector) add(evt types.TwitterEvent) {
	c.Lock()
	defer c.Unlock()
	switch e := evt.(type) {
	case *types.Message:
		seq := cmp.Or(e.SequenceID, e.ID)
		if compareSeq(seq, c.newest) > 0 {
			c.newest = seq
		}
		if c.latest == nil || compareSeq(seq, cmp.Or(c.latest.SequenceID, c.latest.ID)) > 0 {
			c.latest = e
		}
		if e.MessageData.SenderID == c.me {
			// Answering is reading: x.com marks a chat read when the person writes in it.
			if compareSeq(seq, c.myRead) > 0 {
				c.myRead = seq
			}
		} else {
			c.others = append(c.others, seq)
		}
	case *types.ConversationRead:
		if e.SenderID == c.me && compareSeq(e.LastReadEventID, c.myRead) > 0 {
			c.myRead = e.LastReadEventID
		}
	}
}

// summary is what was gathered: unread counts the others' messages that come after the person's own read mark.
func (c *collector) summary() inboxSummary {
	c.Lock()
	defer c.Unlock()
	s := inboxSummary{latest: c.latest, newest: c.newest}
	for _, seq := range c.others {
		if compareSeq(seq, c.myRead) > 0 {
			s.unread++
		}
	}
	return s
}

// chatFromItem reads one inbox item: the keys it carries are stored, its events opened for the newest message and
// what is unread, its people noted, and the chat put into the protocol's shape.
func (a *account) chatFromItem(ctx context.Context, item *response.XChatInboxItem) chatOut {
	conv := normalizeChat(item.ConversationDetail.ConversationID)
	item.ConversationDetail.ConversationID = conv
	processor := a.cli.GetXChatProcessor()
	if err := processor.ProcessKeyChangeEvents(ctx, item); err != nil {
		log.Warn().Err(err).Str("chat", conv).Msg("store the chat's keys")
	}
	col := &collector{me: a.me}
	if err := processor.ProcessMessageAndReadEvents(context.WithValue(ctx, collectKey{}, col), item); err != nil {
		log.Warn().Err(err).Str("chat", conv).Msg("open the chat's newest events")
	}
	sum := col.summary()
	for _, p := range peopleOfItem(item) {
		seen.meet(p)
	}
	group := itemIsGroup(item)
	name := ""
	if group && item.ConversationDetail.GroupMetadata != nil {
		name = decryptGroupName(ctx, conv, item.ConversationDetail.GroupMetadata.GroupName, a.keys.GetConversationKey,
			func(ctx context.Context, conv, _ string) (*crypto.ConversationKey, error) {
				return a.keys.GetLatestConversationKey(ctx, conv)
			})
	}
	trusted := itemTrusted(item)
	seen.noteChat(conv, chatNote{group: group, pending: trusted != nil && !*trusted, newest: sum.newest})
	if m := sum.latest; m != nil {
		seq := cmp.Or(m.SequenceID, m.ID)
		seen.noteMsg(seq, msgNote{chat: conv, from: m.MessageData.SenderID, text: m.MessageData.Text, ts: ms(m.Time), clientID: m.RequestID})
	}
	return chatOf(a.me, item, seen.known, name, sum, func(p person) string { return a.avatar(ctx, p) })
}

// takeInbox reads a page of X's inbox into `chat`s, in its order, and says each as a `chat` event. [live] also
// passes on the page's messages and marks as events (after a reconnect: what came while away).
func (a *account) takeInbox(ctx context.Context, page response.XChatInboxPage, live bool) []chatOut {
	var ids []string
	for i := range page.Items {
		for _, p := range peopleOfItem(&page.Items[i]) {
			seen.meet(p)
			ids = append(ids, p.ID)
		}
		if parts, ok := dmMembers(page.Items[i].ConversationDetail.ConversationID); ok {
			ids = append(ids, parts...)
		}
	}
	a.learnPeople(ctx, ids)

	list := make([]chatOut, len(page.Items))
	var wg sync.WaitGroup
	gate := make(chan struct{}, 4)
	for i := range page.Items {
		if page.Items[i].ConversationDetail.ConversationID == "" {
			continue
		}
		wg.Add(1)
		go func() {
			defer wg.Done()
			gate <- struct{}{}
			defer func() { <-gate }()
			list[i] = a.chatFromItem(ctx, &page.Items[i])
			if live {
				if err := a.cli.GetXChatProcessor().ProcessMessageAndReadEvents(ctx, &page.Items[i]); err != nil {
					log.Warn().Err(err).Msg("pass on what came while away")
				}
			}
		}()
	}
	wg.Wait()
	kept := []chatOut{}
	for _, c := range list {
		if c.ID != "" {
			kept = append(kept, c)
			event("chat", fields(c))
		}
	}
	if page.MaxUserSequenceID != nil {
		a.noteSeq(*page.MaxUserSequenceID)
	}
	a.noteSeq(a.cli.GetXChatProcessor().MaxHandledSequenceID())
	return kept
}

// chats is the newest chats of the inbox, as x.com's Messages page first lists them.
func (a *account) chats(ctx context.Context) (any, error) {
	a.syncLock.Lock()
	defer a.syncLock.Unlock()
	resp, err := a.cli.GetInitialXChatPage(ctx, payload.NewInitialXChatPageQueryVariables(""))
	if err != nil {
		return nil, err
	}
	list := a.takeInbox(ctx, resp.Data.GetInboxPage, false)
	go a.keepState(false)
	return list, nil
}

// syncChats lists the newest chats as `chat` events. It is also how a saved session is checked when it starts.
func (a *account) syncChats(ctx context.Context) {
	if current() != a {
		return
	}
	if _, err := a.chats(ctx); err != nil {
		log.Warn().Err(err).Msg("list the chats")
		if rejected(err) {
			ended(a, err)
		}
	}
}

// refreshChat asks X for one chat and says it as a `chat` event: one the app has not been told of, or one whose
// name or people changed.
func (a *account) refreshChat(ctx context.Context, conv string) {
	resp, err := a.cli.GetConversationData(ctx, payload.NewInboxPageConversationDataQueryVariables(conv, true))
	if err != nil {
		log.Warn().Err(err).Str("chat", conv).Msg("look the chat up")
		return
	}
	item := resp.Data.GetInboxPageConversationData.Data
	if item.ConversationDetail.ConversationID == "" {
		item.ConversationDetail.ConversationID = conv
	}
	var ids []string
	for _, p := range peopleOfItem(&item) {
		seen.meet(p)
		ids = append(ids, p.ID)
	}
	if parts, ok := dmMembers(conv); ok {
		ids = append(ids, parts...)
	}
	a.learnPeople(ctx, ids)
	c := a.chatFromItem(ctx, &item)
	event("chat", fields(c))
}

// onConnect runs each time the live connection is made, before it is read: what came while it was down is passed
// on. A fresh session has nothing to catch up on: `chats` gave the newest.
func (a *account) onConnect(ctx context.Context) error {
	setConnected(a, true)
	seq := a.getMaxSeq()
	if seq == "" {
		return nil
	}
	resp, err := a.cli.GetInitialXChatPage(ctx, payload.NewInitialXChatPageQueryVariables(seq))
	if err != nil {
		// Not the connection's fault: say what comes next, and let the app ask for the chats again.
		log.Warn().Err(err).Msg("catch up after connecting")
		return nil
	}
	page := resp.Data.GetInboxPage
	for range 5 {
		a.takeInbox(ctx, page, true)
		next := page.InboxCursor
		if next.PullFinished || next.CursorID == "" || next.GraphSnapshotID == "" {
			break
		}
		more, err := a.cli.GetInboxPageRequest(ctx, payload.NewInboxPageRequestQueryVariables(&payload.XChatCursor{CursorId: next.CursorID, GraphSnapshotId: next.GraphSnapshotID}))
		if err != nil {
			log.Warn().Err(err).Msg("catch up after connecting")
			break
		}
		page = more.Data.GetInboxPage
	}
	return nil
}

// --- history --------------------------------------------------------------------------------------------------------

// storeKeyChange opens a chat key X sends sealed for the person, and keeps it.
func (a *account) storeKeyChange(ctx context.Context, evt *payload.MessageEvent) error {
	ck := evt.Detail.ConversationKeyChangeEvent
	conv, version := normalizeChat(ptr.Val(evt.ConversationId)), ptr.Val(ck.ConversationKeyVersion)
	if conv == "" || version == "" {
		return errors.New("a key change without its chat or version")
	}
	if _, err := a.keys.GetConversationKey(ctx, conv, version); err == nil {
		return nil
	}
	own, err := a.keys.GetOwnSigningKey(ctx)
	if err != nil || own.DecryptKeyB64 == "" {
		return errors.New("the X Chat keys are missing")
	}
	sealed := ""
	for _, pk := range ck.ConversationParticipantKeys {
		if ptr.Val(pk.UserId) == a.me {
			sealed = ptr.Val(pk.EncryptedConversationKey)
			break
		}
	}
	if sealed == "" {
		return nil
	}
	key, err := crypto.UnwrapConversationKey(sealed, own.DecryptKeyB64)
	if err != nil {
		return err
	}
	at := methods.ParseMsecTimestamp(ptr.Val(evt.CreatedAtMsec))
	if at.IsZero() {
		at = time.Now()
	}
	return a.keys.PutConversationKey(ctx, &crypto.ConversationKey{ConversationID: conv, KeyVersion: version, Key: key, CreatedAt: at})
}

// takeKeys stores the keys and tokens a page of history carries.
func (a *account) takeKeys(ctx context.Context, conv string, encoded ...[]string) {
	for _, list := range encoded {
		for _, e := range list {
			evt, err := twittermeow.DecodeMessageEvent(e)
			if err != nil || evt == nil {
				continue
			}
			if c := ptr.Val(evt.ConversationId); c == "" || normalizeChat(c) == conv {
				evt.ConversationId = ptr.Ptr(conv)
				if t := ptr.Val(evt.ConversationToken); t != "" {
					_ = a.keys.PutConversationToken(ctx, conv, t)
				}
				if evt.Detail != nil && evt.Detail.ConversationKeyChangeEvent != nil {
					if err := a.storeKeyChange(ctx, evt); err != nil {
						log.Warn().Err(err).Str("chat", conv).Msg("store a chat key")
					}
				}
			}
		}
	}
}

// history is a page of a chat's messages older than [before] (the newest, with none), oldest first.
func (a *account) history(ctx context.Context, chat, before string) (any, error) {
	conv := normalizeChat(chat)
	if conv == "" {
		return nil, errors.New("no chat was asked for")
	}
	before = strings.TrimSpace(before)
	if before != "" && !isDigits(before) {
		return nil, errors.New("that is not an X message id: history pages back from a message's id")
	}
	fetch := func() (response.XChatConversationPage, error) {
		settings := payload.DefaultGetConversationPageQuerySettings()
		settings.ConversationEventLimit = historyEvents
		minKey := maxSeqAll
		if k, err := a.keys.GetLatestConversationKey(ctx, conv); err == nil && k.KeyVersion != "" {
			minKey = k.KeyVersion
		}
		resp, err := a.cli.GetConversationPage(ctx, payload.NewGetConversationPageQueryVariables(conv, cmp.Or(before, maxSeqAll), minKey, settings))
		if err != nil {
			return response.XChatConversationPage{}, err
		}
		return resp.Data.GetConversationPage, nil
	}
	page, err := fetch()
	if err != nil {
		return nil, err
	}
	a.takeKeys(ctx, conv, page.MissingConversationKeyChangeEvents, page.EncodedMessageEvents)
	note, _ := seen.chat(conv)
	group := note.group || isGroupChat(conv)
	res := parsePage(ctx, a.me, conv, group, page.EncodedMessageEvents, before, a.keys.GetConversationKey, nameOf)
	if res.unread > 0 {
		// Messages sealed with a key X has not sent with the page: ask for the chat's keys once, and read again.
		if err := a.cli.RefreshConversationKeys(ctx, conv); err != nil {
			log.Warn().Err(err).Str("chat", conv).Msg("fetch the chat's keys")
		}
		res = parsePage(ctx, a.me, conv, group, page.EncodedMessageEvents, before, a.keys.GetConversationKey, nameOf)
		if res.unread > 0 {
			log.Warn().Int("messages", res.unread).Str("chat", conv).Msg("messages that could not be opened")
		}
	}
	var senders []string
	for _, m := range res.messages {
		senders = append(senders, m.From)
	}
	a.learnPeople(ctx, senders)
	for i := range res.messages {
		m := &res.messages[i]
		m.Name = nameOf(m.From)
		seen.noteMsg(m.ID, msgNote{chat: conv, from: m.From, text: m.Text, ts: m.TS})
	}
	go func() {
		for _, id := range senders {
			a.sayName(person{ID: id})
		}
	}()
	more := page.HasMore && res.oldest != "" && res.oldest != before
	return map[string]any{"messages": res.messages, "more": more}, nil
}

// --- sending --------------------------------------------------------------------------------------------------------

// sealed is whether what is sent to [conv] is encrypted: the chat has a key here. A chat with only a token is one of
// X Chat's unencrypted ones (signed, not sealed). A chat with neither is looked up first.
func (a *account) sealed(ctx context.Context, conv string) bool {
	if !a.keys.hasKeys(conv) && !a.keys.hasToken(conv) {
		if err := a.cli.RefreshConversationKeys(ctx, conv); err != nil {
			log.Warn().Err(err).Str("chat", conv).Msg("fetch the chat's keys")
		}
	}
	return a.keys.hasKeys(conv)
}

// replyTo is the reply X wants: the quoted message's ids with its sender and words, from what this run has seen of
// it or else from what the app sent along.
func replyTo(q quote) *payload.ReplyingToPreview {
	if q.ID == "" {
		return nil
	}
	clientID := q.ID
	if n, ok := seen.msg(q.ID); ok {
		q.Author, q.Text = cmp.Or(n.from, q.Author), cmp.Or(n.text, q.Text)
		clientID = cmp.Or(n.clientID, q.ID)
	}
	p := &payload.ReplyingToPreview{ReplyingToMessageId: ptr.Ptr(clientID), ReplyingToMessageSequenceId: ptr.Ptr(q.ID)}
	if q.Text != "" {
		p.MessageText = ptr.Ptr(q.Text)
	}
	var sender int64
	if _, err := fmt.Sscan(q.Author, &sender); err == nil && sender > 0 {
		p.SenderId = &sender
		if n := nameOf(q.Author); n != "" {
			p.SenderDisplayName = ptr.Ptr(n)
		}
	}
	return p
}

// sendFailure says why X turned a message away.
func sendFailure(f *payload.MessageFailureEvent) error {
	switch payload.FailureType(ptr.Val(f.FailureType)) {
	case payload.FailureTypeContentsTooLarge:
		return errors.New("X turned the message away: it is too large.")
	case payload.FailureTypeRecipientHasNotTrustedConversation:
		return errors.New("X turned the message away: they have not accepted this chat yet.")
	case payload.FailureTypeInvalidSenderSignature, payload.FailureTypeSignatureVerificationFailed, payload.FailureTypeInvalidSignatureVersion:
		return errors.New("X turned the message away: it did not accept its signature. Sign in again to refresh the X Chat keys.")
	}
	return fmt.Errorf("X turned the message away (failure %d).", ptr.Val(f.FailureType))
}

// send answers `send`, and `send_media` once the file is uploaded ([att]): sealed where the chat has a key, signed
// only where it has not. [messageID] is the message's own id (a UUID); the answer carries the sequence id X gave it,
// which is the id the app knows it by.
func (a *account) send(ctx context.Context, r request, messageID string, att *payload.MessageAttachment) (any, error) {
	to := normalizeChat(r.To)
	if to == "" {
		return nil, errors.New("no chat to send to")
	}
	if r.Text == "" && att == nil {
		return nil, errors.New("nothing to send")
	}
	encrypted := a.sealed(ctx, to)
	if note, ok := seen.chat(to); ok && note.pending {
		// As the website's reply box does: answering a message request accepts it.
		if err := a.cli.AcceptConversation(ctx, to); err != nil && !errors.Is(err, twittermeow.ErrConversationDoesntExist) {
			log.Warn().Err(err).Msg("accept the message request")
		} else {
			note.pending = false
			seen.noteChat(to, note)
		}
	}
	opts := twittermeow.SendEncryptedMessageOpts{ConversationID: to, MessageID: messageID, Text: r.Text}
	if att != nil {
		opts.Attachments = []*payload.MessageAttachment{att}
	}
	if r.Quote != nil {
		opts.ReplyTo = replyTo(*r.Quote)
	}
	var resp *response.SendMessageMutationResponse
	var err error
	if encrypted {
		resp, err = a.cli.SendEncryptedMessage(ctx, opts)
	} else {
		resp, err = a.cli.SendUnencryptedMessage(ctx, opts)
	}
	if err != nil {
		return nil, err
	}
	evt, err := twittermeow.DecodeSendMessageMutationMessageEvent(resp.Data.XChatSendCreateMessageEvent.EncodedMessageEvent)
	if err != nil {
		return nil, errors.New("X took the message but its answer could not be read")
	}
	if evt.Detail != nil && evt.Detail.MessageFailureEvent != nil {
		return nil, sendFailure(evt.Detail.MessageFailureEvent)
	}
	id := ptr.Val(evt.SequenceId)
	if id == "" {
		return nil, errors.New("X took the message but did not say its id")
	}
	ts := ms(ptr.Val(evt.CreatedAtMsec))
	if ts == 0 {
		ts = time.Now().UnixMilli()
	}
	seen.noteMsg(id, msgNote{chat: to, from: a.me, text: r.Text, ts: ts, clientID: messageID})
	return map[string]any{"id": id, "ts": ts}, nil
}

// upload hands X a file and gives the attachment a message needs to carry it: a picture, a GIF, a video, or a voice
// message (which X wants as an MP4 file with a picture track: made with ffmpeg, where it is installed).
func (a *account) upload(ctx context.Context, r request, messageID string) (*payload.MessageAttachment, error) {
	to := normalizeChat(r.To)
	if to == "" {
		return nil, errors.New("no chat to send to")
	}
	st, err := os.Stat(r.Path)
	if err != nil {
		return nil, errors.New("the file could not be opened: " + err.Error())
	}
	if st.IsDir() || st.Size() == 0 {
		return nil, errors.New("the file is empty or cannot be read")
	}
	if st.Size() > maxUpload {
		return nil, fmt.Errorf("the file is too large to send here (%d MB at most)", maxUpload>>20)
	}
	data, err := os.ReadFile(r.Path)
	if err != nil {
		return nil, errors.New("the file could not be read: " + err.Error())
	}
	name := cmp.Or(r.Name, filepath.Base(r.Path))
	mimeType := strings.ToLower(cmp.Or(r.Mime, mimeOf("", name)))
	kind, category := payload.MediaTypeImage, payload.MEDIA_CATEGORY_DM_IMAGE
	switch {
	case mimeType == "image/gif":
		kind, category = payload.MediaTypeImage, payload.MEDIA_CATEGORY_DM_GIF
	case strings.HasPrefix(mimeType, "image/"):
	case strings.HasPrefix(mimeType, "video/"):
		kind, category = payload.MediaTypeVideo, payload.MEDIA_CATEGORY_DM_VIDEO
	case strings.HasPrefix(mimeType, "audio/"):
		converted, err := a.cli.ConvertAudioPayload(ctx, data, mimeType)
		if err != nil {
			return nil, errors.New("voice messages need ffmpeg on this device to be sent to X: " + err.Error())
		}
		data, mimeType = converted, "video/mp4"
		kind, category = payload.MediaTypeAudio, payload.MEDIA_CATEGORY_DM_VIDEO
	default:
		return nil, errors.New("X sends only pictures, GIFs, videos and voice messages, not other files")
	}
	var width, height int64
	if cfg, _, err := image.DecodeConfig(bytes.NewReader(data)); err == nil {
		width, height = int64(cfg.Width), int64(cfg.Height)
	}
	size := int64(len(data))
	media := &payload.MediaAttachment{
		Type:          ptr.Ptr(int32(kind)),
		Dimensions:    &payload.MediaDimensions{Width: &width, Height: &height},
		FilesizeBytes: &size,
		Filename:      ptr.Ptr(name),
	}
	if a.sealed(ctx, to) {
		up, err := a.cli.UploadXChatMedia(ctx, to, messageID, data)
		if err != nil {
			return nil, err
		}
		media.MediaHashKey = ptr.Ptr(up.MediaHashKey)
	} else {
		up, err := a.cli.UploadMedia(ctx, &payload.UploadMediaQuery{MediaType: mimeType, MediaCategory: category}, data)
		if err != nil {
			return nil, err
		}
		media.MediaHashKey = ptr.Ptr(up.MediaKey)
		media.AttachmentId = ptr.Ptr(up.MediaIDString)
		if up.Size > 0 {
			size = int64(up.Size)
		}
	}
	return &payload.MessageAttachment{Media: media}, nil
}

// --- marks, reactions, taking back ----------------------------------------------------------------------------------

// read marks [to] read up to message [upto], or up to the newest message this run has seen of it.
func (a *account) read(ctx context.Context, to, upto string) error {
	to = normalizeChat(to)
	if to == "" {
		return errors.New("no chat to mark read")
	}
	if !isDigits(upto) {
		note, _ := seen.chat(to)
		upto = note.newest
	}
	if upto == "" {
		return errors.New("no message to mark read up to: give `upto`, or list the chat's history first")
	}
	err := a.cli.SendXChatReadReceipt(ctx, to, upto, time.Now())
	if err != nil && (errors.Is(err, crypto.ErrKeyNotFound) || errors.Is(err, twittermeow.ErrXChatWebsocketNotConnected)) {
		// As mautrix-twitter does when X Chat cannot carry the mark: the older API's mark.
		return a.cli.MarkConversationRead(ctx, &payload.MarkConversationReadQuery{ConversationID: restChat(to), LastReadEventID: upto})
	}
	return err
}

// restChat is a chat id as X's older API writes it ("<id>-<id>").
func restChat(id string) string {
	if isGroupChat(id) {
		return id
	}
	return strings.ReplaceAll(id, ":", "-")
}

// react adds or takes back a reaction: through X Chat in an encrypted chat, through X's older API (with its form
// of the chat id) in the others.
func (a *account) react(ctx context.Context, to, target, emoji string, remove bool) error {
	to = normalizeChat(to)
	if to == "" || target == "" || emoji == "" {
		return errors.New("a reaction needs a chat, a message and an emoji")
	}
	emoji = variationselector.FullyQualify(emoji)
	if a.sealed(ctx, to) {
		_, err := a.cli.SendEncryptedReaction(ctx, to, target, emoji, remove)
		return err
	}
	resp, err := a.cli.React(ctx, &payload.ReactionActionPayload{ConversationID: restChat(to), MessageID: target, ReactionTypes: []string{"Emoji"}, EmojiReactions: []string{emoji}}, remove)
	if err != nil {
		return err
	}
	if !remove && resp.Data.CreateDmReaction.Typename == "CreateDMReactionFailure" || remove && resp.Data.DeleteDmReaction.Typename == "DeleteDMReactionFailure" {
		return errors.New("X did not take the reaction")
	}
	return nil
}

// unsend takes the person's own message back for everyone. X allows it in its encrypted chats; in the others its
// website can only hide a message from the person themselves, which is not what `delete` means.
func (a *account) unsend(ctx context.Context, to, target string) error {
	to = normalizeChat(to)
	if to == "" || target == "" {
		return errors.New("no message to delete")
	}
	if !isDigits(target) {
		return errors.New("that is not an X message id")
	}
	if !a.sealed(ctx, to) {
		return errors.New("X takes messages back for everyone only in its encrypted chats; this chat is not one")
	}
	return a.cli.DeleteXChatMessage(ctx, twittermeow.DeleteXChatMessageOpts{ConversationID: to, SequenceIDs: []string{target}, DeleteForAll: true})
}

// --- files ----------------------------------------------------------------------------------------------------------

// xHost is whether [host] is one of X's own.
func xHost(host string) bool {
	for _, h := range []string{"twimg.com", "x.com", "twitter.com"} {
		if host == h || strings.HasSuffix(host, "."+h) {
			return true
		}
	}
	return false
}

// parsePointer reads a `download`'s pointer: the object a message gave, or that object as a string.
func parsePointer(raw json.RawMessage) (pointer, error) {
	var p pointer
	var inner string
	if json.Unmarshal(raw, &inner) == nil {
		raw = json.RawMessage(inner)
	}
	bad := errors.New("that is not an X file")
	if err := json.Unmarshal(raw, &p); err != nil {
		return p, bad
	}
	switch {
	case p.Conv != "" && p.Hash != "":
		if strings.ContainsAny(p.Conv+p.Hash, "/?#\\") {
			return p, bad
		}
		p.Conv = normalizeChat(p.Conv)
		return p, nil
	case p.URL != "":
		u, err := url.Parse(p.URL)
		if err != nil || u.Scheme != "https" || !xHost(u.Hostname()) {
			return p, bad
		}
		return p, nil
	}
	return p, bad
}

// download writes a message's file to [path], whole or not at all: opened with the chat's key where it is sealed.
func (a *account) download(ctx context.Context, raw json.RawMessage, path string) error {
	p, err := parsePointer(raw)
	if err != nil {
		return err
	}
	if path == "" {
		return errors.New("nowhere to write the file")
	}
	tmp := path + ".part"
	f, err := os.OpenFile(tmp, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
	if err != nil {
		return errors.New("the file could not be written: " + err.Error())
	}
	if p.Hash != "" {
		_, err = a.cli.DownloadXChatMedia(ctx, p.Conv, p.Hash, p.Version, f)
		if errors.Is(err, crypto.ErrKeyNotFound) {
			if rerr := a.cli.RefreshConversationKeys(ctx, p.Conv); rerr == nil {
				_ = f.Truncate(0)
				_, _ = f.Seek(0, io.SeekStart)
				_, err = a.cli.DownloadXChatMedia(ctx, p.Conv, p.Hash, p.Version, f)
			}
		}
	} else {
		err = a.fetch(ctx, p.URL, f)
	}
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		_ = os.Remove(tmp)
		switch statusOf(err) {
		case http.StatusNotFound, http.StatusGone:
			return errors.New("X no longer has this file.")
		}
		return err
	}
	return os.Rename(tmp, path)
}

// fetch writes what an address of X's holds into [w]: as a browser fetches it, with the cookies where it is not one
// of X's public addresses.
func (a *account) fetch(ctx context.Context, u string, w io.Writer) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return err
	}
	if host := req.URL.Hostname(); host == "pbs.twimg.com" || host == "video.twimg.com" || host == "abs.twimg.com" {
		req.Header.Set("User-Agent", a.cli.GetUserAgent())
		req.Header.Set("Accept", "*/*")
	} else {
		req.Header = a.cli.GetBaseHeaders()
		req.Header.Set("Cookie", a.cli.GetCookieString())
	}
	resp, err := a.cli.HTTP.Do(req)
	if err != nil {
		return fmt.Errorf("%w: %w", twittermeow.ErrRequestFailed, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 400 {
		return fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	_, err = io.Copy(w, resp.Body)
	return err
}

// --- what X says, live ----------------------------------------------------------------------------------------------

// onEvent is the library's handler for X Chat's events, opened and turned into its own types. While a chat is being
// read for the inbox, the events go to that chat's collector instead of the app. It answers true: an event the app
// has no use for is not an error.
func (a *account) onEvent(ctx context.Context, evt types.TwitterEvent) bool {
	if col, ok := ctx.Value(collectKey{}).(*collector); ok {
		col.add(evt)
		return true
	}
	if current() != a {
		return true
	}
	switch e := evt.(type) {
	case *types.Message:
		a.onMessage(ctx, e)
	case *types.MessageEdit:
		chat, target := normalizeChat(e.ConversationID), e.MessageData.ID
		if chat != "" && target != "" {
			if n, ok := seen.msg(target); ok {
				n.text = e.MessageData.Text
				seen.noteMsg(target, n)
			}
			event("edited", map[string]any{"chat": chat, "target": target, "text": e.MessageData.Text})
		}
	case *types.MessageDelete:
		chat := normalizeChat(e.ConversationID)
		for _, m := range e.Messages {
			if id := cmp.Or(m.MessageID, m.MessageCreateEventID); chat != "" && id != "" {
				event("deleted", map[string]any{"chat": chat, "target": id})
			}
		}
	case *types.MessageReactionCreate:
		a.onReaction((*types.MessageReaction)(e), false)
	case *types.MessageReactionDelete:
		a.onReaction((*types.MessageReaction)(e), true)
	case *types.ConversationRead:
		chat := normalizeChat(e.ConversationID)
		if chat != "" && e.SenderID != "" {
			ev := map[string]any{"chat": chat, "from": e.SenderID, "id": e.LastReadEventID, "kind": "read"}
			if t := ms(e.Time); t > 0 {
				ev["ts"] = t
			}
			event("receipt", ev)
		}
	case *types.ConversationCreate:
		a.refreshChat(ctx, normalizeChat(e.ConversationID))
	case *types.ConversationNameUpdate:
		go a.refreshChat(a.live, normalizeChat(e.ConversationID))
	case *types.ConversationAvatarUpdate:
		go a.refreshChat(a.live, normalizeChat(e.ConversationID))
	case *types.ParticipantsJoin:
		go a.refreshChat(a.live, normalizeChat(e.ConversationID))
	case *types.ParticipantsLeave:
		go a.refreshChat(a.live, normalizeChat(e.ConversationID))
	case *types.ConversationDelete:
		// The protocol has no word for a chat removed on the website; the app keeps what it has.
		log.Info().Msg("a chat was deleted on X")
	case *types.XChatMessageFailure:
		log.Warn().Int32("failure", int32(e.FailureType)).Msg("X turned a message away")
	}
	return true
}

// onMessage says a message as a `message` event, once: one this run has already passed on is dropped.
func (a *account) onMessage(ctx context.Context, m *types.Message) {
	chat := normalizeChat(m.ConversationID)
	id := cmp.Or(m.SequenceID, m.ID)
	if chat == "" || id == "" {
		return
	}
	if _, known := seen.chat(chat); !known {
		// The first message of a chat the app has not been told of: the chat first.
		a.refreshChat(ctx, chat)
	}
	sender := m.MessageData.SenderID
	if !seen.noteMsg(id, msgNote{chat: chat, from: sender, text: m.MessageData.Text, ts: ms(m.Time), clientID: m.RequestID}) {
		return
	}
	note, _ := seen.chat(chat)
	out := messageOf(a.me, chat, note.group || isGroupChat(chat), m, nameOf)
	event("message", fields(out))
	a.noteSeq(id)
	go a.sayName(person{ID: sender})
}

// onReaction says a reaction added or taken back as a `reaction` event.
func (a *account) onReaction(r *types.MessageReaction, remove bool) {
	chat := normalizeChat(r.ConversationID)
	if chat == "" || r.MessageID == "" || r.SenderID == "" || r.EmojiReaction == "" {
		return
	}
	event("reaction", map[string]any{"chat": chat, "from": r.SenderID, "target": r.MessageID, "emoji": r.EmojiReaction, "remove": remove})
}

// --- the log file ---------------------------------------------------------------------------------------------------

// logFile is twitter.log in the session's folder, begun afresh past a megabyte; standard error alone where it can't
// open.
func logFile() *os.File {
	path := filepath.Join(dir, "twitter.log")
	if st, err := os.Stat(path); err == nil && st.Size() > 1<<20 {
		_ = os.Remove(path)
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return os.Stderr
	}
	return f
}
