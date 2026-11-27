// Uplink's LinkedIn helper (README.md, PROTOCOL.md). AGPL-3.0, as mautrix-linkedin, on whose linkedingo
// package it is built.
//
// Matt, 2026-11-20: "Let's do the feasible ones but skip X and google voice". It signs in to LinkedIn as the person,
// with the cookies of a browser signed in to their account, behaves as the website does, and speaks JSON lines over
// standard input and output: the protocol all of Uplink's account helpers share (../ACCOUNT_HELPERS.md). Requests,
// each with an "id" its answer carries back:
//
//	{"id":1,"op":"status"}                                     → {"linked","connected","me","name","handle"}
//	{"id":2,"op":"sign_in","cookies":{"li_at":"…","JSESSIONID":"…"}} → {"me","name","handle"}, and the event "linked"
//	{"id":3,"op":"unlink"}                                     → null; everything kept is forgotten
//	{"id":4,"op":"chats"}                                      → [<chat>…], the newest conversations
//	{"id":5,"op":"history","chat":"…","before":"<message id>"} → {"messages":[…],"more":bool}, oldest first
//	{"id":6,"op":"send","to":"…","text":"…","quote":{"id"}}    → {"id":"<message id>","ts":…}
//	{"id":7,"op":"send_media","to":"…","path":"…","mime":"…","name":"…","text":"…"} → {"id","ts"}
//	{"id":8,"op":"read","to":"…","upto":"<message id>"}        → null
//	{"id":9,"op":"react","to":"…","target":"…","emoji":"👍","remove":false} → null
//	{"id":10,"op":"delete","to":"…","target":"…"}              → null (your own message, taken back for everyone)
//	{"id":11,"op":"download","pointer":{…},"path":"…"}         → null once written
//	{"id":12,"op":"who","who":"…"}                             → {"id","name","handle","avatar"}
//
// Answers: {"id":1,"ok":true,"result":…} or {"id":1,"ok":false,"error":"…"}. Events, unasked, each with "ev": ready,
// linked, unlinked, connected, disconnected, chat, message, edited, deleted, reaction, receipt, name.
package main

import (
	"bufio"
	"cmp"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/google/uuid"
	"github.com/rs/zerolog"
	"go.mau.fi/util/jsontime"

	"go.mau.fi/mautrix-linkedin/pkg/linkedingo"
)

// pageSize is how many conversations LinkedIn lists at a time, and how many messages a page of history asks for.
const pageSize = 20

// quote is the message a `send` or `send_media` replies to, as the app names it.
type quote struct {
	ID string `json:"id"`
	// What the quoted message was, for a quote of a message this run has not seen (LinkedIn wants its sender and
	// time beside its id). Optional: the helper remembers every message it has passed on since it started.
	Author string `json:"author"`
	Text   string `json:"text"`
	TS     int64  `json:"ts"`
}

// request is one line Uplink sends: an op, and whichever of the other fields that op takes.
type request struct {
	ID      int64             `json:"id"`
	Op      string            `json:"op"`
	Cookies map[string]string `json:"cookies"`
	Chat    string            `json:"chat"`
	Before  string            `json:"before"`
	// Optional, beside `before`: that message's time (ms). LinkedIn pages history by time, not by message.
	BeforeTS int64  `json:"before_ts"`
	To       string `json:"to"`
	// `read`: the newest message read. Taken and not used: LinkedIn marks a whole conversation read.
	Upto    string          `json:"upto"`
	Text    string          `json:"text"`
	Quote   *quote          `json:"quote"`
	Path    string          `json:"path"`
	Mime    string          `json:"mime"`
	Name    string          `json:"name"`
	Target  string          `json:"target"`
	Emoji   string          `json:"emoji"`
	Remove  bool            `json:"remove"`
	Pointer json.RawMessage `json:"pointer"`
	Who     string          `json:"who"`
}

// account is one signed-in session: the library's client and who it is.
type account struct {
	cli    *linkedingo.Client
	jar    *linkedingo.StringCookieJar
	me     string // the last part of the person's profile URN, as every prefix of it ends
	name   string
	handle string

	// The library keeps its place in the conversation list in the client, unguarded: one sync at a time.
	syncLock sync.Mutex
	// saved is the cookies as session.json last held them (their JSON), to tell when LinkedIn has changed one;
	// guarded by saveLock.
	saveLock sync.Mutex
	saved    string
}

// meID is the person's own id as a message's `from` gives it.
func (a *account) meID() string { return participantPrefix + a.me }

var (
	// dir is the folder the session, the log and the cached pictures are kept in (--dir). out is standard output,
	// written a whole line at a time under outLock.
	dir     string
	log     zerolog.Logger
	out     = json.NewEncoder(os.Stdout)
	outLock sync.Mutex

	// mu guards acct (the session, nil while signed out) and connected (whether its live stream is up).
	mu        sync.Mutex
	acct      *account
	connected bool
	// One sign-in or sign-out at a time.
	signLock sync.Mutex
	// The requests being answered, which quitting waits for.
	inflight sync.WaitGroup
)

// say writes [v] to standard output as one JSON line; the lock keeps lines said from different goroutines whole.
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

// main takes up a saved session where there is one, says "ready", then answers each line of standard input until
// it ends.
func main() {
	flag.StringVar(&dir, "dir", "", "where the LinkedIn session is kept")
	flag.Parse()
	if dir == "" {
		fmt.Fprintln(os.Stderr, "--dir is needed")
		os.Exit(2)
	}
	_ = os.MkdirAll(dir, 0o700)
	// The log goes to standard error (Uplink's developer log) and linkedin.log beside the session; never stdout.
	log = zerolog.New(zerolog.MultiLevelWriter(os.Stderr, logFile())).With().Timestamp().Logger().Level(zerolog.InfoLevel)
	out.SetEscapeHTML(false)

	var a *account
	if s := loadSession(sessionPath()); s != nil {
		a = newAccount(*s)
		mu.Lock()
		acct = a
		mu.Unlock()
	}
	event("ready", map[string]any{"linked": a != nil})
	if a != nil {
		start(a)
	}

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
			a.keepCookies()
			a.cli.RealtimeDisconnect()
		}
		close(waited)
	}()
	select {
	case <-waited:
	case <-time.After(3 * time.Second):
	}
}

// parseRequest reads one line as a request. A line that is not JSON, or names no op, is an error: main passes over
// it without an answer.
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

// bg is the context of work no request bounds, carrying the log for the library to write to.
func bg() context.Context { return log.WithContext(context.Background()) }

// --- the session ----------------------------------------------------------------------------------------------------

// errNotLinked answers every op but status, sign_in and unlink while no one is signed in.
var errNotLinked = errors.New("not signed in to LinkedIn")

// current is the signed-in account, or nil.
func current() *account {
	mu.Lock()
	defer mu.Unlock()
	return acct
}

// newAccount makes the library's client for a session. Nothing is asked of LinkedIn yet.
func newAccount(s session) *account {
	a := &account{jar: s.Cookies, me: s.Me, name: s.Name, handle: s.Handle}
	if b, err := json.Marshal(s.Cookies); err == nil {
		a.saved = string(b)
	}
	// The browser's own X-LI-Track and page-instance headers are not asked of the person: the library has defaults.
	a.cli = linkedingo.NewClient(bg(), linkedingo.NewURN(s.Me), s.Cookies, "", "", "", linkedingo.Handlers{
		Heartbeat: func(context.Context) {
			setConnected(a, true)
			a.keepCookies()
		},
		ClientConnection: func(ctx context.Context, _ *linkedingo.ClientConnection) {
			setConnected(a, true)
			// What changed while the stream was down. Not on the stream's own goroutine, which must keep reading.
			go a.syncChats(ctx)
		},
		TransientDisconnect: func(_ context.Context, err error) {
			log.Warn().Err(err).Msg("the live connection dropped; the library connects again")
			setConnected(a, false)
		},
		BadCredentials: func(_ context.Context, err error) { ended(a, err) },
		DecoratedEvent: a.onEvent,
	})
	return a
}

// start checks the session by asking for the conversations (said as `chat` events), then opens the live stream.
func start(a *account) {
	go func() {
		a.syncChats(bg())
		mu.Lock()
		defer mu.Unlock()
		// Signed out meanwhile (by the person, or by LinkedIn in that first answer): nothing to connect.
		if acct != a || !a.cli.IsLoggedIn() {
			return
		}
		if err := a.cli.RealtimeConnect(bg()); err != nil {
			log.Err(err).Msg("open the live stream")
		}
	}()
}

// setConnected notes whether [a]'s live stream is up, and says `connected` or `disconnected` when that changes.
// Nothing is noted or said for an account that is no longer the session.
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

// drop lets go of [a], if it is still the session: its stream closed, what was remembered of it forgotten.
func drop(a *account) bool {
	mu.Lock()
	if acct != a {
		mu.Unlock()
		return false
	}
	acct = nil
	connected = false
	mu.Unlock()
	// In the background: the stream's own goroutine may be the caller, and closing waits for it.
	go a.cli.RealtimeDisconnect()
	seen.reset()
	return true
}

// ended is LinkedIn turning the session away: everything is forgotten and the app told, to ask for a new sign-in.
func ended(a *account, err error) {
	if !drop(a) {
		return
	}
	log.Warn().Err(err).Msg("LinkedIn ended the session")
	forgetFiles()
	event("unlinked", map[string]any{"error": endedWords(err)})
}

// forgetFiles removes what a session keeps on disk: the saved sign-in, one half written, and the cached pictures.
func forgetFiles() {
	_ = os.Remove(sessionPath())
	_ = os.Remove(sessionPath() + ".new")
	_ = os.RemoveAll(avatarDir())
}

// keepCookies writes the session again when LinkedIn has changed a cookie, as it does now and then.
func (a *account) keepCookies() {
	a.saveLock.Lock()
	defer a.saveLock.Unlock()
	b, err := json.Marshal(a.jar)
	if err != nil || string(b) == a.saved || current() != a {
		return
	}
	if err := saveSession(sessionPath(), session{Me: a.me, Name: a.name, Handle: a.handle, Cookies: a.jar}); err != nil {
		log.Err(err).Msg("keep the changed cookies")
		return
	}
	a.saved = string(b)
}

// identity is who the account is, as sign_in's answer and the `linked` event give it.
func (a *account) identity() map[string]any {
	return map[string]any{"me": a.meID(), "name": a.name, "handle": a.handle}
}

// status answers `status`: whether a session is held, whether its stream is up, and whose it is.
func status() map[string]any {
	mu.Lock()
	defer mu.Unlock()
	if acct == nil {
		return map[string]any{"linked": false, "connected": false, "me": "", "name": "", "handle": ""}
	}
	return map[string]any{"linked": true, "connected": connected, "me": acct.meID(), "name": acct.name, "handle": acct.handle}
}

// signIn takes the browser's cookies, asks LinkedIn whose they are (which is also the check that it takes them),
// keeps the session and connects.
func signIn(ctx context.Context, cookies map[string]string) (any, error) {
	signLock.Lock()
	defer signLock.Unlock()
	jar, err := cookieJar(cookies)
	if err != nil {
		return nil, err
	}
	probe := linkedingo.NewClient(ctx, linkedingo.NewURN(""), jar, "", "", "", linkedingo.Handlers{})
	profile, err := probe.GetCurrentUserProfile(ctx)
	if err != nil {
		log.Warn().Err(err).Msg("sign in")
		return nil, signInWords(err)
	}
	mini := profile.MiniProfile
	if mini.EntityURN.ID() == "" {
		return nil, signInWords(linkedingo.ErrTokenInvalidated)
	}
	s := session{
		Me:      mini.EntityURN.ID(),
		Name:    strings.TrimSpace(mini.FirstName + " " + mini.LastName),
		Handle:  mini.PublicIdentifier,
		Cookies: jar,
	}
	if old := current(); old != nil {
		drop(old)
	}
	if err := saveSession(sessionPath(), s); err != nil {
		log.Err(err).Msg("save session")
		return nil, errors.New("the sign-in could not be kept on this device: " + err.Error())
	}
	a := newAccount(s)
	seen.meet(person{ID: a.meID(), Name: s.Name, Handle: s.Handle, Pic: mini.Picture.VectorImage})
	mu.Lock()
	acct = a
	mu.Unlock()
	event("linked", a.identity())
	start(a)
	return a.identity(), nil
}

// unlink forgets the session here. LinkedIn is not told: its sign-out would end the browser's session too, since
// the cookies are the browser's own.
func unlink() {
	signLock.Lock()
	defer signLock.Unlock()
	if a := current(); a != nil {
		drop(a)
	}
	forgetFiles()
}

// --- requests -------------------------------------------------------------------------------------------------------

// do answers one request: status, sign_in and unlink here, the rest by the account. A request has a minute, and one
// that moves a file nearly three. A failure that means LinkedIn turned the session away also ends it.
func do(r request) (any, error) {
	limit := 60 * time.Second
	if r.Op == "download" || r.Op == "send_media" {
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
		return signIn(ctx, r.Cookies)
	case "unlink":
		unlink()
		return nil, nil
	}
	a := current()
	if a == nil {
		return nil, errNotLinked
	}
	result, err := a.do(ctx, r)
	if err != nil {
		log.Warn().Err(err).Str("op", r.Op).Int64("req", r.ID).Msg("failed")
		// A file's address answers 401 or redirects on its own account; anything else doing so is the session.
		if r.Op != "download" && rejected(err) {
			ended(a, err)
		}
		return nil, plain(err)
	}
	return result, nil
}

// do answers the ops that need a session. A chat, a person and a message are each named by LinkedIn's own URN.
func (a *account) do(ctx context.Context, r request) (any, error) {
	switch r.Op {
	case "chats":
		return a.chats(ctx)
	case "history":
		return a.history(ctx, r.Chat, r.Before, r.BeforeTS)
	case "send":
		return a.send(ctx, r, nil)
	case "send_media":
		render, err := a.upload(ctx, r)
		if err != nil {
			return nil, err
		}
		return a.send(ctx, r, render)
	case "read":
		if r.To == "" {
			return nil, errors.New("no chat to mark read")
		}
		// LinkedIn marks a whole conversation read, not up to a message: `upto` is not needed.
		_, err := a.cli.MarkConversationRead(ctx, linkedingo.NewURN(r.To))
		return nil, err
	case "react":
		if r.Target == "" || r.Emoji == "" {
			return nil, errors.New("a reaction needs a message and an emoji")
		}
		if r.Remove {
			return nil, a.cli.RemoveReaction(ctx, linkedingo.NewURN(r.Target), r.Emoji)
		}
		return nil, a.cli.SendReaction(ctx, linkedingo.NewURN(r.Target), r.Emoji)
	case "delete":
		if r.Target == "" {
			return nil, errors.New("no message to delete")
		}
		return nil, a.cli.RecallMessage(ctx, linkedingo.NewURN(r.Target))
	case "download":
		return nil, a.download(ctx, r.Pointer, r.Path)
	case "who":
		return a.who(ctx, r.Who)
	}
	return nil, fmt.Errorf("the LinkedIn helper does not know %q", r.Op)
}

// --- what this run has seen -----------------------------------------------------------------------------------------

// LinkedIn's events lean on what its website already holds: a reaction names its message but not the chat, a reply
// wants the quoted message's sender and time, history is paged by time. So the helper remembers, in memory only and
// for this run, the chats, people and newest messages that have passed through it.

// chatNote is what is remembered of one chat.
type chatNote struct {
	group bool
	// A message request not yet answered: answering it accepts it, as the website's reply box does.
	pending bool
}

// msgNote is what is remembered of one message: its chat, its sender's id, its words as LinkedIn wrote them, and
// when it was delivered (ms, 0 where not known).
type msgNote struct {
	chat string
	from string
	text string
	ts   int64
}

// msgNotes is how many messages are remembered before the oldest are let go.
const msgNotes = 5000

// memory is what this run has seen, behind its own lock. Everything is kept by LinkedIn's id for it; order is the
// ids of msgs, oldest first, which is the order they are let go in.
type memory struct {
	sync.Mutex
	chats  map[string]chatNote
	msgs   map[string]msgNote
	order  []string
	people map[string]person
	// What the last `name` event said of each person, so the same thing is not said twice.
	said map[string]string
}

// seen is the one memory, emptied when the session is let go.
var seen = newMemory()

func newMemory() *memory {
	return &memory{chats: map[string]chatNote{}, msgs: map[string]msgNote{}, people: map[string]person{}, said: map[string]string{}}
}

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

func (m *memory) noteChat(id string, n chatNote) {
	m.Lock()
	defer m.Unlock()
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
	return !had
}

// meet remembers a person, keeping the picture and handle already known where this sighting has none.
func (m *memory) meet(p person) {
	if p.ID == "" {
		return
	}
	m.Lock()
	defer m.Unlock()
	if old, ok := m.people[p.ID]; ok {
		p.Name = cmp.Or(p.Name, old.Name)
		p.Handle = cmp.Or(p.Handle, old.Handle)
		if p.Pic == nil {
			p.Pic = old.Pic
		}
	}
	m.people[p.ID] = p
}

func (m *memory) person(id string) (person, bool) {
	m.Lock()
	defer m.Unlock()
	p, ok := m.people[id]
	return p, ok
}

// newsOf is whether [p] differs from what was last said of them, noting it as said.
func (m *memory) newsOf(p person) bool {
	sig := p.Name + "\n" + p.Handle
	if p.Pic != nil {
		sig += "\n" + p.Pic.RootURL
	}
	m.Lock()
	defer m.Unlock()
	if m.said[p.ID] == sig {
		return false
	}
	m.said[p.ID] = sig
	return true
}

// noteMessage remembers a message of [chat], and says whether it was new to this run.
func (a *account) noteMessage(chat string, msg linkedingo.Message) bool {
	n := msgNote{chat: chat, from: urnText(msg.Sender.EntityURN), text: msg.Body.Text}
	if !msg.DeliveredAt.IsZero() {
		n.ts = msg.DeliveredAt.UnixMilli()
	}
	return seen.noteMsg(urnText(msg.EntityURN), n)
}

// chatOfMessage is the chat of a message under an event: what the message says, else where this run saw it.
func (a *account) chatOfMessage(msg linkedingo.Message) string {
	if id := urnText(msg.Conversation.EntityURN); id != "" {
		return id
	}
	if n, ok := seen.msg(urnText(msg.EntityURN)); ok && n.chat != "" {
		return n.chat
	}
	return conversationOf(a.me, msg)
}

// --- people and avatars ---------------------------------------------------------------------------------------------

// avatarDir is where people's pictures are cached, beside the session.
func avatarDir() string { return filepath.Join(dir, "avatars") }

// nullable is [s], or JSON's null for "".
func nullable(s string) any {
	if s == "" {
		return nil
	}
	return s
}

// artifactNear is the smallest of a picture's sizes at least [want] pixels wide, the largest where none is.
func artifactNear(pic linkedingo.VectorImage, want int) linkedingo.VectorArtifact {
	best := pic.GetLargestArtifact()
	for _, a := range pic.Artifacts {
		if a.Width >= want && a.Width < best.Width {
			best = a
		}
	}
	return best
}

// avatarName names a person's cached picture. The address LinkedIn gives is signed anew every few weeks; the part
// before the size is the picture itself, so that and the size are what is hashed.
func avatarName(who person, art linkedingo.VectorArtifact) string {
	base := who.Pic.RootURL
	if base == "" {
		base, _, _ = strings.Cut(art.FileIdentifyingURLPathSegment, "?")
	}
	sum := sha256.Sum256([]byte(who.ID + "\n" + base + "\n" + strconv.Itoa(art.Width)))
	return hex.EncodeToString(sum[:12])
}

// avatar is a person's picture as a file under avatars/, fetched once; "" where there is none or it can't be had.
// LinkedIn's picture addresses are signed and need no cookies.
func (a *account) avatar(ctx context.Context, who person) string {
	if who.Pic == nil || len(who.Pic.Artifacts) == 0 {
		return ""
	}
	art := artifactNear(*who.Pic, 200)
	if art.FileIdentifyingURLPathSegment == "" {
		return ""
	}
	p := filepath.Join(avatarDir(), avatarName(who, art))
	if _, err := os.Stat(p); err == nil {
		return p
	}
	ctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	data, err := a.cli.DownloadBytes(ctx, who.Pic.RootURL+art.FileIdentifyingURLPathSegment)
	if err != nil || len(data) == 0 || len(data) > 4<<20 {
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
	if who.ID == "" || who.Name == "" && who.Pic == nil {
		return
	}
	seen.meet(who)
	who, _ = seen.person(who.ID)
	if !seen.newsOf(who) {
		return
	}
	event("name", map[string]any{"id": who.ID, "name": who.Name, "handle": who.Handle, "avatar": nullable(a.avatar(bg(), who))})
}

// who answers `who` from what this run has seen: the person themself, or someone met in a chat or a message.
func (a *account) who(ctx context.Context, id string) (any, error) {
	if id == "" {
		return nil, errors.New("no one was asked for")
	}
	who, ok := seen.person(id)
	if !ok && id == a.meID() {
		who, ok = person{ID: id, Name: a.name, Handle: a.handle}, true
	}
	if !ok {
		// LinkedIn's messaging has no "who is this" of its own here: people are known from chats and messages.
		return nil, errors.New("LinkedIn has not shown this person here yet: they are named once one of their chats or messages is listed")
	}
	return map[string]any{"id": who.ID, "name": who.Name, "handle": who.Handle, "avatar": nullable(a.avatar(ctx, who))}, nil
}

// --- chats ----------------------------------------------------------------------------------------------------------

// noteConversation remembers a conversation, its people and the messages listed under it.
func (a *account) noteConversation(conv linkedingo.Conversation) {
	id := urnText(conv.EntityURN)
	seen.noteChat(id, chatNote{group: conv.GroupChat, pending: conv.State == linkedingo.ConversationStatePending})
	for _, p := range conv.ConversationParticipants {
		seen.meet(personOf(p))
	}
	for _, m := range conv.Messages.Elements {
		a.noteMessage(id, m)
	}
}

// chatsOf turns the conversations LinkedIn listed into `chat`s, in its order, fetching their pictures side by side.
func (a *account) chatsOf(ctx context.Context, convs []linkedingo.Conversation) []chatOut {
	var kept []linkedingo.Conversation
	for _, conv := range convs {
		if listed(conv) {
			a.noteConversation(conv)
			kept = append(kept, conv)
		}
	}
	list := make([]chatOut, len(kept))
	var wg sync.WaitGroup
	gate := make(chan struct{}, 4)
	for i, conv := range kept {
		wg.Add(1)
		go func() {
			defer wg.Done()
			gate <- struct{}{}
			defer func() { <-gate }()
			list[i] = chatOf(a.me, conv, func(p person) string { return a.avatar(ctx, p) })
		}()
	}
	wg.Wait()
	return list
}

// sayChats says the conversations that belong in the inbox as `chat` events, and gives them.
func (a *account) sayChats(ctx context.Context, convs []linkedingo.Conversation) []chatOut {
	list := a.chatsOf(ctx, convs)
	for _, c := range list {
		event("chat", fields(c))
	}
	return list
}

// chats is the newest conversations of the inbox, as LinkedIn's website first lists them.
func (a *account) chats(ctx context.Context) (any, error) {
	resp, err := a.cli.GetConversationsUpdatedBefore(ctx, time.Now())
	if err != nil {
		return nil, err
	}
	if resp == nil {
		return []chatOut{}, nil
	}
	return a.sayChats(ctx, resp.Elements), nil
}

// syncChats asks for the conversations changed since the last time it asked (all the newest, the first time) and
// says each as a `chat` event. It is also how a saved session is checked when the helper starts.
func (a *account) syncChats(ctx context.Context) {
	a.syncLock.Lock()
	defer a.syncLock.Unlock()
	if current() != a {
		return
	}
	resp, err := a.cli.GetConversationsBySyncToken(ctx)
	if err != nil {
		log.Warn().Err(err).Msg("sync conversations")
		if rejected(err) {
			ended(a, err)
		}
		return
	}
	if resp != nil {
		a.sayChats(ctx, resp.Elements)
	}
}

// --- history --------------------------------------------------------------------------------------------------------

// shown is whether a message is one to show: not one taken back, nor LinkedIn's own notes in a conversation.
func shown(msg linkedingo.Message) bool {
	return msg.MessageBodyRenderFormat != linkedingo.MessageBodyRenderFormatRecalled && msg.MessageBodyRenderFormat != linkedingo.MessageBodyRenderFormatSystem
}

// anchorTime finds when message [before] of [chat] was delivered, which is what LinkedIn pages by: from what this
// run has seen, else by reading back from the newest, a page at a time, until the message turns up.
func (a *account) anchorTime(ctx context.Context, chat, before string) (time.Time, error) {
	if n, ok := seen.msg(before); ok && n.ts > 0 {
		return time.UnixMilli(n.ts), nil
	}
	at := time.Now()
	for range 15 {
		resp, err := a.cli.GetMessagesBefore(ctx, linkedingo.NewURN(chat), at, pageSize)
		if err != nil {
			return time.Time{}, err
		}
		oldest := at
		for _, m := range resp.Elements {
			a.noteMessage(chat, m)
			if !m.DeliveredAt.IsZero() && m.DeliveredAt.Before(oldest) {
				oldest = m.DeliveredAt.Time
			}
		}
		if n, ok := seen.msg(before); ok && n.ts > 0 {
			return time.UnixMilli(n.ts), nil
		}
		if !oldest.Before(at) {
			break
		}
		at = oldest
	}
	return time.Time{}, errors.New("that message is too far back to find from here: send its time as before_ts")
}

// history is a page of a chat's messages older than [before] (the newest, with none), oldest first.
func (a *account) history(ctx context.Context, chat, before string, beforeTS int64) (any, error) {
	if chat == "" {
		return nil, errors.New("no chat was asked for")
	}
	at := time.Now()
	switch {
	case beforeTS > 0:
		at = time.UnixMilli(beforeTS)
	case before != "":
		found, err := a.anchorTime(ctx, chat, before)
		if err != nil {
			return nil, err
		}
		at = found
	}
	resp, err := a.cli.GetMessagesBefore(ctx, linkedingo.NewURN(chat), at, pageSize)
	if err != nil {
		return nil, err
	}
	note, _ := seen.chat(chat)
	paged := before != "" || beforeTS > 0
	older := 0
	list := []messageOut{}
	for _, m := range resp.Elements {
		// LinkedIn counts the message at that very time as "before" it.
		if paged && (urnText(m.EntityURN) == before || !m.DeliveredAt.Before(at)) {
			continue
		}
		older++
		a.noteMessage(chat, m)
		seen.meet(personOf(m.Sender))
		if shown(m) {
			list = append(list, messageOf(a.me, chat, note.group, m))
		}
	}
	sort.SliceStable(list, func(i, j int) bool { return list[i].TS < list[j].TS })
	a.fillAll(ctx, list)
	go func() {
		for _, m := range resp.Elements {
			a.sayName(personOf(m.Sender))
		}
	}()
	// LinkedIn does not say whether there is more: a page with anything in it means "ask again", and the page after
	// the last comes back empty.
	return map[string]any{"messages": list, "more": older > 0}, nil
}

// fillMedia asks LinkedIn what kind of file a picture or a voice message is (it says so only in the file's own
// headers). Where it does not answer, the kind its website makes is given.
func (a *account) fillMedia(ctx context.Context, list []mediaOut) {
	for i := range list {
		m := &list[i]
		if m.Mime != "" {
			continue
		}
		hctx, cancel := context.WithTimeout(ctx, 8*time.Second)
		var mime, name string
		var size int
		if m.Pointer.Kind == "audio" {
			if info, n, err := a.cli.GetAudioFileInfo(hctx, &linkedingo.AudioMetadata{URL: m.Pointer.URL}); err == nil {
				mime, size, name = info.MimeType, info.Size, n
			}
		} else if info, n, err := a.cli.GetVectorImageFileInfo(hctx, &linkedingo.VectorImage{RootURL: m.Pointer.URL}); err == nil {
			mime, size, name = info.MimeType, info.Size, n
		}
		cancel()
		mime, _, _ = strings.Cut(mime, ";")
		mime = strings.TrimSpace(mime)
		if mime == "" || !strings.Contains(mime, "/") {
			mime = "image/jpeg"
			if m.Pointer.Kind == "audio" {
				mime = "audio/mp4"
			}
		}
		m.Mime = mime
		if size > 0 && m.Size == 0 {
			m.Size = int64(size)
		}
		if name != "" {
			m.Name = name
		}
	}
}

// fillAll does fillMedia for every message of a page that carries something, four messages at a time.
func (a *account) fillAll(ctx context.Context, list []messageOut) {
	var wg sync.WaitGroup
	gate := make(chan struct{}, 4)
	for i := range list {
		if len(list[i].Media) == 0 {
			continue
		}
		wg.Add(1)
		go func() {
			defer wg.Done()
			gate <- struct{}{}
			defer func() { <-gate }()
			a.fillMedia(ctx, list[i].Media)
		}()
	}
	wg.Wait()
}

// --- sending --------------------------------------------------------------------------------------------------------

// quoted is the reply LinkedIn wants: the quoted message's id with its sender, time and words, from what this run
// has seen of it or else from what the app sent along. Nil where neither knows the sender and the time.
func quoted(q quote) *linkedingo.SendRepliedMessage {
	if n, ok := seen.msg(q.ID); ok {
		q.Author, q.Text, q.TS = cmp.Or(n.from, q.Author), cmp.Or(n.text, q.Text), cmp.Or(n.ts, q.TS)
	}
	if q.ID == "" || q.Author == "" || q.TS == 0 {
		return nil
	}
	return &linkedingo.SendRepliedMessage{
		OriginalSenderURN:  linkedingo.NewURN(q.Author),
		OriginalSendAt:     jsontime.UM(time.UnixMilli(q.TS)),
		OriginalMessageURN: linkedingo.NewURN(q.ID),
		MessageBody:        linkedingo.AttributedText{Text: q.Text},
	}
}

// send posts a message to a chat: words, a file already uploaded ([render]), or both, with the quoted message
// where it is known. Sending into a message request not yet answered accepts it.
func (a *account) send(ctx context.Context, r request, render []linkedingo.SendRenderContent) (any, error) {
	if r.To == "" {
		return nil, errors.New("no chat to send to")
	}
	if r.Text == "" && len(render) == 0 {
		return nil, errors.New("nothing to send")
	}
	if r.Quote != nil && r.Quote.ID != "" {
		if q := quoted(*r.Quote); q != nil {
			render = append(render, linkedingo.SendRenderContent{RepliedMessageContent: q})
		} else {
			// Better said plainly than not said: the words go, without the quote above them.
			log.Warn().Int64("req", r.ID).Msg("the quoted message is not known here; sent without the quote")
		}
	}
	var state linkedingo.ConversationState
	if note, ok := seen.chat(r.To); ok && note.pending {
		state = linkedingo.ConversationStateAccepted
	}
	resp, err := a.cli.SendMessage(ctx, linkedingo.NewURN(r.To), linkedingo.SendMessageBody{Text: r.Text}, render, uuid.NewString(), state)
	if err != nil {
		return nil, err
	}
	id := urnText(resp.Data.EntityURN)
	ts := time.Now().UnixMilli()
	if !resp.Data.DeliveredAt.IsZero() {
		ts = resp.Data.DeliveredAt.UnixMilli()
	}
	seen.noteMsg(id, msgNote{chat: r.To, from: a.meID(), text: r.Text, ts: ts})
	if state != "" {
		if note, ok := seen.chat(r.To); ok {
			note.pending = false
			seen.noteChat(r.To, note)
		}
	}
	return map[string]any{"id": id, "ts": ts}, nil
}

// upload hands LinkedIn a file and gives what a message needs to carry it: a picture as its website attaches one,
// anything else as a file.
func (a *account) upload(ctx context.Context, r request) ([]linkedingo.SendRenderContent, error) {
	if r.To == "" {
		return nil, errors.New("no chat to send to")
	}
	f, err := os.Open(r.Path)
	if err != nil {
		return nil, errors.New("the file could not be opened: " + err.Error())
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil || st.IsDir() || st.Size() == 0 {
		return nil, errors.New("the file is empty or cannot be read")
	}
	name := cmp.Or(r.Name, filepath.Base(r.Path))
	mime := cmp.Or(r.Mime, "application/octet-stream")
	kind := linkedingo.MediaUploadTypeFileAttachment
	if strings.HasPrefix(mime, "image/") {
		kind = linkedingo.MediaUploadTypePhotoAttachment
	}
	urn, err := a.cli.UploadMedia(ctx, kind, name, mime, int(st.Size()), f)
	if err != nil {
		return nil, err
	}
	if urn.IsEmpty() {
		return nil, errors.New("LinkedIn did not take the file")
	}
	return []linkedingo.SendRenderContent{{File: &linkedingo.SendFile{AssetURN: urn, ByteSize: int(st.Size()), MediaType: mime, Name: name}}}, nil
}

// --- files ----------------------------------------------------------------------------------------------------------

// parsePointer reads a `download`'s pointer: the object a message gave, or that object as a string.
func parsePointer(raw json.RawMessage) (pointer, error) {
	var p pointer
	var inner string
	if json.Unmarshal(raw, &inner) == nil {
		raw = json.RawMessage(inner)
	}
	if err := json.Unmarshal(raw, &p); err != nil || p.URL == "" {
		return p, errors.New("that is not a LinkedIn file")
	}
	if u, err := url.Parse(p.URL); err != nil || u.Scheme != "https" || u.Host == "" {
		return p, errors.New("that is not a LinkedIn file")
	}
	return p, nil
}

// download writes a message's file to [path]: fetched as the website fetches it, whole or not at all.
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
	err = a.cli.Download(ctx, f, p.URL)
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		_ = os.Remove(tmp)
		switch statusOf(err) {
		case http.StatusUnauthorized, http.StatusForbidden, http.StatusNotFound, http.StatusGone:
			return errors.New("LinkedIn's link to this file has run out. Open the chat again for a fresh one.")
		}
		return err
	}
	return os.Rename(tmp, path)
}

// --- what LinkedIn says, live ---------------------------------------------------------------------------------------

// onEvent takes one thing the live stream said, told apart by its topic: a conversation changed, a message, a read
// receipt, a reaction. Nothing once [a] is no longer the session.
func (a *account) onEvent(ctx context.Context, ev *linkedingo.DecoratedEvent) {
	if ev == nil || current() != a {
		return
	}
	data := ev.Payload.Data
	// Topics are "urn:li-realtime:<topic>:<whose>".
	switch ev.Topic.NthPrefixPart(2) {
	case linkedingo.RealtimeEventTopicConversations, linkedingo.RealtimeEventTopicTabBadgeUpdate:
		if data.DecoratedConversation != nil {
			a.sayChats(ctx, []linkedingo.Conversation{data.DecoratedConversation.Result})
		} else {
			// Only "something changed": ask what. Not on the stream's own goroutine.
			go a.syncChats(ctx)
		}
	case linkedingo.RealtimeEventTopicMessages:
		if data.DecoratedMessage != nil {
			a.onMessage(ctx, data.DecoratedMessage.Result)
		}
	case linkedingo.RealtimeEventTopicMessageSeenReceipts:
		if data.DecoratedSeenReceipt != nil {
			a.onSeen(data.DecoratedSeenReceipt.Result)
		}
	case linkedingo.RealtimeEventTopicMessageReactionSummaries:
		if data.DecoratedReactionSummary != nil {
			a.onReaction(data.DecoratedReactionSummary.Result)
		}
	case linkedingo.RealtimeEventTopicConversationDelete:
		// The protocol has no word for a chat removed on the website; the app keeps what it has.
		log.Info().Msg("a conversation was deleted on LinkedIn")
	}
}

// onMessage takes a message from the stream, which is also how LinkedIn says one was taken back or edited: its
// render format tells which. A new message is said as `message`, after its chat where the app has not been told of it.
func (a *account) onMessage(ctx context.Context, msg linkedingo.Message) {
	id := urnText(msg.EntityURN)
	chat := a.chatOfMessage(msg)
	if id == "" || chat == "" {
		log.Debug().Str("message", id).Msg("a live message without its conversation was passed over")
		return
	}
	before, known := seen.msg(id)
	a.noteMessage(chat, msg)
	sender := personOf(msg.Sender)
	seen.meet(sender)

	switch msg.MessageBodyRenderFormat {
	case linkedingo.MessageBodyRenderFormatRecalled:
		event("deleted", map[string]any{"chat": chat, "target": id})
		return
	case linkedingo.MessageBodyRenderFormatSystem:
		return
	case linkedingo.MessageBodyRenderFormatEdited:
		// LinkedIn sends an edited message again whenever anything about it changes (a reaction, say): only a change
		// of its words is an edit.
		text := messageText(msg)
		if !known || before.text != msg.Body.Text {
			event("edited", map[string]any{"chat": chat, "target": id, "text": text})
		}
		return
	}

	group := msg.Conversation.GroupChat
	note, chatKnown := seen.chat(chat)
	if msg.Conversation.EntityURN.IsEmpty() {
		group = note.group
	} else if !chatKnown && len(msg.Conversation.ConversationParticipants) > 0 {
		// The first message of a chat the app has not been told of: the chat first.
		a.sayChats(ctx, []linkedingo.Conversation{msg.Conversation})
	}
	mine := isMine(a.me, msg.Sender)
	if !known && !mine {
		// As the website does on receiving a message: it is what turns the sender's tick to "delivered".
		go func() {
			if err := a.cli.AcknowledgeDelivery(bg(), linkedingo.DeliveryMechanismRealtime, msg.EntityURN); err != nil {
				log.Warn().Err(err).Msg("acknowledge delivery")
			}
		}()
	}
	m := messageOf(a.me, chat, group, msg)
	a.fillMedia(ctx, m.Media)
	event("message", fields(m))
	go a.sayName(sender)
}

// onSeen says that someone has read up to a message, as a `receipt`.
func (a *account) onSeen(r linkedingo.SeenReceipt) {
	id, chat := urnText(r.Message.EntityURN), a.chatOfMessage(r.Message)
	from := urnText(r.SeenByParticipant.EntityURN)
	if id == "" || chat == "" || from == "" {
		return
	}
	event("receipt", map[string]any{"chat": chat, "from": from, "id": id, "kind": "read"})
}

// onReaction says a reaction added or removed. LinkedIn names the message and may not name its chat, which
// chatOfMessage then finds.
func (a *account) onReaction(r linkedingo.RealtimeReactionSummary) {
	id, chat := urnText(r.Message.EntityURN), a.chatOfMessage(r.Message)
	from := urnText(r.Actor.EntityURN)
	if id == "" || chat == "" || from == "" || r.ReactionSummary.Emoji == "" {
		return
	}
	event("reaction", map[string]any{"chat": chat, "from": from, "target": id, "emoji": r.ReactionSummary.Emoji, "remove": !r.ReactionAdded})
}

// --- the log file ---------------------------------------------------------------------------------------------------

// logFile is linkedin.log in the session's folder, begun afresh past a megabyte; standard error alone where it can't
// open.
func logFile() io.Writer {
	path := filepath.Join(dir, "linkedin.log")
	if st, err := os.Stat(path); err == nil && st.Size() > 1<<20 {
		_ = os.Remove(path)
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		// Not os.Stderr: the logger writes there already, and each line would be written twice.
		return io.Discard
	}
	return f
}
