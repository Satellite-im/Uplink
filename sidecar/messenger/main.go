// Uplink's Messenger helper (README.md, PROTOCOL.md). AGPL-3.0, as mautrix-meta, on whose messagix it is
// built.
//
// Matt, 2026-11-20: "Let's do the feasible ones but skip X and google voice". It signs in to the person's Facebook
// Messenger with the cookies of a browser signed in to it, behaves as messenger.com does, and speaks JSON lines over
// standard input and output in the shape every account helper shares (../ACCOUNT_HELPERS.md). Requests, each with
// an "id" its answer carries back:
//
//	{"id":1,"op":"status"}                                   → {"linked","connected","me","name","handle"}
//	{"id":2,"op":"sign_in","cookies":{"c_user":"…","xs":"…","datr":"…"}} → {"me","name","handle"}, and a "linked" event
//	{"id":3,"op":"unlink"}                                   → null; everything forgotten
//	{"id":4,"op":"chats"}                                    → [<chat>…]
//	{"id":5,"op":"history","chat":"…","before":"mid.$…"}     → {"messages":[…],"more":bool}
//	{"id":6,"op":"send","to":"…","text":"…","quote":{"id":"mid.$…"}} → {"id","ts"}
//	{"id":7,"op":"send_media","to":"…","path":"…","mime":"…","name":"…","text":"…"} → {"id","ts"}
//	{"id":8,"op":"read","to":"…","upto":"mid.$…"}            → null
//	{"id":9,"op":"react","to":"…","target":"mid.$…","emoji":"👍","remove":false} → null
//	{"id":10,"op":"delete","to":"…","target":"mid.$…"}       → null (your own message, unsent for everyone)
//	{"id":11,"op":"download","pointer":{…},"path":"…"}       → null once written
//	{"id":12,"op":"who","who":"…"}                           → {"id","name","handle","avatar"}
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
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/rs/zerolog"
	globallog "github.com/rs/zerolog/log"
	"go.mau.fi/util/exhttp"
	"go.mau.fi/whatsmeow"

	"go.mau.fi/mautrix-meta/pkg/messagix"
	"go.mau.fi/mautrix-meta/pkg/messagix/cookies"
	"go.mau.fi/mautrix-meta/pkg/messagix/dgw"
	"go.mau.fi/mautrix-meta/pkg/messagix/httpclient"
	"go.mau.fi/mautrix-meta/pkg/messagix/table"
	"go.mau.fi/mautrix-meta/pkg/messagix/types"
)

// quote is the message a `send` answers, by its id.
type quote struct {
	ID string `json:"id"`
}

// request is one line read from standard input. Each op reads the fields it needs and leaves the rest.
type request struct {
	ID      int64             `json:"id"`
	Op      string            `json:"op"`
	Cookies map[string]string `json:"cookies"`
	// Site says which site the cookies are from, "messenger" or "facebook", where the app knows. Without it
	// messenger.com is tried first and facebook.com after it.
	Site    string          `json:"site"`
	Chat    string          `json:"chat"`
	Before  string          `json:"before"`
	To      string          `json:"to"`
	Text    string          `json:"text"`
	Quote   *quote          `json:"quote"`
	Path    string          `json:"path"`
	Mime    string          `json:"mime"`
	Name    string          `json:"name"`
	Upto    string          `json:"upto"`
	Target  string          `json:"target"`
	Emoji   string          `json:"emoji"`
	Remove  bool            `json:"remove"`
	Pointer json.RawMessage `json:"pointer"`
	Who     string          `json:"who"`
}

// conn is one loading of Messenger's page and the live connection that follows it.
type conn struct {
	cli    *messagix.Client
	ctx    context.Context
	cancel context.CancelFunc

	// The encrypted side (e2ee.go), under e2mu: its client once made, whether connecting it has begun, and how
	// many times its device has been registered anew.
	e2mu      sync.Mutex
	e2        *whatsmeow.Client
	e2Started bool
	e2Tries   int
}

// dir is where the session, the keys, the log and the pictures are kept (--dir); out is standard output, written a
// JSON line at a time under outLock. mu guards the session, the connection in use (cur), whether it is up, the book
// and when the session was last written. waiters, under waitMu, are the `history` requests waiting for a stretch,
// by thread.
var (
	dir     string
	log     zerolog.Logger
	out     = json.NewEncoder(os.Stdout)
	outLock sync.Mutex

	mu        sync.Mutex
	sess      *session
	cur       *conn
	connected bool
	bk        *book
	// loaded is closed once the chats Messenger lists first have been taken in.
	loaded    = make(chan struct{})
	lastSaved time.Time
	reloading atomic.Bool
	inflight  sync.WaitGroup

	waitMu  sync.Mutex
	waiters = map[int64][]*stretchWait{}
)

// How long a loading of the page is used before it is loaded again, as the website is by anyone who leaves it open:
// its tokens grow old.
const refreshEvery = 20 * time.Hour

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
// goroutine, until Uplink closes it; the session is written a last time on the way out.
func main() {
	flag.StringVar(&dir, "dir", "", "where the Messenger session is kept")
	flag.Parse()
	if dir == "" {
		fmt.Fprintln(os.Stderr, "--dir is needed")
		os.Exit(2)
	}
	_ = os.MkdirAll(dir, 0o700)
	// The log goes to standard error (Uplink's developer log) and messenger.log beside the session; never stdout.
	// Info level: messagix says what a message holds only at trace level.
	log = zerolog.New(zerolog.MultiLevelWriter(os.Stderr, logFile())).With().Timestamp().Logger().Level(zerolog.InfoLevel)
	globallog.Logger = log
	out.SetEscapeHTML(false)

	mu.Lock()
	sess = loadSession(dir)
	linked := sess != nil
	mu.Unlock()
	event("ready", map[string]any{"linked": linked})
	if linked {
		go resume()
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
	mu.Lock()
	c := cur
	cur = nil
	mu.Unlock()
	if c != nil {
		keep(c, true)
		c.stop()
	}
	closeKeys()
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

// logFile is messenger.log in the session's folder, begun afresh past a megabyte; standard error alone where it
// can't open.
func logFile() *os.File {
	path := filepath.Join(dir, "messenger.log")
	if st, err := os.Stat(path); err == nil && st.Size() > 1<<20 {
		_ = os.Remove(path)
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return os.Stderr
	}
	return f
}

// --- cookies and signing in -----------------------------------------------------------------------------------------

// platformOf is the site a name stands for: Facebook where it says so, Messenger for anything else ("" too).
func platformOf(site string) types.Platform {
	if strings.Contains(strings.ToLower(site), "facebook") {
		return types.Facebook
	}
	return types.Messenger
}

// siteOf is the site's address as a person knows it, for the words that send them to the browser.
func siteOf(p types.Platform) string {
	if p == types.Facebook {
		return "facebook.com"
	}
	return "messenger.com"
}

// jar puts a browser's cookies, by name, into the library's jar for one of the two sites. Empty ones are left out.
func jar(platform types.Platform, values map[string]string) *cookies.Cookies {
	c := &cookies.Cookies{Platform: platform}
	typed := make(map[cookies.MetaCookieName]string, len(values))
	for k, v := range values {
		if k = strings.TrimSpace(k); k != "" && v != "" {
			typed[cookies.MetaCookieName(k)] = strings.TrimSpace(v)
		}
	}
	c.UpdateValues(typed)
	return c
}

// missingCookies says which of the cookies Messenger cannot do without are not among [values], in words, or nil.
func missingCookies(values map[string]string) error {
	missing := jar(types.Messenger, values).GetMissingCookieNames()
	if len(missing) == 0 {
		return nil
	}
	names := make([]string, len(missing))
	for i, n := range missing {
		names[i] = string(n)
	}
	sort.Strings(names)
	word := "These cookies are missing: "
	if len(names) == 1 {
		word = "This cookie is missing: "
	}
	return errors.New(word + strings.Join(names, ", ") + ". Copy them from messenger.com (or facebook.com) in a browser signed in to your account.")
}

// refusal is why Messenger would not load, in words a person can act on, and whether the cookies are no use any
// more (fatal) or it is worth trying again. address is where Messenger sent the browser, where it said.
func refusal(err error, site string) (words string, fatal bool, address string) {
	address = httpclient.GetErrorRedirectURL(err)
	again := " Open " + site + " in the browser, "
	var ls *types.ErrorResponse
	switch {
	case errors.Is(err, httpclient.ErrCheckpointRequired), errors.Is(err, httpclient.ErrChallengeRequired):
		return "Messenger is asking to confirm it is you." + again + "finish the check there, then copy the cookies again.", true, address
	case errors.Is(err, httpclient.ErrConsentRequired):
		return "Messenger is asking you to agree to something first." + again + "answer it there, then copy the cookies again.", true, address
	case errors.Is(err, httpclient.ErrAccountSuspended):
		return "Meta has suspended this account." + again + "and see what it says there.", true, address
	case errors.Is(err, httpclient.ErrTokenInvalidated):
		return "Messenger did not take these cookies: that browser session has ended or was signed out." + again + "sign in, then copy the cookies again.", true, address
	case errors.As(err, &ls) && ls.ErrorCode == 1357053:
		return "Messenger says this session is no longer signed in." + again + "sign in, then copy the cookies again.", true, address
	}
	return "Messenger could not be reached: " + err.Error(), false, address
}

// newClient makes the library's client for a site with a browser's cookies. Nothing is asked of Messenger yet.
func newClient(platform types.Platform, values map[string]string) *messagix.Client {
	return messagix.NewClient(jar(platform, values), log.With().Str("component", "messagix").Logger(),
		&messagix.Config{ClientSettings: exhttp.SensibleClientSettings})
}

// open loads Messenger's page with the cookies, as a browser opening the site does: who is signed in, and the table
// of the chats listed first.
func open(ctx context.Context, platform types.Platform, values map[string]string) (*conn, types.UserInfo, *table.LSTable, error) {
	cli := newClient(platform, values)
	user, tbl, err := cli.LoadMessagesPage(ctx)
	if err != nil {
		return nil, nil, nil, err
	}
	if user == nil || user.GetFBID() == 0 {
		return nil, nil, nil, httpclient.ErrUserIDIsZero
	}
	cctx, cancel := context.WithCancel(bg())
	return &conn{cli: cli, ctx: cctx, cancel: cancel}, user, tbl, nil
}

// signIn answers `sign_in`: the cookies are checked by loading Messenger's page with them, whatever was signed in
// before is forgotten, and the new session is kept, said (`linked`) and connected.
func signIn(ctx context.Context, r request) (any, error) {
	if len(r.Cookies) == 0 {
		return nil, errors.New("No cookies were given. Copy them from messenger.com in a browser signed in to your account.")
	}
	if err := missingCookies(r.Cookies); err != nil {
		return nil, err
	}
	// The two sites' cookies have the same names, so which site a set is from cannot be told by looking: the one
	// the app names is tried, else messenger.com, and the other one only where the first says the session is not
	// its own.
	first := platformOf(r.Site)
	second := types.Facebook
	if first == types.Facebook {
		second = types.Messenger
	}
	order := []types.Platform{first, second}
	if r.Site != "" {
		order = order[:1]
	}
	var c *conn
	var user types.UserInfo
	var tbl *table.LSTable
	var err error
	var platform types.Platform
	for _, platform = range order {
		c, user, tbl, err = open(ctx, platform, r.Cookies)
		if err == nil || !errors.Is(err, httpclient.ErrTokenInvalidated) {
			break
		}
		log.Info().Str("site", siteOf(platform)).Msg("the cookies are not this site's")
	}
	if err != nil {
		log.Err(err).Msg("sign in")
		words, _, _ := refusal(err, siteOf(first))
		return nil, errors.New(words)
	}

	// Whatever was signed in before is put away first.
	mu.Lock()
	old := cur
	cur = nil
	mu.Unlock()
	if old != nil {
		old.stop()
	}
	if err := wipe(); err != nil {
		log.Err(err).Msg("forget the session before")
	}

	me := idString(user.GetFBID())
	s := &session{Platform: platform.String(), Cookies: r.Cookies, Me: me, Name: user.GetName(), Handle: user.GetUsername()}
	if err := saveSession(dir, s); err != nil {
		c.stop()
		return nil, fmt.Errorf("The session could not be kept: %w", err)
	}
	mu.Lock()
	sess = s
	mu.Unlock()
	who := map[string]any{"me": me, "name": s.Name, "handle": s.Handle}
	event("linked", who)
	adopt(c, user, tbl)
	return who, nil
}

// resume connects with the session kept, trying again while Messenger cannot be reached and giving the session up
// where Messenger will not have it.
func resume() {
	wait := 2 * time.Second
	for {
		mu.Lock()
		s := sess
		busy := cur != nil
		mu.Unlock()
		if s == nil || busy {
			return
		}
		ctx, cancel := context.WithTimeout(bg(), 90*time.Second)
		c, user, tbl, err := open(ctx, platformOf(s.Platform), s.Cookies)
		cancel()
		if err == nil {
			mu.Lock()
			still := sess == s && cur == nil
			mu.Unlock()
			if !still {
				c.stop()
				return
			}
			adopt(c, user, tbl)
			return
		}
		words, fatal, address := refusal(err, siteOf(platformOf(s.Platform)))
		log.Err(err).Bool("fatal", fatal).Msg("load Messenger")
		if fatal {
			unlinked(nil, words, address)
			return
		}
		time.Sleep(wait)
		wait = min(wait*2, 5*time.Minute)
	}
}

// adopt makes [c] the connection in use: the chats its page listed are said, then the live connection is opened.
func adopt(c *conn, user types.UserInfo, tbl *table.LSTable) {
	me := user.GetFBID()
	mu.Lock()
	cur = c
	if bk == nil || bk.me != me {
		bk = newBook(me)
		bk.avatar = avatarFile
		for k, v := range kindsKept() {
			if id, ok := parseID(k); ok {
				bk.kinds[id] = table.ThreadType(v)
			}
		}
	}
	// The page names the person; a name that changed is kept.
	if sess != nil && (sess.Name != user.GetName() || sess.Handle != user.GetUsername()) && user.GetName() != "" {
		sess.Name, sess.Handle = user.GetName(), user.GetUsername()
	}
	mu.Unlock()
	if tbl != nil {
		c.take(tbl, true)
	}
	mu.Lock()
	select {
	case <-loaded:
	default:
		close(loaded)
	}
	mu.Unlock()
	keep(c, true)
	c.cli.SetEventHandler(c.onEvent)
	if err := c.cli.Connect(c.ctx); err != nil {
		log.Err(err).Msg("connect")
	}
	time.AfterFunc(refreshEvery, func() { reload(c, "the page is 20 hours old") })
}

// current is whether [c] is still the connection in use: one replaced or signed out is no longer listened to.
func (c *conn) current() bool {
	mu.Lock()
	defer mu.Unlock()
	return cur == c
}

// stop closes [c]'s connections. It is not called with mu held.
func (c *conn) stop() {
	c.cli.SetEventHandler(nil)
	c.cancel()
	c.cli.Disconnect()
	c.e2mu.Lock()
	e2 := c.e2
	c.e2 = nil
	c.e2mu.Unlock()
	if e2 != nil {
		e2.Disconnect()
	}
}

// setConnected notes whether [c]'s live connection is up, and says `connected` or `disconnected` when that changes.
func setConnected(c *conn, now bool) {
	mu.Lock()
	if cur != c || connected == now {
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

// reload loads Messenger's page again and connects anew, as reloading the tab does: for a page grown old, or a
// connection Messenger will not sync.
func reload(c *conn, why string) {
	if !c.current() || !reloading.CompareAndSwap(false, true) {
		return
	}
	defer reloading.Store(false)
	log.Info().Str("why", why).Msg("loading Messenger's page again")
	keep(c, true)
	setConnected(c, false)
	mu.Lock()
	if cur != c {
		mu.Unlock()
		return
	}
	cur = nil
	mu.Unlock()
	c.stop()
	resume()
}

// unlinked is Messenger ending the session: everything is forgotten and the app told why.
func unlinked(c *conn, words, address string) {
	mu.Lock()
	if c != nil && cur != c {
		mu.Unlock()
		return
	}
	old := cur
	cur = nil
	was := connected
	connected = false
	mu.Unlock()
	if old != nil {
		old.stop()
	}
	if err := wipe(); err != nil {
		log.Err(err).Msg("forget after Messenger ended the session")
	}
	if was {
		event("disconnected", nil)
	}
	fields := map[string]any{"error": words}
	if address != "" {
		fields["url"] = address
	}
	event("unlinked", fields)
}

// wipe forgets everything kept: the session, the encrypted chats' keys, the pictures, and what is remembered of
// chats. Called with no connection in use.
func wipe() error {
	mu.Lock()
	sess = nil
	bk = nil
	connected = false
	loaded = make(chan struct{})
	mu.Unlock()
	closeKeys()
	for _, suffix := range []string{"", "-wal", "-shm"} {
		_ = os.Remove(keysPath() + suffix)
	}
	_ = os.RemoveAll(avatarDir())
	return dropSession(dir)
}

// keep writes the session: the cookies as Messenger last set them, messagix's state, and the kinds of threads met.
// It is written once a minute at most unless [now].
func keep(c *conn, now bool) {
	mu.Lock()
	defer mu.Unlock()
	if sess == nil || (cur != c && cur != nil) || (!now && time.Since(lastSaved) < time.Minute) {
		return
	}
	lastSaved = time.Now()
	if all := c.cli.GetCookies().GetAll(); len(all) > 0 {
		fresh := make(map[string]string, len(all))
		for k, v := range all {
			fresh[string(k)] = v
		}
		sess.Cookies = fresh
	}
	if state, err := c.cli.DumpState(); err == nil && state != nil {
		sess.State = state
	}
	if bk != nil {
		bk.mu.Lock()
		sess.Kinds = make(map[string]int64, len(bk.kinds))
		for k, v := range bk.kinds {
			sess.Kinds[idString(k)] = int64(v)
		}
		bk.mu.Unlock()
	}
	if err := saveSession(dir, sess); err != nil {
		log.Err(err).Msg("keep the session")
	}
}

// --- what Messenger says ----------------------------------------------------------------------------------------------

// onEvent is the library's handler: a table of rows is taken in, and what it says of the connection is passed on
// or acted on (the page loaded again, or the session ended where Messenger signed it out).
func (c *conn) onEvent(ctx context.Context, raw any) {
	if !c.current() {
		return
	}
	switch evt := raw.(type) {
	case *table.LSTable:
		c.take(evt, false)
	case *messagix.ConnectedEvent, *messagix.ReconnectedEvent:
		setConnected(c, true)
		go c.startKeys()
	case *messagix.TransientDisconnectEvent:
		log.Info().AnErr("why", evt.Err).Msg("Messenger's connection dropped")
		setConnected(c, false)
		if errors.Is(evt.Err, messagix.ErrFatalSocketSyncError) {
			// Trying the same connection again fails the same way until the page is loaded again.
			go reload(c, "Messenger would not sync")
		}
	case *messagix.PermanentErrorEvent:
		log.Err(evt.Err).Msg("Messenger closed the connection for good")
		if dgw.IsUnauthorized(evt.Err) {
			site := siteOf(c.cli.GetPlatform())
			go unlinked(c, "Messenger signed this session out. Open "+site+" in the browser, sign in, then copy the cookies again.", "")
			return
		}
		setConnected(c, false)
		go func() {
			time.Sleep(30 * time.Second)
			reload(c, "the connection was closed for good")
		}()
	default:
		log.Warn().Type("kind", raw).Msg("an event from messagix that is not known")
	}
}

// take takes in a table: the app is told what it says, and whoever asked for a stretch of history is handed it.
func (c *conn) take(tbl *table.LSTable, first bool) {
	mu.Lock()
	b := bk
	mu.Unlock()
	if b == nil {
		return
	}
	res := b.apply(tbl)
	for _, e := range res.Events {
		event(e.Name, e.Fields)
	}
	for k, up := range res.Upserts {
		if up != nil && up.Range != nil {
			handStretch(b.keyOf(k), up)
		}
	}
	for _, r := range res.Ranges {
		endStretch(b.keyOf(r.ThreadKey), r.TimestampMS)
	}
	if !first {
		c.cli.PostHandlePublishResponse(tbl)
		keep(c, false)
	}
}

// keyOf is key, for a caller that does not hold the book's lock.
func (b *book) keyOf(k int64) int64 {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.key(k)
}

// stretchWait is a `history` request waiting for Messenger to send a stretch of a thread: the one before [before]
// (ms), or the newest where it is 0.
type stretchWait struct {
	before int64
	ch     chan *table.UpsertMessages
}

// awaitStretch begins waiting for a stretch of thread [k]. It is called before the task that asks for one is sent,
// so the answer cannot slip by; the caller ends the wait with dropWait.
func awaitStretch(k, before int64) *stretchWait {
	w := &stretchWait{before: before, ch: make(chan *table.UpsertMessages, 1)}
	waitMu.Lock()
	waiters[k] = append(waiters[k], w)
	waitMu.Unlock()
	return w
}

// dropWait ends a wait, answered or not.
func dropWait(k int64, w *stretchWait) {
	waitMu.Lock()
	defer waitMu.Unlock()
	list := waiters[k]
	for i, x := range list {
		if x == w {
			waiters[k] = append(list[:i:i], list[i+1:]...)
			break
		}
	}
	if len(waiters[k]) == 0 {
		delete(waiters, k)
	}
}

// handStretch hands a stretch Messenger sent of thread [k] to whoever waits for it. A waiter's channel holds one,
// and a waiter handed its stretch is taken off the list, so this never blocks.
func handStretch(k int64, up *table.UpsertMessages) {
	waitMu.Lock()
	defer waitMu.Unlock()
	rest := waiters[k][:0:0]
	for _, w := range waiters[k] {
		// A stretch that starts after the message asked about is some other one (the newest, sent unasked).
		if w.before != 0 && up.Range.MaxTimestampMsTemplate > w.before {
			rest = append(rest, w)
			continue
		}
		w.ch <- up
	}
	waiters[k] = rest
}

// endStretch is Messenger saying there is nothing before the time asked about.
func endStretch(k, ts int64) {
	waitMu.Lock()
	defer waitMu.Unlock()
	rest := waiters[k][:0:0]
	for _, w := range waiters[k] {
		if w.before != ts {
			rest = append(rest, w)
			continue
		}
		w.ch <- nil
	}
	waiters[k] = rest
}

// --- requests -------------------------------------------------------------------------------------------------------

var errNotLinked = errors.New("not signed in to Messenger")

// linkedConn is the connection in use and its book, once Messenger's page has loaded.
func linkedConn(ctx context.Context) (*conn, *book, error) {
	mu.Lock()
	s, wait := sess, loaded
	mu.Unlock()
	if s == nil {
		return nil, nil, errNotLinked
	}
	select {
	case <-wait:
	case <-ctx.Done():
	case <-time.After(20 * time.Second):
	}
	mu.Lock()
	defer mu.Unlock()
	if sess == nil {
		return nil, nil, errNotLinked
	}
	if cur == nil || bk == nil {
		return nil, nil, errors.New("Messenger is not connected yet; try again in a moment")
	}
	return cur, bk, nil
}

// status answers `status`: whether anyone is signed in, whether the live connection is up, and who it is.
func status() map[string]any {
	mu.Lock()
	defer mu.Unlock()
	if sess == nil {
		return map[string]any{"linked": false, "connected": false, "me": "", "name": "", "handle": ""}
	}
	return map[string]any{"linked": true, "connected": connected && cur != nil, "me": sess.Me, "name": sess.Name, "handle": sess.Handle}
}

// do answers one request within a time limit: a minute, or nearly three for a sign-in or a file. Every op but
// status, sign_in and unlink needs the connection in use, and waits a while for Messenger's page to load.
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
		return signIn(ctx, r)
	case "unlink":
		// Only this helper forgets; the browser's own session is not signed out.
		mu.Lock()
		old := cur
		cur = nil
		mu.Unlock()
		if old != nil {
			old.stop()
		}
		return nil, wipe()
	}
	c, b, err := linkedConn(ctx)
	if err != nil {
		return nil, err
	}
	switch r.Op {
	case "chats":
		return b.chats(), nil
	case "history":
		return history(ctx, c, b, r.Chat, r.Before)
	case "send":
		return send(ctx, c, b, r.To, r.Text, r.Quote, 0)
	case "send_media":
		return sendMedia(ctx, c, b, r)
	case "read":
		return nil, read(ctx, c, b, r.To, r.Upto)
	case "react":
		return nil, react(ctx, c, b, r.To, r.Target, r.Emoji, r.Remove)
	case "delete":
		return nil, unsend(ctx, c, b, r.To, r.Target)
	case "download":
		return nil, download(ctx, c, r.Pointer, r.Path)
	case "who":
		return who(ctx, c, b, r.Who)
	}
	return nil, fmt.Errorf("unknown op %q", r.Op)
}

// kindsKept is the thread kinds the session holds. Called with mu held.
func kindsKept() map[string]int64 {
	if sess == nil {
		return nil
	}
	return sess.Kinds
}
