// Uplink's Slack helper (README.md, PROTOCOL.md). AGPL-3.0, as mautrix-slack and its slack-go fork, on
// whose Slack client it is built.
//
// It signs in to one Slack workspace as the person, with the token and cookie of a browser signed in to it, behaves
// as Slack's website does (its API with the browser's session, and its live RTM stream), and speaks JSON lines over
// standard input and output: the protocol all of Uplink's account helpers share (../ACCOUNT_HELPERS.md). Requests,
// each with an "id" its answer carries back:
//
//	{"id":1,"op":"status"}                                       → {"linked","connected","me","name","handle"}
//	{"id":2,"op":"sign_in","cookies":{"d":"xoxd-…","token":"xoxc-…"}} → {"me","name","handle"}, and the event "linked"
//	{"id":3,"op":"unlink"}                                       → null; everything kept is forgotten
//	{"id":4,"op":"chats"}                                        → [<chat>…], the chats with the newest messages
//	{"id":5,"op":"history","chat":"T…-C…","before":"<ts>"}       → {"messages":[…],"more":bool}, oldest first
//	{"id":6,"op":"send","to":"…","text":"…","quote":{"id"}}      → {"id":"<ts>","ts":…} (a quote: a reply in its thread)
//	{"id":7,"op":"send_media","to":"…","path":"…","mime":"…","name":"…","text":"…"} → {"id","ts"}
//	{"id":8,"op":"read","to":"…","upto":"<ts>"}                  → null
//	{"id":9,"op":"react","to":"…","target":"<ts>","emoji":"👍","remove":false} → null
//	{"id":10,"op":"delete","to":"…","target":"<ts>"}             → null (your own message)
//	{"id":11,"op":"download","pointer":{…},"path":"…"}           → null once written
//	{"id":12,"op":"who","who":"U…"}                              → {"id","name","handle","avatar"}
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
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/gorilla/websocket"
	"github.com/rs/zerolog"
	"github.com/slack-go/slack"
)

// pageSize is how many chats `chats` gives, and how many messages a page of history asks for.
const pageSize = 20

// threadsPerPage and repliesPerThread bound what a page of history asks of Slack for the threads under its messages.
const (
	threadsPerPage   = 10
	repliesPerThread = 100
)

// quote is the message a `send` or `send_media` replies to, as the app names it.
type quote struct {
	ID string `json:"id"`
	// What the app knows of the quoted message. Taken and not needed: a reply goes into the quoted message's thread.
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
	// Optional, beside `before`: that message's time (ms). Taken and not needed: a Slack message's id is its time.
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
	// `people`: what is looked for in the workspace's members, by name or handle; empty for all of them.
	Query string `json:"query"`
}

// account is one signed-in session: the library's client, its live stream, and who it is.
type account struct {
	s   session
	cli *slack.Client

	// Set once the stream is opened; guarded by mu.
	rtm  *slack.RTM
	stop context.CancelFunc
	// Whether the stream has said hello before: a second hello is a reconnection, after which the chats are asked
	// again for what changed meanwhile.
	helloed atomic.Bool
	// Whether the client has the website's version (what sign_in's client already asked for).
	versioned bool

	syncLock sync.Mutex
}

var (
	// dir is the folder the session, the log and the cached pictures are kept in (--dir). out is standard output,
	// written a whole line at a time under outLock.
	dir     string
	log     = zerolog.Nop()
	out     = json.NewEncoder(os.Stdout)
	outLock sync.Mutex

	// mu guards acct (the session, nil while signed out), its stream's fields, and connected (whether the stream is
	// up).
	mu        sync.Mutex
	acct      *account
	connected bool
	// One sign-in or sign-out at a time.
	signLock sync.Mutex
	// The requests being answered, which quitting waits for.
	inflight sync.WaitGroup

	// How Slack is reached: the library's requests, files, pictures, and the live stream. The tests point them at a
	// stand-in for Slack; nothing else changes them.
	httpClient           = &http.Client{}
	wsDialer             *websocket.Dialer
	fetchVersion         = true
	reconnectAfterFatal  = time.Minute
	fileShareWait        = time.Second
	fileShareWaitAttempt = 6
)

// slackLog passes the library's own lines to the log, below info: they may carry what a request said.
type slackLog struct{}

// Output is what the library calls with each line (its logger interface); the call depth is not used.
func (slackLog) Output(_ int, s string) error {
	log.Debug().Str("from", "slack-go").Msg(strings.TrimSpace(s))
	return nil
}

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

func main() {
	flag.StringVar(&dir, "dir", "", "where the Slack session is kept")
	flag.Parse()
	if dir == "" {
		fmt.Fprintln(os.Stderr, "--dir is needed")
		os.Exit(2)
	}
	setup(os.Stderr)
	serve(os.Stdin)
}

// setup makes the session's folder and the log: [errOut] (Uplink's developer log) and slack.log beside the session,
// never stdout.
func setup(errOut io.Writer) {
	_ = os.MkdirAll(dir, 0o700)
	log = zerolog.New(zerolog.MultiLevelWriter(errOut, logFile())).With().Timestamp().Logger().Level(zerolog.InfoLevel)
	out.SetEscapeHTML(false)
}

// serve says the helper is ready, answers what [in] asks until it closes, then lets the session go.
func serve(in io.Reader) {
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

	scan := bufio.NewScanner(in)
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
			drop(a)
		}
		close(waited)
	}()
	select {
	case <-waited:
	case <-time.After(3 * time.Second):
	}
}

// parseRequest reads one line as a request. A line that is not JSON, or names no op, is an error: serve passes over
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
var errNotLinked = errors.New("not signed in to Slack")

// current is the signed-in account, or nil.
func current() *account {
	mu.Lock()
	defer mu.Unlock()
	return acct
}

// newAccount makes the account for a session, on [cli] where sign_in already made the client. Nothing is asked of
// Slack yet.
func newAccount(s session, cli *slack.Client) *account {
	versioned := cli != nil
	if cli == nil {
		cli = slack.New(s.Token, clientOptions(s.Cookies)...)
	}
	return &account{s: s, cli: cli, versioned: versioned}
}

// start asks for the chats (said as `chat` events), which is also the check that a saved session still holds, then
// opens the live stream.
func start(a *account) {
	go func() {
		ctx := bg()
		if fetchVersion && !a.versioned {
			// What the website sends with each request; without it Slack still answers.
			if err := a.cli.FetchVersionData(ctx); err != nil {
				log.Warn().Err(err).Msg("Slack's website version")
			}
		}
		a.syncChats(ctx)
		if current() != a {
			return
		}
		a.connect()
	}()
}

// connect opens the live stream (Slack's RTM websocket, as the website's own), which connects again by itself.
func (a *account) connect() {
	ctx, cancel := context.WithCancel(bg())
	var opts []slack.RTMOption
	if wsDialer != nil {
		d := *wsDialer
		opts = append(opts, slack.RTMOptionDialer(&d))
	}
	rtm := a.cli.NewRTM(opts...)
	mu.Lock()
	if acct != a {
		mu.Unlock()
		cancel()
		return
	}
	a.rtm, a.stop = rtm, cancel
	mu.Unlock()
	go a.consume(ctx, rtm)
	go rtm.ManageConnection()
}

// consume hands what the stream says to onEvent until the stream is let go, then reads on until it falls quiet, so
// the library's own goroutine is never left waiting to say something.
func (a *account) consume(ctx context.Context, rtm *slack.RTM) {
	for {
		select {
		case <-ctx.Done():
			for {
				select {
				case <-rtm.IncomingEvents:
				case <-time.After(10 * time.Second):
					return
				}
			}
		case ev := <-rtm.IncomingEvents:
			a.onEvent(ctx, ev.Data)
		}
	}
}

// setConnected notes whether [a]'s stream is up, and says `connected` or `disconnected` when that changes. Nothing
// is noted or said for an account that is no longer the session.
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
	rtm, stop := a.rtm, a.stop
	mu.Unlock()
	if stop != nil {
		stop()
	}
	if rtm != nil {
		_ = rtm.Disconnect()
	}
	seen.reset()
	return true
}

// ended is Slack turning the session away: everything is forgotten and the app told, to ask for a new sign-in.
func ended(a *account, err error) {
	if !drop(a) {
		return
	}
	log.Warn().Err(err).Msg("Slack ended the session")
	forgetFiles()
	event("unlinked", map[string]any{"error": endedWords(err)})
}

// forgetFiles removes what a session keeps on disk: the saved sign-in, one half written, and the cached pictures.
func forgetFiles() {
	_ = os.Remove(sessionPath())
	_ = os.Remove(sessionPath() + ".new")
	_ = os.RemoveAll(avatarDir())
}

// identity is who the account is, as sign_in's answer and the `linked` event give it.
func (a *account) identity() map[string]any {
	return map[string]any{"me": a.s.Me, "name": a.s.Name, "handle": a.s.Handle}
}

// view is what convert.go needs beside a chat or message to put it in the protocol's shape: the workspace, who the
// person is, and this run's memory of people, channel names and messages' words.
func (a *account) view() view {
	return view{
		team:    a.s.Team,
		me:      a.s.Me,
		person:  func(id string) person { p, _ := seen.person(id); return p },
		channel: func(id string) string { ch, _ := seen.chat(id); return ch.Name },
		parent:  func(ch, ts string) string { n, _ := seen.msg(ch, ts); return n.text },
	}
}

// status answers `status`: whether a session is held, whether its stream is up, and whose it is.
func status() map[string]any {
	mu.Lock()
	defer mu.Unlock()
	if acct == nil {
		return map[string]any{"linked": false, "connected": false, "me": "", "name": "", "handle": ""}
	}
	return map[string]any{"linked": true, "connected": connected, "me": acct.s.Me, "name": acct.s.Name, "handle": acct.s.Handle}
}

// signIn takes the browser's token and cookies, asks Slack whose they are (which is also the check that it takes
// them), keeps the session and connects. The workspace is the one the token is for.
func signIn(ctx context.Context, given map[string]string) (any, error) {
	signLock.Lock()
	defer signLock.Unlock()
	token, cookies, err := credentials(given)
	if err != nil {
		return nil, err
	}
	cli := slack.New(token, clientOptions(cookies)...)
	if fetchVersion {
		if err := cli.FetchVersionData(ctx); err != nil {
			log.Warn().Err(err).Msg("Slack's website version")
		}
	}
	boot, err := cli.ClientUserBootContext(ctx, time.Time{})
	if err != nil {
		log.Warn().Err(err).Msg("sign in")
		return nil, signInWords(err)
	}
	team := boot.Team.ID
	if team == "" {
		// Not seen from Slack, but the token's own workspace is the one auth.test names.
		if who, err := cli.AuthTestContext(ctx); err == nil {
			team = who.TeamID
		}
	}
	if boot.Self.ID == "" || team == "" {
		return nil, errors.New("Slack did not say who this is" + copyAgain)
	}
	me := personOfUser(boot.Self)
	s := session{
		Team:       team,
		TeamName:   boot.Team.Name,
		TeamDomain: boot.Team.Domain,
		Me:         me.ID,
		Name:       me.Name,
		Handle:     me.Handle,
		Token:      token,
		Cookies:    cookies,
	}
	if old := current(); old != nil {
		drop(old)
	}
	if err := saveSession(sessionPath(), s); err != nil {
		log.Err(err).Msg("save session")
		return nil, errors.New("the sign-in could not be kept on this device: " + err.Error())
	}
	a := newAccount(s, cli)
	seen.meet(me)
	for _, ch := range boot.Channels {
		seen.noteChat(ch.Channel)
	}
	for _, ch := range boot.IMs {
		seen.noteChat(ch.Channel)
	}
	mu.Lock()
	acct = a
	mu.Unlock()
	event("linked", a.identity())
	start(a)
	return a.identity(), nil
}

// unlink forgets the session here. Slack is not told: its sign-out would end the browser's session too, since the
// token and cookie are the browser's own.
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
// that moves a file nearly three. A failure that means Slack turned the session away also ends it.
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
		if rejected(err) {
			ended(a, err)
		}
		return nil, plain(err)
	}
	return result, nil
}

// channelOf is the Slack channel of chat [id], or an error in words.
func (a *account) channelOf(id string) (string, error) {
	if id == "" {
		return "", errors.New("no chat was named")
	}
	ch, ok := parseChatID(a.s.Team, id)
	if !ok {
		return "", errors.New("that is not a chat of this Slack workspace")
	}
	return ch, nil
}

// do answers the ops that need a session, each on the Slack channel its chat id names.
func (a *account) do(ctx context.Context, r request) (any, error) {
	switch r.Op {
	case "chats":
		return a.chats(ctx)
	case "history":
		ch, err := a.channelOf(r.Chat)
		if err != nil {
			return nil, err
		}
		return a.history(ctx, ch, r.Before)
	case "send":
		ch, err := a.channelOf(r.To)
		if err != nil {
			return nil, err
		}
		return a.send(ctx, ch, r)
	case "send_media":
		ch, err := a.channelOf(r.To)
		if err != nil {
			return nil, err
		}
		return a.sendMedia(ctx, ch, r)
	case "read":
		ch, err := a.channelOf(r.To)
		if err != nil {
			return nil, err
		}
		return nil, a.read(ctx, ch, r.Upto)
	case "react":
		ch, err := a.channelOf(r.To)
		if err != nil {
			return nil, err
		}
		return nil, a.react(ctx, ch, r.Target, r.Emoji, r.Remove)
	case "delete":
		ch, err := a.channelOf(r.To)
		if err != nil {
			return nil, err
		}
		if r.Target == "" {
			return nil, errors.New("no message to delete")
		}
		_, _, err = a.cli.DeleteMessageContext(ctx, ch, r.Target)
		return nil, err
	case "download":
		return nil, a.download(ctx, r.Pointer, r.Path)
	case "who":
		return a.who(ctx, r.Who)
	case "people":
		return a.people(ctx, r.Query)
	case "open":
		return a.open(ctx, r.Who)
	}
	return nil, fmt.Errorf("the Slack helper does not know %q", r.Op)
}

// --- what this run has seen -----------------------------------------------------------------------------------------

// Slack's events name a channel, a person and a message by id alone. So the helper remembers, in memory only and for
// this run, the chats, people and newest messages that have passed through it.

// msgNote is what is remembered of one message.
type msgNote struct {
	thread string // the thread's first message, for a reply in one
	text   string // in words, for a quote of it
	from   string
}

// msgNotes is how many messages are remembered before the oldest are let go.
const msgNotes = 5000

// memory is what this run has seen, behind its own lock. Chats and people are kept by Slack's id, messages by msgKey.
type memory struct {
	sync.Mutex
	chats map[string]slack.Channel
	said  map[string]bool // chats the app has been told of
	msgs  map[string]msgNote
	// order is the keys of msgs, oldest first: the order they are let go in.
	order []string
	// people: everyone met; asked: those Slack was asked for and did not name, not asked again this run.
	people map[string]person
	asked  map[string]bool
	named  map[string]string // what the last `name` event said of each person
}

// seen is the one memory, emptied when the session is let go.
var seen = newMemory()

func newMemory() *memory {
	m := &memory{}
	m.clear()
	return m
}

// clear empties everything. The caller holds the lock, or is the only one to know of [m] yet.
func (m *memory) clear() {
	m.chats, m.said, m.msgs, m.order = map[string]slack.Channel{}, map[string]bool{}, map[string]msgNote{}, nil
	m.people, m.asked, m.named = map[string]person{}, map[string]bool{}, map[string]string{}
}

func (m *memory) reset() {
	m.Lock()
	defer m.Unlock()
	m.clear()
}

// chat is the channel remembered under Slack's id for it (not the chat id, which carries the workspace too).
func (m *memory) chat(id string) (slack.Channel, bool) {
	m.Lock()
	defer m.Unlock()
	ch, ok := m.chats[id]
	return ch, ok
}

// noteChat remembers a channel, keeping the members already known where this sighting lists none.
func (m *memory) noteChat(ch slack.Channel) {
	if ch.ID == "" {
		return
	}
	m.Lock()
	defer m.Unlock()
	if old, ok := m.chats[ch.ID]; ok {
		if len(ch.Members) == 0 {
			ch.Members = old.Members
		}
		if ch.Name == "" {
			ch.Name = old.Name
		}
	}
	m.chats[ch.ID] = ch
}

// markSaid notes that the app was told of chat [id], and says whether it had been before.
func (m *memory) markSaid(id string) bool {
	m.Lock()
	defer m.Unlock()
	had := m.said[id]
	m.said[id] = true
	return had
}

// msgKey is what a message is remembered under: a ts names a message within its channel only.
func msgKey(ch, ts string) string { return ch + "/" + ts }

// msg is what is remembered of message [ts] of channel [ch].
func (m *memory) msg(ch, ts string) (msgNote, bool) {
	m.Lock()
	defer m.Unlock()
	n, ok := m.msgs[msgKey(ch, ts)]
	return n, ok
}

// noteMsg remembers a message, letting the oldest go past msgNotes. One already held is replaced where it stands.
func (m *memory) noteMsg(ch, ts string, n msgNote) {
	if ts == "" {
		return
	}
	k := msgKey(ch, ts)
	m.Lock()
	defer m.Unlock()
	if _, had := m.msgs[k]; !had {
		m.order = append(m.order, k)
		if len(m.order) > msgNotes {
			delete(m.msgs, m.order[0])
			m.order = m.order[1:]
		}
	}
	m.msgs[k] = n
}

// meet remembers a person, keeping the name, handle and picture already known where this sighting has none.
func (m *memory) meet(p person) {
	if p.ID == "" {
		return
	}
	m.Lock()
	defer m.Unlock()
	if old, ok := m.people[p.ID]; ok {
		p.Name, p.Handle, p.Pic = cmp.Or(p.Name, old.Name), cmp.Or(p.Handle, old.Handle), cmp.Or(p.Pic, old.Pic)
	}
	m.people[p.ID] = p
}

func (m *memory) person(id string) (person, bool) {
	m.Lock()
	defer m.Unlock()
	p, ok := m.people[id]
	return p, ok
}

// toAsk is which of [ids] are not known yet and not asked for already, marking them asked.
func (m *memory) toAsk(ids []string) []string {
	m.Lock()
	defer m.Unlock()
	var want []string
	for _, id := range ids {
		if _, ok := m.people[id]; ok || id == "" || m.asked[id] {
			continue
		}
		m.asked[id] = true
		want = append(want, id)
	}
	return want
}

// newsOf is whether [p] differs from what was last said of them, noting it as said.
func (m *memory) newsOf(p person) bool {
	sig := p.Name + "\n" + p.Handle + "\n" + p.Pic
	m.Lock()
	defer m.Unlock()
	if m.named[p.ID] == sig {
		return false
	}
	m.named[p.ID] = sig
	return true
}

// noteMessage remembers a message of channel [ch]: its thread, its words and sender.
func (a *account) noteMessage(ch string, m slack.Msg) {
	root, _ := inThread(m)
	seen.noteMsg(ch, m.Timestamp, msgNote{thread: root, text: messageText(a.view(), ch, m), from: senderOf(m)})
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

// lookUp asks Slack for whoever of [ids] is not known yet: members by users.info, apps by bots.info.
func (a *account) lookUp(ctx context.Context, ids []string) {
	want := seen.toAsk(ids)
	var wg sync.WaitGroup
	gate := make(chan struct{}, 4)
	for _, id := range want {
		wg.Add(1)
		go func() {
			defer wg.Done()
			gate <- struct{}{}
			defer func() { <-gate }()
			if strings.HasPrefix(id, "B") {
				if b, err := a.cli.GetBotInfoContext(ctx, slack.GetBotInfoParameters{Bot: id, TeamID: a.s.Team}); err == nil && b != nil {
					seen.meet(personOfBot(*b))
				}
				return
			}
			u, err := a.cli.GetUserInfoContext(ctx, id)
			if err != nil {
				log.Debug().Err(err).Str("who", id).Msg("users.info")
				return
			}
			seen.meet(personOfUser(*u))
		}()
	}
	wg.Wait()
}

// avatarName names a person's cached picture: by them and the picture's address, which changes with the picture.
func avatarName(who person) string {
	sum := sha256.Sum256([]byte(who.ID + "\n" + who.Pic))
	return hex.EncodeToString(sum[:12])
}

// avatar is a person's picture as a file under avatars/, fetched once; "" where there is none or it can't be had.
// Slack's picture addresses are public and need no session.
func (a *account) avatar(ctx context.Context, who person) string {
	u, err := url.Parse(who.Pic)
	if who.Pic == "" || err != nil || u.Scheme != "https" {
		return ""
	}
	p := filepath.Join(avatarDir(), avatarName(who))
	if _, err := os.Stat(p); err == nil {
		return p
	}
	ctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, who.Pic, nil)
	if err != nil {
		return ""
	}
	resp, err := httpClient.Do(req)
	if err != nil {
		return ""
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, 4<<20+1))
	if resp.StatusCode != http.StatusOK || err != nil || len(data) == 0 || len(data) > 4<<20 {
		return ""
	}
	_ = os.MkdirAll(avatarDir(), 0o700)
	if os.WriteFile(p, data, 0o600) != nil {
		return ""
	}
	return p
}

// sayName tells the app of someone met in a message, once for each thing known of them.
func (a *account) sayName(id string) {
	who, ok := seen.person(id)
	if !ok || who.Name == "" && who.Pic == "" || !seen.newsOf(who) {
		return
	}
	event("name", map[string]any{"id": who.ID, "name": who.Name, "handle": who.Handle, "avatar": nullable(a.avatar(bg(), who))})
}

// who answers `who`: a member or an app by id, from this run's memory else asked of Slack, with their picture as a
// file.
func (a *account) who(ctx context.Context, id string) (any, error) {
	id = strings.TrimSpace(id)
	if id == "" || !slackIDPattern.MatchString(id) {
		return nil, errors.New("no one was asked for")
	}
	who, ok := seen.person(id)
	if !ok {
		var err error
		if strings.HasPrefix(id, "B") {
			var b *slack.Bot
			if b, err = a.cli.GetBotInfoContext(ctx, slack.GetBotInfoParameters{Bot: id, TeamID: a.s.Team}); err == nil {
				who = personOfBot(*b)
			}
		} else {
			var u *slack.User
			if u, err = a.cli.GetUserInfoContext(ctx, id); err == nil {
				who = personOfUser(*u)
			}
		}
		if err != nil {
			return nil, err
		}
		seen.meet(who)
	}
	return map[string]any{"id": who.ID, "name": who.Name, "handle": who.Handle, "avatar": nullable(a.avatar(ctx, who))}, nil
}

// --- the workspace's members, and a direct message with one (GMFB-61) ------------------------------------------------

// The most members asked for (pages of 200), how many are answered at once, and how long the list is good for.
const (
	peoplePages = 5
	peopleMost  = 50
	peopleFor   = 10 * time.Minute
)

// roster is the workspace's members as last listed, for this run: users.list is the whole workspace a page at a
// time, too much to ask at every letter typed.
var roster struct {
	sync.Mutex
	team string
	at   time.Time
	list []person
}

// members is the workspace's people, listed once every ten minutes: no apps, no one removed, not the person
// themself. The first thousand in a workspace of more; anyone met in a chat is known besides (seen).
func (a *account) members(ctx context.Context) ([]person, error) {
	roster.Lock()
	defer roster.Unlock()
	if roster.team == a.s.Team && roster.list != nil && time.Since(roster.at) < peopleFor {
		return roster.list, nil
	}
	list := []person{}
	p := a.cli.GetUsersPaginated(slack.GetUsersOptionLimit(200), slack.GetUsersOptionTeamID(a.s.Team))
	for page := 0; page < peoplePages; page++ {
		var err error
		if p, err = p.Next(ctx); err != nil {
			if p.Done(err) {
				break
			}
			if len(list) == 0 {
				return nil, err
			}
			break
		}
		for _, u := range p.Users {
			if u.Deleted || u.IsBot || u.IsAppUser || u.ID == a.s.Me || u.ID == "USLACKBOT" {
				continue
			}
			who := personOfUser(u)
			seen.meet(who)
			list = append(list, who)
		}
	}
	sort.SliceStable(list, func(i, j int) bool { return strings.ToLower(list[i].Name) < strings.ToLower(list[j].Name) })
	roster.team, roster.at, roster.list = a.s.Team, time.Now(), list
	return list, nil
}

// people answers `people`: the members whose name or handle has [query] in it (all of them for none), by name, fifty
// at most. No pictures are fetched for a list: `who` gives one person's.
func (a *account) people(ctx context.Context, query string) (any, error) {
	list, err := a.members(ctx)
	if err != nil {
		return nil, err
	}
	q := strings.ToLower(strings.TrimPrefix(strings.TrimSpace(query), "@"))
	out := []map[string]any{}
	for _, who := range list {
		if q != "" && !strings.Contains(strings.ToLower(who.Name), q) && !strings.Contains(strings.ToLower(who.Handle), q) {
			continue
		}
		out = append(out, map[string]any{"id": who.ID, "name": who.Name, "handle": who.Handle, "avatar": nil})
		if len(out) == peopleMost {
			break
		}
	}
	return out, nil
}

// open answers `open`: the direct message with [id], made where there is none yet (conversations.open; nothing is
// sent, and the other person is told nothing). Its chat id.
func (a *account) open(ctx context.Context, id string) (any, error) {
	id = strings.TrimSpace(id)
	if id == "" || !slackIDPattern.MatchString(id) {
		return nil, errors.New("no one was named")
	}
	ch, _, _, err := a.cli.OpenConversationContext(ctx, &slack.OpenConversationParameters{Users: []string{id}, ReturnIM: true})
	if err != nil {
		return nil, err
	}
	if ch == nil || ch.ID == "" {
		return nil, errors.New("Slack did not open a chat with them")
	}
	return map[string]any{"id": chatID(a.s.Team, ch.ID)}, nil
}

// --- chats ----------------------------------------------------------------------------------------------------------

// conversations is every conversation the person is in: channels, private channels, group DMs and DMs, not
// archived ones.
func (a *account) conversations(ctx context.Context) ([]slack.Channel, error) {
	var all []slack.Channel
	cursor := ""
	for range 25 {
		page, next, err := a.cli.GetConversationsForUserContext(ctx, &slack.GetConversationsForUserParameters{
			Types:           []string{"public_channel", "private_channel", "mpim", "im"},
			Limit:           200,
			Cursor:          cursor,
			ExcludeArchived: true,
		})
		if err != nil {
			return nil, err
		}
		all = append(all, page...)
		if next == "" {
			break
		}
		cursor = next
	}
	return all, nil
}

// sidebar is what Slack's sidebar knows of each chat: its newest message and what is unread. Empty where Slack does
// not answer; the chats are then listed in its own order.
func (a *account) sidebar(ctx context.Context) map[string]counts {
	resp, err := a.cli.ClientCountsContext(ctx, &slack.ClientCountsParams{ThreadCountsByChannel: true, OrgWideAware: true})
	if err != nil {
		log.Warn().Err(err).Msg("client.counts")
		return map[string]counts{}
	}
	got := map[string]counts{}
	for _, list := range [][]slack.ClientCountsChannel{resp.Channels, resp.MpIMs, resp.IMs} {
		for _, c := range list {
			got[c.ID] = counts{Latest: c.Latest, Unreads: c.HasUnreads, Mentions: c.MentionCount}
		}
	}
	return got
}

// filled is [ch] with what a `chat` needs that a listing leaves out: a group DM's members.
func (a *account) filled(ctx context.Context, ch slack.Channel) slack.Channel {
	if known, ok := seen.chat(ch.ID); ok && len(ch.Members) == 0 {
		ch.Members = known.Members
	}
	if ch.IsMpIM && len(ch.Members) == 0 {
		if ids, _, err := a.cli.GetUsersInConversationContext(ctx, &slack.GetUsersInConversationParameters{ChannelID: ch.ID, Limit: 50}); err == nil {
			ch.Members = ids
		}
	}
	seen.noteChat(ch)
	return ch
}

// newest is a chat's newest message (not a reply in a thread), or nil.
func (a *account) newest(ctx context.Context, ch string) *slack.Msg {
	resp, err := a.cli.GetConversationHistoryContext(ctx, &slack.GetConversationHistoryParameters{ChannelID: ch, Limit: 1})
	if err != nil || len(resp.Messages) == 0 {
		return nil
	}
	for _, m := range resp.Messages {
		if shown(m.Msg) {
			m := m.Msg
			return &m
		}
	}
	return nil
}

// chatsOf turns [list] into `chat`s, in its order: each with its members named, its newest message and the other
// person's picture, fetched a few at a time.
func (a *account) chatsOf(ctx context.Context, list []slack.Channel, side map[string]counts, latest map[string]*slack.Msg) []chatOut {
	full := make([]slack.Channel, len(list))
	newest := make([]*slack.Msg, len(list))
	var wg sync.WaitGroup
	gate := make(chan struct{}, 4)
	for i, ch := range list {
		wg.Add(1)
		go func() {
			defer wg.Done()
			gate <- struct{}{}
			defer func() { <-gate }()
			full[i] = a.filled(ctx, ch)
			if m, ok := latest[ch.ID]; ok {
				newest[i] = m
			} else {
				newest[i] = a.newest(ctx, ch.ID)
			}
		}()
	}
	wg.Wait()
	var ids []string
	for i, ch := range full {
		if ch.IsIM {
			ids = append(ids, ch.User)
		}
		if ch.IsMpIM {
			ids = append(ids, ch.Members...)
		}
		if m := newest[i]; m != nil {
			ids = append(ids, senderOf(*m))
			ids = append(ids, mentions(m.Text)...)
		}
	}
	a.lookUp(ctx, ids)
	v := a.view()
	outList := make([]chatOut, len(full))
	for i, ch := range full {
		wg.Add(1)
		go func() {
			defer wg.Done()
			gate <- struct{}{}
			defer func() { <-gate }()
			if m := newest[i]; m != nil {
				a.noteMessage(ch.ID, *m)
			}
			outList[i] = chatOf(v, ch, side[ch.ID], newest[i], func(p person) string { return a.avatar(ctx, p) })
		}()
	}
	wg.Wait()
	return outList
}

// sayChats says each of [list] as a `chat` event, noting that the app has now been told of it.
func (a *account) sayChats(list []chatOut) {
	for _, c := range list {
		if ch, ok := parseChatID(a.s.Team, c.ID); ok {
			seen.markSaid(ch)
		}
		event("chat", fields(c))
	}
}

// chats is the chats with the newest messages, as Slack's sidebar orders them by its newest messages.
func (a *account) chats(ctx context.Context) ([]chatOut, error) {
	all, err := a.conversations(ctx)
	if err != nil {
		return nil, err
	}
	side := a.sidebar(ctx)
	var list []slack.Channel
	for _, ch := range all {
		// users.conversations lists the DMs of everyone the person ever had one with; Slack's sidebar shows the
		// open ones and those with something in them.
		if ch.IsIM && ch.IsUserDeleted {
			continue
		}
		list = append(list, ch)
	}
	sort.SliceStable(list, func(i, j int) bool { return side[list[i].ID].Latest > side[list[j].ID].Latest })
	if len(list) > pageSize {
		list = list[:pageSize]
	}
	got := a.chatsOf(ctx, list, side, nil)
	a.sayChats(got)
	return got, nil
}

// syncChats asks for the chats and says each as a `chat` event. It is how a saved session is checked when the helper
// starts, and how the app learns what changed while the stream was down.
func (a *account) syncChats(ctx context.Context) {
	a.syncLock.Lock()
	defer a.syncLock.Unlock()
	if current() != a {
		return
	}
	if _, err := a.chats(ctx); err != nil {
		log.Warn().Err(err).Msg("sync chats")
		if rejected(err) {
			ended(a, err)
		}
	}
}

// sayChat tells the app of one chat again (it was renamed, joined, or a message came in it): asked of Slack, with
// [latest] as its newest message where one just came.
func (a *account) sayChat(ctx context.Context, ch string, latest *slack.Msg) {
	info, err := a.cli.GetConversationInfoContext(ctx, &slack.GetConversationInfoInput{ChannelID: ch})
	if err != nil {
		log.Warn().Err(err).Msg("conversations.info")
		return
	}
	var given map[string]*slack.Msg
	if latest != nil {
		given = map[string]*slack.Msg{ch: latest}
	}
	a.sayChats(a.chatsOf(ctx, []slack.Channel{*info}, nil, given))
}

// groupOf is whether chat [ch] is a group, from what this run knows of it, else asked of Slack.
func (a *account) groupOf(ctx context.Context, ch string) bool {
	if known, ok := seen.chat(ch); ok {
		return isGroup(known)
	}
	if strings.HasPrefix(ch, "D") {
		return false
	}
	if info, err := a.cli.GetConversationInfoContext(ctx, &slack.GetConversationInfoInput{ChannelID: ch}); err == nil {
		seen.noteChat(*info)
		return isGroup(*info)
	}
	return true
}

// --- history --------------------------------------------------------------------------------------------------------

// history is a page of a chat's messages older than [before] (the newest, with none), oldest first. Slack's history
// holds a channel's own messages; the replies of the threads under them are asked for beside, and put among them,
// each quoting the thread's first message.
func (a *account) history(ctx context.Context, ch, before string) (any, error) {
	resp, err := a.cli.GetConversationHistoryContext(ctx, &slack.GetConversationHistoryParameters{ChannelID: ch, Latest: before, Limit: pageSize})
	if err != nil {
		return nil, err
	}
	var page []slack.Msg
	have := map[string]bool{}
	var parents []string
	for _, m := range resp.Messages {
		if before != "" && m.Timestamp >= before {
			continue
		}
		page = append(page, m.Msg)
		have[m.Timestamp] = true
		if m.ReplyCount > 0 && len(parents) < threadsPerPage {
			if _, reply := inThread(m.Msg); !reply {
				parents = append(parents, m.Timestamp)
			}
		}
	}
	more := resp.HasMore
	for _, m := range page {
		a.noteMessage(ch, m)
	}
	replies := make([][]slack.Message, len(parents))
	var wg sync.WaitGroup
	gate := make(chan struct{}, 3)
	for i, root := range parents {
		wg.Add(1)
		go func() {
			defer wg.Done()
			gate <- struct{}{}
			defer func() { <-gate }()
			r, err := a.cli.GetConversationRepliesContext(ctx, &slack.GetConversationRepliesParameters{
				GetConversationHistoryParameters: slack.GetConversationHistoryParameters{ChannelID: ch, Limit: repliesPerThread},
				Timestamp:                        root,
			})
			if err != nil {
				log.Warn().Err(err).Msg("conversations.replies")
				return
			}
			replies[i] = r.Messages
		}()
	}
	wg.Wait()
	for _, list := range replies {
		for _, m := range list {
			if have[m.Timestamp] {
				continue
			}
			have[m.Timestamp] = true
			page = append(page, m.Msg)
		}
	}
	var ids []string
	for _, m := range page {
		ids = append(ids, senderOf(m))
		ids = append(ids, mentions(m.Text)...)
		for _, r := range m.Reactions {
			ids = append(ids, r.Users...)
		}
	}
	a.lookUp(ctx, ids)
	group := a.groupOf(ctx, ch)
	list := []messageOut{}
	v := a.view()
	for _, m := range page {
		a.noteMessage(ch, m)
		if shown(m) {
			list = append(list, messageOf(v, ch, group, m))
		}
	}
	sort.SliceStable(list, func(i, j int) bool { return list[i].ID < list[j].ID })
	go func() {
		for _, m := range page {
			a.sayName(senderOf(m))
		}
	}()
	return map[string]any{"messages": list, "more": more}, nil
}

// --- sending --------------------------------------------------------------------------------------------------------

// threadOf is the thread a reply to message [ts] goes into: the thread it is in, or the one it begins.
func (a *account) threadOf(ctx context.Context, ch, ts string) string {
	if n, ok := seen.msg(ch, ts); ok {
		return cmp.Or(n.thread, ts)
	}
	r, err := a.cli.GetConversationRepliesContext(ctx, &slack.GetConversationRepliesParameters{
		GetConversationHistoryParameters: slack.GetConversationHistoryParameters{ChannelID: ch, Limit: 1, Inclusive: true},
		Timestamp:                        ts,
	})
	if err == nil && len(r.Messages) > 0 {
		m := r.Messages[0]
		return cmp.Or(m.ThreadTimestamp, m.Timestamp, ts)
	}
	return ts
}

// send posts words to a chat; with a quote, as a reply in the quoted message's thread. The answer's id is the new
// message's ts.
func (a *account) send(ctx context.Context, ch string, r request) (any, error) {
	if strings.TrimSpace(r.Text) == "" {
		return nil, errors.New("nothing to send")
	}
	// The words go as written: "<", ">" and "&" are escaped so Slack takes none of them for its own markup.
	opts := []slack.MsgOption{slack.MsgOptionText(r.Text, true)}
	thread := ""
	if r.Quote != nil && r.Quote.ID != "" {
		thread = a.threadOf(ctx, ch, r.Quote.ID)
		opts = append(opts, slack.MsgOptionTS(thread))
	}
	_, ts, err := a.cli.PostMessageContext(ctx, ch, opts...)
	if err != nil {
		return nil, err
	}
	seen.noteMsg(ch, ts, msgNote{thread: thread, text: r.Text, from: a.s.Me})
	return map[string]any{"id": ts, "ts": cmp.Or(tsMillis(ts), time.Now().UnixMilli())}, nil
}

// shareTS is the message [f] was shared into [ch] as, or "".
func shareTS(f *slack.File, ch string) string {
	if f == nil {
		return ""
	}
	for _, shares := range []map[string][]slack.ShareFileInfo{f.Shares.Private, f.Shares.Public} {
		if s := shares[ch]; len(s) > 0 && s[0].Ts != "" {
			return s[0].Ts
		}
	}
	return ""
}

// sendMedia hands Slack a file, shared into the chat with the words beside it, as its website does.
func (a *account) sendMedia(ctx context.Context, ch string, r request) (any, error) {
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
	params := slack.UploadFileParameters{Reader: f, FileSize: int(st.Size()), Filename: name, Title: name, Channel: ch, InitialComment: r.Text}
	if r.Quote != nil && r.Quote.ID != "" {
		params.ThreadTimestamp = a.threadOf(ctx, ch, r.Quote.ID)
	}
	file, err := a.cli.UploadFileContext(ctx, params)
	if err != nil {
		return nil, err
	}
	// Slack shares the file into the chat a moment after taking it: the message it became is asked for until then.
	ts := shareTS(file, ch)
	for i := 0; ts == "" && i < fileShareWaitAttempt; i++ {
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-time.After(fileShareWait):
		}
		if info, _, _, err := a.cli.GetFileInfoContext(ctx, file.ID, 0, 0); err == nil {
			ts = shareTS(info, ch)
		}
	}
	if ts == "" {
		// Sent, but Slack has not said as what yet: the stream says the message when it does.
		log.Warn().Int64("req", r.ID).Msg("the file was taken but not yet shared")
		return map[string]any{"id": "", "ts": time.Now().UnixMilli()}, nil
	}
	seen.noteMsg(ch, ts, msgNote{thread: params.ThreadTimestamp, text: r.Text, from: a.s.Me})
	return map[string]any{"id": ts, "ts": tsMillis(ts)}, nil
}

// read marks a chat read up to [upto] (its newest message, with none). A reply in a thread marks its thread, and the
// chat up to the newest of its own messages at that time: Slack keeps the two apart.
func (a *account) read(ctx context.Context, ch, upto string) error {
	if upto == "" {
		m := a.newest(ctx, ch)
		if m == nil {
			return nil
		}
		upto = m.Timestamp
	}
	n, known := seen.msg(ch, upto)
	if !known || n.thread == "" || n.thread == upto {
		return a.cli.MarkConversationContext(ctx, ch, upto)
	}
	if err := a.cli.MarkThreadContext(ctx, ch, n.thread, upto); err != nil {
		return err
	}
	resp, err := a.cli.GetConversationHistoryContext(ctx, &slack.GetConversationHistoryParameters{ChannelID: ch, Latest: upto, Inclusive: true, Limit: 1})
	if err != nil || len(resp.Messages) == 0 {
		return err
	}
	return a.cli.MarkConversationContext(ctx, ch, resp.Messages[0].Timestamp)
}

// react adds or removes the person's reaction to a message. Slack takes an emoji by its name; a reaction already
// there, or already gone, is no error.
func (a *account) react(ctx context.Context, ch, target, e string, remove bool) error {
	if target == "" || e == "" {
		return errors.New("a reaction needs a message and an emoji")
	}
	name := reactionName(e)
	if name == "" {
		return errors.New("Slack has no emoji for that")
	}
	ref := slack.NewRefToMessage(ch, target)
	if remove {
		if err := a.cli.RemoveReactionContext(ctx, name, ref); err != nil && errCode(err) != "no_reaction" {
			return err
		}
		return nil
	}
	if err := a.cli.AddReactionContext(ctx, name, ref); err != nil && errCode(err) != "already_reacted" {
		return err
	}
	return nil
}

// --- files ----------------------------------------------------------------------------------------------------------

// parsePointer reads a `download`'s pointer: the object a message gave, or that object as a string.
func parsePointer(raw json.RawMessage) (pointer, error) {
	var p pointer
	var inner string
	if json.Unmarshal(raw, &inner) == nil {
		raw = json.RawMessage(inner)
	}
	if err := json.Unmarshal(raw, &p); err != nil || !slackIDPattern.MatchString(p.File) {
		return p, errors.New("that is not a Slack file")
	}
	if p.URL != "" {
		// The library sends the session only to Slack's own file host, and refuses any other address.
		if u, err := url.Parse(p.URL); err != nil || u.Scheme != "https" || u.Host != "files.slack.com" {
			return p, errors.New("that is not a Slack file")
		}
	}
	return p, nil
}

// download writes a message's file to [path], whole or not at all: from the address the message gave, else from a
// fresh one asked of Slack.
func (a *account) download(ctx context.Context, raw json.RawMessage, path string) error {
	p, err := parsePointer(raw)
	if err != nil {
		return err
	}
	if path == "" {
		return errors.New("nowhere to write the file")
	}
	fetch := func(link string) error {
		resp, err := a.cli.GetFileResponseContext(ctx, link)
		if err != nil {
			return err
		}
		defer resp.Body.Close()
		tmp := path + ".part"
		f, err := os.OpenFile(tmp, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
		if err != nil {
			return errors.New("the file could not be written: " + err.Error())
		}
		_, err = io.Copy(f, resp.Body)
		if cerr := f.Close(); err == nil {
			err = cerr
		}
		if err != nil {
			_ = os.Remove(tmp)
			return err
		}
		return os.Rename(tmp, path)
	}
	if p.URL != "" {
		if err = fetch(p.URL); err == nil {
			return nil
		}
		log.Warn().Err(err).Msg("download from the message's address")
	}
	info, _, _, ierr := a.cli.GetFileInfoContext(ctx, p.File, 0, 0)
	if ierr != nil {
		return ierr
	}
	link := cmp.Or(info.URLPrivateDownload, info.URLPrivate)
	if link == "" || info.IsExternal {
		return errors.New("Slack keeps no copy of that file to download")
	}
	if link == p.URL && err != nil {
		return err
	}
	return fetch(link)
}

// --- what Slack says, live ------------------------------------------------------------------------------------------

// chatOfChannel is the chat id the app knows channel [ch] by.
func (a *account) chatOfChannel(ch string) string { return chatID(a.s.Team, ch) }

// onEvent takes one thing the live stream said: the connection's own state, messages, reactions, reads, and changes
// to chats and people. Nothing once [a] is no longer the session.
func (a *account) onEvent(ctx context.Context, data any) {
	if current() != a {
		return
	}
	switch ev := data.(type) {
	case *slack.HelloEvent:
		setConnected(a, true)
		if a.helloed.Swap(true) && !ev.Resume {
			// Connected again: what changed meanwhile. Not on the stream's own goroutine.
			go a.syncChats(bg())
		}
	case *slack.DisconnectedEvent:
		if !ev.Intentional {
			log.Warn().Err(ev.Cause).Msg("the live connection dropped; the library connects again")
			setConnected(a, false)
		}
	case *slack.InvalidAuthEvent:
		ended(a, slack.SlackErrorResponse{Err: "invalid_auth"})
	case *slack.ConnectionErrorEvent:
		setConnected(a, false)
		log.Warn().Err(ev.ErrorObj).Msg("the live connection could not be opened; the library tries again")
		go func() {
			// A refusal at the door may be the session ended: auth.test says which.
			if _, err := a.cli.AuthTestContext(bg()); err != nil && rejected(err) {
				ended(a, err)
			}
		}()
	case *slack.FatalConnectionErrorEvent:
		setConnected(a, false)
		log.Error().Msg("the live connection gave up; trying again in a minute")
		go func() {
			time.Sleep(reconnectAfterFatal)
			if current() == a {
				a.connect()
			}
		}()
	case *slack.MessageEvent:
		a.onMessage(ctx, ev)
	case *slack.ReactionAddedEvent:
		a.onReaction(ev.Item, ev.User, ev.Reaction, false)
	case *slack.ReactionRemovedEvent:
		a.onReaction(ev.Item, ev.User, ev.Reaction, true)
	case *slack.ChannelMarkedEvent:
		a.onMarked(ev.Channel, ev.Timestamp)
	case *slack.IMMarkedEvent:
		a.onMarked(ev.Channel, ev.Timestamp)
	case *slack.GroupMarkedEvent:
		a.onMarked(ev.Channel, ev.Timestamp)
	case *slack.ThreadMarkedEvent:
		a.onMarked(ev.Subscription.Channel, ev.Subscription.LastRead)
	case *slack.ChannelJoinedEvent:
		seen.noteChat(ev.Channel)
		go a.sayChat(bg(), ev.Channel.ID, nil)
	case *slack.GroupJoinedEvent:
		seen.noteChat(ev.Channel)
		go a.sayChat(bg(), ev.Channel.ID, nil)
	case *slack.ChannelRenameEvent:
		go a.sayChat(bg(), ev.Channel.ID, nil)
	case *slack.GroupRenameEvent:
		go a.sayChat(bg(), ev.Group.ID, nil)
	case *slack.ChannelUpdateEvent:
		go a.sayChat(bg(), ev.Channel, nil)
	case *slack.UserChangeEvent:
		seen.meet(personOfUser(ev.User))
		go a.sayName(ev.User.ID)
	case *slack.UserProfileChangedEvent:
		seen.meet(personOfUser(ev.User))
		go a.sayName(ev.User.ID)
	case *slack.ChannelLeftEvent, *slack.GroupLeftEvent:
		// The protocol has no word for a chat left; the app keeps what it has.
		log.Info().Msg("a chat was left on Slack")
	}
}

// onMessage takes a message event, which is also how Slack says a deletion, an edit and a chat's renaming: the
// subtype tells which. A new message is said as `message`, after its chat where the app has not been told of it.
func (a *account) onMessage(ctx context.Context, ev *slack.MessageEvent) {
	ch := ev.Channel
	if ch == "" {
		return
	}
	switch ev.SubType {
	case slack.MsgSubTypeMessageDeleted:
		if ev.DeletedTimestamp != "" {
			event("deleted", map[string]any{"chat": a.chatOfChannel(ch), "target": ev.DeletedTimestamp})
		}
		return
	case slack.MsgSubTypeMessageChanged:
		sub := ev.SubMessage
		if sub == nil || sub.Timestamp == "" {
			return
		}
		if sub.SubType == "tombstone" {
			// A thread's first message deleted: Slack leaves a note in its place for the replies to hang from.
			event("deleted", map[string]any{"chat": a.chatOfChannel(ch), "target": sub.Timestamp})
			return
		}
		// Slack changes a message for many things (a reply's count, a link's preview): only a change of its words is
		// an edit.
		before, known := seen.msg(ch, sub.Timestamp)
		if ev.PreviousMessage != nil && ev.PreviousMessage.Text == sub.Text {
			return
		}
		a.lookUp(ctx, mentions(sub.Text))
		text := messageText(a.view(), ch, *sub)
		if known && before.text == text {
			return
		}
		a.noteMessage(ch, *sub)
		event("edited", map[string]any{"chat": a.chatOfChannel(ch), "target": sub.Timestamp, "text": text})
		return
	case slack.MsgSubTypeChannelName, slack.MsgSubTypeGroupName, slack.MsgSubTypeChannelTopic, slack.MsgSubTypeGroupTopic,
		slack.MsgSubTypeChannelPurpose, slack.MsgSubTypeGroupPurpose:
		go a.sayChat(bg(), ch, nil)
		return
	}
	if !shown(ev.Msg) || ev.Timestamp == "" {
		return
	}
	a.lookUp(ctx, append(mentions(ev.Text), senderOf(ev.Msg)))
	if _, reply := inThread(ev.Msg); reply {
		if root := ev.ThreadTimestamp; root != "" {
			if _, known := seen.msg(ch, root); !known && ev.Root != nil {
				a.noteMessage(ch, *ev.Root)
			}
		}
	}
	a.noteMessage(ch, ev.Msg)
	if !seen.markSaid(ch) {
		// The first message of a chat the app has not been told of: the chat first.
		latest := ev.Msg
		a.sayChat(ctx, ch, &latest)
	}
	m := messageOf(a.view(), ch, a.groupOf(ctx, ch), ev.Msg)
	event("message", fields(m))
	go a.sayName(senderOf(ev.Msg))
}

// onReaction says a reaction added or removed, Slack's name for the emoji turned back into the emoji.
func (a *account) onReaction(item slack.ReactionItem, from, name string, remove bool) {
	if item.Channel == "" || item.Timestamp == "" || from == "" || name == "" {
		// A reaction to a file, not a message.
		return
	}
	event("reaction", map[string]any{"chat": a.chatOfChannel(item.Channel), "from": from, "target": item.Timestamp, "emoji": reactionEmoji(name), "remove": remove})
}

// onMarked is the person reading a chat (or a thread in it) in Slack's own app. Slack says nothing of others' reads.
func (a *account) onMarked(ch, ts string) {
	if ch == "" || ts == "" {
		return
	}
	event("receipt", map[string]any{"chat": a.chatOfChannel(ch), "from": a.s.Me, "id": ts, "ts": tsMillis(ts), "kind": "read"})
}

// --- the log file ---------------------------------------------------------------------------------------------------

// logFile is slack.log in the session's folder, begun afresh past a megabyte; standard error alone where it can't
// open.
func logFile() io.Writer {
	path := filepath.Join(dir, "slack.log")
	if st, err := os.Stat(path); err == nil && st.Size() > 1<<20 {
		_ = os.Remove(path)
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return io.Discard
	}
	return f
}
