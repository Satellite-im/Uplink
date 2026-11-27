// The Instagram side of the helper: signing in with a browser's cookies, the live connection, what Instagram sends
// turned into the protocol's events, and the requests the app makes. It follows how mautrix-meta's own bridge
// (pkg/igconnector) drives the instameow library, without the bridge: no Matrix, no database.
package main

import (
	"cmp"
	"context"
	"errors"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"sync"
	"time"

	"go.mau.fi/util/exhttp"
	"go.mau.fi/util/jsontime"
	"go.mau.fi/util/variationselector"

	"go.mau.fi/mautrix-meta/pkg/instameow"
	"go.mau.fi/mautrix-meta/pkg/instameow/slidetypes"
	"go.mau.fi/mautrix-meta/pkg/messagix/cookies"
	"go.mau.fi/mautrix-meta/pkg/messagix/dgw"
	"go.mau.fi/mautrix-meta/pkg/messagix/httpclient"
	"go.mau.fi/mautrix-meta/pkg/messagix/methods"
	"go.mau.fi/mautrix-meta/pkg/messagix/types"
)

// What the person is told when Instagram ends, or will not take, the session. Each says what to do about it.
const (
	wordsSignedOut  = "Instagram signed this session out: sign in to instagram.com in the browser, then sign in here again"
	wordsChallenge  = "Instagram asked to confirm it's you: finish that in the browser, then sign in here again"
	wordsConsent    = "Instagram is asking you to agree to something first: finish that in the browser, then sign in here again"
	wordsSuspended  = "Instagram has suspended this account: open instagram.com in the browser to see what it asks"
	wordsRestricted = "Instagram is limiting this account: open Instagram in the browser or its app to see what it asks, then sign in here again"
	wordsSlowDown   = "Instagram is asking to slow down: wait a while and try again"
	wordsNoIdentity = "Instagram did not say whose account this is: open your messages on instagram.com in the browser, then copy the cookies again"
)

// What a request is answered with when there is no session, or one whose inbox page has not loaded yet.
var (
	errNotLinked = errors.New("not signed in to Instagram")
	errNotReady  = errors.New("Instagram is still connecting: try again in a moment")
)

// rejection is what to tell the person where [err] means Instagram no longer takes the session (signed out, a check
// to finish, something to agree to); "" for anything else, which is worth trying again. The list is the bridge's
// (igconnector's errorToBridgeState and loginWithCookies).
func rejection(err error) string {
	switch {
	case err == nil:
		return ""
	case errors.Is(err, httpclient.ErrChallengeRequired), errors.Is(err, httpclient.ErrCheckpointRequired):
		return wordsChallenge
	case errors.Is(err, httpclient.ErrConsentRequired):
		return wordsConsent
	case errors.Is(err, httpclient.ErrAccountSuspended):
		return wordsSuspended
	case errors.Is(err, httpclient.ErrTokenInvalidated):
		return wordsSignedOut
	case errors.Is(err, types.ErrContentUnavailable):
		return wordsRestricted
	}
	return ""
}

// fail puts a failed request in words: Instagram's refusal where it is one, else [what] and the library's reason.
func fail(what string, err error) error {
	if w := rejection(err); w != "" {
		return errors.New(w)
	}
	switch {
	case errors.Is(err, httpclient.ErrRateLimited):
		return errors.New(wordsSlowDown)
	case errors.Is(err, context.DeadlineExceeded):
		return errors.New(what + ": Instagram took too long to answer")
	}
	return fmt.Errorf("%s: %v", what, err)
}

// --- what is held while running -------------------------------------------------------------------------------------

// The session in use and its client, all under mu. runCtx lives as long as the session does and outlasts a client
// replaced by restart; stopRun ends it.
var (
	mu        sync.Mutex
	sess      *session
	cli       *instameow.Client
	loaded    bool // Instagram's inbox page has been read with this client, so requests can be made
	connected bool
	refused   int // times in a row the live connection was refused as not signed in
	runCtx    context.Context
	stopRun   context.CancelFunc
)

// thread is what the helper remembers of a chat while it runs. Instagram names a thread three ways and its requests
// want different ones: the chat id the protocol carries (id), a long one for unsending and marking seen (long), and
// a number for uploads (key).
type thread struct {
	id    string
	long  string
	key   int64
	group bool
	seen  []seen
}

// reacted is whose reaction on which message a reaction's own id stands for: Instagram names only that id when a
// reaction is taken off.
type reacted struct {
	target string
	from   int64
}

// memo is what this run remembers of the account, in memory only: who the person is, the threads and people met,
// and whose reaction each reaction id stands for. Its lock guards every field.
var memo struct {
	sync.Mutex
	me      int64
	threads map[string]*thread
	people  map[int64]*slidetypes.User
	reacts  map[string]reacted
}

// resetMemo forgets everything remembered and begins again for the person [me] (0 for nobody).
func resetMemo(me int64) {
	memo.Lock()
	defer memo.Unlock()
	memo.me = me
	memo.threads = map[string]*thread{}
	memo.people = map[int64]*slidetypes.User{}
	memo.reacts = map[string]reacted{}
}

// myID is the id messages name the signed-in person by; 0 where nobody is.
func myID() int64 {
	memo.Lock()
	defer memo.Unlock()
	return memo.me
}

// nameOf is what to call the person [fbid], from what is remembered of them.
func nameOf(fbid int64) string {
	memo.Lock()
	defer memo.Unlock()
	return userName(memo.people[fbid])
}

// notePerson remembers [u]; true where they are new or their name, username or picture changed.
func notePerson(u *slidetypes.User) bool {
	if u == nil || u.InteropMessagingUserFBID == 0 {
		return false
	}
	memo.Lock()
	defer memo.Unlock()
	old := memo.people[u.InteropMessagingUserFBID]
	if old != nil && old.FullName == u.FullName && old.Username == u.Username && avatarPath(old.ProfilePicURL) == avatarPath(u.ProfilePicURL) {
		return false
	}
	kept := *u
	memo.people[u.InteropMessagingUserFBID] = &kept
	return true
}

// noteMessages remembers the times of a thread's messages, and whose reactions their reaction ids stand for.
func noteMessages(chat string, list ...*slidetypes.Message) {
	memo.Lock()
	defer memo.Unlock()
	th := memo.threads[chat]
	if th == nil {
		th = &thread{id: chat}
		memo.threads[chat] = th
	}
	for _, m := range list {
		if m == nil {
			continue
		}
		th.seen = noteSeen(th.seen, seen{id: messageID(m), ts: m.TimestampMS.UnixMilli()})
		for _, r := range m.Reactions {
			if r != nil && r.LogMessageID != "" {
				noteReactionLocked(r.LogMessageID, messageID(m), r.SenderFBID)
			}
		}
	}
}

// noteReactionLocked remembers whose reaction on which message [logID] stands for. The memo's lock must be held.
// Past 20,000 the lot is let go rather than the oldest picked out.
func noteReactionLocked(logID, target string, from int64) {
	if len(memo.reacts) > 20000 {
		memo.reacts = map[string]reacted{}
	}
	memo.reacts[logID] = reacted{target: target, from: from}
}

// known is the thread as remembered; ok is false where the helper has not met it.
func known(chat string) (thread, bool) {
	memo.Lock()
	defer memo.Unlock()
	th := memo.threads[chat]
	if th == nil {
		return thread{id: chat}, false
	}
	return *th, true
}

// --- signing in and connecting --------------------------------------------------------------------------------------

// cookieJar puts a browser's cookies, by name, into the library's jar for Instagram.
func cookieJar(values map[string]string) *cookies.Cookies {
	jar := &cookies.Cookies{Platform: types.Instagram}
	named := make(map[cookies.MetaCookieName]string, len(values))
	for name, value := range values {
		named[cookies.MetaCookieName(name)] = value
	}
	jar.UpdateValues(named)
	return jar
}

// cookieValues is the cookies [c] holds now, by name: Instagram refreshes them as the client is used.
func cookieValues(c *instameow.Client) map[string]string {
	values := map[string]string{}
	for name, value := range c.GetCookies().GetAll() {
		if value != "" {
			values[string(name)] = value
		}
	}
	return values
}

// newClient makes a client for a browser's cookies, as the bridge's getInstaClient does. Typing notices are left off:
// the protocol has none, and it saves a second connection.
func newClient(values map[string]string) *instameow.Client {
	c := instameow.NewClient(instameow.ClientParams{
		Cookies:       cookieJar(values),
		Log:           log.With().Str("component", "instameow").Logger(),
		Settings:      exhttp.SensibleClientSettings,
		DisableTyping: true,
	})
	c.SetEventHandler(func(ctx context.Context, evt slidetypes.ClientEvent) error { return onEvent(ctx, c, evt) })
	return c
}

// status answers `status`: whether anyone is signed in, whether the live connection is up, and who it is.
func status() map[string]any {
	mu.Lock()
	defer mu.Unlock()
	if sess == nil {
		return map[string]any{"linked": false, "connected": false, "me": "", "name": "", "handle": ""}
	}
	return map[string]any{"linked": true, "connected": connected, "me": sess.Me, "name": sess.Name, "handle": sess.Handle}
}

// client is the signed-in client once requests can be made with it.
func client() (*instameow.Client, error) {
	mu.Lock()
	defer mu.Unlock()
	if cli == nil || sess == nil {
		return nil, errNotLinked
	}
	if !loaded {
		return nil, errNotReady
	}
	return cli, nil
}

// isCurrent is whether [c] is still the client in use: one replaced or signed out is no longer listened to.
func isCurrent(c *instameow.Client) bool {
	mu.Lock()
	defer mu.Unlock()
	return cli == c
}

// resume takes up a kept session: the client is made and Instagram's inbox loaded in the background.
func resume(s *session) {
	c := newClient(s.Cookies)
	ctx, cancel := context.WithCancel(bg())
	resetMemo(parsePersonID(s.Me))
	mu.Lock()
	sess, cli, loaded, connected, refused = s, c, false, false, 0
	runCtx, stopRun = ctx, cancel
	mu.Unlock()
	go run(ctx, c)
}

// run loads Instagram's inbox page with [c] as a browser would, says the chats it lists, then holds the live
// connection. A refusal ends the session; anything else (no network, Instagram unwell) is tried again, slower each
// time.
func run(ctx context.Context, c *instameow.Client) {
	for attempt := 0; ctx.Err() == nil && isCurrent(c); attempt++ {
		user, mailbox, err := c.LoadIndex(ctx)
		if err == nil {
			if !adopt(c, user) {
				return
			}
			absorbMailbox(c, mailbox, true)
			go c.Connect(ctx)
			return
		}
		if ctx.Err() != nil {
			return
		}
		if w := rejection(err); w != "" {
			log.Warn().Err(err).Msg("Instagram no longer takes this session")
			unlinkNow(c, w)
			return
		}
		wait := min(time.Duration(1<<min(attempt, 9))*2*time.Second, 5*time.Minute)
		log.Warn().Err(err).Stringer("retry_in", wait).Msg("Instagram's inbox could not be loaded")
		select {
		case <-ctx.Done():
			return
		case <-time.After(wait):
		}
	}
}

// adopt records who the loaded page says the account is and opens the client to requests; false where [c] is no
// longer the client in use.
func adopt(c *instameow.Client, user *types.PolarisViewer) bool {
	mu.Lock()
	defer mu.Unlock()
	if cli != c || sess == nil {
		return false
	}
	if fbid := c.GetOwnFBID(); fbid != 0 {
		sess.Me = personID(fbid)
	}
	if user != nil {
		sess.IGID = cmp.Or(user.ID, sess.IGID)
		sess.Handle = cmp.Or(user.GetUsername(), sess.Handle)
		sess.Name = cmp.Or(user.GetName(), sess.Name, sess.Handle)
	}
	sess.Cookies = cookieValues(c)
	sess.Saved = time.Now().UnixMilli()
	if err := saveSession(sessionPath(), sess); err != nil {
		log.Err(err).Msg("the session could not be kept")
	}
	memo.Lock()
	memo.me = parsePersonID(sess.Me)
	memo.Unlock()
	loaded = true
	return true
}

// keepCookies writes the cookies as Instagram has since refreshed them, so the next start signs in with the newest.
func keepCookies(c *instameow.Client) {
	mu.Lock()
	defer mu.Unlock()
	if cli != c || sess == nil {
		return
	}
	sess.Cookies = cookieValues(c)
	sess.Saved = time.Now().UnixMilli()
	if err := saveSession(sessionPath(), sess); err != nil {
		log.Err(err).Msg("the session could not be kept")
	}
}

// signIn checks a browser's cookies with Instagram as the bridge's loginWithCookies does (by loading the inbox with
// them), keeps them, and connects.
func signIn(ctx context.Context, given map[string]string) (any, error) {
	values := cleanCookies(given)
	if w := missingCookieWords(values); w != "" {
		return nil, errors.New(w)
	}
	// Until it is taken, this client is not the one in use, so what it says while loading reaches nobody.
	c := newClient(values)
	user, mailbox, err := c.LoadIndex(ctx)
	if err != nil {
		log.Warn().Err(err).Msg("Instagram did not take the cookies")
		if errors.Is(err, httpclient.ErrChallengeRequired) || errors.Is(err, httpclient.ErrCheckpointRequired) {
			return nil, errors.New("Instagram asked to confirm it's you: finish that in the browser, then copy the cookies again")
		}
		if errors.Is(err, httpclient.ErrTokenInvalidated) {
			return nil, errors.New("Instagram did not take these cookies: they are signed out or out of date. Sign in to instagram.com in the browser and copy them again")
		}
		return nil, fail("Instagram could not be reached", err)
	}
	me := c.GetOwnFBID()
	if me == 0 || user == nil {
		return nil, errors.New(wordsNoIdentity)
	}
	s := &session{
		Cookies: cookieValues(c),
		Me:      personID(me),
		IGID:    user.ID,
		Handle:  user.GetUsername(),
		Name:    cmp.Or(user.GetName(), user.GetUsername()),
		Saved:   time.Now().UnixMilli(),
	}
	// A session already held (this account's or another's) gives way to the new one, with what was kept for it.
	if old := takeDown(); old != nil {
		old.Disconnect()
	}
	forgetFiles()
	if err = saveSession(sessionPath(), s); err != nil {
		return nil, fmt.Errorf("the session could not be kept: %v", err)
	}
	live, cancel := context.WithCancel(bg())
	resetMemo(me)
	mu.Lock()
	sess, cli, loaded, connected, refused = s, c, true, false, 0
	runCtx, stopRun = live, cancel
	mu.Unlock()
	who := map[string]any{"me": s.Me, "name": s.Name, "handle": s.Handle}
	event("linked", who)
	absorbMailbox(c, mailbox, true)
	go c.Connect(live)
	return who, nil
}

// takeDown lets go of the client in use and returns it to be disconnected; nil where there is none. Called without
// mu held; disconnecting waits for the connection to end, so it is the caller's to do, off the connection's own
// goroutine.
func takeDown() *instameow.Client {
	mu.Lock()
	old, cancel := cli, stopRun
	sess, cli, loaded, connected, refused = nil, nil, false, false, 0
	runCtx, stopRun = nil, nil
	mu.Unlock()
	if cancel != nil {
		cancel()
	}
	return old
}

// forgetFiles removes what is kept for a session: the cookies and the pictures of the people in it.
func forgetFiles() {
	_ = os.Remove(sessionPath())
	_ = os.Remove(sessionPath() + ".tmp")
	_ = os.RemoveAll(avatarDir())
}

// unlink is the person signing out here. The browser's own session is left alone: signing that out would sign the
// browser out too.
func unlink() {
	if old := takeDown(); old != nil {
		old.Disconnect()
	}
	resetMemo(0)
	forgetFiles()
}

// unlinkNow is Instagram ending the session: everything is forgotten and the app told why, in [words].
func unlinkNow(c *instameow.Client, words string) {
	mu.Lock()
	if cli != c {
		mu.Unlock()
		return
	}
	mu.Unlock()
	if old := takeDown(); old != nil {
		// This may be running on the connection's own goroutine, which a disconnect waits for.
		go old.Disconnect()
	}
	resetMemo(0)
	forgetFiles()
	event("unlinked", map[string]any{"error": words})
}

// restart begins again with a fresh client and the same cookies, as the bridge's FullReconnect does: after Instagram
// says its stream of changes can no longer be followed, or refuses the live connection once.
func restart(old *instameow.Client) {
	mu.Lock()
	if cli != old || sess == nil {
		mu.Unlock()
		return
	}
	c := newClient(cookieValues(old))
	was := connected
	cli, loaded, connected = c, false, false
	ctx := runCtx
	mu.Unlock()
	if was {
		event("disconnected", nil)
	}
	old.Disconnect()
	run(ctx, c)
}

// shutdown is the app quitting: the newest cookies are kept for the next start and the connection closed. The
// session stays.
func shutdown() {
	mu.Lock()
	c := cli
	mu.Unlock()
	if c == nil {
		return
	}
	keepCookies(c)
	mu.Lock()
	cancel := stopRun
	mu.Unlock()
	if cancel != nil {
		cancel()
	}
	c.Disconnect()
}

// setConnected notes whether [c]'s live connection is up, and says `connected` or `disconnected` when that changes.
// Connecting clears the count of refusals.
func setConnected(c *instameow.Client, now bool) {
	mu.Lock()
	if cli != c || connected == now {
		mu.Unlock()
		return
	}
	connected = now
	if now {
		refused = 0
	}
	mu.Unlock()
	if now {
		event("connected", nil)
	} else {
		event("disconnected", nil)
	}
}

// --- what Instagram sends -------------------------------------------------------------------------------------------

// onEvent takes what the library says of the connection and of the account. An error returned from here makes the
// library stop (after a refusal) or reconnect and send the change again, so only a refused connection returns one.
func onEvent(ctx context.Context, c *instameow.Client, evt slidetypes.ClientEvent) (err error) {
	defer func() {
		if v := recover(); v != nil {
			log.Error().Interface("panic", v).Type("event", evt).Msg("an event from Instagram could not be handled")
			err = nil
		}
	}()
	if !isCurrent(c) {
		if _, gone := evt.(*slidetypes.Disconnected); gone {
			return errors.New("this client is no longer in use")
		}
		return nil
	}
	switch e := evt.(type) {
	case *slidetypes.Connected:
		setConnected(c, true)
	case *slidetypes.Disconnected:
		setConnected(c, false)
		log.Warn().Err(e.Error).Int("failures", e.FailureCount).Msg("the connection to Instagram dropped")
		if dgw.IsUnauthorized(e.Error) || errors.Is(e.Error, instameow.ErrUserIDMissing) {
			// The live connection says the session is not signed in. Once, that is checked by starting over (the
			// inbox page then says for certain, and why); twice in a row with no connection between, it is believed.
			mu.Lock()
			refused++
			again := refused < 2
			mu.Unlock()
			if again {
				go restart(c)
			} else {
				unlinkNow(c, wordsSignedOut)
			}
			return errors.New("the connection was refused; not reconnecting with it")
		}
	case *slidetypes.AuthError:
		if w := rejection(e.Error); w != "" {
			log.Warn().Err(e.Error).Msg("Instagram no longer takes this session")
			unlinkNow(c, w)
		} else {
			log.Warn().Err(e.Error).Msg("Instagram refused a request")
		}
	case *slidetypes.ReconnectionStateUpdate:
		// The page was loaded again; Instagram may have refreshed the cookies with it.
		keepCookies(c)
	case *slidetypes.ResnapshotRequired:
		go restart(c)
	case *slidetypes.Delta:
		onDelta(ctx, c, e)
	}
	return nil
}

// refresh asks Instagram for a thread again and says it as a `chat`.
func refresh(ctx context.Context, c *instameow.Client, chat string) (thread, error) {
	resp, err := c.GetThread(ctx, slidetypes.MakeGetThreadInfoRequest(chat))
	if err != nil {
		return thread{id: chat}, err
	}
	if resp == nil || resp.ThreadInfo.AsIGDirectThread == nil {
		return thread{id: chat}, errors.New("Instagram does not know that chat")
	}
	absorbThread(c, resp.ThreadInfo.AsIGDirectThread, true)
	th, _ := known(resp.ThreadInfo.AsIGDirectThread.ID)
	return th, nil
}

// threadOf is the thread with all its names known, asked of Instagram where the helper has not met it (which also
// says it to the app as a `chat`).
func threadOf(ctx context.Context, c *instameow.Client, chat string) (thread, error) {
	if chat == "" {
		return thread{}, errors.New("no chat was named")
	}
	if th, ok := known(chat); ok && th.long != "" {
		return th, nil
	}
	return refresh(ctx, c, chat)
}

// onDelta turns one change Instagram sends into the protocol's events (as the bridge's handleDelta does).
func onDelta(ctx context.Context, c *instameow.Client, d *slidetypes.Delta) {
	chat := d.ThreadIGID
	me := myID()
	switch e := d.Data.(type) {
	case *slidetypes.NewMessageEvent:
		// Some messages come without the thread beside them, only inside (the bridge's note).
		if chat == "" && e.Message != nil {
			chat = e.Message.ThreadFBID
		}
		sayMessage(ctx, c, chat, e.Message, me)
	case *slidetypes.AdminMessageEvent:
		sayMessage(ctx, c, chat, e.Message, me)
	case *slidetypes.EditMessageEvent:
		event("edited", map[string]any{"chat": chat, "target": e.MessageID, "text": e.TextBody})
	case *slidetypes.DeleteMessageEvent:
		event("deleted", map[string]any{"chat": chat, "target": e.MessageID})
	case *slidetypes.CreateReactionEvent:
		if e.Reaction.LogMessageID != "" {
			memo.Lock()
			noteReactionLocked(e.Reaction.LogMessageID, e.MessageID, e.Reaction.SenderFBID)
			memo.Unlock()
		}
		event("reaction", reactionShape(chat, e.MessageID, e.Reaction.SenderFBID, e.Reaction.Reaction, false))
	case *slidetypes.DeleteReactionEvent:
		target, from := e.MessageID, e.Reaction.SenderFBID
		if from == 0 {
			// Instagram names only the reaction's own id here: whose it was is what was noted when it was put on.
			memo.Lock()
			was, ok := memo.reacts[e.Reaction.LogMessageID]
			memo.Unlock()
			if !ok {
				log.Debug().Msg("a reaction this helper never met was taken off")
				return
			}
			target, from = was.target, was.from
		}
		event("reaction", reactionShape(chat, target, from, e.Reaction.Reaction, true))
	case *slidetypes.MarkReadEvent:
		// The person read the thread somewhere else.
		th, _ := known(chat)
		event("receipt", receiptShape(chat, me, th.seen, e.ReadTimestampMS.UnixMilli()))
	case *slidetypes.ReadReceiptEvent:
		th, _ := known(chat)
		event("receipt", receiptShape(chat, e.ReadReceipt.ParticipantFBID, th.seen, e.ReadReceipt.WatermarkTimestampMS.UnixMilli()))
	case *slidetypes.UpdateThreadNameEvent, *slidetypes.UpdateThreadImageEvent, *slidetypes.ParticipantJoinEvent,
		*slidetypes.ParticipantLeaveEvent, *slidetypes.AdminChangeEvent:
		// The thread's name, picture or people changed: ask for it whole and say it again.
		if chat != "" {
			if _, err := refresh(ctx, c, chat); err != nil {
				log.Warn().Err(err).Msg("a changed chat could not be read again")
			}
		}
	case *slidetypes.UpdateThreadFolderEvent:
		// A request accepted becomes a chat like any other.
		if chat != "" && e.Folder != "OTHER" && e.Folder != "PENDING" && e.Folder != "SPAM" {
			if _, err := threadOf(ctx, c, chat); err != nil {
				log.Warn().Err(err).Msg("a moved chat could not be read")
			}
		}
	case *slidetypes.DeleteThreadEvent:
		memo.Lock()
		delete(memo.threads, chat)
		memo.Unlock()
	}
}

// sayMessage says a message that arrived (or that the person sent from elsewhere, or from here: Instagram tells this
// connection of those too).
func sayMessage(ctx context.Context, c *instameow.Client, chat string, m *slidetypes.Message, me int64) {
	if m == nil || chat == "" {
		return
	}
	// A thread first heard of by a message is asked for, so the app has the chat before the message in it.
	th, err := threadOf(ctx, c, chat)
	if err != nil {
		log.Warn().Err(err).Msg("the chat of a new message could not be read")
	}
	if m.Sender != nil && notePerson(&m.Sender.UserDict) {
		sayName(c, &m.Sender.UserDict)
	}
	noteMessages(chat, m)
	if shape, ok := messageShape(chat, th.group, m, me, nameOf); ok {
		event("message", shape)
	}
}

// absorbMailbox takes in a page of the inbox and returns its threads as chats, saying each where [emit].
func absorbMailbox(c *instameow.Client, mailbox *slidetypes.Mailbox, emit bool) []map[string]any {
	list := []map[string]any{}
	if mailbox == nil {
		return list
	}
	for _, edge := range mailbox.ThreadsByFolder.Edges {
		// As the bridge skips them: a hole in the list, or a thread Instagram gave no people for.
		if t := edge.Node.AsIGDirectThread; t != nil && t.Users != nil {
			list = append(list, absorbThread(c, t, emit))
		}
	}
	return list
}

// absorbThread remembers a thread's names and people, says the people as `name` events where they are new, and
// returns the thread as a chat (said as a `chat` event where [emit]). Pictures not yet kept are fetched afterwards and
// the chat said again with its picture.
func absorbThread(c *instameow.Client, t *slidetypes.ThreadInfo, emit bool) map[string]any {
	memo.Lock()
	th := memo.threads[t.ID]
	if th == nil {
		th = &thread{id: t.ID}
		memo.threads[t.ID] = th
	}
	th.long = cmp.Or(t.ThreadID, th.long)
	th.key = cmp.Or(t.ThreadKey, th.key)
	th.group = isGroup(t)
	me := memo.me
	memo.Unlock()

	if t.SlideMessages != nil {
		for _, edge := range t.SlideMessages.Edges {
			noteMessages(t.ID, edge.Node)
		}
	}
	notePerson(t.Viewer)
	for _, u := range t.Users {
		if notePerson(u) {
			sayName(c, u)
		}
	}

	address := threadAvatarURL(t)
	chat := chatShape(t, me, avatarCached(address))
	if emit {
		event("chat", chat)
	}
	if address != "" && chat["avatar"] == nil {
		later(c, address, func(file string) {
			again := make(map[string]any, len(chat))
			for k, v := range chat {
				again[k] = v
			}
			again["avatar"] = file
			event("chat", again)
		})
	}
	return chat
}

// sayName says a person met in a thread or a message, and again with their picture once that is fetched.
func sayName(c *instameow.Client, u *slidetypes.User) {
	kept := *u
	file := avatarCached(kept.ProfilePicURL)
	event("name", nameShape(&kept, file))
	if file == "" && kept.ProfilePicURL != "" {
		later(c, kept.ProfilePicURL, func(file string) { event("name", nameShape(&kept, file)) })
	}
}

// --- what the app asks ----------------------------------------------------------------------------------------------

// chats is the first page of the inbox, as the website lists it first (about twenty threads). Older threads appear as
// a `chat` event when a message arrives in one.
func chats(ctx context.Context) (any, error) {
	c, err := client()
	if err != nil {
		return nil, err
	}
	resp, err := c.GetMailbox(ctx)
	if err != nil {
		return nil, fail("The chats could not be read", err)
	}
	if resp.GetMailbox() == nil {
		return nil, errors.New("Instagram sent no list of chats")
	}
	return absorbMailbox(c, resp.Mailbox, false), nil
}

// history is a page of a thread: its newest twenty, or the twenty older than [before]. Instagram pages by message id
// itself, so nothing is kept between calls.
func history(ctx context.Context, chat, before string) (any, error) {
	c, err := client()
	if err != nil {
		return nil, err
	}
	if chat == "" {
		return nil, errors.New("no chat was named")
	}
	me := myID()
	var page *slidetypes.SlideMessages
	group := false
	if before == "" {
		resp, err := c.GetThread(ctx, slidetypes.MakeGetThreadInfoRequest(chat))
		if err != nil {
			return nil, fail("The messages could not be read", err)
		}
		if resp == nil || resp.ThreadInfo.AsIGDirectThread == nil {
			return nil, errors.New("Instagram does not know that chat")
		}
		t := resp.ThreadInfo.AsIGDirectThread
		absorbThread(c, t, false)
		page, group = t.SlideMessages, isGroup(t)
	} else {
		th, _ := known(chat)
		group = th.group
		older := &before
		var cursor *string
		// A page can hold nothing but Instagram's own notices; then the next is read, a few at most, so the app is
		// never handed an empty page with more behind it and no message id to ask from.
		for range 5 {
			resp, err := c.PaginateMessages(ctx, &slidetypes.PaginateMessagesRequest{
				AfterCursor:             cursor,
				OlderThanMessageID:      older,
				ThreadID:                chat,
				FirstN:                  20,
				InitialMessagePageCount: 20,
			})
			if err != nil {
				return nil, fail("The older messages could not be read", err)
			}
			if resp == nil || resp.ThreadInfo.AsIGDirectThread == nil || resp.ThreadInfo.AsIGDirectThread.Messages == nil {
				return nil, errors.New("Instagram sent no older messages for that chat")
			}
			got := resp.ThreadInfo.AsIGDirectThread.Messages
			if page == nil {
				page = got
			} else {
				page.Edges = append(page.Edges, got.Edges...)
				page.PageInfo = got.PageInfo
			}
			if len(historyShape(chat, group, page.Edges, me, nil)) > 0 || !got.PageInfo.HasNextPage || got.PageInfo.EndCursor == "" {
				break
			}
			older, cursor = nil, &got.PageInfo.EndCursor
		}
	}
	if page == nil {
		return map[string]any{"messages": []map[string]any{}, "more": false}, nil
	}
	for _, edge := range page.Edges {
		noteMessages(chat, edge.Node)
		if edge.Node != nil && edge.Node.Sender != nil {
			notePerson(&edge.Node.Sender.UserDict)
		}
	}
	return map[string]any{
		"messages": historyShape(chat, group, page.Edges, me, nameOf),
		"more":     page.PageInfo.HasNextPage,
	}, nil
}

// offlineID is a new id of the sender's own for something sent, which Instagram wants with every send.
func offlineID() string { return strconv.FormatInt(methods.GenerateEpochID(), 10) }

// sent is what a send answers, {"id","ts"}, from what Instagram says of the message it took; the time is now where
// it gives none. The message is remembered with the thread's, so it can be marked seen up to.
func sent(chat string, m slidetypes.SentMessage) (any, error) {
	id := cmp.Or(m.ID, m.MessageID)
	if id == "" {
		return nil, errors.New("Instagram did not say the message was sent")
	}
	ts := m.TimestampMS.UnixMilli()
	if m.TimestampMS.IsZero() {
		ts = time.Now().UnixMilli()
	}
	memo.Lock()
	if th := memo.threads[chat]; th != nil {
		th.seen = noteSeen(th.seen, seen{id: id, ts: ts})
	}
	memo.Unlock()
	return map[string]any{"id": id, "ts": ts}, nil
}

// send sends words to a thread, as the bridge's ToInstagram builds the request; [quoted] is the message replied to.
func send(ctx context.Context, to, text, quoted string) (any, error) {
	c, err := client()
	if err != nil {
		return nil, err
	}
	if to == "" {
		return nil, errors.New("no chat was named")
	}
	if text == "" {
		return nil, errors.New("there is nothing to send")
	}
	attribution := "igd_web_chat_tab:in_thread"
	req := &slidetypes.SendTextRequest{
		IGThreadIGID:       &to,
		OfflineThreadingID: offlineID(),
		Text:               slidetypes.SensitiveString{Value: text},
		SendAttribution:    &attribution,
	}
	if quoted != "" {
		req.ReplyToMessageID = &quoted
	}
	resp, err := c.SendMessage(ctx, req)
	if err != nil {
		return nil, fail("Instagram did not send the message", err)
	}
	return sent(to, resp.GetMessage())
}

// maxUpload is the largest file this helper reads into memory to send.
const maxUpload = 100 << 20

// sendMedia uploads a file as the website does and sends it (the bridge's ReuploadFileToMeta and SendMedia). A file
// on Instagram carries no words of its own, so [text] follows as a message after it.
func sendMedia(ctx context.Context, to, path, mime, name, text string) (any, error) {
	c, err := client()
	if err != nil {
		return nil, err
	}
	th, err := threadOf(ctx, c, to)
	if err != nil {
		return nil, fail("The chat could not be read", err)
	}
	if st, err := os.Stat(path); err != nil {
		return nil, fmt.Errorf("the file could not be read: %v", err)
	} else if st.Size() > maxUpload {
		return nil, errors.New("the file is too large to send to Instagram from here (100 MB at most)")
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("the file could not be read: %v", err)
	}
	if mime == "" {
		mime = http.DetectContentType(data)
	}
	if name == "" {
		name = filepath.Base(path)
	}
	upload := func() (int64, error) {
		resp, err := c.GetHTTP().SendMercuryUploadRequest(ctx, th.key, &httpclient.MercuryUploadMedia{
			Filename: name, MimeType: mime, MediaData: data,
		})
		if err != nil {
			return 0, err
		}
		if resp == nil || resp.Payload.RealMetadata == nil {
			return 0, nil
		}
		return resp.Payload.RealMetadata.GetFbId(), nil
	}
	attachment, err := upload()
	if errors.Is(err, types.ErrPleaseReloadPage) {
		// As the bridge does: Instagram wants its page loaded again first; once.
		if reloaded, reloadErr := c.ReloadIndex(ctx); reloadErr == nil && reloaded {
			attachment, err = upload()
		}
	}
	if err != nil {
		return nil, fail("Instagram did not take the file", err)
	}
	if attachment == 0 {
		// The bridge falls back to Instagram's phone app's upload for videos some accounts cannot send from the
		// website; this helper only ever acts as the website.
		return nil, errors.New("Instagram did not take the file: it can't be sent from here yet")
	}
	resp, err := c.SendMedia(ctx, &slidetypes.SendMediaRequest{
		AttachmentFBID:     strconv.FormatInt(attachment, 10),
		ThreadID:           to,
		OfflineThreadingID: offlineID(),
	})
	if err != nil {
		return nil, fail("Instagram did not send the file", err)
	}
	result, err := sent(to, resp.GetMessage())
	if err != nil {
		return nil, err
	}
	if text != "" {
		if _, err = send(ctx, to, text, ""); err != nil {
			return nil, fmt.Errorf("the file was sent, but not the words with it: %v", err)
		}
	}
	return result, nil
}

// markRead marks a thread seen up to [id] (the newest message the helper has met in it where none is named), with the
// two requests the website makes.
func markRead(ctx context.Context, to, id string) error {
	c, err := client()
	if err != nil {
		return err
	}
	th, err := threadOf(ctx, c, to)
	if err != nil {
		return fail("The chat could not be read", err)
	}
	if id == "" && len(th.seen) == 0 {
		// Nothing of the thread has been met in this run: its newest messages say what there is to mark.
		if th, err = refresh(ctx, c, to); err != nil {
			return fail("The chat could not be read", err)
		}
	}
	var ts int64
	for _, s := range th.seen {
		if s.id == id {
			ts = s.ts
		}
	}
	if id == "" {
		if len(th.seen) == 0 {
			return nil
		}
		last := th.seen[len(th.seen)-1]
		id, ts = last.id, last.ts
	}
	empty := ""
	if _, err = c.MarkRead(ctx, &slidetypes.MarkReadRequest{
		Metadata: slidetypes.MarkReadMetadata{IGThreadIGID: th.long},
		Data:     slidetypes.MarkReadData{MessageID: id, ItemID: &empty},
	}); err != nil {
		return fail("Instagram did not mark the chat seen", err)
	}
	if ts == 0 {
		// The second request names the message's time, which is only known for a message met in this run.
		return nil
	}
	if _, err = c.MarkReadValidation(ctx, &slidetypes.MarkReadRequest{
		Metadata: slidetypes.MarkReadMetadata{IGThreadIGID: th.long},
		Data:     slidetypes.MarkReadData{MessageID: id, MessageTimestampMS: jsontime.UnixMilliString{Time: time.UnixMilli(ts)}},
	}); err != nil {
		log.Warn().Err(err).Msg("Instagram did not confirm the seen mark")
	}
	return nil
}

// react puts the person's reaction on a message, or takes it off. Instagram keeps one reaction a person a message.
func react(ctx context.Context, to, target, emoji string, remove bool) error {
	c, err := client()
	if err != nil {
		return err
	}
	if to == "" || target == "" {
		return errors.New("no message was named")
	}
	if emoji == "" && !remove {
		return errors.New("no emoji was named")
	}
	state := slidetypes.ReactionStatusCreated
	if remove {
		state = slidetypes.ReactionStatusDeleted
	}
	_, err = c.SendReaction(ctx, &slidetypes.CreateReactionRequest{Input: slidetypes.ReactionInput{
		Emoji:          variationselector.Remove(emoji),
		MessageID:      target,
		ReactionStatus: state,
		ThreadID:       to,
	}})
	if err != nil {
		return fail("Instagram did not take the reaction", err)
	}
	return nil
}

// unsend takes back the person's own message for everyone.
func unsend(ctx context.Context, to, target string) error {
	c, err := client()
	if err != nil {
		return err
	}
	if target == "" {
		return errors.New("no message was named")
	}
	th, err := threadOf(ctx, c, to)
	if err != nil {
		return fail("The chat could not be read", err)
	}
	resp, err := c.UnsendMessage(ctx, &slidetypes.UnsendMessageRequest{
		MessageID: target,
		SendData:  slidetypes.SendData{ThreadID: th.long},
	})
	if err != nil {
		return fail("Instagram did not unsend the message", err)
	}
	if resp != nil && !resp.DirectUnsendMessage {
		return errors.New("Instagram did not unsend the message")
	}
	return nil
}

// who is a person by id: as met in a thread or a message, or asked of Instagram.
func who(ctx context.Context, id string) (any, error) {
	c, err := client()
	if err != nil {
		return nil, err
	}
	fbid := parsePersonID(id)
	if fbid == 0 {
		return nil, errors.New("no person was named")
	}
	memo.Lock()
	u := memo.people[fbid]
	memo.Unlock()
	if u == nil {
		resp, err := c.GetUserForNewDM(ctx, fbid)
		if err != nil {
			return nil, fail("Instagram did not say who that is", err)
		}
		if resp == nil || resp.Data == nil {
			return nil, errors.New("Instagram does not know that person")
		}
		u = resp.Data
		if u.InteropMessagingUserFBID == 0 {
			u.InteropMessagingUserFBID = fbid
		}
		notePerson(u)
	}
	file := avatarCached(u.ProfilePicURL)
	if file == "" && u.ProfilePicURL != "" {
		file = fetchAvatar(ctx, u.ProfilePicURL)
	}
	return nameShape(u, file), nil
}
