// Uplink's Discord helper (README.md, PROTOCOL.md). AGPL-3.0, as mautrix-discord, whose way of signing in
// as a person (beeper's discordgo fork, speaking as Discord's website does) it is built on.
//
// It signs in to Discord as the person, with the token of a browser signed in to their account, behaves as the
// website does, and speaks JSON lines over standard input and output: the protocol all of Uplink's account helpers
// share (../ACCOUNT_HELPERS.md). Requests, each with an "id" its answer carries back:
//
//	{"id":1,"op":"status"}                                     → {"linked","connected","me","name","handle"}
//	{"id":2,"op":"sign_in","cookies":{"token":"…"}}            → {"me","name","handle"}, and the event "linked"
//	{"id":3,"op":"unlink"}                                     → null; everything kept is forgotten
//	{"id":4,"op":"chats"}                                      → [<chat>…], the newest direct messages and groups
//	{"id":5,"op":"history","chat":"…","before":"<message id>"} → {"messages":[…],"more":bool}, oldest first
//	{"id":6,"op":"send","to":"…","text":"…","quote":{"id"}}    → {"id":"<message id>","ts":…}
//	{"id":7,"op":"send_media","to":"…","path":"…","mime":"…","name":"…","text":"…"} → {"id","ts"}
//	{"id":8,"op":"read","to":"…","upto":"<message id>"}        → null
//	{"id":9,"op":"react","to":"…","target":"…","emoji":"👍","remove":false} → null
//	{"id":10,"op":"delete","to":"…","target":"…"}              → null (your own message, deleted for everyone)
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
	"regexp"
	"slices"
	"strings"
	"sync"
	"time"

	"github.com/bwmarrin/discordgo"
	"github.com/rs/zerolog"
	"go.mau.fi/util/variationselector"
)

const (
	// chatsListed is how many direct messages and groups `chats` gives, the newest first.
	chatsListed = 20
	// chatsSaid is how many are said as `chat` events each time the gateway connects afresh.
	chatsSaid = 50
	// pageSize is how many messages a page of history asks for, as Discord's website does.
	pageSize = 50
)

// quote is the message a `send` or `send_media` replies to, as the app names it.
type quote struct {
	ID string `json:"id"`
	// What the app knows of the quoted message. Not needed: Discord wants the message's id alone.
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
	// Taken and not needed: Discord pages history by message id.
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

// account is one signed-in session: the library's client and who it is.
type account struct {
	cli    client
	token  string
	me     string
	name   string
	handle string

	// How far each channel has been read, as Discord last said (READY, then read marks).
	readLock sync.Mutex
	reads    map[string]readMark
	// Closed when the session is let go: a connection being retried stops.
	stop chan struct{}
}

var (
	// dir is the folder the session, the log and the cached pictures are kept in (--dir). out is standard output,
	// written a whole line at a time under outLock.
	dir     string
	log     = zerolog.Nop()
	out     = json.NewEncoder(os.Stdout)
	outLock sync.Mutex

	// mu guards acct (the session, nil while signed out) and connected (whether its gateway connection is up).
	mu        sync.Mutex
	acct      *account
	connected bool
	// One sign-in or sign-out at a time.
	signLock sync.Mutex
	// The requests being answered, which quitting waits for.
	inflight sync.WaitGroup
	// What the helper does beside the requests (spawn).
	background sync.WaitGroup
)

// spawn runs [f] beside the caller. Every such goroutine is counted, so the tests can wait for them all.
func spawn(f func()) {
	background.Add(1)
	go func() {
		defer background.Done()
		f()
	}()
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
	flag.StringVar(&dir, "dir", "", "where the Discord session is kept")
	flag.Parse()
	if dir == "" {
		fmt.Fprintln(os.Stderr, "--dir is needed")
		os.Exit(2)
	}
	_ = os.MkdirAll(dir, 0o700)
	// The log goes to standard error (Uplink's developer log) and discord.log beside the session; never stdout.
	log = zerolog.New(zerolog.MultiLevelWriter(os.Stderr, logFile())).With().Timestamp().Logger().Level(zerolog.InfoLevel)
	out.SetEscapeHTML(false)
	serve(os.Stdin)
}

// serve says "ready", then answers each line of [in] until it ends.
func serve(in io.Reader) {
	var a *account
	if s := loadSession(sessionPath()); s != nil {
		made, err := newAccount(*s)
		if err != nil {
			log.Err(err).Msg("make the client for the saved session")
		} else {
			a = made
			mu.Lock()
			acct = a
			mu.Unlock()
		}
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
			a.keep()
			a.cli.Close()
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

// bg is the context of work no request bounds.
func bg() context.Context { return context.Background() }

// --- the session ----------------------------------------------------------------------------------------------------

// errNotLinked answers every op but status, sign_in and unlink while no one is signed in.
var errNotLinked = errors.New("not signed in to Discord")

// current is the signed-in account, or nil.
func current() *account {
	mu.Lock()
	defer mu.Unlock()
	return acct
}

// newAccount makes the library's client for a session. Nothing is asked of Discord yet.
func newAccount(s session) (*account, error) {
	a := &account{token: s.Token, me: s.Me, name: s.Name, handle: s.Handle, reads: map[string]readMark{}, stop: make(chan struct{})}
	cli, err := newClient(s.Token, s.Heartbeat, a.onEvent)
	if err != nil {
		return nil, err
	}
	a.cli = cli
	return a, nil
}

// start connects the gateway in the background, trying again (a little longer each time) while it can't, until
// Discord refuses the token or the session is let go. Once connected, the library keeps the connection itself.
func start(a *account) {
	spawn(func() {
		wait := 5 * time.Second
		for {
			err := a.cli.Open()
			if err == nil {
				return
			}
			if rejected(err) {
				ended(a, err)
				return
			}
			log.Warn().Err(err).Dur("again_in", wait).Msg("connect to Discord")
			select {
			case <-a.stop:
				return
			case <-time.After(wait):
			}
			wait = min(wait*2, 5*time.Minute)
		}
	})
}

// setConnected notes whether [a]'s gateway connection is up, and says `connected` or `disconnected` when that
// changes. Nothing is noted or said for an account that is no longer the session.
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
	connected = false
	mu.Unlock()
	close(a.stop)
	// In the background: the gateway's own goroutine may be the caller.
	spawn(a.cli.Close)
	seen.reset()
	return true
}

// ended is Discord turning the session away: everything is forgotten and the app told, to ask for a new sign-in.
func ended(a *account, err error) {
	if !drop(a) {
		return
	}
	log.Warn().Err(err).Msg("Discord ended the session")
	forgetFiles()
	event("unlinked", map[string]any{"error": endedWords(err)})
}

// forgetFiles removes what a session keeps on disk: the saved sign-in, one half written, and the cached pictures.
func forgetFiles() {
	_ = os.Remove(sessionPath())
	_ = os.Remove(sessionPath() + ".new")
	_ = os.RemoveAll(avatarDir())
}

// keep writes the session again, with the app's heartbeat session as it now is.
func (a *account) keep() {
	if current() != a {
		return
	}
	if err := saveSession(sessionPath(), a.session()); err != nil {
		log.Err(err).Msg("keep the session")
	}
}

// session is the account as session.json holds it.
func (a *account) session() session {
	return session{Me: a.me, Name: a.name, Handle: a.handle, Token: a.token, Heartbeat: a.cli.Heartbeat()}
}

// identity is who the account is, as sign_in's answer and the `linked` event give it.
func (a *account) identity() map[string]any {
	return map[string]any{"me": a.me, "name": a.name, "handle": a.handle}
}

// status answers `status`: whether a session is held, whether its connection is up, and whose it is.
func status() map[string]any {
	mu.Lock()
	defer mu.Unlock()
	if acct == nil {
		return map[string]any{"linked": false, "connected": false, "me": "", "name": "", "handle": ""}
	}
	return map[string]any{"linked": true, "connected": connected, "me": acct.me, "name": acct.name, "handle": acct.handle}
}

// signIn takes the browser's token and connects with it: Discord's READY says whose it is, which is also the check
// that it takes it. Then the session is kept and the chats said.
func signIn(cookies map[string]string) (any, error) {
	signLock.Lock()
	defer signLock.Unlock()
	token, err := tokenOf(cookies)
	if err != nil {
		return nil, err
	}
	a, err := newAccount(session{Token: token})
	if err != nil {
		return nil, signInWords(err)
	}
	if err := a.cli.Open(); err != nil {
		a.cli.Close()
		log.Warn().Err(err).Msg("sign in")
		return nil, signInWords(err)
	}
	me := personOf(a.cli.Me(), nil)
	if me.ID == "" {
		a.cli.Close()
		return nil, errors.New("Discord answered without saying whose the token is. Try again.")
	}
	a.me, a.name, a.handle = me.ID, me.Name, me.Handle
	if old := current(); old != nil {
		drop(old)
	}
	if err := saveSession(sessionPath(), a.session()); err != nil {
		a.cli.Close()
		log.Err(err).Msg("save session")
		return nil, errors.New("the sign-in could not be kept on this device: " + err.Error())
	}
	seen.meet(me)
	mu.Lock()
	acct, connected = a, true
	mu.Unlock()
	event("linked", a.identity())
	event("connected", nil)
	// READY reached the event handler before the session was kept, and was let pass: what it said, now.
	a.takeReads(a.cli.ReadState())
	spawn(func() { a.sayChats(bg(), chatsSaid) })
	return a.identity(), nil
}

// unlink forgets the session here. Discord is not told: its sign-out would end the browser's session too, since
// the token is the browser's own.
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
// that moves a file nearly three. A failure that means Discord turned the session away also ends it.
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
		return signIn(r.Cookies)
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
		// A file's address answers on its own account; anything else answering 401 is the session.
		if r.Op != "download" && rejected(err) {
			ended(a, err)
		}
		return nil, plain(err)
	}
	return result, nil
}

// do answers the ops that need a session.
func (a *account) do(ctx context.Context, r request) (any, error) {
	switch r.Op {
	case "chats":
		return a.sayChats(ctx, chatsListed), nil
	case "history":
		return a.history(ctx, r.Chat, r.Before)
	case "send":
		return a.send(ctx, r, nil)
	case "send_media":
		att, err := a.upload(ctx, r)
		if err != nil {
			return nil, err
		}
		return a.send(ctx, r, att)
	case "read":
		return nil, a.read(ctx, r.To, r.Upto)
	case "react":
		c, err := parseChat(r.To)
		if err != nil {
			return nil, err
		}
		if !snowflake(r.Target) || strings.TrimSpace(r.Emoji) == "" {
			return nil, errors.New("a reaction needs a message and an emoji")
		}
		return nil, a.cli.React(ctx, c, r.Target, reactionEmoji(r.Emoji), r.Remove)
	case "delete":
		c, err := parseChat(r.To)
		if err != nil {
			return nil, err
		}
		if !snowflake(r.Target) {
			return nil, errors.New("no message to delete")
		}
		return nil, a.cli.Delete(ctx, c, r.Target)
	case "download":
		return nil, a.download(ctx, r.Pointer, r.Path)
	case "who":
		return a.who(ctx, r.Who)
	}
	return nil, fmt.Errorf("the Discord helper does not know %q", r.Op)
}

// customEmojiTag is a server's own emoji as a message writes it: <:name:id>, or <a:name:id> for a moving one.
var customEmojiTag = regexp.MustCompile(`^<a?:([A-Za-z0-9_~]+):([0-9]+)>$`)

// reactionEmoji is the emoji as Discord wants it: fully qualified (❤ as ❤️), or a server's own as name:id (given
// as name:id, or as a message writes it, <:name:id>).
func reactionEmoji(e string) string {
	e = strings.TrimSpace(e)
	if m := customEmojiTag.FindStringSubmatch(e); m != nil {
		return m[1] + ":" + m[2]
	}
	if name, id, ok := strings.Cut(e, ":"); ok && name != "" && snowflake(id) {
		return e
	}
	return variationselector.FullyQualify(e)
}

// --- what this run has seen -----------------------------------------------------------------------------------------

// The helper remembers, in memory only and for this run, the chats it has told the app of, the words of the
// newest messages (so an edit is told only when the words change) and the people met.

// msgNotes is how many messages are remembered before the oldest are let go.
const msgNotes = 5000

// memory is what this run has seen, behind its own lock.
type memory struct {
	sync.Mutex
	// chats: the chat ids the app has been told of. msgs: each remembered message's words as Discord wrote them, by
	// message id; order: those ids, oldest first, the order they are let go in.
	chats  map[string]bool
	msgs   map[string]string
	order  []string
	people map[string]person
	// What the last `name` event said of each person, so the same thing is not said twice.
	said map[string]string
}

// seen is the one memory, emptied when the session is let go.
var seen = newMemory()

func newMemory() *memory {
	return &memory{chats: map[string]bool{}, msgs: map[string]string{}, people: map[string]person{}, said: map[string]string{}}
}

func (m *memory) reset() {
	m.Lock()
	defer m.Unlock()
	m.chats, m.msgs, m.order = map[string]bool{}, map[string]string{}, nil
	m.people, m.said = map[string]person{}, map[string]string{}
}

// toldChat notes that the app knows of a chat, and says whether it already did.
func (m *memory) toldChat(id string) bool {
	m.Lock()
	defer m.Unlock()
	had := m.chats[id]
	m.chats[id] = true
	return had
}

// knowsChat is whether the app has been told of a chat.
func (m *memory) knowsChat(id string) bool {
	m.Lock()
	defer m.Unlock()
	return m.chats[id]
}

// noteMsg remembers a message's words, and gives what they were before (ok: it was known).
func (m *memory) noteMsg(id, text string) (before string, ok bool) {
	if id == "" {
		return "", false
	}
	m.Lock()
	defer m.Unlock()
	before, ok = m.msgs[id]
	m.msgs[id] = text
	if !ok {
		m.order = append(m.order, id)
		if len(m.order) > msgNotes {
			delete(m.msgs, m.order[0])
			m.order = m.order[1:]
		}
	}
	return before, ok
}

// meet remembers a person, keeping what was known where this sighting has nothing.
func (m *memory) meet(p person) {
	if p.ID == "" {
		return
	}
	m.Lock()
	defer m.Unlock()
	if old, ok := m.people[p.ID]; ok {
		p.Name = cmp.Or(p.Name, old.Name)
		p.Handle = cmp.Or(p.Handle, old.Handle)
		p.Avatar = cmp.Or(p.Avatar, old.Avatar)
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
	sig := p.Name + "\n" + p.Handle + "\n" + p.Avatar
	m.Lock()
	defer m.Unlock()
	if m.said[p.ID] == sig {
		return false
	}
	m.said[p.ID] = sig
	return true
}

// --- read marks -----------------------------------------------------------------------------------------------------

// takeReads notes how far each channel had been read when Discord said READY.
func (a *account) takeReads(rs *discordgo.ReadStateList) {
	if rs == nil {
		return
	}
	a.readLock.Lock()
	defer a.readLock.Unlock()
	for _, e := range rs.Entries {
		if e != nil && e.ID != "" {
			a.reads[e.ID] = readMark{Last: string(e.LastMessageID), Mentions: e.MentionCount}
		}
	}
}

// readOf is how far a channel has been read; nil where Discord has not said.
func (a *account) readOf(channel string) *readMark {
	a.readLock.Lock()
	defer a.readLock.Unlock()
	if r, ok := a.reads[channel]; ok {
		return &r
	}
	return nil
}

// markRead notes a channel read up to a message (never back to an older one).
func (a *account) markRead(channel, upto string) {
	a.readLock.Lock()
	defer a.readLock.Unlock()
	if r, ok := a.reads[channel]; !ok || !newer(r.Last, upto) {
		a.reads[channel] = readMark{Last: upto}
	}
}

// --- people and avatars ---------------------------------------------------------------------------------------------

// avatarDir is where pictures are cached, beside the session.
func avatarDir() string { return filepath.Join(dir, "avatars") }

// nullable is [s], or JSON's null for "".
func nullable(s string) any {
	if s == "" {
		return nil
	}
	return s
}

// avatarName names a picture's file: a hash of whose it is and which picture.
func avatarName(key string) string {
	sum := sha256.Sum256([]byte(key))
	return hex.EncodeToString(sum[:12]) + ".png"
}

// avatar is a picture as a file under avatars/, fetched once; "" where there is none or it can't be had.
func (a *account) avatar(ctx context.Context, pic icon) string {
	if pic.URL == "" {
		return ""
	}
	p := filepath.Join(avatarDir(), avatarName(pic.Key))
	if _, err := os.Stat(p); err == nil {
		return p
	}
	ctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	var buf strings.Builder
	if err := a.cli.Get(ctx, pic.URL, &buf, 4<<20); err != nil || buf.Len() == 0 {
		return ""
	}
	_ = os.MkdirAll(avatarDir(), 0o700)
	if os.WriteFile(p, []byte(buf.String()), 0o600) != nil {
		return ""
	}
	return p
}

// sayName tells the app of someone met in a message, once for each thing known of them.
func (a *account) sayName(who person) {
	if who.ID == "" || who.Name == "" {
		return
	}
	seen.meet(who)
	who, _ = seen.person(who.ID)
	if !seen.newsOf(who) {
		return
	}
	event("name", map[string]any{"id": who.ID, "name": who.Name, "handle": who.Handle, "avatar": nullable(a.avatar(bg(), userIcon(who)))})
}

// who is a person as this run has met them, else as Discord says.
func (a *account) who(ctx context.Context, id string) (any, error) {
	if !snowflake(id) {
		return nil, errors.New("no one was asked for")
	}
	who, ok := seen.person(id)
	if !ok {
		u, err := a.cli.User(ctx, id)
		if err != nil {
			return nil, err
		}
		who = personOf(u, nil)
		seen.meet(who)
	}
	return map[string]any{"id": who.ID, "name": who.Name, "handle": who.Handle, "avatar": nullable(a.avatar(ctx, userIcon(who)))}, nil
}

// --- chats ----------------------------------------------------------------------------------------------------------

// chatOfChannel puts a channel into a `chat`, its picture fetched where [fetch].
func (a *account) chatOfChannel(ctx context.Context, ch *discordgo.Channel, fetch bool) chatOut {
	var guild *discordgo.Guild
	if ch.GuildID != "" {
		guild = a.cli.Guild(ch.GuildID)
	}
	for _, u := range ch.Recipients {
		seen.meet(personOf(u, nil))
	}
	var avatar func(icon) string
	if fetch {
		avatar = func(pic icon) string { return a.avatar(ctx, pic) }
	}
	return chatOf(a.me, ch, guild, a.readOf(ch.ID), avatar)
}

// sayChats says the newest [n] direct messages and groups as `chat` events, and gives them.
func (a *account) sayChats(ctx context.Context, n int) []chatOut {
	var chans []*discordgo.Channel
	for _, ch := range newestFirst(a.cli.PrivateChannels()) {
		if private(ch) {
			chans = append(chans, ch)
		}
	}
	chans = chans[:min(n, len(chans))]
	list := make([]chatOut, len(chans))
	var wg sync.WaitGroup
	gate := make(chan struct{}, 4)
	for i, ch := range chans {
		wg.Add(1)
		go func() {
			defer wg.Done()
			gate <- struct{}{}
			defer func() { <-gate }()
			list[i] = a.chatOfChannel(ctx, ch, true)
		}()
	}
	wg.Wait()
	for _, c := range list {
		seen.toldChat(c.ID)
		event("chat", fields(c))
	}
	return list
}

// sayChat tells the app of one chat at once, without its picture; then again with it, once fetched.
func (a *account) sayChat(ch *discordgo.Channel) {
	c := a.chatOfChannel(bg(), ch, false)
	seen.toldChat(c.ID)
	event("chat", fields(c))
	spawn(func() {
		if full := a.chatOfChannel(bg(), ch, true); full.Avatar != nil {
			event("chat", fields(full))
		}
	})
}

// channelOf finds a chat's channel as the gateway described it; a bare one where it has not.
func (a *account) channelOf(c chatRef) *discordgo.Channel {
	if ch := a.cli.Channel(c.Channel); ch != nil {
		if ch.GuildID == "" && c.Guild != "" {
			cp := *ch
			cp.GuildID = c.Guild
			return &cp
		}
		return ch
	}
	if c.Guild != "" {
		return &discordgo.Channel{ID: c.Channel, GuildID: c.Guild, Type: discordgo.ChannelTypeGuildText}
	}
	return &discordgo.Channel{ID: c.Channel, Type: discordgo.ChannelTypeDM}
}

// isGroup is whether a chat is anything but a direct message between two: a server's channel, or a group. A
// channel the gateway has not described counts as a direct message.
func (a *account) isGroup(c chatRef) bool {
	if c.Guild != "" {
		return true
	}
	ch := a.cli.Channel(c.Channel)
	return ch != nil && ch.Type == discordgo.ChannelTypeGroupDM
}

// --- history --------------------------------------------------------------------------------------------------------

// history is a page of a chat's messages older than [before] (the newest, with none), oldest first.
func (a *account) history(ctx context.Context, chat, before string) (any, error) {
	c, err := parseChat(chat)
	if err != nil {
		return nil, err
	}
	if before != "" && !snowflake(before) {
		return nil, errors.New("that is not a Discord message")
	}
	msgs, err := a.cli.Messages(ctx, c, pageSize, before, "")
	if err != nil {
		return nil, err
	}
	// From now on the app knows this chat: a server channel's new messages are passed on too.
	if c.Guild != "" && !seen.knowsChat(c.id()) {
		a.sayChat(a.channelOf(c))
	}
	group := a.isGroup(c)
	list := []messageOut{}
	var met []person
	for _, m := range msgs {
		if m == nil {
			continue
		}
		seen.noteMsg(m.ID, m.Content)
		if m.Author != nil {
			met = append(met, personOf(m.Author, m.Member))
		}
		if shown(m) {
			list = append(list, messageOf(a.me, c.id(), group, m))
		}
	}
	slices.SortStableFunc(list, func(x, y messageOut) int {
		switch {
		case newer(y.ID, x.ID):
			return -1
		case newer(x.ID, y.ID):
			return 1
		}
		return 0
	})
	spawn(func() {
		for _, p := range met {
			a.sayName(p)
		}
	})
	return map[string]any{"messages": list, "more": len(msgs) == pageSize}, nil
}

// --- sending --------------------------------------------------------------------------------------------------------

// send posts a message to a chat: words, a file already uploaded ([att]), or both; with a quote, as a reply to it.
func (a *account) send(ctx context.Context, r request, att *discordgo.MessageAttachment) (any, error) {
	c, err := parseChat(r.To)
	if err != nil {
		return nil, err
	}
	if strings.TrimSpace(r.Text) == "" && att == nil {
		return nil, errors.New("nothing to send")
	}
	if len([]rune(r.Text)) > 2000 {
		return nil, errors.New("Discord takes at most 2000 characters in a message")
	}
	m := &discordgo.MessageSend{Content: r.Text, Nonce: nonce(time.Now())}
	if att != nil {
		m.Attachments = []*discordgo.MessageAttachment{att}
	}
	if r.Quote != nil && snowflake(r.Quote.ID) {
		m.Reference = &discordgo.MessageReference{MessageID: r.Quote.ID, ChannelID: c.Channel, GuildID: c.Guild}
	}
	sent, err := a.cli.Send(ctx, c, m)
	if err != nil {
		return nil, err
	}
	if sent == nil || sent.ID == "" {
		return nil, errors.New("Discord did not say it took the message")
	}
	ts := time.Now().UnixMilli()
	if !sent.Timestamp.IsZero() {
		ts = sent.Timestamp.UnixMilli()
	}
	seen.noteMsg(sent.ID, sent.Content)
	seen.toldChat(c.id())
	// Discord counts your own message as read.
	a.markRead(c.Channel, sent.ID)
	return map[string]any{"id": sent.ID, "ts": ts}, nil
}

// upload hands Discord a file, as its website attaches one, and gives what the message carries for it.
func (a *account) upload(ctx context.Context, r request) (*discordgo.MessageAttachment, error) {
	c, err := parseChat(r.To)
	if err != nil {
		return nil, err
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
	uploaded, err := a.cli.Upload(ctx, c, name, mime, st.Size(), f)
	if err != nil {
		return nil, err
	}
	if uploaded == "" {
		return nil, errors.New("Discord did not take the file")
	}
	return &discordgo.MessageAttachment{ID: "0", Filename: name, UploadedFilename: uploaded, OriginalContentType: mime}, nil
}

// read marks a chat read up to [upto]; without it, up to its newest message.
func (a *account) read(ctx context.Context, to, upto string) error {
	c, err := parseChat(to)
	if err != nil {
		return err
	}
	if upto != "" && !snowflake(upto) {
		return errors.New("that is not a Discord message")
	}
	if upto == "" {
		if ch := a.cli.Channel(c.Channel); ch != nil {
			upto = ch.LastMessageID
		}
	}
	if upto == "" {
		msgs, err := a.cli.Messages(ctx, c, 1, "", "")
		if err != nil {
			return err
		}
		if len(msgs) == 0 || msgs[0] == nil {
			return nil
		}
		upto = msgs[0].ID
	}
	if err := a.cli.Ack(ctx, c, upto); err != nil {
		return err
	}
	a.markRead(c.Channel, upto)
	return nil
}

// --- files ----------------------------------------------------------------------------------------------------------

// discordHost is whether a file's address is one of Discord's own servers.
func discordHost(host string) bool {
	host = strings.ToLower(host)
	for _, d := range []string{"discordapp.com", "discordapp.net", "discord.com"} {
		if host == d || strings.HasSuffix(host, "."+d) {
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
	if err := json.Unmarshal(raw, &p); err != nil || p.URL == "" {
		return p, errors.New("that is not a Discord file")
	}
	if u, err := url.Parse(p.URL); err != nil || u.Scheme != "https" || !discordHost(u.Hostname()) {
		return p, errors.New("that is not a Discord file")
	}
	return p, nil
}

// fresh asks Discord for the message a file is in again, for a newly signed address of the file.
func (a *account) fresh(ctx context.Context, p pointer) (string, error) {
	c, err := parseChat(p.Chat)
	if err != nil || !snowflake(p.Message) || p.Attachment == "" {
		return "", errors.New("Discord's link to this file has run out. Open the chat again for a fresh one.")
	}
	msgs, err := a.cli.Messages(ctx, c, 1, "", p.Message)
	if err != nil {
		return "", err
	}
	for _, m := range msgs {
		if m == nil || m.ID != p.Message {
			continue
		}
		for _, att := range mediaOf(p.Chat, m) {
			if att.Pointer.Attachment == p.Attachment {
				return att.Pointer.URL, nil
			}
		}
	}
	return "", errors.New("Discord no longer has this file.")
}

// download writes a message's file to [path], whole or not at all. An address that has run out is asked for again.
func (a *account) download(ctx context.Context, raw json.RawMessage, path string) error {
	p, err := parsePointer(raw)
	if err != nil {
		return err
	}
	if path == "" {
		return errors.New("nowhere to write the file")
	}
	err = a.fetchTo(ctx, p.URL, path)
	switch statusOf(err) {
	case http.StatusForbidden, http.StatusNotFound, http.StatusGone, http.StatusUnauthorized:
		again, ferr := a.fresh(ctx, p)
		if ferr != nil {
			return ferr
		}
		err = a.fetchTo(ctx, again, path)
	}
	return err
}

// fetchTo fetches the file at [from] into [path], by way of a ".part" file beside it so a fetch that fails leaves
// nothing behind. A file may be up to a gigabyte. Each fetch has a ".part" file of its own (name.png.<random>.part):
// two asked for one path at once, as the app did each time a picture was drawn, shared one, and the first renamed it
// into place while the second still wrote to it; the second's rename then found nothing ("rename …png.part …png: no
// such file or directory").
func (a *account) fetchTo(ctx context.Context, from, path string) error {
	f, err := os.CreateTemp(filepath.Dir(path), filepath.Base(path)+".*.part")
	if err != nil {
		return errors.New("the file could not be written: " + err.Error())
	}
	tmp := f.Name()
	err = a.cli.Get(ctx, from, f, 1<<30)
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		_ = os.Remove(tmp)
		return err
	}
	return os.Rename(tmp, path)
}

// --- what Discord says, live ----------------------------------------------------------------------------------------

// onEvent is the library's event handler. It is called on the gateway's own goroutine, in order: anything slow is
// done beside it.
func (a *account) onEvent(raw any) {
	if current() != a {
		return
	}
	defer func() {
		if p := recover(); p != nil {
			log.Error().Any("panic", p).Msg("in a Discord event")
		}
	}()
	switch ev := raw.(type) {
	case *discordgo.Ready:
		a.takeReads(ev.ReadState)
		setConnected(a, true)
		spawn(a.keep)
		spawn(func() { a.sayChats(bg(), chatsSaid) })
	case *discordgo.Resumed, *discordgo.Connect:
		setConnected(a, true)
	case *discordgo.Disconnect:
		setConnected(a, false)
	case *discordgo.InvalidAuth:
		spawn(func() { ended(a, errBadToken) })
	case *discordgo.ChannelCreate:
		if private(ev.Channel) {
			a.sayChat(ev.Channel)
		}
	case *discordgo.ChannelUpdate:
		if private(ev.Channel) {
			a.sayChat(ev.Channel)
		}
	case *discordgo.ChannelRecipientAdd:
		a.resayChat(ev.ChannelID)
	case *discordgo.ChannelRecipientRemove:
		a.resayChat(ev.ChannelID)
	case *discordgo.MessageCreate:
		if ev.Message != nil {
			a.onMessage(ev.Message)
		}
	case *discordgo.MessageUpdate:
		if ev.Message != nil {
			a.onEdit(ev.Message)
		}
	case *discordgo.MessageDelete:
		if ev.Message != nil {
			a.onDelete(ev.GuildID, ev.ChannelID, ev.ID)
		}
	case *discordgo.MessageDeleteBulk:
		for _, id := range ev.Messages {
			a.onDelete(ev.GuildID, ev.ChannelID, id)
		}
	case *discordgo.MessageReactionAdd:
		if ev.MessageReaction != nil {
			a.onReaction(ev.MessageReaction, false)
		}
	case *discordgo.MessageReactionRemove:
		if ev.MessageReaction != nil {
			a.onReaction(ev.MessageReaction, true)
		}
	case *discordgo.MessageAck:
		a.onAck(ev)
	}
}

// resayChat says a group again as the gateway now describes it, after someone joined or left it.
func (a *account) resayChat(channel string) {
	if ch := a.cli.Channel(channel); private(ch) {
		a.sayChat(ch)
	}
}

// passed is whether the app hears of what happens in a chat: every direct message and group, and a server channel
// once it has been told of it.
func passed(c chatRef) bool { return c.Guild == "" || seen.knowsChat(c.id()) }

// onMessage says a new message, after its chat where the app has not been told of it. A message in a server channel
// the app does not know is passed on only if it is for the person, and from then on so is the rest of that channel.
func (a *account) onMessage(m *discordgo.Message) {
	c := chatRef{Guild: m.GuildID, Channel: m.ChannelID}
	if !snowflake(c.Channel) || m.ID == "" {
		return
	}
	if !passed(c) && !mentionsMe(a.me, m) {
		// A server has many channels: one is passed on once a message in it is for the person.
		return
	}
	seen.noteMsg(m.ID, m.Content)
	if !seen.knowsChat(c.id()) {
		a.sayChat(a.channelOf(c))
	}
	if !shown(m) {
		return
	}
	msg := messageOf(a.me, c.id(), a.isGroup(c), m)
	if msg.Mine {
		a.markRead(c.Channel, m.ID)
	}
	event("message", fields(msg))
	if m.Author != nil {
		who := personOf(m.Author, m.Member)
		spawn(func() { a.sayName(who) })
	}
}

// onEdit says an edit. Discord sends a message again when anything about it changes (a link's preview, say); only
// a change of its words is an edit.
func (a *account) onEdit(m *discordgo.Message) {
	c := chatRef{Guild: m.GuildID, Channel: m.ChannelID}
	if m.ID == "" || !snowflake(c.Channel) || !passed(c) || m.EditedTimestamp == nil {
		return
	}
	before, known := seen.noteMsg(m.ID, m.Content)
	if known && before == m.Content {
		return
	}
	event("edited", map[string]any{"chat": c.id(), "target": m.ID, "text": messageText(m)})
}

// onDelete says a message deleted, in a chat the app hears of.
func (a *account) onDelete(guild, channel, id string) {
	c := chatRef{Guild: guild, Channel: channel}
	if id == "" || !snowflake(channel) || !passed(c) {
		return
	}
	event("deleted", map[string]any{"chat": c.id(), "target": id})
}

// onReaction says a reaction added or removed, in a chat the app hears of.
func (a *account) onReaction(r *discordgo.MessageReaction, remove bool) {
	c := chatRef{Guild: r.GuildID, Channel: r.ChannelID}
	emoji := emojiText(r.Emoji)
	if r.MessageID == "" || r.UserID == "" || emoji == "" || !snowflake(c.Channel) || !passed(c) {
		return
	}
	event("reaction", map[string]any{"chat": c.id(), "from": r.UserID, "target": r.MessageID, "emoji": emoji, "remove": remove})
}

// onAck is the person reading a chat in Discord's own app (or this helper's own read mark coming back).
func (a *account) onAck(ev *discordgo.MessageAck) {
	if !snowflake(ev.ChannelID) || !snowflake(ev.MessageID) {
		return
	}
	a.markRead(ev.ChannelID, ev.MessageID)
	c := chatRef{Channel: ev.ChannelID}
	if ch := a.cli.Channel(ev.ChannelID); ch != nil {
		c.Guild = ch.GuildID
	}
	if !passed(c) {
		return
	}
	event("receipt", map[string]any{"chat": c.id(), "from": a.me, "id": ev.MessageID, "ts": snowflakeMS(ev.MessageID), "kind": "read"})
}

// --- the log file ---------------------------------------------------------------------------------------------------

// logFile is discord.log in the session's folder, begun afresh past a megabyte; standard error alone where it can't
// open.
func logFile() io.Writer {
	path := filepath.Join(dir, "discord.log")
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
