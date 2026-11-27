package main

// The requests that go to Messenger: history, sending, reading, reacting, unsending, files and people.

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"go.mau.fi/util/variationselector"

	"go.mau.fi/mautrix-meta/pkg/messagix/httpclient"
	"go.mau.fi/mautrix-meta/pkg/messagix/methods"
	"go.mau.fi/mautrix-meta/pkg/messagix/socket"
	"go.mau.fi/mautrix-meta/pkg/messagix/table"
	"go.mau.fi/mautrix-meta/pkg/messagix/useragent"
)

// The largest file sent or fetched: Messenger's own limit for a file is 25 MB, a video's is larger.
const maxFile = 100 << 20

// chatKey reads a chat id from the app as a thread's number, or says it is not one.
func chatKey(s string) (int64, error) {
	k, ok := parseID(s)
	if !ok {
		return 0, fmt.Errorf("%q is not a Messenger chat", s)
	}
	return k, nil
}

// threadCopy is what is known of a thread, copied out from under the book's lock.
func (b *book) threadCopy(k int64) thread {
	b.mu.Lock()
	defer b.mu.Unlock()
	if t := b.threads[k]; t != nil {
		return *t
	}
	return thread{Key: k, Type: b.kinds[k]}
}

// ref is what is remembered of a message, for a caller that does not hold the book's lock.
func (b *book) ref(id string) (msgRef, bool) {
	b.mu.Lock()
	defer b.mu.Unlock()
	r, ok := b.msgs[id]
	return r, ok
}

// when is sentAt, for a caller that does not hold the book's lock.
func (b *book) when(id string) int64 {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.sentAt(id)
}

// tasks sends tasks down Messenger's connection once it can take them, and gives back the table it answers with.
func tasks(ctx context.Context, c *conn, list ...socket.Task) (*table.LSTable, error) {
	if err := c.cli.WaitUntilCanSendMessages(ctx, 20*time.Second); err != nil {
		return nil, errors.New("Messenger is not connected; try again in a moment")
	}
	tbl, err := c.cli.ExecuteTasks(ctx, list...)
	if err != nil {
		log.Err(err).Msg("a task Messenger did not take")
		return nil, fmt.Errorf("Messenger did not answer: %w", err)
	}
	return tbl, nil
}

// syncGroup is the sync group a thread's tasks name (Messenger keeps its tables in several): the one its rows
// gave, else 1.
func syncGroup(t thread) int64 {
	if t.SyncGroup != 0 {
		return t.SyncGroup
	}
	return 1
}

// --- history --------------------------------------------------------------------------------------------------------

// history answers `history`: from the newest stretch kept where that reaches, else by asking Messenger for the
// thread (no [before]) or for what came before a message, and waiting for the stretch it sends.
func history(ctx context.Context, c *conn, b *book, chat, before string) (any, error) {
	k, err := chatKey(chat)
	if err != nil {
		return nil, err
	}
	t := b.threadCopy(k)
	if t.Type.IsWhatsApp() {
		// An end-to-end encrypted chat's past is not on Messenger's servers in a form this helper reads yet: the
		// app has what arrived while it was running.
		return map[string]any{"messages": []any{}, "more": false, "encrypted": true}, nil
	}
	if list, more, ok := b.history(k, before); ok {
		return map[string]any{"messages": list, "more": more}, nil
	}
	var at int64
	var task socket.Task = &socket.CreateThreadTask{ThreadFBID: k, SyncGroup: int(syncGroup(t))}
	if before != "" {
		if at = b.when(before); at == 0 {
			return nil, errors.New("That message's time is not known, so what came before it cannot be asked for")
		}
		task = &socket.FetchMessagesTask{
			ThreadKey: k, Direction: 0, ReferenceTimestampMs: at, ReferenceMessageId: before,
			SyncGroup: syncGroup(t), Cursor: c.cli.GetCursor(syncGroup(t)),
		}
	}
	// The stretch comes on its own a moment after the task is taken, not in the task's answer.
	w := awaitStretch(k, at)
	defer dropWait(k, w)
	if _, err := tasks(ctx, c, task); err != nil {
		return nil, err
	}
	select {
	case up := <-w.ch:
		if up == nil {
			return map[string]any{"messages": []any{}, "more": false}, nil
		}
		list, more := b.stretch(up, before)
		return map[string]any{"messages": list, "more": more}, nil
	case <-time.After(25 * time.Second):
		return nil, errors.New("Messenger did not send this chat's history; try again")
	case <-ctx.Done():
		return nil, errors.New("Messenger did not send this chat's history in time")
	}
}

// --- sending --------------------------------------------------------------------------------------------------------

// send sends words (and, where [attachment] is not 0, a file already uploaded) to a chat.
func send(ctx context.Context, c *conn, b *book, to, text string, q *quote, attachment int64) (any, error) {
	k, err := chatKey(to)
	if err != nil {
		return nil, err
	}
	if strings.TrimSpace(text) == "" && attachment == 0 {
		return nil, errors.New("There is nothing to send")
	}
	t := b.threadCopy(k)
	if t.Type.IsWhatsApp() {
		return sendEncrypted(ctx, c, b, t, text, q)
	}
	otid := methods.GenerateEpochID()
	task := &socket.SendMessageTask{
		ThreadId:         k,
		Otid:             otid,
		Source:           table.MESSENGER_INBOX_IN_THREAD,
		InitiatingSource: table.FACEBOOK_INBOX,
		SendType:         table.TEXT,
		SyncGroup:        syncGroup(t),
		Text:             text,
	}
	if t.Folder == "pending" {
		// Answering a message request from the requests list is what accepts it.
		task.Source = table.MESSENGER_INBOX_PENDING_REQUESTS
	}
	if attachment != 0 {
		task.SendType = table.MEDIA
		task.AttachmentFBIds = []int64{attachment}
	}
	if q != nil && q.ID != "" {
		task.ReplyMetaData = &socket.ReplyMetaData{ReplyMessageId: q.ID, ReplySourceType: 1, ReplyType: 0}
	}
	// The website marks the chat read as it sends.
	seen := &socket.ThreadMarkReadTask{ThreadId: k, SyncGroup: 1, LastReadWatermarkTs: time.Now().UnixMilli()}
	tbl, err := tasks(ctx, c, task, seen)
	if err != nil {
		// Never sent twice: whether this one went is not known, and the app says so.
		return nil, fmt.Errorf("%w. The message may or may not have been sent", err)
	}
	id, err := sentID(tbl, otid)
	if err != nil {
		return nil, err
	}
	ts, perr := methods.ParseMessageID(id)
	if now := time.Now().UnixMilli(); perr != nil || ts < now-3600_000 || ts > now+3600_000 {
		ts = now
	}
	b.mu.Lock()
	b.remember(k, id, ts, b.me)
	b.mu.Unlock()
	return map[string]any{"id": id, "ts": ts}, nil
}

// sentID is the id Messenger gave the message sent as [otid], or why it was not sent.
func sentID(tbl *table.LSTable, otid int64) (string, error) {
	want := idString(otid)
	if tbl != nil {
		for _, row := range tbl.LSReplaceOptimsiticMessage {
			if row.OfflineThreadingId == want && row.MessageId != "" {
				return row.MessageId, nil
			}
		}
		for _, row := range tbl.LSMarkOptimisticMessageFailed {
			return "", fmt.Errorf("Messenger refused the message: %s", strings.TrimSpace(row.Message))
		}
		for _, row := range tbl.LSHandleFailedTask {
			return "", fmt.Errorf("Messenger did not send the message: %s", strings.TrimSpace(row.Message))
		}
	}
	return "", errors.New("Messenger did not confirm the message. It may or may not have been sent")
}

// sendMedia answers `send_media`: the file is read whole and uploaded as the website does, then sent as a message
// with the words beside it. Not in encrypted chats yet.
func sendMedia(ctx context.Context, c *conn, b *book, r request) (any, error) {
	k, err := chatKey(r.To)
	if err != nil {
		return nil, err
	}
	if b.threadCopy(k).Type.IsWhatsApp() {
		return nil, errors.New("Files can't be sent in end-to-end encrypted Messenger chats from here yet")
	}
	st, err := os.Stat(r.Path)
	if err != nil {
		return nil, fmt.Errorf("The file could not be read: %w", err)
	}
	if st.Size() > maxFile {
		return nil, errors.New("The file is too large for Messenger")
	}
	data, err := os.ReadFile(r.Path)
	if err != nil {
		return nil, fmt.Errorf("The file could not be read: %w", err)
	}
	mime := r.Mime
	if mime == "" {
		mime = http.DetectContentType(data)
	}
	name := r.Name
	if name == "" {
		name = filepath.Base(r.Path)
	}
	resp, err := c.cli.GetHTTP().SendMercuryUploadRequest(ctx, k, &httpclient.MercuryUploadMedia{Filename: name, MimeType: mime, MediaData: data})
	if err != nil {
		log.Err(err).Msg("upload")
		return nil, errors.New("Messenger did not take the file")
	}
	var fbid int64
	if resp != nil && resp.Payload.RealMetadata != nil {
		fbid = resp.Payload.RealMetadata.GetFbId()
	}
	if fbid == 0 {
		return nil, errors.New("Messenger took the file but gave no name for it, so it could not be sent")
	}
	return send(ctx, c, b, r.To, r.Text, nil, fbid)
}

// --- reading, reacting, unsending -----------------------------------------------------------------------------------

// read marks a chat read up to [upto], or up to now where none is named.
func read(ctx context.Context, c *conn, b *book, to, upto string) error {
	k, err := chatKey(to)
	if err != nil {
		return err
	}
	t := b.threadCopy(k)
	if t.Type.IsWhatsApp() {
		return readEncrypted(ctx, c, b, t, upto)
	}
	// Messenger marks reading by time: the time of the message read up to, or now.
	at := time.Now().UnixMilli()
	if upto != "" {
		if ts := b.when(upto); ts != 0 {
			at = ts
		}
	}
	// Never to before the chat's newest activity: something newer than the message named (a reaction, a message this
	// app does not show) left the chat unread on Messenger, to come back unread when the app next started.
	if t.Last > at {
		at = t.Last
	}
	_, err = tasks(ctx, c, &socket.ThreadMarkReadTask{ThreadId: k, LastReadWatermarkTs: at, SyncGroup: syncGroup(t)})
	if err == nil {
		b.mu.Lock()
		if live := b.threads[k]; live != nil && at >= live.Last {
			live.Unread, live.Read = 0, at
		}
		b.mu.Unlock()
	}
	return err
}

// react puts the person's reaction on a message, or takes it off: Messenger takes an empty reaction as none.
// Which side the message is on is told by its id.
func react(ctx context.Context, c *conn, b *book, to, target, emoji string, remove bool) error {
	k, err := chatKey(to)
	if err != nil {
		return err
	}
	if target == "" {
		return errors.New("No message was named to react to")
	}
	if remove {
		emoji = ""
	} else if emoji == "" {
		return errors.New("No emoji was given")
	}
	if isEncryptedID(target) {
		return reactEncrypted(ctx, c, b, b.threadCopy(k), target, emoji)
	}
	_, err = tasks(ctx, c, &socket.SendReactionTask{
		ThreadKey:       k,
		TimestampMs:     time.Now().UnixMilli(),
		MessageID:       target,
		ActorID:         b.me,
		Reaction:        variationselector.Remove(emoji),
		SyncGroup:       1,
		SendAttribution: table.MESSENGER_INBOX_IN_THREAD,
	})
	return err
}

// unsend takes back the person's own message for everyone. A message known to be someone else's is refused here;
// one this run has not met is left to Messenger to refuse.
func unsend(ctx context.Context, c *conn, b *book, to, target string) error {
	k, err := chatKey(to)
	if err != nil {
		return err
	}
	if target == "" {
		return errors.New("No message was named to unsend")
	}
	if isEncryptedID(target) {
		return unsendEncrypted(ctx, c, b, b.threadCopy(k), target)
	}
	if r, ok := b.ref(target); ok && r.From != b.me {
		return errors.New("Only your own messages can be unsent")
	}
	_, err = tasks(ctx, c, &socket.DeleteMessageTask{MessageId: target})
	return err
}

// --- files ----------------------------------------------------------------------------------------------------------

// pointer is what `download` is handed back for a message's file: an address on Meta's servers and the kind of
// file it is, or the keys of an encrypted one.
type pointer struct {
	URL  string `json:"url"`
	Mime string `json:"mime"`
	// Keys is set for a file of an end-to-end encrypted chat: where its sealed bytes are and what opens them.
	Keys *sealed `json:"e2ee"`
}

// metaHosts are the domains Meta serves files from; their subdomains count too.
var metaHosts = []string{"fbcdn.net", "fbsbx.com", "facebook.com", "messenger.com", "cdninstagram.com"}

// metaAddress is whether an address is one of Meta's own file servers: the helper fetches nothing else, whatever a
// pointer says.
func metaAddress(address string) bool {
	u, err := url.Parse(address)
	if err != nil || u.Scheme != "https" {
		return false
	}
	host := strings.ToLower(u.Hostname())
	for _, h := range metaHosts {
		if host == h || strings.HasSuffix(host, "."+h) {
			return true
		}
	}
	return false
}

// fileClient fetches files and pictures, five minutes at most for each. It holds no cookies.
var fileClient = &http.Client{Timeout: 5 * time.Minute}

// fetch asks one of Meta's file servers for a file, as the website's page would.
func fetch(ctx context.Context, address, mime string) (*http.Response, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, address, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Accept", "*/*")
	switch strings.Split(mime, "/")[0] {
	case "image":
		req.Header.Set("Accept", "image/avif,image/webp,*/*")
		req.Header.Set("Sec-Fetch-Dest", "image")
	case "video":
		req.Header.Set("Sec-Fetch-Dest", "video")
	case "audio":
		req.Header.Set("Sec-Fetch-Dest", "audio")
	default:
		req.Header.Set("Sec-Fetch-Dest", "empty")
	}
	req.Header.Set("Sec-Fetch-Mode", "no-cors")
	req.Header.Set("Sec-Fetch-Site", "cross-site")
	req.Header.Set("User-Agent", useragent.UserAgent)
	req.Header.Set("sec-ch-ua", useragent.SecCHUserAgent)
	req.Header.Set("sec-ch-ua-platform", useragent.SecCHPlatform)
	return fileClient.Do(req)
}

// writeWhole writes a file whole or not at all.
func writeWhole(dest string, from io.Reader) error {
	tmp := dest + ".part"
	f, err := os.OpenFile(tmp, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
	if err != nil {
		return err
	}
	n, err := io.Copy(f, io.LimitReader(from, maxFile+1))
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err == nil && n > maxFile {
		err = errors.New("the file is too large")
	}
	if err == nil && n == 0 {
		err = errors.New("the file came empty")
	}
	if err != nil {
		_ = os.Remove(tmp)
		return err
	}
	return os.Rename(tmp, dest)
}

// download answers `download`: the file a pointer names is written to [dest], whole or not at all.
func download(ctx context.Context, c *conn, raw json.RawMessage, dest string) error {
	var p pointer
	if len(raw) == 0 || json.Unmarshal(raw, &p) != nil || (p.URL == "" && p.Keys == nil) {
		return errors.New("This is not a file of a Messenger message")
	}
	if dest == "" {
		return errors.New("No place was given to put the file")
	}
	if p.Keys != nil {
		return downloadSealed(ctx, c, p.Keys, dest)
	}
	if !metaAddress(p.URL) {
		return errors.New("This file is not kept on Messenger's servers, so it is not fetched")
	}
	resp, err := fetch(ctx, p.URL, p.Mime)
	if err != nil {
		return fmt.Errorf("The file could not be fetched: %w", err)
	}
	defer resp.Body.Close()
	switch {
	case resp.StatusCode == http.StatusForbidden || resp.StatusCode == http.StatusGone || resp.StatusCode == http.StatusNotFound:
		// Messenger's file addresses stop working after some days; the chat's history gives new ones.
		return errors.New("This file's address has expired. Open the chat again to get a new one")
	case resp.StatusCode != http.StatusOK:
		return fmt.Errorf("Messenger's file server answered %d", resp.StatusCode)
	}
	if err := writeWhole(dest, resp.Body); err != nil {
		return fmt.Errorf("The file could not be written: %w", err)
	}
	return nil
}

// --- pictures of people and chats -----------------------------------------------------------------------------------

// avatarDir is where the pictures of people and chats are kept once fetched.
func avatarDir() string { return filepath.Join(dir, "avatars") }

// avatarBusy, under avatarLock, is the pictures being fetched or that could not be; avatarSlots lets four be
// fetched at a time.
var (
	avatarLock  sync.Mutex
	avatarBusy  = map[string]bool{}
	avatarSlots = make(chan struct{}, 4)
)

// avatarName names the file a picture is kept in: by whose it is and the picture's own name on Meta's servers (the
// last part of its address; the rest changes each time it is given).
func avatarName(owner, address string) string {
	base := address
	if u, err := url.Parse(address); err == nil && u.Path != "" {
		base = path.Base(u.Path)
	}
	sum := sha256.Sum256([]byte(owner + ":" + base))
	return hex.EncodeToString(sum[:12])
}

// avatarFile is the book's way to a picture: the file where it is kept already, else "" now, the picture fetched
// behind, and the person or chat said again once it is there. Called with the book's lock held.
func avatarFile(owner, address string) string {
	if address == "" || dir == "" {
		return ""
	}
	p := filepath.Join(avatarDir(), avatarName(owner, address))
	if _, err := os.Stat(p); err == nil {
		return p
	}
	avatarLock.Lock()
	busy := avatarBusy[p]
	avatarBusy[p] = true
	avatarLock.Unlock()
	if !busy {
		go func() {
			avatarSlots <- struct{}{}
			ok := fetchAvatar(bg(), address, p)
			<-avatarSlots
			if ok {
				// Left marked where it failed, so a picture that cannot be had is not asked for over and over.
				avatarLock.Lock()
				delete(avatarBusy, p)
				avatarLock.Unlock()
				sayAgain(owner)
			}
		}()
	}
	return ""
}

// fetchAvatar fetches a picture from one of Meta's servers into [dest]; false where it could not be had.
func fetchAvatar(ctx context.Context, address, dest string) bool {
	if !metaAddress(address) {
		return false
	}
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	resp, err := fetch(ctx, address, "image/*")
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return false
	}
	_ = os.MkdirAll(avatarDir(), 0o700)
	return writeWhole(dest, &atMost{r: resp.Body, left: maxAvatar}) == nil
}

// maxAvatar is the largest picture kept for a person or a chat.
const maxAvatar = 5 << 20

// atMost reads [r] and fails once more than [left] bytes have come, so a longer body is refused, not kept cut short.
type atMost struct {
	r    io.Reader
	left int64
}

func (a *atMost) Read(p []byte) (int, error) {
	n, err := a.r.Read(p)
	if a.left -= int64(n); a.left < 0 {
		return n, errors.New("the file is too large")
	}
	return n, err
}

// sayAgain says a person ("u…") or a chat ("t…") again, now that their picture is kept.
func sayAgain(owner string) {
	mu.Lock()
	b := bk
	mu.Unlock()
	id, ok := parseID(owner[1:])
	if b == nil || !ok {
		return
	}
	var out []ev
	b.mu.Lock()
	if owner[0] == 'u' {
		if c := b.contacts[id]; c != nil {
			out = append(out, ev{"name", b.personJSON(c)})
		}
	}
	if t := b.threads[id]; t != nil && listable(t) && (owner[0] == 't' || !isGroup(t.Type)) {
		out = append(out, ev{"chat", b.chatJSON(t)})
	}
	b.mu.Unlock()
	for _, e := range out {
		event(e.Name, e.Fields)
	}
}

// who answers `who`: a person by id, asked of Messenger where the book has not met them.
func who(ctx context.Context, c *conn, b *book, id string) (any, error) {
	n, ok := parseID(id)
	if !ok {
		return nil, fmt.Errorf("%q is not a person on Messenger", id)
	}
	b.mu.Lock()
	known := b.contacts[n]
	b.mu.Unlock()
	if known == nil || known.Name == "" {
		// Not someone met in a chat yet: Messenger is asked.
		tbl, err := tasks(ctx, c, &socket.GetContactsFullTask{ContactID: n})
		if err != nil {
			return nil, err
		}
		c.take(tbl, true)
	}
	b.mu.Lock()
	var person map[string]any
	var address string
	if known = b.contacts[n]; known != nil {
		person = b.personJSON(known)
		address = known.Picture
	}
	b.mu.Unlock()
	if person == nil {
		return nil, errors.New("Messenger does not say who that is")
	}
	// The answer waits a little for the picture (it is being fetched behind), as the app asks for one person at
	// a time.
	if person["avatar"] == nil && address != "" {
		p := filepath.Join(avatarDir(), avatarName("u"+idString(n), address))
		for end := time.Now().Add(8 * time.Second); time.Now().Before(end) && ctx.Err() == nil; time.Sleep(200 * time.Millisecond) {
			if _, err := os.Stat(p); err == nil {
				person["avatar"] = p
				break
			}
		}
	}
	return person, nil
}
