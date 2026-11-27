package main

import (
	"bufio"
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	"github.com/slack-go/slack"
)

func encode(t *testing.T, v any) string {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

// --- the pure parts -------------------------------------------------------------------------------------------------

func TestParseRequest(t *testing.T) {
	r, err := parseRequest([]byte(`{"id":2,"op":"sign_in","cookies":{"d":"xoxd-a%2Fb","token":"xoxc-1","d-s":"9"}}`))
	if err != nil || r.ID != 2 || r.Op != "sign_in" || r.Cookies["d"] != "xoxd-a%2Fb" || r.Cookies["token"] != "xoxc-1" {
		t.Fatalf("sign_in: %+v %v", r, err)
	}
	r, err = parseRequest([]byte(`{"id":5,"op":"history","chat":"T1-C1","before":"1700000000.000100","before_ts":1700000000000}`))
	if err != nil || r.Chat != "T1-C1" || r.Before != "1700000000.000100" || r.BeforeTS != 1700000000000 {
		t.Fatalf("history: %+v %v", r, err)
	}
	r, err = parseRequest([]byte(`{"id":8,"op":"read","to":"T1-C1","upto":"1.2"}`))
	if err != nil || r.ID != 8 || r.Upto != "1.2" {
		t.Fatalf("read: %+v %v", r, err)
	}
	if _, err := parseRequest([]byte(`{"id":1}`)); err == nil {
		t.Fatal("a request without op was taken")
	}
	if _, err := parseRequest([]byte(`not json`)); err == nil {
		t.Fatal("a broken line was taken")
	}
}

func TestAnswerEncoding(t *testing.T) {
	if got := encode(t, answer(1, nil, nil)); got != `{"id":1,"ok":true,"result":null}` {
		t.Fatalf("null result: %s", got)
	}
	if got := encode(t, answer(3, nil, errors.New("no"))); got != `{"error":"no","id":3,"ok":false}` {
		t.Fatalf("error: %s", got)
	}
}

func TestCredentials(t *testing.T) {
	cases := []struct {
		given map[string]string
		want  string
	}{
		{map[string]string{"token": "xoxc-1"}, "the d cookie is missing"},
		{map[string]string{"d": "xoxd-1"}, "the token (xoxc-…) is missing"},
		{map[string]string{"d": "xoxd-1", "token": "  "}, "the token (xoxc-…) is missing"},
		{nil, "the d cookie is missing and the token (xoxc-…) is missing"},
		{map[string]string{"d": "xoxd-1", "token": "xoxb-1"}, "that token is not a browser session's"},
		{map[string]string{"d": "abc", "token": "xoxc-1"}, "that d cookie is not Slack's sign-in"},
	}
	for _, c := range cases {
		_, _, err := credentials(c.given)
		if err == nil || !strings.HasPrefix(err.Error(), c.want) || !strings.Contains(err.Error(), "copy the cookies and token again") {
			t.Fatalf("%v: %v", c.given, err)
		}
	}
	token, cookies, err := credentials(map[string]string{"D": " xoxd-a%2Fb%3D ", "Token": `"xoxc-1"`, "d-s": "17", "bad;name": "x", "empty": ""})
	if err != nil || token != "xoxc-1" {
		t.Fatalf("token: %q %v", token, err)
	}
	// The browser shows the cookie escaped; it is kept as Slack set it, for the library to escape once.
	if cookies["d"] != "xoxd-a/b=" || cookies["d-s"] != "17" || len(cookies) != 2 {
		t.Fatalf("cookies: %v", cookies)
	}
	if _, cookies, _ := credentials(map[string]string{"d": "xoxd-a+b/c=", "token": "xoxc-1"}); cookies["d"] != "xoxd-a+b/c=" {
		t.Fatalf("an unescaped d: %v", cookies)
	}
}

func TestSessionRoundTrip(t *testing.T) {
	path := filepath.Join(t.TempDir(), "session.json")
	if loadSession(path) != nil {
		t.Fatal("a session where there is no file")
	}
	if err := os.WriteFile(path, []byte(`{"team":"T1","me":"U1"}`), 0o644); err != nil {
		t.Fatal(err)
	}
	if loadSession(path) != nil {
		t.Fatal("a session without its token was taken")
	}
	s := session{Team: "T1", TeamName: "Acme", Me: "UME", Name: "Mo", Handle: "mo", Token: "xoxc-1", Cookies: map[string]string{"d": "xoxd-1", "d-s": "2"}}
	if err := saveSession(path, s); err != nil {
		t.Fatal(err)
	}
	if runtime.GOOS != "windows" {
		st, err := os.Stat(path)
		if err != nil || st.Mode().Perm() != 0o600 {
			t.Fatalf("mode: %v %v", st.Mode().Perm(), err)
		}
	}
	if _, err := os.Stat(path + ".new"); !os.IsNotExist(err) {
		t.Fatal("the half-written file was left behind")
	}
	got := loadSession(path)
	if got == nil || got.Team != "T1" || got.Me != "UME" || got.Token != "xoxc-1" || got.Cookies["d-s"] != "2" {
		t.Fatalf("loaded: %+v", got)
	}
}

func TestWords(t *testing.T) {
	code := func(c string) error { return fmt.Errorf("x: %w", slack.SlackErrorResponse{Err: c}) }
	for _, c := range []string{"invalid_auth", "token_revoked", "account_inactive", "user_removed_from_team"} {
		if !rejected(code(c)) {
			t.Fatalf("%s was not seen as the session ending", c)
		}
	}
	if rejected(code("ratelimited")) || rejected(code("channel_not_found")) || rejected(errors.New("dial tcp")) {
		t.Fatal("a passing trouble was taken for the session ending")
	}
	if endedWords(code("invalid_auth")) != wordsSignedOut || !strings.Contains(endedWords(code("account_inactive")), "deactivated") {
		t.Fatal("ended words")
	}
	if got := signInWords(code("invalid_auth")).Error(); !strings.Contains(got, "did not take that token") {
		t.Fatalf("sign in: %s", got)
	}
	if got := plain(&slack.RateLimitedError{RetryAfter: time.Second}).Error(); !strings.Contains(got, "too many requests") {
		t.Fatalf("rate limited: %s", got)
	}
	if got := plain(code("weird_thing")).Error(); !strings.Contains(got, "weird_thing") {
		t.Fatalf("unknown: %s", got)
	}
	if got := plain(slack.StatusCodeError{Code: 503}).Error(); !strings.Contains(got, "problem of its own") {
		t.Fatalf("503: %s", got)
	}
	if err := errors.New("nothing to send"); plain(err) != err {
		t.Fatal("words already plain were changed")
	}
}

func TestIDs(t *testing.T) {
	if chatID("T1", "C2") != "T1-C2" {
		t.Fatal("chat id")
	}
	if ch, ok := parseChatID("T1", "T1-C2"); !ok || ch != "C2" {
		t.Fatalf("parse: %q %v", ch, ok)
	}
	if ch, ok := parseChatID("T1", "D9"); !ok || ch != "D9" {
		t.Fatalf("a bare channel: %q %v", ch, ok)
	}
	for _, bad := range []string{"T2-C2", "T1-", "", "T1-c2", "T1-C2/../x"} {
		if _, ok := parseChatID("T1", bad); ok {
			t.Fatalf("%q was taken", bad)
		}
	}
	if tsMillis("1700000000.000100") != 1700000000000 || tsMillis("1700000001.123456") != 1700000001123 || tsMillis("") != 0 || tsMillis("0000000000.000000") != 0 {
		t.Fatal("ts")
	}
}

func TestPlainText(t *testing.T) {
	user := func(id string) string {
		if id == "UANN" {
			return "Ann"
		}
		return ""
	}
	channel := func(id string) string {
		if id == "C1" {
			return "general"
		}
		return ""
	}
	cases := map[string]string{
		"hi <@UANN>, see <#C1> and <#C2|random>":    "hi @Ann, see #general and #random",
		"<@UZZZ|zed> <@UQQQ>":                       "@zed @UQQQ",
		"<!here> <!channel> <!subteam^S1|@design>":  "@here @channel @design",
		"<https://x.com|the site> <https://y.com>":  "the site (https://x.com) https://y.com",
		"<mailto:a@b.c|a@b.c> <http://q.com|q.com>": "a@b.c http://q.com",
		"a &lt;b&gt; &amp; c :tada: :not_an_emoji:": "a <b> & c 🎉 :not_an_emoji:",
		"*bold* _it_":                      "*bold* _it_",
		"<!date^1700000000^{date}|Nov 14>": "Nov 14",
		"<https://x.com/?a=1&amp;b=2>":     "https://x.com/?a=1&b=2",
	}
	for in, want := range cases {
		if got := plainText(in, user, channel); got != want {
			t.Fatalf("%q:\n got %q\nwant %q", in, got, want)
		}
	}
	if got := mentions("<@UANN> <@UBEN|ben> <#C1> <!here>"); len(got) != 2 || got[0] != "UANN" || got[1] != "UBEN" {
		t.Fatalf("mentions: %v", got)
	}
}

func TestReactions(t *testing.T) {
	if reactionName("👍") != "+1" || reactionName(":partyparrot:") != "partyparrot" || reactionName("thumbsup") != "thumbsup" || reactionName("hello there") != "" {
		t.Fatal("names")
	}
	if !strings.HasPrefix(reactionEmoji("+1"), "👍") || reactionEmoji("partyparrot") != ":partyparrot:" {
		t.Fatal("emoji")
	}
	if e := reactionEmoji("+1::skin-tone-2"); e == "" || strings.HasPrefix(e, ":") {
		t.Fatalf("skin tone: %q", e)
	}
}

func testView() view {
	people := map[string]person{
		"UME":  {ID: "UME", Name: "Mo", Handle: "mo"},
		"UANN": {ID: "UANN", Name: "Ann Lee", Handle: "ann", Pic: "https://avatars.slack-edge.com/ann_192.png"},
		"UBEN": {ID: "UBEN", Name: "Ben Okoro", Handle: "ben"},
	}
	return view{
		team:   "T1",
		me:     "UME",
		person: func(id string) person { return people[id] },
		parent: func(ch, ts string) string {
			if ch == "D1" && ts == "1700000001.000000" {
				return "lunch?"
			}
			return ""
		},
	}
}

func TestChatOf(t *testing.T) {
	v := testView()
	im := slack.Channel{IsMember: true}
	im.ID, im.IsIM, im.User = "D1", true, "UANN"
	latest := slack.Msg{User: "UME", Text: "see you then", Timestamp: "1700000003.000000"}
	var asked []string
	got := encode(t, chatOf(v, im, counts{Latest: "1700000003.000000", Unreads: true, Mentions: 2}, &latest, func(p person) string {
		asked = append(asked, p.ID)
		return "/d/avatars/aa"
	}))
	want := `{"id":"T1-D1","title":"Ann Lee","group":false,"members":[{"id":"UANN","name":"Ann Lee"}],"avatar":"/d/avatars/aa","unread":2,"last":1700000003000,"snippet":"see you then","snippet_mine":true}`
	if got != want {
		t.Fatalf("a DM:\n got %s\nwant %s", got, want)
	}
	if len(asked) != 1 || asked[0] != "UANN" {
		t.Fatalf("avatar asked of %v", asked)
	}

	mpim := slack.Channel{}
	mpim.ID, mpim.IsMpIM, mpim.Name, mpim.Members = "G1", true, "mpdm-ann--ben--mo-1", []string{"UME", "UANN", "UBEN"}
	got = encode(t, chatOf(v, mpim, counts{}, nil, func(person) string { t.Fatal("a group has no one picture"); return "" }))
	want = `{"id":"T1-G1","title":"Ann Lee, Ben Okoro","group":true,"members":[{"id":"UANN","name":"Ann Lee"},{"id":"UBEN","name":"Ben Okoro"}],"avatar":null,"unread":0,"last":0}`
	if got != want {
		t.Fatalf("a group DM:\n got %s\nwant %s", got, want)
	}
	// Members not listed: the names in the group DM's own name stand in.
	mpim.Members = nil
	if c := chatOf(view{team: "T1", me: "UME", person: func(id string) person { return person{Handle: "mo"} }}, mpim, counts{}, nil, nil); c.Title != "ann, ben" {
		t.Fatalf("a group DM from its name: %q", c.Title)
	}

	channel := slack.Channel{IsChannel: true}
	channel.ID, channel.Name = "C1", "general"
	c := chatOf(v, channel, counts{Latest: "1700000002.000100", Unreads: true}, nil, nil)
	if c.Title != "#general" || !c.Group || len(c.Members) != 0 || c.Unread != 1 || c.Last != 1700000002000 || c.Avatar != nil {
		t.Fatalf("a channel: %+v", c)
	}
}

func TestMessageOf(t *testing.T) {
	v := testView()
	reply := slack.Msg{
		User:            "UANN",
		Text:            "yes <@UME> :tada:",
		Timestamp:       "1700000002.000000",
		ThreadTimestamp: "1700000001.000000",
		Files: []slack.File{
			{ID: "F1", Name: "menu.pdf", Mimetype: "application/pdf", Size: 4096, URLPrivateDownload: "https://files.slack.com/files-pri/T1-F1/download/menu.pdf"},
			{ID: "F2", Name: "pic.png", Mimetype: "image/png", OriginalW: 640, OriginalH: 480, URLPrivate: "https://files.slack.com/files-pri/T1-F2/pic.png"},
			{ID: "F3", Mode: "hidden_by_limit"},
			{ID: "F4", IsExternal: true, Permalink: "https://drive.example/doc"},
		},
		Reactions: []slack.ItemReaction{{Name: "+1", Users: []string{"UME", "UBEN"}}},
	}
	got := encode(t, messageOf(v, "D1", false, reply))
	want := `{"chat":"T1-D1","group":false,"id":"1700000002.000000","from":"UANN","name":"Ann Lee","mine":false,"ts":1700000002000,"text":"yes @Mo 🎉\nhttps://drive.example/doc",` +
		`"media":[{"pointer":{"file":"F1","url":"https://files.slack.com/files-pri/T1-F1/download/menu.pdf","kind":"file"},"mime":"application/pdf","name":"menu.pdf","size":4096,"width":0,"height":0},` +
		`{"pointer":{"file":"F2","url":"https://files.slack.com/files-pri/T1-F2/pic.png","kind":"image"},"mime":"image/png","name":"pic.png","size":0,"width":640,"height":480}],` +
		`"quote":{"id":"1700000001.000000","text":"lunch?"},"reactions":[{"from":"UME","emoji":"👍️"},{"from":"UBEN","emoji":"👍️"}]}`
	if got != want {
		t.Fatalf("a reply:\n got %s\nwant %s", got, want)
	}
	// A thread's first message is not a reply; an app's message has the name it posted under.
	bot := slack.Msg{BotID: "B1", Username: "Deploys", Timestamp: "1700000001.000000", ThreadTimestamp: "1700000001.000000", Attachments: []slack.Attachment{{Fallback: "built <https://ci|#42>"}}}
	if got := encode(t, messageOf(v, "C1", true, bot)); got != `{"chat":"T1-C1","group":true,"id":"1700000001.000000","from":"B1","name":"Deploys","mine":false,"ts":1700000001000,"text":"built #42 (https://ci)","media":[]}` {
		t.Fatalf("an app's message: %s", got)
	}
	if !shown(slack.Msg{}) || shown(slack.Msg{SubType: "channel_join"}) || shown(slack.Msg{SubType: "something_new", Hidden: true}) || !shown(slack.Msg{SubType: "thread_broadcast"}) {
		t.Fatal("shown")
	}
}

func TestPointer(t *testing.T) {
	p, err := parsePointer(json.RawMessage(`{"file":"F1","url":"https://files.slack.com/x","kind":"file"}`))
	if err != nil || p.File != "F1" || p.URL != "https://files.slack.com/x" {
		t.Fatalf("object: %+v %v", p, err)
	}
	if p, err = parsePointer(json.RawMessage(`"{\"file\":\"F2\",\"kind\":\"image\"}"`)); err != nil || p.File != "F2" {
		t.Fatalf("string: %+v %v", p, err)
	}
	for _, bad := range []string{`{}`, `null`, `{"file":"F1","url":"https://evil.example/x"}`, `{"file":"F1","url":"http://files.slack.com/x"}`, `{"file":"../x"}`, ``} {
		if _, err := parsePointer(json.RawMessage(bad)); err == nil {
			t.Fatalf("%q was taken for a file", bad)
		}
	}
}

// --- the protocol, against a stand-in for Slack ---------------------------------------------------------------------

// standIn plays Slack: its web API at slack.com/api, files at files.slack.com, pictures, and the RTM websocket at
// wss-primary.slack.com. Every address the helper asks for is dialled to it.
type standIn struct {
	t   *testing.T
	srv *httptest.Server

	mu       sync.Mutex
	calls    []call
	signedIn bool // false: everything answers invalid_auth
	ws       *websocket.Conn
	wsReady  chan struct{}
}

type call struct {
	method string
	form   url.Values
}

const (
	testToken = "xoxc-test"
	testD     = "xoxd-a/b="
)

func user(id, name, display string) map[string]any {
	return map[string]any{"id": id, "name": strings.ToLower(strings.Fields(display)[0]), "real_name": name, "profile": map[string]any{
		"display_name": display, "real_name": name, "image_192": "https://avatars.slack-edge.com/" + id + "_192.png",
	}}
}

var testUsers = map[string]map[string]any{
	"UME":  user("UME", "Mo Example", "Mo"),
	"UANN": user("UANN", "Ann Lee", "Ann Lee"),
	"UBEN": user("UBEN", "Ben Okoro", "Ben Okoro"),
}

func newStandIn(t *testing.T) *standIn {
	s := &standIn{t: t, signedIn: true, wsReady: make(chan struct{})}
	s.srv = httptest.NewTLSServer(http.HandlerFunc(s.serve))
	t.Cleanup(s.srv.Close)
	addr := s.srv.Listener.Addr().String()
	dial := func(ctx context.Context, network, _ string) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, network, addr)
	}
	tlsConf := &tls.Config{InsecureSkipVerify: true}
	oldHTTP, oldWS, oldFetch, oldWait := httpClient, wsDialer, fetchVersion, fileShareWait
	httpClient = &http.Client{Transport: &http.Transport{DialContext: dial, TLSClientConfig: tlsConf}}
	wsDialer = &websocket.Dialer{NetDialContext: dial, TLSClientConfig: tlsConf, HandshakeTimeout: 5 * time.Second}
	fetchVersion = true // answered 404 here: the helper goes on without it
	fileShareWait = 10 * time.Millisecond
	t.Cleanup(func() { httpClient, wsDialer, fetchVersion, fileShareWait = oldHTTP, oldWS, oldFetch, oldWait })
	return s
}

func (s *standIn) called(method string) []url.Values {
	s.mu.Lock()
	defer s.mu.Unlock()
	var got []url.Values
	for _, c := range s.calls {
		if c.method == method {
			got = append(got, c.form)
		}
	}
	return got
}

func (s *standIn) push(v any) {
	select {
	case <-s.wsReady:
	case <-time.After(5 * time.Second):
		s.t.Fatal("the helper never opened the live stream")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.ws.WriteJSON(v); err != nil {
		s.t.Fatalf("push: %v", err)
	}
}

func reply(w http.ResponseWriter, v map[string]any) {
	if _, ok := v["ok"]; !ok {
		v["ok"] = true
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(v)
}

func (s *standIn) authed(r *http.Request, token string) bool {
	s.mu.Lock()
	ok := s.signedIn
	s.mu.Unlock()
	c, err := r.Cookie("d")
	if err != nil || !ok {
		return false
	}
	d, _ := url.QueryUnescape(c.Value)
	return d == testD && token == testToken
}

func (s *standIn) serve(w http.ResponseWriter, r *http.Request) {
	switch r.Host {
	case "app.slack.com":
		http.NotFound(w, r)
		return
	case "avatars.slack-edge.com":
		_, _ = w.Write([]byte("PNGDATA"))
		return
	case "wss-primary.slack.com":
		if !s.authed(r, r.URL.Query().Get("token")) {
			http.Error(w, "no", http.StatusUnauthorized)
			return
		}
		conn, err := (&websocket.Upgrader{CheckOrigin: func(*http.Request) bool { return true }}).Upgrade(w, r, nil)
		if err != nil {
			return
		}
		s.mu.Lock()
		s.ws = conn
		_ = conn.WriteJSON(map[string]any{"type": "hello"})
		s.mu.Unlock()
		close(s.wsReady)
		for {
			if _, _, err := conn.ReadMessage(); err != nil {
				return
			}
		}
	case "files.slack.com":
		if strings.HasPrefix(r.URL.Path, "/upload/") {
			_, _ = io.Copy(io.Discard, r.Body)
			_, _ = w.Write([]byte("OK"))
			return
		}
		if r.Header.Get("Authorization") != "Bearer "+testToken {
			http.Error(w, "no", http.StatusForbidden)
			return
		}
		if strings.Contains(r.URL.Path, "expired") {
			http.NotFound(w, r)
			return
		}
		_, _ = w.Write([]byte("FILEDATA"))
		return
	}
	method := strings.TrimPrefix(r.URL.Path, "/api/")
	_ = r.ParseForm()
	s.mu.Lock()
	s.calls = append(s.calls, call{method, r.Form})
	s.mu.Unlock()
	if !s.authed(r, r.Form.Get("token")) {
		reply(w, map[string]any{"ok": false, "error": "invalid_auth"})
		return
	}
	switch method {
	case "client.userBoot":
		reply(w, map[string]any{"self": testUsers["UME"], "team": map[string]any{"id": "T1", "name": "Acme", "domain": "acme"}})
	case "auth.test":
		reply(w, map[string]any{"team_id": "T1", "user_id": "UME"})
	case "users.conversations":
		reply(w, map[string]any{"channels": []map[string]any{
			{"id": "C1", "name": "general", "is_channel": true, "is_member": true},
			{"id": "D1", "is_im": true, "user": "UANN"},
			{"id": "G1", "name": "mpdm-ann--ben--mo-1", "is_mpim": true, "is_group": true},
			{"id": "C2", "name": "random", "is_channel": true, "is_member": true},
		}, "response_metadata": map[string]any{"next_cursor": ""}})
	case "client.counts":
		reply(w, map[string]any{
			"channels": []map[string]any{{"id": "C1", "latest": "1700000002.000100", "has_unreads": true}, {"id": "C2", "latest": "0000000000.000000"}},
			"ims":      []map[string]any{{"id": "D1", "latest": "1700000003.000000", "has_unreads": true, "mention_count": 2}},
			"mpims":    []map[string]any{{"id": "G1", "latest": "1700000001.000000"}},
		})
	case "conversations.members":
		reply(w, map[string]any{"members": []string{"UME", "UANN", "UBEN"}})
	case "conversations.info":
		switch r.Form.Get("channel") {
		case "D1":
			reply(w, map[string]any{"channel": map[string]any{"id": "D1", "is_im": true, "user": "UANN"}})
		case "C3":
			reply(w, map[string]any{"channel": map[string]any{"id": "C3", "name": "new-room", "is_channel": true}})
		default:
			reply(w, map[string]any{"channel": map[string]any{"id": r.Form.Get("channel"), "name": "general", "is_channel": true}})
		}
	case "users.info":
		if u, ok := testUsers[r.Form.Get("user")]; ok {
			reply(w, map[string]any{"user": u})
		} else {
			reply(w, map[string]any{"ok": false, "error": "user_not_found"})
		}
	case "users.list":
		list := []map[string]any{}
		for _, id := range []string{"UME", "UANN", "UBEN"} {
			list = append(list, testUsers[id])
		}
		gone := user("UGONE", "Gone Away", "Gone")
		gone["deleted"] = true
		app := user("UAPP", "Deploys", "Deploys")
		app["is_bot"] = true
		reply(w, map[string]any{"members": append(list, gone, app), "response_metadata": map[string]any{"next_cursor": ""}})
	case "conversations.open":
		reply(w, map[string]any{"channel": map[string]any{"id": "D2", "is_im": true, "user": r.Form.Get("users")}})
	case "bots.info":
		reply(w, map[string]any{"bot": map[string]any{"id": r.Form.Get("bot"), "name": "Deploys"}})
	case "conversations.history":
		s.history(w, r.Form)
	case "conversations.replies":
		reply(w, map[string]any{"messages": []map[string]any{
			{"ts": "1700000001.000000", "thread_ts": "1700000001.000000", "user": "UANN", "text": "lunch?", "reply_count": 1},
			{"ts": "1700000001.500000", "thread_ts": "1700000001.000000", "user": "UME", "text": "yes <@UANN>"},
		}})
	case "chat.postMessage":
		reply(w, map[string]any{"channel": r.Form.Get("channel"), "ts": "1700000010.000100"})
	case "chat.delete", "reactions.add", "reactions.remove", "conversations.mark", "subscriptions.thread.mark":
		reply(w, map[string]any{})
	case "files.getUploadURLExternal":
		reply(w, map[string]any{"upload_url": "https://files.slack.com/upload/v1/abc", "file_id": "F9"})
	case "files.completeUploadExternal":
		reply(w, map[string]any{"files": []map[string]any{{"id": "F9", "title": "note.txt"}}})
	case "files.info":
		if r.Form.Get("file") == "F9" {
			reply(w, map[string]any{"file": map[string]any{"id": "F9", "shares": map[string]any{"private": map[string]any{"D1": []map[string]any{{"ts": "1700000011.000000"}}}}}})
			return
		}
		reply(w, map[string]any{"file": map[string]any{"id": r.Form.Get("file"), "url_private_download": "https://files.slack.com/files-pri/T1-F1/download/fresh.pdf"}})
	default:
		reply(w, map[string]any{"ok": false, "error": "unknown_method"})
	}
}

func (s *standIn) history(w http.ResponseWriter, form url.Values) {
	var msgs []map[string]any
	switch form.Get("channel") {
	case "D1":
		msgs = []map[string]any{
			{"ts": "1700000003.000000", "user": "UME", "text": "see you then"},
			{"ts": "1700000002.000000", "user": "UANN", "text": "at <https://x.com|the place> :tada:", "files": []map[string]any{
				{"id": "F1", "name": "menu.pdf", "mimetype": "application/pdf", "size": 9, "url_private_download": "https://files.slack.com/files-pri/T1-F1/download/expired.pdf"},
			}, "reactions": []map[string]any{{"name": "heart", "users": []string{"UME"}, "count": 1}}},
			{"ts": "1700000001.200000", "subtype": "channel_join", "user": "UANN", "text": "joined"},
			{"ts": "1700000001.000000", "thread_ts": "1700000001.000000", "user": "UANN", "text": "lunch?", "reply_count": 1, "latest_reply": "1700000001.500000"},
		}
		if latest := form.Get("latest"); latest != "" {
			var older []map[string]any
			for _, m := range msgs {
				if m["ts"].(string) < latest || form.Get("inclusive") == "true" && m["ts"].(string) == latest {
					older = append(older, m)
				}
			}
			msgs = older
		}
		if form.Get("limit") == "1" && len(msgs) > 1 {
			msgs = msgs[:1]
		}
	case "C1":
		msgs = []map[string]any{{"ts": "1700000002.000100", "bot_id": "B1", "username": "Deploys", "text": "built"}}
	}
	reply(w, map[string]any{"messages": msgs, "has_more": false})
}

// harness runs the helper's protocol loop on pipes, reading what it says into lines a test waits for.
type harness struct {
	t     *testing.T
	in    *io.PipeWriter
	done  chan struct{}
	mu    sync.Mutex
	lines []map[string]any
	used  []bool
	added chan struct{}
}

func start1(t *testing.T, folder string) *harness {
	t.Helper()
	dir = folder
	acct, connected = nil, false
	seen.reset()
	setup(io.Discard)
	inR, inW := io.Pipe()
	outR, outW := io.Pipe()
	outLock.Lock()
	out = json.NewEncoder(outW)
	out.SetEscapeHTML(false)
	outLock.Unlock()
	h := &harness{t: t, in: inW, done: make(chan struct{}), added: make(chan struct{}, 1)}
	go func() {
		sc := bufio.NewScanner(outR)
		sc.Buffer(make([]byte, 1<<20), 8<<20)
		for sc.Scan() {
			var m map[string]any
			if json.Unmarshal(sc.Bytes(), &m) != nil {
				t.Errorf("not JSON on stdout: %s", sc.Text())
				continue
			}
			h.mu.Lock()
			h.lines = append(h.lines, m)
			h.used = append(h.used, false)
			h.mu.Unlock()
			select {
			case h.added <- struct{}{}:
			default:
			}
		}
	}()
	go func() {
		serve(inR)
		close(h.done)
	}()
	t.Cleanup(func() {
		_ = inW.Close()
		select {
		case <-h.done:
		case <-time.After(5 * time.Second):
		}
		_ = outW.Close()
	})
	return h
}

// wait is the first line not yet waited for that [match] takes.
func (h *harness) wait(what string, match func(map[string]any) bool) map[string]any {
	h.t.Helper()
	deadline := time.After(10 * time.Second)
	for {
		h.mu.Lock()
		for i, m := range h.lines {
			if !h.used[i] && match(m) {
				h.used[i] = true
				h.mu.Unlock()
				return m
			}
		}
		h.mu.Unlock()
		select {
		case <-h.added:
		case <-time.After(50 * time.Millisecond):
		case <-deadline:
			h.mu.Lock()
			defer h.mu.Unlock()
			h.t.Fatalf("no %s; said: %s", what, encode(h.t, h.lines))
		}
	}
}

func (h *harness) ev(name string, also func(map[string]any) bool) map[string]any {
	h.t.Helper()
	return h.wait("event "+name, func(m map[string]any) bool { return m["ev"] == name && (also == nil || also(m)) })
}

var nextID = int64(100)

// ask sends a request and waits for its answer: the result, failing the test on an error.
func (h *harness) ask(op string, fields map[string]any) any {
	h.t.Helper()
	m := h.ask2(op, fields)
	if m["ok"] != true {
		h.t.Fatalf("%s: %v", op, m["error"])
	}
	return m["result"]
}

func (h *harness) ask2(op string, fields map[string]any) map[string]any {
	h.t.Helper()
	nextID++
	id := nextID
	req := map[string]any{"id": id, "op": op}
	for k, v := range fields {
		req[k] = v
	}
	b, _ := json.Marshal(req)
	if _, err := h.in.Write(append(b, '\n')); err != nil {
		h.t.Fatal(err)
	}
	return h.wait("answer to "+op, func(m map[string]any) bool { n, ok := m["id"].(float64); return ok && int64(n) == id && m["ev"] == nil })
}

func TestProtocolAgainstStandIn(t *testing.T) {
	s := newStandIn(t)
	folder := t.TempDir()
	h := start1(t, folder)
	if r := h.ev("ready", nil); r["linked"] != false {
		t.Fatalf("ready: %v", r)
	}
	if m := h.ask2("chats", nil); m["ok"] != false || m["error"] != "not signed in to Slack" {
		t.Fatalf("chats before signing in: %v", m)
	}
	if m := h.ask2("sign_in", map[string]any{"cookies": map[string]string{"token": testToken}}); m["ok"] != false || !strings.Contains(m["error"].(string), "the d cookie is missing") {
		t.Fatalf("sign in without d: %v", m)
	}
	if m := h.ask2("sign_in", map[string]any{"cookies": map[string]string{"token": "xoxc-wrong", "d": "xoxd-a%2Fb%3D"}}); m["ok"] != false || !strings.Contains(m["error"].(string), "did not take that token") {
		t.Fatalf("sign in turned away: %v", m)
	}

	got := h.ask("sign_in", map[string]any{"cookies": map[string]string{"token": testToken, "d": "xoxd-a%2Fb%3D", "d-s": "1700000000"}})
	if encode(t, got) != `{"handle":"mo","me":"UME","name":"Mo"}` {
		t.Fatalf("signed in as %s", encode(t, got))
	}
	h.ev("linked", func(m map[string]any) bool { return m["me"] == "UME" })
	saved := loadSession(filepath.Join(folder, "session.json"))
	if saved == nil || saved.Team != "T1" || saved.Token != testToken || saved.Cookies["d"] != testD || saved.Cookies["d-s"] != "1700000000" {
		t.Fatalf("session.json: %+v", saved)
	}
	if runtime.GOOS != "windows" {
		if st, _ := os.Stat(filepath.Join(folder, "session.json")); st.Mode().Perm() != 0o600 {
			t.Fatalf("session.json mode %v", st.Mode().Perm())
		}
	}
	h.ev("chat", func(m map[string]any) bool { return m["id"] == "T1-D1" })
	h.ev("connected", nil)
	if st := h.ask("status", nil).(map[string]any); st["linked"] != true || st["connected"] != true || st["me"] != "UME" {
		t.Fatalf("status: %v", st)
	}

	// chats: newest first, by Slack's sidebar.
	list := h.ask("chats", nil).([]any)
	var titles []string
	for _, c := range list {
		titles = append(titles, c.(map[string]any)["title"].(string))
	}
	if strings.Join(titles, "|") != "Ann Lee|#general|Ann Lee, Ben Okoro|#random" {
		t.Fatalf("chats: %v", titles)
	}
	dm := list[0].(map[string]any)
	if dm["group"] != false || dm["unread"] != 2.0 || dm["snippet"] != "see you then" || dm["snippet_mine"] != true || dm["avatar"] == nil {
		t.Fatalf("the DM: %v", dm)
	}
	if b, err := os.ReadFile(dm["avatar"].(string)); err != nil || string(b) != "PNGDATA" {
		t.Fatalf("avatar: %q %v", b, err)
	}
	if g := list[2].(map[string]any); g["group"] != true || len(g["members"].([]any)) != 2 {
		t.Fatalf("the group DM: %v", g)
	}
	if c := list[1].(map[string]any); c["snippet"] != "built" || c["snippet_mine"] != false || c["unread"] != 1.0 {
		t.Fatalf("the channel: %v", c)
	}

	// history: oldest first, the thread's reply among them quoting its first message.
	hist := h.ask("history", map[string]any{"chat": "T1-D1"}).(map[string]any)
	var lines []string
	for _, m := range hist["messages"].([]any) {
		m := m.(map[string]any)
		q := ""
		if m["quote"] != nil {
			qq := m["quote"].(map[string]any)
			q = " > " + qq["id"].(string) + " " + qq["text"].(string)
		}
		lines = append(lines, fmt.Sprintf("%s %s %v: %s%s", m["id"], m["from"], m["mine"], m["text"], q))
	}
	want := []string{
		"1700000001.000000 UANN false: lunch?",
		"1700000001.500000 UME true: yes @Ann Lee > 1700000001.000000 lunch?",
		"1700000002.000000 UANN false: at the place (https://x.com) 🎉",
		"1700000003.000000 UME true: see you then",
	}
	if strings.Join(lines, "\n") != strings.Join(want, "\n") || hist["more"] != false {
		t.Fatalf("history:\n%s", strings.Join(lines, "\n"))
	}
	withFile := hist["messages"].([]any)[2].(map[string]any)
	if encode(t, withFile["reactions"]) != `[{"emoji":"❤️","from":"UME"}]` {
		t.Fatalf("reactions: %s", encode(t, withFile["reactions"]))
	}
	older := h.ask("history", map[string]any{"chat": "T1-D1", "before": "1700000002.000000"}).(map[string]any)
	if n := len(older["messages"].([]any)); n != 2 {
		t.Fatalf("older page: %s", encode(t, older))
	}

	// send: a quote of the reply goes into its thread.
	sent := h.ask("send", map[string]any{"to": "T1-D1", "text": "a <b> & c", "quote": map[string]any{"id": "1700000001.500000"}}).(map[string]any)
	if sent["id"] != "1700000010.000100" || sent["ts"] != 1700000010000.0 {
		t.Fatalf("sent: %v", sent)
	}
	post := s.called("chat.postMessage")
	if len(post) != 1 || post[0].Get("channel") != "D1" || post[0].Get("thread_ts") != "1700000001.000000" || post[0].Get("text") != "a &lt;b&gt; &amp; c" {
		t.Fatalf("postMessage: %v", post)
	}
	if m := h.ask2("send", map[string]any{"to": "T2-D1", "text": "x"}); m["ok"] != false || !strings.Contains(m["error"].(string), "not a chat of this Slack workspace") {
		t.Fatalf("a chat of another workspace: %v", m)
	}

	h.ask("react", map[string]any{"to": "T1-D1", "target": "1700000002.000000", "emoji": "👍", "remove": false})
	h.ask("react", map[string]any{"to": "T1-D1", "target": "1700000002.000000", "emoji": ":partyparrot:", "remove": true})
	if add, rm := s.called("reactions.add"), s.called("reactions.remove"); len(add) != 1 || add[0].Get("name") != "+1" || add[0].Get("timestamp") != "1700000002.000000" || len(rm) != 1 || rm[0].Get("name") != "partyparrot" {
		t.Fatalf("reactions: %v %v", add, rm)
	}

	// read: up to a reply marks its thread, and the chat up to its own newest message then.
	h.ask("read", map[string]any{"to": "T1-D1", "upto": "1700000001.500000"})
	if th, conv := s.called("subscriptions.thread.mark"), s.called("conversations.mark"); len(th) != 1 || th[0].Get("thread_ts") != "1700000001.000000" || len(conv) != 1 || conv[0].Get("ts") != "1700000001.200000" {
		t.Fatalf("read a reply: %v %v", th, conv)
	}
	h.ask("read", map[string]any{"to": "T1-D1", "upto": "1700000003.000000"})
	if conv := s.called("conversations.mark"); len(conv) != 2 || conv[1].Get("ts") != "1700000003.000000" {
		t.Fatalf("read: %v", conv)
	}

	h.ask("delete", map[string]any{"to": "T1-D1", "target": "1700000003.000000"})
	if del := s.called("chat.delete"); len(del) != 1 || del[0].Get("ts") != "1700000003.000000" {
		t.Fatalf("delete: %v", del)
	}

	who := h.ask("who", map[string]any{"who": "UBEN"}).(map[string]any)
	if who["name"] != "Ben Okoro" || who["handle"] != "ben" || who["avatar"] == nil {
		t.Fatalf("who: %v", who)
	}
	if bot := h.ask("who", map[string]any{"who": "B1"}).(map[string]any); bot["name"] != "Deploys" {
		t.Fatalf("who, an app: %v", bot)
	}

	// people (GMFB-61): the workspace's members by name or handle, no apps, no one removed, not the person; and open,
	// the direct message with one of them.
	if all := h.ask("people", nil).([]any); len(all) != 2 || all[0].(map[string]any)["id"] != "UANN" || all[1].(map[string]any)["handle"] != "ben" {
		t.Fatalf("people: %v", all)
	}
	if found := h.ask("people", map[string]any{"query": "@BEN"}).([]any); len(found) != 1 || found[0].(map[string]any)["name"] != "Ben Okoro" {
		t.Fatalf("people, searched: %v", found)
	}
	if n := len(s.called("users.list")); n != 1 {
		t.Fatalf("the members were listed %d times for two askings", n)
	}
	if opened := h.ask("open", map[string]any{"who": "UBEN"}).(map[string]any); opened["id"] != "T1-D2" || s.called("conversations.open")[0].Get("users") != "UBEN" {
		t.Fatalf("open: %v", opened)
	}
	if m := h.ask2("open", map[string]any{"who": ""}); m["ok"] != false {
		t.Fatalf("a chat with no one was opened: %v", m)
	}

	// download: the message's address has run out here, so a fresh one is asked for.
	target := filepath.Join(t.TempDir(), "menu.pdf")
	h.ask("download", map[string]any{"pointer": withFile["media"].([]any)[0].(map[string]any)["pointer"], "path": target})
	if b, err := os.ReadFile(target); err != nil || string(b) != "FILEDATA" {
		t.Fatalf("downloaded %q %v", b, err)
	}
	if m := h.ask2("download", map[string]any{"pointer": map[string]any{"file": "F1", "url": "https://evil.example/x"}, "path": target}); m["ok"] != false {
		t.Fatalf("a file elsewhere was fetched: %v", m)
	}

	file := filepath.Join(t.TempDir(), "note.txt")
	if err := os.WriteFile(file, []byte("hello"), 0o600); err != nil {
		t.Fatal(err)
	}
	media := h.ask("send_media", map[string]any{"to": "T1-D1", "path": file, "mime": "text/plain", "name": "note.txt", "text": "here"}).(map[string]any)
	if media["id"] != "1700000011.000000" {
		t.Fatalf("send_media: %v", media)
	}
	if done := s.called("files.completeUploadExternal"); len(done) != 1 || done[0].Get("channel_id") != "D1" || done[0].Get("initial_comment") != "here" {
		t.Fatalf("completeUploadExternal: %v", done)
	}

	// What Slack says live.
	s.push(map[string]any{"type": "message", "channel": "D1", "user": "UANN", "text": "new <@UME>", "ts": "1700000020.000000"})
	msg := h.ev("message", func(m map[string]any) bool { return m["id"] == "1700000020.000000" })
	if msg["chat"] != "T1-D1" || msg["text"] != "new @Mo" || msg["mine"] != false || msg["group"] != false || msg["name"] != "Ann Lee" {
		t.Fatalf("message: %v", msg)
	}
	s.push(map[string]any{"type": "message", "channel": "D1", "user": "UANN", "text": "in thread", "ts": "1700000021.000000", "thread_ts": "1700000001.000000"})
	if m := h.ev("message", func(m map[string]any) bool { return m["id"] == "1700000021.000000" }); encode(t, m["quote"]) != `{"id":"1700000001.000000","text":"lunch?"}` {
		t.Fatalf("a live reply: %v", m)
	}
	// A message in a chat the app has not been told of: the chat comes first.
	s.push(map[string]any{"type": "message", "channel": "C3", "user": "UBEN", "text": "hello room", "ts": "1700000022.000000"})
	h.ev("chat", func(m map[string]any) bool {
		return m["id"] == "T1-C3" && m["title"] == "#new-room" && m["snippet"] == "hello room"
	})
	h.ev("message", func(m map[string]any) bool { return m["id"] == "1700000022.000000" && m["group"] == true })
	s.push(map[string]any{"type": "reaction_added", "user": "UANN", "reaction": "+1", "item": map[string]any{"type": "message", "channel": "D1", "ts": "1700000010.000100"}})
	h.ev("reaction", func(m map[string]any) bool {
		return m["chat"] == "T1-D1" && m["from"] == "UANN" && m["target"] == "1700000010.000100" && strings.HasPrefix(m["emoji"].(string), "👍") && m["remove"] == false
	})
	s.push(map[string]any{"type": "im_marked", "channel": "D1", "ts": "1700000020.000000"})
	h.ev("receipt", func(m map[string]any) bool {
		return m["chat"] == "T1-D1" && m["from"] == "UME" && m["id"] == "1700000020.000000" && m["kind"] == "read"
	})
	s.push(map[string]any{"type": "message", "subtype": "message_changed", "channel": "D1", "ts": "1700000030.000000",
		"message":          map[string]any{"user": "UANN", "text": "new, changed", "ts": "1700000020.000000"},
		"previous_message": map[string]any{"user": "UANN", "text": "new <@UME>", "ts": "1700000020.000000"}})
	h.ev("edited", func(m map[string]any) bool { return m["target"] == "1700000020.000000" && m["text"] == "new, changed" })
	s.push(map[string]any{"type": "message", "subtype": "message_deleted", "channel": "D1", "deleted_ts": "1700000020.000000", "ts": "1700000031.000000", "hidden": true})
	h.ev("deleted", func(m map[string]any) bool { return m["chat"] == "T1-D1" && m["target"] == "1700000020.000000" })
	h.ev("name", func(m map[string]any) bool { return m["id"] == "UANN" && m["name"] == "Ann Lee" })

	if h.ask("unlink", nil) != nil {
		t.Fatal("unlink answered something")
	}
	if _, err := os.Stat(filepath.Join(folder, "session.json")); !os.IsNotExist(err) {
		t.Fatal("session.json was kept after unlink")
	}
	if st := h.ask("status", nil).(map[string]any); st["linked"] != false {
		t.Fatalf("status after unlink: %v", st)
	}
}

func TestSavedSessionThenSignedOut(t *testing.T) {
	s := newStandIn(t)
	folder := t.TempDir()
	dir = folder
	if err := saveSession(sessionPath(), session{Team: "T1", Me: "UME", Name: "Mo", Handle: "mo", Token: testToken, Cookies: map[string]string{"d": testD}}); err != nil {
		t.Fatal(err)
	}
	h := start1(t, folder)
	if r := h.ev("ready", nil); r["linked"] != true {
		t.Fatalf("ready: %v", r)
	}
	h.ev("connected", nil)
	if st := h.ask("status", nil).(map[string]any); st["me"] != "UME" || st["linked"] != true {
		t.Fatalf("status: %v", st)
	}
	// Slack signs the session out: the next request finds it so, and the app is told.
	s.mu.Lock()
	s.signedIn = false
	s.mu.Unlock()
	m := h.ask2("history", map[string]any{"chat": "T1-C1"})
	if m["ok"] != false || m["error"] != wordsSignedOut {
		t.Fatalf("history after sign-out: %v", m)
	}
	h.ev("unlinked", func(m map[string]any) bool { return m["error"] == wordsSignedOut })
	if _, err := os.Stat(filepath.Join(folder, "session.json")); !os.IsNotExist(err) {
		t.Fatal("session.json was kept after Slack ended the session")
	}
}
