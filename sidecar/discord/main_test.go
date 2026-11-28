package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/bwmarrin/discordgo"
)

// Ids are made from times, as Discord's are, so their order and their times agree.
func idAt(ms int64) string { return fmt.Sprint((ms - 1420070400000) << 22) }

const (
	t0 = int64(1700000000000)
)

var (
	meID     = idAt(t0 - 9e9)
	annID    = idAt(t0 - 8e9)
	benID    = idAt(t0 - 7e9)
	dmID     = idAt(t0 - 6e9)
	groupID  = idAt(t0 - 5e9)
	serverID = idAt(t0 - 4e9)
	chanID   = idAt(t0 - 3e9)
	msg1     = idAt(t0 + 1000)
	msg2     = idAt(t0 + 2000)
	msg3     = idAt(t0 + 3000)

	me  = &discordgo.User{ID: meID, Username: "mo", GlobalName: "Mo Example", Discriminator: "0"}
	ann = &discordgo.User{ID: annID, Username: "ann", GlobalName: "Ann Lee", Discriminator: "0", Avatar: "a1b2"}
	ben = &discordgo.User{ID: benID, Username: "ben", Discriminator: "4321"}
)

// fake stands in for Discord: what the gateway described, and a note of every request.
type fake struct {
	mu       sync.Mutex
	token    string
	openErr  error
	handler  func(any)
	chans    []*discordgo.Channel
	guilds   map[string]*discordgo.Guild
	reads    *discordgo.ReadStateList
	messages map[string][]*discordgo.Message // by channel, newest first
	files    map[string]string               // by address
	held     chan struct{}                   // where set, each Get writes half its file and waits for it to close
	calls    []string
	sent     []*discordgo.MessageSend
	sendErr  error
	closed   bool
}

func (f *fake) note(format string, a ...any) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls = append(f.calls, fmt.Sprintf(format, a...))
}

func (f *fake) called(prefix string) bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	for _, c := range f.calls {
		if strings.HasPrefix(c, prefix) {
			return true
		}
	}
	return false
}

func (f *fake) Open() error {
	if f.openErr != nil {
		return f.openErr
	}
	f.handler(&discordgo.Ready{User: me, PrivateChannels: f.chans, ReadState: f.reads})
	f.handler(&discordgo.Connect{})
	return nil
}
func (f *fake) Close()                                { f.mu.Lock(); f.closed = true; f.mu.Unlock() }
func (f *fake) Me() *discordgo.User                   { return me }
func (f *fake) PrivateChannels() []*discordgo.Channel { return f.chans }
func (f *fake) ReadState() *discordgo.ReadStateList   { return f.reads }
func (f *fake) Heartbeat() *discordgo.HeartbeatSession {
	hb := discordgo.NewHeartbeatSession()
	return &hb
}
func (f *fake) Guild(id string) *discordgo.Guild { return f.guilds[id] }
func (f *fake) Channel(id string) *discordgo.Channel {
	for _, c := range f.chans {
		if c.ID == id {
			return c
		}
	}
	for _, g := range f.guilds {
		for _, c := range g.Channels {
			if c.ID == id {
				return c
			}
		}
	}
	return nil
}

func (f *fake) Messages(_ context.Context, c chatRef, limit int, before, around string) ([]*discordgo.Message, error) {
	f.note("messages %s %d %s %s", c.id(), limit, before, around)
	var out []*discordgo.Message
	for _, m := range f.messages[c.Channel] {
		if around != "" && m.ID != around || before != "" && !newer(before, m.ID) {
			continue
		}
		out = append(out, m)
		if len(out) == limit {
			break
		}
	}
	return out, nil
}

func (f *fake) Send(_ context.Context, c chatRef, m *discordgo.MessageSend) (*discordgo.Message, error) {
	f.note("send %s", c.id())
	if f.sendErr != nil {
		return nil, f.sendErr
	}
	f.mu.Lock()
	f.sent = append(f.sent, m)
	f.mu.Unlock()
	return &discordgo.Message{ID: msg3, ChannelID: c.Channel, Content: m.Content, Timestamp: time.UnixMilli(t0 + 3000), Author: me}, nil
}

func (f *fake) Upload(_ context.Context, c chatRef, name, mime string, size int64, r io.Reader) (string, error) {
	data, _ := io.ReadAll(r)
	f.note("upload %s %s %s %d %d", c.id(), name, mime, size, len(data))
	return "uploads/abc/" + name, nil
}

func (f *fake) React(_ context.Context, c chatRef, message, emoji string, remove bool) error {
	f.note("react %s %s %s %v", c.id(), message, emoji, remove)
	return nil
}

func (f *fake) Delete(_ context.Context, c chatRef, message string) error {
	f.note("delete %s %s", c.id(), message)
	return nil
}

func (f *fake) Ack(_ context.Context, c chatRef, message string) error {
	f.note("ack %s %s", c.id(), message)
	return nil
}

func (f *fake) User(_ context.Context, id string) (*discordgo.User, error) {
	f.note("user %s", id)
	if id == benID {
		return ben, nil
	}
	return nil, &discordgo.RESTError{Response: &http.Response{StatusCode: 404, Status: "404 Not Found"}, Message: &discordgo.APIErrorMessage{Code: 10013}}
}

func (f *fake) Get(_ context.Context, url string, w io.Writer, limit int64) error {
	f.note("get %s", url)
	data, ok := f.files[url]
	if !ok {
		return &statusError{Code: 404}
	}
	if f.held != nil {
		if _, err := io.WriteString(w, data[:len(data)/2]); err != nil {
			return err
		}
		<-f.held
		data = data[len(data)/2:]
	}
	_, err := io.WriteString(w, data)
	return err
}

func newFake() *fake {
	dm := &discordgo.Channel{ID: dmID, Type: discordgo.ChannelTypeDM, LastMessageID: msg2, Recipients: []*discordgo.User{ann}}
	group := &discordgo.Channel{ID: groupID, Type: discordgo.ChannelTypeGroupDM, LastMessageID: msg1, Recipients: []*discordgo.User{ann, ben}}
	text := &discordgo.Channel{ID: chanID, GuildID: serverID, Name: "general", Type: discordgo.ChannelTypeGuildText}
	return &fake{
		chans:  []*discordgo.Channel{group, dm},
		guilds: map[string]*discordgo.Guild{serverID: {ID: serverID, Name: "Book Club", Channels: []*discordgo.Channel{text}}},
		reads:  &discordgo.ReadStateList{Entries: []*discordgo.ReadState{{ID: dmID, LastMessageID: discordgo.StringOrInt(msg1), MentionCount: 1}, {ID: groupID, LastMessageID: discordgo.StringOrInt(msg1)}}},
		messages: map[string][]*discordgo.Message{
			dmID: {
				{ID: msg2, ChannelID: dmID, Author: me, Content: "see you then", Timestamp: time.UnixMilli(t0 + 2000), Type: discordgo.MessageTypeReply,
					MessageReference: &discordgo.MessageReference{MessageID: msg1}, ReferencedMessage: &discordgo.Message{ID: msg1, Content: "lunch?"},
					Reactions: []*discordgo.MessageReactions{{Count: 2, Me: true, Emoji: &discordgo.Emoji{Name: "👍"}}, {Count: 1, Emoji: &discordgo.Emoji{Name: "🎉"}}}},
				{ID: idAt(t0 + 1500), ChannelID: dmID, Author: ann, Type: discordgo.MessageTypeChannelPinnedMessage},
				{ID: msg1, ChannelID: dmID, Author: ann, Content: "lunch?", Timestamp: time.UnixMilli(t0 + 1000),
					Attachments: []*discordgo.MessageAttachment{{ID: "77", URL: "https://cdn.discordapp.com/attachments/1/77/menu.pdf?ex=1", Filename: "menu.pdf", ContentType: "application/pdf", Size: 4096}}},
			},
		},
		files: map[string]string{
			"https://cdn.discordapp.com/avatars/" + annID + "/a1b2.png?size=128": "PNG-ann",
			"https://cdn.discordapp.com/attachments/1/77/menu.pdf?ex=2":          "%PDF fresh",
		},
	}
}

// harness: a fresh folder, the stand-in in place of Discord, and every line the helper writes kept.
type harness struct {
	t   *testing.T
	f   *fake
	buf *safeBuffer
}

type safeBuffer struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (s *safeBuffer) Write(p []byte) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.b.Write(p)
}

func (s *safeBuffer) lines() []map[string]any {
	s.mu.Lock()
	defer s.mu.Unlock()
	var out []map[string]any
	for _, line := range strings.Split(strings.TrimSpace(s.b.String()), "\n") {
		if line == "" {
			continue
		}
		m := map[string]any{}
		_ = json.Unmarshal([]byte(line), &m)
		out = append(out, m)
	}
	return out
}

func setup(t *testing.T) *harness {
	t.Helper()
	h := &harness{t: t, f: newFake(), buf: &safeBuffer{}}
	dir = t.TempDir()
	out = json.NewEncoder(h.buf)
	out.SetEscapeHTML(false)
	seen.reset()
	mu.Lock()
	acct, connected = nil, false
	mu.Unlock()
	newClient = func(token string, _ *discordgo.HeartbeatSession, handler func(any)) (client, error) {
		h.f.token, h.f.handler = token, handler
		return h.f, nil
	}
	t.Cleanup(func() {
		if a := current(); a != nil {
			drop(a)
		}
		background.Wait()
		inflight.Wait()
		newClient = newDiscordClient
		outLock.Lock()
		out = json.NewEncoder(os.Stdout)
		outLock.Unlock()
	})
	return h
}

// events are the events said so far with this name.
func (h *harness) events(name string) []map[string]any {
	var out []map[string]any
	for _, m := range h.buf.lines() {
		if m["ev"] == name {
			out = append(out, m)
		}
	}
	return out
}

// waitFor waits for an event the helper says from a goroutine of its own.
func (h *harness) waitFor(name string, match func(map[string]any) bool) map[string]any {
	h.t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		for _, e := range h.events(name) {
			if match == nil || match(e) {
				return e
			}
		}
		time.Sleep(5 * time.Millisecond)
	}
	h.t.Fatalf("no %q event; said: %v", name, h.buf.lines())
	return nil
}

func (h *harness) signIn() {
	h.t.Helper()
	res, err := do(request{ID: 1, Op: "sign_in", Cookies: map[string]string{"Token": ` "mfa.abcdefghijklmnopqrstuvwxyz0123456789" `, "__dcfduid": "x"}})
	if err != nil {
		h.t.Fatal(err)
	}
	if got := encode(h.t, res); got != `{"handle":"mo","me":"`+meID+`","name":"Mo Example"}` {
		h.t.Fatalf("sign in: %s", got)
	}
	h.waitFor("chat", nil)
}

func encode(t *testing.T, v any) string {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func TestParseRequest(t *testing.T) {
	r, err := parseRequest([]byte(`{"id":2,"op":"sign_in","cookies":{"token":"abc","locale":"en"}}`))
	if err != nil || r.ID != 2 || r.Op != "sign_in" || r.Cookies["token"] != "abc" {
		t.Fatalf("sign_in: %+v %v", r, err)
	}
	r, err = parseRequest([]byte(`{"id":8,"op":"read","to":"` + dmID + `","upto":"` + msg1 + `"}`))
	if err != nil || r.ID != 8 || r.To != dmID || r.Upto != msg1 {
		t.Fatalf("read: %+v %v", r, err)
	}
	if _, err := parseRequest([]byte(`{"id":1}`)); err == nil {
		t.Fatal("a request without op was taken")
	}
	if _, err := parseRequest([]byte(`not json`)); err == nil {
		t.Fatal("a broken line was taken")
	}
	if got := encode(t, answer(3, nil, errors.New("no"))); got != `{"error":"no","id":3,"ok":false}` {
		t.Fatalf("error: %s", got)
	}
	if got := encode(t, answer(1, nil, nil)); got != `{"id":1,"ok":true,"result":null}` {
		t.Fatalf("null: %s", got)
	}
}

func TestToken(t *testing.T) {
	if tok, err := tokenOf(map[string]string{"TOKEN": `"abcdefghijklmnopqrstuvwxyz.123"`}); err != nil || tok != "abcdefghijklmnopqrstuvwxyz.123" {
		t.Fatalf("quoted token: %q %v", tok, err)
	}
	for _, c := range []struct {
		cookies map[string]string
		want    string
	}{
		{nil, "the Discord token is missing"},
		{map[string]string{"__dcfduid": "x"}, "the Discord token is missing"},
		{map[string]string{"token": "Bot abcdefghijklmnopqrstuvwxyz"}, "that is a bot's or an app's token"},
		{map[string]string{"token": "short"}, "that does not look like a Discord token"},
		{map[string]string{"token": "abcdefghij klmnopqrstuvwxyz"}, "that does not look like a Discord token"},
	} {
		if _, err := tokenOf(c.cookies); err == nil || !strings.HasPrefix(err.Error(), c.want) {
			t.Fatalf("%v: %v", c.cookies, err)
		}
	}
}

func TestSessionRoundTrip(t *testing.T) {
	path := filepath.Join(t.TempDir(), "session.json")
	if loadSession(path) != nil {
		t.Fatal("a session where there is no file")
	}
	if err := os.WriteFile(path, []byte(`{"me":"1"}`), 0o644); err != nil {
		t.Fatal(err)
	}
	if loadSession(path) != nil {
		t.Fatal("a session without a token was taken")
	}
	hb := discordgo.NewHeartbeatSession()
	if err := saveSession(path, session{Me: meID, Name: "Mo", Handle: "mo", Token: "tok", Heartbeat: &hb}); err != nil {
		t.Fatal(err)
	}
	if runtime.GOOS != "windows" {
		if st, err := os.Stat(path); err != nil || st.Mode().Perm() != 0o600 {
			t.Fatalf("mode: %v %v", st.Mode().Perm(), err)
		}
	}
	s := loadSession(path)
	if s == nil || s.Me != meID || s.Token != "tok" || s.Heartbeat == nil || s.Heartbeat.ID != hb.ID {
		t.Fatalf("loaded: %+v", s)
	}
}

func TestWords(t *testing.T) {
	rest := func(status, code int, body string) error {
		return &discordgo.RESTError{Response: &http.Response{StatusCode: status, Status: fmt.Sprint(status)}, ResponseBody: []byte(body), Message: &discordgo.APIErrorMessage{Code: code}}
	}
	if !rejected(rest(401, 0, "")) || !rejected(errBadToken) || !rejected(fmt.Errorf("x: %w", discordgo.ErrUnauthorized)) {
		t.Fatal("a rejected session was not seen as one")
	}
	if rejected(rest(403, 50013, "")) || rejected(rest(429, 0, "")) || rejected(errors.New("dial tcp")) {
		t.Fatal("a passing trouble was taken for the session ending")
	}
	cases := map[error]string{
		rest(401, 0, ""):                      "signed this session out",
		rest(400, 0, `{"captcha_key":["x"]}`): "captcha",
		rest(403, 40002, ""):                  "verified",
		rest(403, 50007, ""):                  "only from friends",
		rest(403, 50013, ""):                  "does not let this account",
		rest(404, 10008, ""):                  "no longer has that message",
		&discordgo.RateLimitError{RateLimit: &discordgo.RateLimit{TooManyRequests: &discordgo.TooManyRequests{}}}: "too many requests",
		rest(502, 0, ""): "problem of its own",
		rest(418, 0, ""): "418",
		errors.New("dial tcp: lookup discord.com: no such host"): "could not be reached",
	}
	for err, want := range cases {
		if got := plain(err).Error(); !strings.Contains(got, want) {
			t.Fatalf("%v: %q, want %q", err, got, want)
		}
	}
	if got := signInWords(errBadToken).Error(); !strings.Contains(got, "did not take that token") {
		t.Fatalf("sign in: %s", got)
	}
	if err := errors.New("nothing to send"); plain(err) != err {
		t.Fatal("words already plain were changed")
	}
}

func TestChatIDs(t *testing.T) {
	if c, err := parseChat(dmID); err != nil || c.Guild != "" || c.Channel != dmID || c.id() != dmID {
		t.Fatalf("dm: %+v %v", c, err)
	}
	id := chatID(serverID, chanID)
	if id != "guild:"+serverID+":"+chanID {
		t.Fatalf("guild id: %s", id)
	}
	if c, err := parseChat(id); err != nil || c.Guild != serverID || c.Channel != chanID {
		t.Fatalf("guild: %+v %v", c, err)
	}
	for _, bad := range []string{"", "abc", "guild:1", "guild:x:2", "urn:li:x", "123456789012345678901"} {
		if _, err := parseChat(bad); err == nil {
			t.Fatalf("%q was taken for a chat", bad)
		}
	}
	if snowflakeMS(msg1) != t0+1000 || !newer(msg2, msg1) || newer(msg1, msg2) || !newer(msg1, "") {
		t.Fatal("ids and times")
	}
}

func TestChatOf(t *testing.T) {
	f := newFake()
	dm := f.chans[1]
	var asked []string
	got := encode(t, chatOf(meID, dm, nil, &readMark{Last: msg1, Mentions: 1}, func(p icon) string { asked = append(asked, p.URL); return "/d/avatars/x.png" }))
	want := `{"id":"` + dmID + `","title":"Ann Lee","group":false,"members":[{"id":"` + annID + `","name":"Ann Lee"}],"avatar":"/d/avatars/x.png","unread":1,"last":` + fmt.Sprint(t0+2000) + `}`
	if got != want {
		t.Fatalf("dm:\n got %s\nwant %s", got, want)
	}
	if len(asked) != 1 || asked[0] != "https://cdn.discordapp.com/avatars/"+annID+"/a1b2.png?size=128" {
		t.Fatalf("avatar asked of %v", asked)
	}
	group := f.chans[0]
	got = encode(t, chatOf(meID, group, nil, &readMark{Last: msg1}, func(icon) string { t.Fatal("a group without an icon has no picture"); return "" }))
	want = `{"id":"` + groupID + `","title":"Ann Lee, ben","group":true,"members":[{"id":"` + annID + `","name":"Ann Lee"},{"id":"` + benID + `","name":"ben"}],"avatar":null,"unread":0,"last":` + fmt.Sprint(t0+1000) + `}`
	if got != want {
		t.Fatalf("group:\n got %s\nwant %s", got, want)
	}
	text := f.guilds[serverID].Channels[0]
	text.LastMessageID = msg2
	c := chatOf(meID, text, f.guilds[serverID], &readMark{Last: msg1, Mentions: 5}, nil)
	if c.ID != "guild:"+serverID+":"+chanID || c.Title != "Book Club › #general" || !c.Group || c.Unread != 1 || len(c.Members) != 0 {
		t.Fatalf("server channel: %+v", c)
	}
	// Discord said nothing of how far it was read: nothing is guessed.
	if c := chatOf(meID, dm, nil, nil, nil); c.Unread != 0 {
		t.Fatalf("unknown read mark: %+v", c)
	}
}

func TestMessageOf(t *testing.T) {
	f := newFake()
	reply := f.messages[dmID][0]
	got := encode(t, messageOf(meID, dmID, false, reply))
	want := `{"chat":"` + dmID + `","group":false,"id":"` + msg2 + `","from":"` + meID + `","name":"Mo Example","mine":true,"ts":` + fmt.Sprint(t0+2000) +
		`,"text":"see you then","media":[],"quote":{"id":"` + msg1 + `","text":"lunch?"},"reactions":[{"from":"` + meID + `","emoji":"👍"}]}`
	if got != want {
		t.Fatalf("reply:\n got %s\nwant %s", got, want)
	}
	// A reply says whom it answers, and for a picture with no words what kind of thing it was (GMFB-44).
	pic := &discordgo.Message{ID: msg1, Author: ann, Attachments: []*discordgo.MessageAttachment{{ID: "9", URL: "https://cdn.discordapp.com/attachments/1/9/cat.png", ContentType: "image/png"}}}
	answer := &discordgo.Message{ID: msg3, Author: me, Content: "ha", MessageReference: &discordgo.MessageReference{MessageID: msg1}, ReferencedMessage: pic}
	if got := encode(t, messageOf(meID, dmID, false, answer).Quote); got != `{"id":"`+msg1+`","from":"`+annID+`","name":"`+ann.DisplayName()+`","mime":"image/png"}` {
		t.Fatalf("reply to a picture: %s", got)
	}
	pic.Content, pic.Member = "look", &discordgo.Member{Nick: "Annie"}
	if got := encode(t, messageOf(meID, dmID, false, answer).Quote); got != `{"id":"`+msg1+`","text":"look","from":"`+annID+`","name":"Annie"}` {
		t.Fatalf("reply to words: %s", got)
	}
	card := &discordgo.Message{ID: msg1, Embeds: []*discordgo.MessageEmbed{{Title: "Build passed"}}}
	answer.ReferencedMessage = card
	if got := encode(t, messageOf(meID, dmID, false, answer).Quote); got != `{"id":"`+msg1+`","text":"Build passed"}` {
		t.Fatalf("reply to a card: %s", got)
	}
	// The one answered is gone, or Discord sent nothing of it: its id alone.
	answer.ReferencedMessage = nil
	if got := encode(t, messageOf(meID, dmID, false, answer).Quote); got != `{"id":"`+msg1+`"}` {
		t.Fatalf("reply to one not sent along: %s", got)
	}
	file := f.messages[dmID][2]
	got = encode(t, messageOf(meID, dmID, false, file).Media)
	want = `[{"pointer":{"url":"https://cdn.discordapp.com/attachments/1/77/menu.pdf?ex=1","chat":"` + dmID + `","message":"` + msg1 + `","attachment":"77"},"mime":"application/pdf","name":"menu.pdf","size":4096,"width":0,"height":0}]`
	if got != want {
		t.Fatalf("file:\n got %s\nwant %s", got, want)
	}
	m := &discordgo.Message{ID: msg3, Author: ann, Member: &discordgo.Member{Nick: "Annie"}, Content: "hi <@" + meID + "> <:blob:123456789012345678> <@!999>",
		Mentions:         []*discordgo.User{me},
		MessageSnapshots: []discordgo.MessageSnapshot{{Message: &discordgo.Message{Content: "one\ntwo"}}},
		StickerItems:     []*discordgo.StickerItem{{ID: "5", Name: "wave", FormatType: discordgo.StickerFormatTypeGIF}, {ID: "6", FormatType: discordgo.StickerFormatTypeLottie}},
	}
	o := messageOf(meID, "guild:1:2", true, m)
	if o.Text != "hi @Mo Example :blob: <@!999>\n> one\n> two" || o.Name != "Annie" || o.Mine || o.TS != t0+3000 {
		t.Fatalf("words: %+v", o)
	}
	if len(o.Media) != 1 || o.Media[0].Mime != "image/gif" || o.Media[0].Name != "wave" {
		t.Fatalf("stickers: %+v", o.Media)
	}
	if !mentionsMe(meID, m) || mentionsMe(meID, &discordgo.Message{Content: "@everyone"}) {
		t.Fatal("mentions")
	}
	if shown(f.messages[dmID][1]) {
		t.Fatal("a pin notice was shown")
	}
}

func TestReactionEmoji(t *testing.T) {
	for in, want := range map[string]string{
		"❤":                            "❤️",
		"👍":                            "👍",
		"<:blob:123456789012345678>":   "blob:123456789012345678",
		"<a:dance:123456789012345678>": "dance:123456789012345678",
		"blob:123456789012345678":      "blob:123456789012345678",
	} {
		if got := reactionEmoji(in); got != want {
			t.Fatalf("%q: %q, want %q", in, got, want)
		}
	}
	if emojiText(discordgo.Emoji{ID: "1", Name: "blob"}) != ":blob:" || emojiText(discordgo.Emoji{Name: "🎉"}) != "🎉" {
		t.Fatal("emoji text")
	}
}

func TestPointer(t *testing.T) {
	p, err := parsePointer(json.RawMessage(`"{\"url\":\"https://media.discordapp.net/x\",\"chat\":\"1\"}"`))
	if err != nil || p.URL != "https://media.discordapp.net/x" || p.Chat != "1" {
		t.Fatalf("string: %+v %v", p, err)
	}
	for _, bad := range []string{`{}`, `null`, `{"url":"http://cdn.discordapp.com/x"}`, `{"url":"https://evil.example/x"}`, `{"url":"https://discordapp.com.evil.example/x"}`, `{"url":"file:///etc/passwd"}`, ``} {
		if _, err := parsePointer(json.RawMessage(bad)); err == nil {
			t.Fatalf("%q was taken for a file", bad)
		}
	}
}

// --- the protocol, end to end against the stand-in ------------------------------------------------------------------

func TestSignInAndChats(t *testing.T) {
	h := setup(t)
	if _, err := do(request{ID: 1, Op: "chats"}); err == nil || err != errNotLinked {
		t.Fatalf("chats before signing in: %v", err)
	}
	h.signIn()
	if h.f.token != "mfa.abcdefghijklmnopqrstuvwxyz0123456789" {
		t.Fatalf("token: %q", h.f.token)
	}
	if e := h.events("linked"); len(e) != 1 || e[0]["me"] != meID || e[0]["name"] != "Mo Example" || e[0]["handle"] != "mo" {
		t.Fatalf("linked: %v", e)
	}
	if len(h.events("connected")) != 1 {
		t.Fatalf("connected: %v", h.events("connected"))
	}
	// The session is kept for the person alone.
	s := loadSession(sessionPath())
	if s == nil || s.Token != h.f.token || s.Me != meID || s.Heartbeat == nil {
		t.Fatalf("session: %+v", s)
	}
	if runtime.GOOS != "windows" {
		if st, _ := os.Stat(sessionPath()); st.Mode().Perm() != 0o600 {
			t.Fatalf("mode %v", st.Mode().Perm())
		}
	}
	st, _ := do(request{ID: 2, Op: "status"})
	if got := encode(t, st); got != `{"connected":true,"handle":"mo","linked":true,"me":"`+meID+`","name":"Mo Example"}` {
		t.Fatalf("status: %s", got)
	}

	res, err := do(request{ID: 3, Op: "chats"})
	if err != nil {
		t.Fatal(err)
	}
	list := res.([]chatOut)
	// The newest first: the direct message (its last message is later), then the group.
	if len(list) != 2 || list[0].ID != dmID || list[1].ID != groupID {
		t.Fatalf("chats: %s", encode(t, list))
	}
	if list[0].Unread != 1 || list[0].Avatar == nil || list[1].Unread != 0 {
		t.Fatalf("chats: %s", encode(t, list))
	}
	if data, err := os.ReadFile(*list[0].Avatar); err != nil || string(data) != "PNG-ann" {
		t.Fatalf("avatar file: %q %v", data, err)
	}
	// Server channels are not listed.
	for _, c := range list {
		if strings.HasPrefix(c.ID, guildPrefix) {
			t.Fatalf("a server channel was listed: %s", c.ID)
		}
	}
}

func TestSignInRefused(t *testing.T) {
	h := setup(t)
	h.f.openErr = errBadToken
	_, err := do(request{ID: 1, Op: "sign_in", Cookies: map[string]string{"token": "abcdefghijklmnopqrstuvwxyz.123"}})
	if err == nil || !strings.Contains(err.Error(), "did not take that token") {
		t.Fatalf("refused: %v", err)
	}
	if loadSession(sessionPath()) != nil || len(h.events("linked")) != 0 {
		t.Fatal("a refused token was kept")
	}
	if _, err := do(request{ID: 2, Op: "sign_in", Cookies: map[string]string{"li_at": "x"}}); err == nil || !strings.Contains(err.Error(), "token is missing") {
		t.Fatalf("no token: %v", err)
	}
}

func TestHistory(t *testing.T) {
	h := setup(t)
	h.signIn()
	res, err := do(request{ID: 1, Op: "history", Chat: dmID})
	if err != nil {
		t.Fatal(err)
	}
	page := res.(map[string]any)
	msgs := page["messages"].([]messageOut)
	// Oldest first; Discord's pin notice left out; fewer than a page, so no more.
	if len(msgs) != 2 || msgs[0].ID != msg1 || msgs[1].ID != msg2 || page["more"] != false {
		t.Fatalf("history: %s", encode(t, page))
	}
	if !h.f.called("messages " + dmID + " 50  ") {
		t.Fatalf("calls: %v", h.f.calls)
	}
	res, _ = do(request{ID: 2, Op: "history", Chat: dmID, Before: msg2})
	if msgs := res.(map[string]any)["messages"].([]messageOut); len(msgs) != 1 || msgs[0].ID != msg1 {
		t.Fatalf("before: %s", encode(t, res))
	}
	if _, err := do(request{ID: 3, Op: "history", Chat: "nonsense"}); err == nil {
		t.Fatal("history of no chat")
	}
	// Asking for a server channel's history tells the app of it, as "Server › #channel".
	if _, err := do(request{ID: 4, Op: "history", Chat: chatID(serverID, chanID)}); err != nil {
		t.Fatal(err)
	}
	h.waitFor("chat", func(e map[string]any) bool { return e["title"] == "Book Club › #general" && e["group"] == true })
	h.waitFor("name", func(e map[string]any) bool { return e["id"] == annID && e["name"] == "Ann Lee" && e["handle"] == "ann" })
}

func TestSendAndOthers(t *testing.T) {
	h := setup(t)
	h.signIn()
	res, err := do(request{ID: 1, Op: "send", To: dmID, Text: "on my way", Quote: &quote{ID: msg1}})
	if err != nil {
		t.Fatal(err)
	}
	if got := encode(t, res); got != `{"id":"`+msg3+`","ts":`+fmt.Sprint(t0+3000)+`}` {
		t.Fatalf("send: %s", got)
	}
	sent := h.f.sent[0]
	if sent.Content != "on my way" || sent.Nonce == "" || sent.Reference == nil || sent.Reference.MessageID != msg1 || sent.Reference.ChannelID != dmID {
		t.Fatalf("sent: %+v", sent)
	}
	if _, err := do(request{ID: 2, Op: "send", To: dmID, Text: "  "}); err == nil {
		t.Fatal("nothing was sent")
	}
	if _, err := do(request{ID: 3, Op: "send", To: dmID, Text: strings.Repeat("x", 2001)}); err == nil {
		t.Fatal("too long a message was sent")
	}

	path := filepath.Join(t.TempDir(), "photo.jpg")
	_ = os.WriteFile(path, []byte("JPEGDATA"), 0o600)
	if _, err := do(request{ID: 4, Op: "send_media", To: chatID(serverID, chanID), Path: path, Mime: "image/jpeg", Text: "look"}); err != nil {
		t.Fatal(err)
	}
	if !h.f.called("upload guild:" + serverID + ":" + chanID + " photo.jpg image/jpeg 8 8") {
		t.Fatalf("calls: %v", h.f.calls)
	}
	att := h.f.sent[1].Attachments
	if len(att) != 1 || att[0].UploadedFilename != "uploads/abc/photo.jpg" || att[0].Filename != "photo.jpg" || h.f.sent[1].Content != "look" {
		t.Fatalf("attachment: %+v", att)
	}

	if _, err := do(request{ID: 5, Op: "react", To: dmID, Target: msg1, Emoji: "❤"}); err != nil {
		t.Fatal(err)
	}
	if !h.f.called("react " + dmID + " " + msg1 + " ❤️ false") {
		t.Fatalf("calls: %v", h.f.calls)
	}
	if _, err := do(request{ID: 6, Op: "react", To: dmID, Target: msg1, Emoji: "❤", Remove: true}); err != nil || !h.f.called("react "+dmID+" "+msg1+" ❤️ true") {
		t.Fatalf("unreact: %v %v", err, h.f.calls)
	}
	if _, err := do(request{ID: 7, Op: "delete", To: dmID, Target: msg3}); err != nil || !h.f.called("delete "+dmID+" "+msg3) {
		t.Fatalf("delete: %v %v", err, h.f.calls)
	}
	// Read up to a message; then without one, up to the newest the gateway knows.
	if _, err := do(request{ID: 8, Op: "read", To: dmID, Upto: msg1}); err != nil || !h.f.called("ack "+dmID+" "+msg1) {
		t.Fatalf("read: %v %v", err, h.f.calls)
	}
	if _, err := do(request{ID: 9, Op: "read", To: groupID}); err != nil || !h.f.called("ack "+groupID+" "+msg1) {
		t.Fatalf("read the newest: %v %v", err, h.f.calls)
	}
	if _, err := do(request{ID: 10, Op: "edit", To: dmID}); err == nil || !strings.Contains(err.Error(), "does not know") {
		t.Fatalf("an unknown op: %v", err)
	}

	// Someone met already, then someone asked of Discord, then no one.
	res, err = do(request{ID: 11, Op: "who", Who: annID})
	if err != nil || res.(map[string]any)["name"] != "Ann Lee" || res.(map[string]any)["avatar"] == nil {
		t.Fatalf("who ann: %v %v", res, err)
	}
	seen.reset()
	res, err = do(request{ID: 12, Op: "who", Who: benID})
	if err != nil || res.(map[string]any)["handle"] != "ben#4321" || res.(map[string]any)["avatar"] != nil {
		t.Fatalf("who ben: %v %v", res, err)
	}
	if _, err := do(request{ID: 13, Op: "who", Who: "123"}); err == nil || !strings.Contains(err.Error(), "Discord") {
		t.Fatalf("who no one: %v", err)
	}
}

func TestSendRejectedEndsSession(t *testing.T) {
	h := setup(t)
	h.signIn()
	h.f.sendErr = &discordgo.RESTError{Response: &http.Response{StatusCode: 401, Status: "401"}}
	if _, err := do(request{ID: 1, Op: "send", To: dmID, Text: "hi"}); err == nil || !strings.Contains(err.Error(), "signed this session out") {
		t.Fatalf("send: %v", err)
	}
	if e := h.events("unlinked"); len(e) != 1 || !strings.Contains(e[0]["error"].(string), "token no longer works") {
		t.Fatalf("unlinked: %v", e)
	}
	if current() != nil || loadSession(sessionPath()) != nil {
		t.Fatal("the session was kept")
	}
}

func TestDownload(t *testing.T) {
	h := setup(t)
	h.signIn()
	// The address in the pointer has run out (404 here): the message is asked for again for a fresh one.
	h.f.messages[dmID][2].Attachments[0].URL = "https://cdn.discordapp.com/attachments/1/77/menu.pdf?ex=2"
	ptr := `{"url":"https://cdn.discordapp.com/attachments/1/77/menu.pdf?ex=1","chat":"` + dmID + `","message":"` + msg1 + `","attachment":"77"}`
	path := filepath.Join(t.TempDir(), "menu.pdf")
	if _, err := do(request{ID: 1, Op: "download", Pointer: json.RawMessage(ptr), Path: path}); err != nil {
		t.Fatal(err)
	}
	if data, _ := os.ReadFile(path); string(data) != "%PDF fresh" {
		t.Fatalf("file: %q", data)
	}
	if !h.f.called("messages " + dmID + " 1  " + msg1) {
		t.Fatalf("calls: %v", h.f.calls)
	}
	if left, _ := filepath.Glob(path + "*.part"); len(left) > 0 {
		t.Fatalf("part files were left: %v", left)
	}
	bad := `{"url":"https://cdn.discordapp.com/gone"}`
	if _, err := do(request{ID: 2, Op: "download", Pointer: json.RawMessage(bad), Path: path + "2"}); err == nil || !strings.Contains(err.Error(), "run out") {
		t.Fatalf("gone: %v", err)
	}
}

// One file asked for twice at once (the app asked each time the picture was drawn): both are answered, the file is
// whole, and nothing is left beside it. The two shared one ".part" file, and the second's rename found it gone:
// "rename …/discord/files/330240540.png.part …/330240540.png: no such file or directory".
func TestDownloadTwiceAtOnce(t *testing.T) {
	h := setup(t)
	h.signIn()
	url := "https://cdn.discordapp.com/attachments/1/77/menu.pdf?ex=1"
	h.f.files[url] = "%PDF the whole of it"
	h.f.held = make(chan struct{})
	ptr := `{"url":"` + url + `","chat":"` + dmID + `","message":"` + msg1 + `","attachment":"77"}`
	path := filepath.Join(t.TempDir(), "330240540.pdf")
	errs := make(chan error, 2)
	for id := range int64(2) {
		go func() {
			_, err := do(request{ID: id + 1, Op: "download", Pointer: json.RawMessage(ptr), Path: path})
			errs <- err
		}()
	}
	// Both under way, each with half its file written, before either goes on.
	deadline := time.Now().Add(5 * time.Second)
	for {
		h.f.mu.Lock()
		n := 0
		for _, c := range h.f.calls {
			if c == "get "+url {
				n++
			}
		}
		h.f.mu.Unlock()
		if n == 2 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("both fetches never began: %v", h.f.calls)
		}
		time.Sleep(5 * time.Millisecond)
	}
	close(h.f.held)
	for range 2 {
		if err := <-errs; err != nil {
			t.Fatal(err)
		}
	}
	if data, _ := os.ReadFile(path); string(data) != "%PDF the whole of it" {
		t.Fatalf("file: %q", data)
	}
	if left, _ := filepath.Glob(path + "*.part"); len(left) > 0 {
		t.Fatalf("part files were left: %v", left)
	}
}

func TestLiveEvents(t *testing.T) {
	h := setup(t)
	h.signIn()
	a := current()
	ts := time.UnixMilli(t0 + 4000)
	newMsg := idAt(t0 + 4000)

	a.onEvent(&discordgo.MessageCreate{Message: &discordgo.Message{ID: newMsg, ChannelID: dmID, Author: ann, Content: "here", Timestamp: ts}})
	e := h.waitFor("message", nil)
	if e["chat"] != dmID || e["id"] != newMsg || e["from"] != annID || e["mine"] != false || e["text"] != "here" || e["group"] != false {
		t.Fatalf("message: %v", e)
	}
	// A preview arriving is no edit; new words are.
	edited := ts.Add(time.Second)
	a.onEvent(&discordgo.MessageUpdate{Message: &discordgo.Message{ID: newMsg, ChannelID: dmID, Content: "here"}})
	a.onEvent(&discordgo.MessageUpdate{Message: &discordgo.Message{ID: newMsg, ChannelID: dmID, Content: "here", EditedTimestamp: &edited}})
	a.onEvent(&discordgo.MessageUpdate{Message: &discordgo.Message{ID: newMsg, ChannelID: dmID, Content: "here now", EditedTimestamp: &edited}})
	if e := h.events("edited"); len(e) != 1 || e[0]["text"] != "here now" || e[0]["target"] != newMsg {
		t.Fatalf("edited: %v", e)
	}
	a.onEvent(&discordgo.MessageReactionAdd{MessageReaction: &discordgo.MessageReaction{UserID: annID, MessageID: msg2, ChannelID: dmID, Emoji: discordgo.Emoji{Name: "🎉"}}})
	a.onEvent(&discordgo.MessageReactionRemove{MessageReaction: &discordgo.MessageReaction{UserID: annID, MessageID: msg2, ChannelID: dmID, Emoji: discordgo.Emoji{ID: "9", Name: "blob"}}})
	if e := h.events("reaction"); len(e) != 2 || e[0]["emoji"] != "🎉" || e[0]["remove"] != false || e[1]["emoji"] != ":blob:" || e[1]["remove"] != true {
		t.Fatalf("reactions: %v", e)
	}
	a.onEvent(&discordgo.MessageDelete{Message: &discordgo.Message{ID: newMsg, ChannelID: dmID}})
	if e := h.events("deleted"); len(e) != 1 || e[0]["chat"] != dmID || e[0]["target"] != newMsg {
		t.Fatalf("deleted: %v", e)
	}
	a.onEvent(&discordgo.MessageAck{ChannelID: dmID, MessageID: newMsg})
	if e := h.events("receipt"); len(e) != 1 || e[0]["from"] != meID || e[0]["id"] != newMsg || e[0]["kind"] != "read" {
		t.Fatalf("receipt: %v", e)
	}

	// A server message not for the person is passed over; one that mentions them brings its chat first.
	chat := chatID(serverID, chanID)
	a.onEvent(&discordgo.MessageCreate{Message: &discordgo.Message{ID: idAt(t0 + 5000), ChannelID: chanID, GuildID: serverID, Author: ben, Content: "anyone?"}})
	a.onEvent(&discordgo.MessageCreate{Message: &discordgo.Message{ID: idAt(t0 + 6000), ChannelID: chanID, GuildID: serverID, Author: ben, Member: &discordgo.Member{Nick: "Benny"},
		Content: "<@" + meID + "> you in?", Mentions: []*discordgo.User{me}}})
	msgs := h.events("message")
	last := msgs[len(msgs)-1]
	if len(msgs) != 2 || last["chat"] != chat || last["group"] != true || last["name"] != "Benny" || last["text"] != "@Mo Example you in?" {
		t.Fatalf("server messages: %v", msgs)
	}
	lines := h.buf.lines()
	chatAt, msgAt := -1, -1
	for i, l := range lines {
		if l["ev"] == "chat" && l["id"] == chat && chatAt < 0 {
			chatAt = i
		}
		if l["ev"] == "message" && l["chat"] == chat {
			msgAt = i
		}
	}
	if chatAt < 0 || chatAt > msgAt {
		t.Fatalf("the chat was not said before its first message: %v", lines)
	}
	// From then on that channel is followed.
	a.onEvent(&discordgo.MessageCreate{Message: &discordgo.Message{ID: idAt(t0 + 7000), ChannelID: chanID, GuildID: serverID, Author: ben, Content: "ok"}})
	if len(h.events("message")) != 3 {
		t.Fatalf("a followed channel's message was passed over: %v", h.events("message"))
	}

	// A new direct message is said as a chat.
	newDM := &discordgo.Channel{ID: idAt(t0 + 8000), Type: discordgo.ChannelTypeDM, Recipients: []*discordgo.User{ben}}
	a.onEvent(&discordgo.ChannelCreate{Channel: newDM})
	h.waitFor("chat", func(e map[string]any) bool { return e["id"] == newDM.ID && e["title"] == "ben" })

	a.onEvent(&discordgo.Disconnect{})
	a.onEvent(&discordgo.Connect{})
	if len(h.events("disconnected")) != 1 || len(h.events("connected")) != 2 {
		t.Fatalf("connection: %v / %v", h.events("disconnected"), h.events("connected"))
	}

	// Discord ending the session: the app is told and nothing is kept.
	a.onEvent(&discordgo.InvalidAuth{})
	h.waitFor("unlinked", nil)
	if loadSession(sessionPath()) != nil || current() != nil {
		t.Fatal("the session outlived Discord ending it")
	}
}

func TestUnlink(t *testing.T) {
	h := setup(t)
	h.signIn()
	if _, err := do(request{ID: 1, Op: "unlink"}); err != nil {
		t.Fatal(err)
	}
	if loadSession(sessionPath()) != nil || current() != nil {
		t.Fatal("unlink kept the session")
	}
	st, _ := do(request{ID: 2, Op: "status"})
	if st.(map[string]any)["linked"] != false {
		t.Fatalf("status: %v", st)
	}
}

// serve reads lines and answers each; a saved session is connected at once.
func TestServeWithSavedSession(t *testing.T) {
	h := setup(t)
	if err := saveSession(sessionPath(), session{Me: meID, Name: "Mo Example", Handle: "mo", Token: "saved-token-abcdefghijklmnop"}); err != nil {
		t.Fatal(err)
	}
	in := strings.NewReader(`{"id":1,"op":"status"}` + "\n" + `garbage` + "\n" + `{"id":2,"op":"history","chat":"` + dmID + `"}` + "\n")
	serve(in)
	lines := h.buf.lines()
	if len(lines) == 0 || lines[0]["ev"] != "ready" || lines[0]["linked"] != true {
		t.Fatalf("first line: %v", lines)
	}
	if h.f.token != "saved-token-abcdefghijklmnop" {
		t.Fatalf("token: %q", h.f.token)
	}
	answers := map[float64]map[string]any{}
	for _, l := range lines {
		if id, ok := l["id"].(float64); ok && l["ok"] != nil {
			answers[id] = l
		}
	}
	if answers[1]["ok"] != true || answers[2]["ok"] != true || len(answers) != 2 {
		t.Fatalf("answers: %v", answers)
	}
	h.waitFor("connected", nil)
	h.waitFor("chat", func(e map[string]any) bool { return e["id"] == dmID })
}
