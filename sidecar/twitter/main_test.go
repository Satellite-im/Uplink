package main

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"image"
	"image/png"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/rs/zerolog"
	"go.mau.fi/util/ptr"

	"go.mau.fi/mautrix-twitter/pkg/juiceboxgo"
	"go.mau.fi/mautrix-twitter/pkg/twittermeow"
	"go.mau.fi/mautrix-twitter/pkg/twittermeow/crypto"
	"go.mau.fi/mautrix-twitter/pkg/twittermeow/data/payload"
	"go.mau.fi/mautrix-twitter/pkg/twittermeow/data/response"
	"go.mau.fi/mautrix-twitter/pkg/twittermeow/data/types"
)

const (
	meID   = "1001"
	annID  = "2002"
	benID  = "3003"
	dmChat = "1001:2002"
	grChat = "g1900000000000000001"
)

var convKeyBytes = bytes.Repeat([]byte{7}, 32)

func TestMain(m *testing.M) {
	log = zerolog.Nop()
	d, err := os.MkdirTemp("", "twitter-sidecar-test")
	if err != nil {
		panic(err)
	}
	dir = d
	code := m.Run()
	_ = os.RemoveAll(d)
	os.Exit(code)
}

func encode(t *testing.T, v any) string {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

// keysFor is a key lookup holding one key, version "50", for [conv].
func keysFor(conv string) keyFunc {
	return func(_ context.Context, c, v string) (*crypto.ConversationKey, error) {
		if c == conv && v == "50" {
			return &crypto.ConversationKey{ConversationID: c, KeyVersion: v, Key: convKeyBytes}, nil
		}
		return nil, crypto.ErrKeyNotFound
	}
}

// evt is an X Chat event, base64 Thrift as X sends it. [entry] is sealed with the test key when [sealed].
func evt(t *testing.T, conv, seq, sender string, at int64, entry *payload.MessageEntryContents, sealed bool) string {
	t.Helper()
	e := &payload.MessageEvent{
		SequenceId:     ptr.Ptr(seq),
		MessageId:      ptr.Ptr("client-" + seq),
		SenderId:       ptr.Ptr(sender),
		ConversationId: ptr.Ptr(conv),
		CreatedAtMsec:  ptr.Ptr(fmt.Sprint(at)),
		IsTrusted:      ptr.Ptr(true),
	}
	if entry != nil {
		mce := &payload.MessageCreateEvent{}
		var err error
		if sealed {
			mce.Contents, err = crypto.EncryptMessageEntryContentsRaw(entry, convKeyBytes)
			mce.ConversationKeyVersion = ptr.Ptr("50")
		} else {
			mce.Contents, err = crypto.EncodeMessageEntryContents(entry)
		}
		if err != nil {
			t.Fatal(err)
		}
		e.Detail = &payload.MessageEventDetail{MessageCreateEvent: mce}
	}
	return encodeEvent(t, e)
}

func encodeEvent(t *testing.T, e *payload.MessageEvent) string {
	t.Helper()
	b, err := payload.Encode(e)
	if err != nil {
		t.Fatal(err)
	}
	return base64.StdEncoding.EncodeToString(b)
}

func text(s string) *payload.MessageEntryContents {
	return &payload.MessageEntryContents{Message: &payload.MessageContents{MessageText: ptr.Ptr(s)}}
}

// --- requests and answers -------------------------------------------------------------------------------------------

func TestParseRequest(t *testing.T) {
	r, err := parseRequest([]byte(`{"id":2,"op":"sign_in","cookies":{"auth_token":"abc","ct0":"def"},"passcode":"1234"}`))
	if err != nil || r.ID != 2 || r.Op != "sign_in" || r.Cookies["auth_token"] != "abc" || r.Cookies["ct0"] != "def" || r.Passcode != "1234" {
		t.Fatalf("sign_in: %+v %v", r, err)
	}
	r, err = parseRequest([]byte(`{"id":5,"op":"history","chat":"` + dmChat + `","before":"1850","before_ts":1700000000000}`))
	if err != nil || r.Chat != dmChat || r.Before != "1850" || r.BeforeTS != 1700000000000 {
		t.Fatalf("history: %+v %v", r, err)
	}
	r, err = parseRequest([]byte(`{"id":6,"op":"send","to":"` + dmChat + `","text":"hi","quote":{"id":"1850","author":"2002","text":"q","ts":5}}`))
	if err != nil || r.To != dmChat || r.Text != "hi" || r.Quote == nil || r.Quote.ID != "1850" || r.Quote.Author != annID {
		t.Fatalf("send: %+v %v", r, err)
	}
	r, err = parseRequest([]byte(`{"id":8,"op":"read","to":"` + dmChat + `","upto":"1850"}`))
	if err != nil || r.ID != 8 || r.Upto != "1850" {
		t.Fatalf("read: %+v %v", r, err)
	}
	r, err = parseRequest([]byte(`{"id":9,"op":"react","to":"c","target":"m","emoji":"👍","remove":true}`))
	if err != nil || r.Target != "m" || r.Emoji != "👍" || !r.Remove {
		t.Fatalf("react: %+v %v", r, err)
	}
	r, err = parseRequest([]byte(`{"id":11,"op":"download","pointer":{"conv":"1:2","hash":"h","kind":"image"},"path":"/tmp/x"}`))
	if err != nil || r.Path != "/tmp/x" || len(r.Pointer) == 0 {
		t.Fatalf("download: %+v %v", r, err)
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

// --- cookies, passcode, session ------------------------------------------------------------------------------------

func TestCookies(t *testing.T) {
	cases := []struct {
		cookies map[string]string
		want    string
	}{
		{map[string]string{"ct0": "x"}, "the auth_token cookie is missing"},
		{map[string]string{"auth_token": "a"}, "the ct0 cookie is missing"},
		{map[string]string{"auth_token": "a", "ct0": "  "}, "the ct0 cookie is missing"},
		{map[string]string{"guest_id": "v1"}, "the auth_token and ct0 cookies are missing"},
		{nil, "the auth_token and ct0 cookies are missing"},
	}
	for _, c := range cases {
		_, err := cleanCookies(c.cookies)
		if err == nil || !strings.HasPrefix(err.Error(), c.want) || !strings.Contains(err.Error(), "copy the cookies again") {
			t.Fatalf("%v: %v", c.cookies, err)
		}
	}
	clean, err := cleanCookies(map[string]string{"Auth_Token": " abc ", "CT0": `"def"`, "TWID": `"u=1001"`, "guest_id": "v1%3A1", "bad;name": "x", "empty": "", "a b": "c"})
	if err != nil {
		t.Fatal(err)
	}
	if encode(t, clean) != `{"auth_token":"abc","ct0":"def","guest_id":"v1%3A1","twid":"u=1001"}` {
		t.Fatalf("clean: %s", encode(t, clean))
	}
	if got := cookieMap("a=1; b=x=y;  ; c="); encode(t, got) != `{"a":"1","b":"x=y"}` {
		t.Fatalf("cookie map: %v", got)
	}
	if !sameCookies(map[string]string{"a": "1"}, map[string]string{"a": "1"}) || sameCookies(map[string]string{"a": "1"}, map[string]string{"a": "2"}) {
		t.Fatal("same cookies")
	}
}

func TestPasscodeAndSecret(t *testing.T) {
	for _, ok := range []string{"0000", "1234"} {
		if !passcodeOK(ok) {
			t.Fatalf("%q refused", ok)
		}
	}
	for _, bad := range []string{"", "123", "12345", "12a4", "١٢٣٤"} {
		if passcodeOK(bad) {
			t.Fatalf("%q taken", bad)
		}
	}
	a, b := scalar(t), scalar(t)
	ra, _ := base64.StdEncoding.DecodeString(a)
	rb, _ := base64.StdEncoding.DecodeString(b)
	k, err := splitSecret(append(append([]byte{}, ra...), rb...))
	if err != nil || k.SecretKey != a || k.SigningKey != b || checkKeys(k) != nil {
		t.Fatalf("raw secret: %+v %v", k, err)
	}
	k, err = splitSecret([]byte(`{"secret_key":"` + a + `","signing_key":"` + b + `"}`))
	if err != nil || k.SecretKey != a || k.SigningKey != b {
		t.Fatalf("json secret: %+v %v", k, err)
	}
	if k, _ := splitSecret(ra); k.SigningKey != "" || checkKeys(k) == nil {
		t.Fatal("half a secret was taken for both keys")
	}

	tm := response.KeyStoreTokenMap{KeyStoreTokenMapJSON: ` {"realms":[]} `, TokenMap: []response.KeyStoreTokenEntry{
		{Key: " ABCD ", Value: response.KeyStoreToken{Token: "t1"}}, {Key: "ef", Value: response.KeyStoreToken{}},
	}}
	cfg, tokens := juiceboxConfig(tm)
	if cfg != `{"realms":[]}` || len(tokens) != 1 || tokens["abcd"] != "t1" {
		t.Fatalf("juicebox config: %q %v", cfg, tokens)
	}
	var resp response.GetPublicKeysResponse
	resp.Data.UserResultsByRestIDs = make([]response.UserResultsWithPublicKeys, 1)
	resp.Data.UserResultsByRestIDs[0].Result.GetPublicKeys.PublicKeysWithTokenMap = []response.PublicKeyWithTokenMap{
		{PublicKeyWithMetadata: response.XChatPublicKeyWithMeta{Version: "100"}, TokenMap: tm},
		{PublicKeyWithMetadata: response.XChatPublicKeyWithMeta{Version: "300"}},
		{PublicKeyWithMetadata: response.XChatPublicKeyWithMeta{Version: "200"}, TokenMap: tm},
	}
	got := passcodeKeys(&resp)
	if len(got) != 2 || got[0].PublicKeyWithMetadata.Version != "200" || got[1].PublicKeyWithMetadata.Version != "100" {
		t.Fatalf("passcode keys: %+v", got)
	}
	if passcodeKeys(&response.GetPublicKeysResponse{}) != nil {
		t.Fatal("keys from nothing")
	}
}

func scalar(t *testing.T) string {
	t.Helper()
	k, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	b, err := k.Bytes()
	if err != nil {
		t.Fatal(err)
	}
	return base64.StdEncoding.EncodeToString(b)
}

func testSession(t *testing.T) session {
	return session{
		Me: meID, Name: "Mo", Handle: "mo",
		Cookies: map[string]string{"auth_token": "abc", "ct0": "def", "twid": "u%3D1001"},
		Keys:    ownKeys{SecretKey: scalar(t), SigningKey: scalar(t), Version: "1"},
	}
}

func TestSessionRoundTrip(t *testing.T) {
	path := filepath.Join(t.TempDir(), "session.json")
	if loadSession(path) != nil {
		t.Fatal("a session where there is no file")
	}
	if err := os.WriteFile(path, []byte("{}"), 0o644); err != nil {
		t.Fatal(err)
	}
	if loadSession(path) != nil {
		t.Fatal("an empty session was taken")
	}
	s := testSession(t)
	s.MaxSeq = "1800"
	s.ConvKeys = map[string]map[string]convKey{dmChat: {"50": {Key: convKeyBytes, CreatedAt: time.UnixMilli(5).UTC()}}}
	s.Tokens = map[string]string{dmChat: "tok"}
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
	if got == nil || got.Me != meID || got.Handle != "mo" || got.Cookies["ct0"] != "def" || got.Keys != s.Keys || got.MaxSeq != "1800" {
		t.Fatalf("loaded: %+v", got)
	}
	if !bytes.Equal(got.ConvKeys[dmChat]["50"].Key, convKeyBytes) || got.Tokens[dmChat] != "tok" {
		t.Fatalf("keys and tokens: %+v", got)
	}
	// A session without its sign-in cookie, or without its keys, is no session.
	bad := s
	bad.Cookies = map[string]string{"ct0": "def"}
	_ = saveSession(path, bad)
	if loadSession(path) != nil {
		t.Fatal("a session without auth_token was taken")
	}
	bad = s
	bad.Keys = ownKeys{}
	_ = saveSession(path, bad)
	if loadSession(path) != nil {
		t.Fatal("a session without keys was taken")
	}
}

func TestKeyStore(t *testing.T) {
	s := testSession(t)
	ks := newKeyStore(s)
	changes := 0
	ks.changed = func() { changes++ }
	ctx := context.Background()
	if _, err := ks.GetConversationKey(ctx, dmChat, "1"); !errors.Is(err, crypto.ErrKeyNotFound) {
		t.Fatal("a key from nowhere")
	}
	if _, err := ks.GetLatestConversationKey(ctx, dmChat); !errors.Is(err, crypto.ErrKeyNotFound) {
		t.Fatal("a latest key from nowhere")
	}
	for _, v := range []string{"900", "1000", "99"} {
		if err := ks.PutConversationKey(ctx, &crypto.ConversationKey{ConversationID: dmChat, KeyVersion: v, Key: []byte(v)}); err != nil {
			t.Fatal(err)
		}
	}
	if k, err := ks.GetLatestConversationKey(ctx, dmChat); err != nil || k.KeyVersion != "1000" {
		t.Fatalf("latest: %+v %v", k, err)
	}
	if !ks.hasKeys(dmChat) || ks.hasKeys(grChat) || ks.hasToken(dmChat) {
		t.Fatal("has keys / token")
	}
	_ = ks.PutConversationToken(ctx, dmChat, "tok")
	_ = ks.PutConversationToken(ctx, dmChat, "tok")
	if tok, err := ks.GetConversationToken(ctx, dmChat); err != nil || tok != "tok" || !ks.hasToken(dmChat) {
		t.Fatalf("token: %q %v", tok, err)
	}
	if changes != 4 {
		t.Fatalf("changes said %d times, want 4 (a token said again is no change)", changes)
	}
	own, err := ks.GetOwnSigningKey(ctx)
	if err != nil || own.SigningKey == nil || own.DecryptKey == nil || own.KeyVersion != "1" || own.UserID != meID {
		t.Fatalf("own key: %+v %v", own, err)
	}
	var out session
	ks.fill(&out)
	if len(out.ConvKeys[dmChat]) != 3 || out.Tokens[dmChat] != "tok" || out.Keys != s.Keys {
		t.Fatalf("fill: %+v", out)
	}
	if err := ks.PutConversationKey(ctx, &crypto.ConversationKey{ConversationID: dmChat}); err == nil {
		t.Fatal("an empty key was kept")
	}
}

func TestWords(t *testing.T) {
	status := func(code int) error { return fmt.Errorf("x: HTTP %d: nope", code) }
	if statusOf(status(429)) != 429 || statusOf(errors.New("plain")) != 0 || statusOf(nil) != 0 {
		t.Fatal("status")
	}
	if !rejected(status(401)) || !rejected(fmt.Errorf("x: %w", twittermeow.ErrCouldNotAuthenticate)) || !rejected(twittermeow.ErrCSRFMismatch) {
		t.Fatal("a rejected session was not seen as one")
	}
	if rejected(status(403)) || rejected(status(500)) || rejected(errors.New("dial tcp")) {
		t.Fatal("a passing trouble was taken for the session ending")
	}
	if endedWords(twittermeow.ErrAccountTemporarilyLocked) != wordsLocked || endedWords(status(401)) != wordsSignedOut {
		t.Fatal("ended words")
	}
	if got := signInWords(status(401)).Error(); !strings.Contains(got, "did not take those cookies") {
		t.Fatalf("sign in 401: %s", got)
	}
	for err, want := range map[error]string{
		status(429): "too many requests",
		status(418): "418",
		status(503): "problem of its own",
		fmt.Errorf("get: %w", crypto.ErrKeyNotFound):                   "key is not on this device",
		fmt.Errorf("x: %w", twittermeow.ErrXChatWebsocketNotConnected): "Not connected",
		context.DeadlineExceeded:                                       "in time",
	} {
		if got := plain(err).Error(); !strings.Contains(got, want) {
			t.Fatalf("%v: %s", err, got)
		}
	}
	if err := errors.New("nothing to send"); plain(err) != err {
		t.Fatal("words already plain were changed")
	}
	if got := passcodeWords(juiceboxgo.ErrInvalidPin(2)).Error(); !strings.Contains(got, "2 tries left") {
		t.Fatalf("wrong passcode: %s", got)
	}
	if got := passcodeWords(juiceboxgo.ErrInvalidPin(1)).Error(); !strings.Contains(got, "1 try left") {
		t.Fatalf("wrong passcode, last: %s", got)
	}
	if got := passcodeWords(juiceboxgo.ErrInvalidPin(0)).Error(); !strings.Contains(got, "locked") {
		t.Fatalf("locked: %s", got)
	}
	if passcodeWords(fmt.Errorf("x: %w", juiceboxgo.ErrNotRegistered)).Error() != wordsNoPasscode {
		t.Fatal("no passcode")
	}
}

// --- converting -----------------------------------------------------------------------------------------------------

func TestIDs(t *testing.T) {
	if normalizeChat(" 1001-2002 ") != dmChat || normalizeChat(grChat) != grChat || restChat(dmChat) != "1001-2002" || restChat(grChat) != grChat {
		t.Fatal("normalize")
	}
	if ids, ok := dmMembers("1001-2002"); !ok || ids[0] != meID || ids[1] != annID {
		t.Fatalf("members: %v", ids)
	}
	if _, ok := dmMembers(grChat); ok {
		t.Fatal("a group has two members")
	}
	if compareSeq("10", "9") <= 0 || compareSeq("009", "9") != 0 || compareSeq("", "1") >= 0 || compareSeq(maxSeqAll, "1850") <= 0 {
		t.Fatal("compare")
	}
}

func inboxItem(t *testing.T) *response.XChatInboxItem {
	return &response.XChatInboxItem{
		ConversationDetail: response.XChatConversationDetail{
			ConversationID: dmChat,
			ParticipantsResults: []response.XChatUserResult{
				{RestID: meID},
				{RestID: annID, Result: &response.XChatUser{RestID: annID, Core: &response.XChatUserCore{Name: "Ann Lee", ScreenName: "annlee"}, Avatar: &response.XChatUserAvatar{ImageURL: "https://pbs.twimg.com/profile_images/1/a_normal.jpg"}}},
			},
		},
		LatestMessageEvents: []string{evt(t, dmChat, "1800", annID, 1700000001000, text("hello"), false)},
	}
}

func TestChatOf(t *testing.T) {
	item := inboxItem(t)
	if tr := itemTrusted(item); tr == nil || !*tr {
		t.Fatal("trusted")
	}
	latest := &types.Message{ID: "1800", SequenceID: "1800", Time: "1700000001000", MessageData: types.MessageData{SenderID: annID, Text: "hello"}}
	var asked []string
	got := encode(t, chatOf(meID, item, nil, "", inboxSummary{latest: latest, unread: 1}, func(p person) string {
		asked = append(asked, p.ID+" "+avatarURL(p.Pic))
		return "/d/avatars/aa"
	}))
	want := `{"id":"1001:2002","title":"Ann Lee","group":false,"members":[{"id":"2002","name":"Ann Lee"}],"avatar":"/d/avatars/aa","unread":1,"last":1700000001000,"snippet":"hello","snippet_mine":false}`
	if got != want {
		t.Fatalf("chat between two:\n got %s\nwant %s", got, want)
	}
	if len(asked) != 1 || asked[0] != annID+" https://pbs.twimg.com/profile_images/1/a_200x200.jpg" {
		t.Fatalf("avatar asked of %v", asked)
	}

	// A two-person chat X lists with nobody in it: the id names both, and [who] names them.
	bare := &response.XChatInboxItem{ConversationDetail: response.XChatConversationDetail{ConversationID: dmChat}}
	who := func(p person) person {
		if p.ID == annID {
			p.Name = "Ann Lee"
		}
		return p
	}
	if c := chatOf(meID, bare, who, "", inboxSummary{}, nil); c.Title != "Ann Lee" || len(c.Members) != 1 || c.Members[0].ID != annID || c.SnippetMine != nil {
		t.Fatalf("bare: %+v", c)
	}

	group := &response.XChatInboxItem{ConversationDetail: response.XChatConversationDetail{
		ConversationID: grChat,
		GroupMetadata:  &response.XChatGroupMetadata{UpdatedAtMsec: "1700000005000"},
		GroupMembersResults: []response.XChatUserResult{
			{RestID: annID, Result: &response.XChatUser{Core: &response.XChatUserCore{Name: "Ann Lee"}}},
			{RestID: meID}, {RestID: benID, Result: &response.XChatUser{Core: &response.XChatUserCore{ScreenName: "ben"}}},
		},
	}}
	got = encode(t, chatOf(meID, group, nil, "", inboxSummary{}, func(person) string { t.Fatal("a group has no one picture"); return "" }))
	want = `{"id":"` + grChat + `","title":"Ann Lee, ben","group":true,"members":[{"id":"2002","name":"Ann Lee"},{"id":"3003","name":""}],"avatar":null,"unread":0,"last":1700000005000}`
	if got != want {
		t.Fatalf("group:\n got %s\nwant %s", got, want)
	}
	if c := chatOf(meID, group, nil, "Planning", inboxSummary{}, nil); c.Title != "Planning" {
		t.Fatalf("named group: %q", c.Title)
	}
	f := fields(chatOf(meID, group, nil, "", inboxSummary{}, nil))
	if f["id"] != grChat || f["avatar"] != nil || f["group"] != true {
		t.Fatalf("fields: %v", f)
	}
}

func TestDecryptGroupName(t *testing.T) {
	sealedName, err := crypto.SecretboxEncrypt([]byte("Planning"), convKeyBytes)
	if err != nil {
		t.Fatal(err)
	}
	b64 := base64.StdEncoding.EncodeToString(sealedName)
	ctx := context.Background()
	keys := keysFor(grChat)
	latest := func(ctx context.Context, c, _ string) (*crypto.ConversationKey, error) { return keys(ctx, c, "50") }
	if got := decryptGroupName(ctx, grChat, "50:"+b64, keys, latest); got != "Planning" {
		t.Fatalf("versioned: %q", got)
	}
	if got := decryptGroupName(ctx, grChat, b64, keys, latest); got != "Planning" {
		t.Fatalf("latest key: %q", got)
	}
	if got := decryptGroupName(ctx, grChat, "51:"+b64, keys, latest); got != "" {
		t.Fatalf("a missing key gave %q", got)
	}
	if got := decryptGroupName(ctx, grChat, "Book club", keys, latest); got != "Book club" {
		t.Fatalf("plain: %q", got)
	}
}

func TestMessageOfAndMedia(t *testing.T) {
	msg := &types.Message{
		ID: "1850", SequenceID: "1850", Time: "1700000002000", ConversationKeyVersion: "50",
		MessageData: types.MessageData{
			SenderID: annID, Text: "look", ConversationKeyVersion: "50",
			ReplyData: types.ReplyData{ID: "1800", Text: "hello"},
			Attachments: []*types.Attachment{
				{Photo: &types.AttachmentInfo{MediaHashKey: "hk1", Filename: "cat.png", FilesizeBytes: 10, OriginalInfo: types.OriginalInfo{Width: 3, Height: 4}}},
				{Video: &types.AttachmentInfo{MediaHashKey: "hk2", AudioOnly: true}},
				{Video: &types.AttachmentInfo{MediaURLHTTPS: "https://video.twimg.com/x.jpg", VideoInfo: types.VideoInfo{Variants: []types.Variant{{Bitrate: 1, URL: "https://video.twimg.com/lo.mp4"}, {Bitrate: 9, URL: "https://video.twimg.com/hi.mp4"}}}}},
				{Tweet: &types.AttachmentTweet{ExpandedURL: "https://x.com/a/status/1"}},
				{Photo: &types.AttachmentInfo{}},
			},
		},
	}
	got := encode(t, messageOf(meID, dmChat, false, msg, func(id string) string { return map[string]string{annID: "Ann Lee"}[id] }))
	want := `{"chat":"1001:2002","group":false,"id":"1850","from":"2002","name":"Ann Lee","mine":false,"ts":1700000002000,"text":"look\nhttps://x.com/a/status/1",` +
		`"media":[{"pointer":{"conv":"1001:2002","hash":"hk1","key_version":"50","kind":"image"},"mime":"image/png","name":"cat.png","size":10,"width":3,"height":4},` +
		`{"pointer":{"conv":"1001:2002","hash":"hk2","key_version":"50","kind":"audio"},"mime":"audio/mp4","name":"voice_message","size":0,"width":0,"height":0},` +
		`{"pointer":{"url":"https://video.twimg.com/hi.mp4","kind":"video"},"mime":"video/mp4","name":"video","size":0,"width":0,"height":0}],` +
		`"quote":{"id":"1800","text":"hello"}}`
	if got != want {
		t.Fatalf("message:\n got %s\nwant %s", got, want)
	}
	own := messageOf(meID, grChat, true, &types.Message{SequenceID: "1851", MessageData: types.MessageData{SenderID: meID, Text: "ok"}}, nil)
	if !own.Mine || own.TS == 0 || own.Group != true || len(own.Media) != 0 {
		t.Fatalf("own: %+v", own)
	}
}

func TestParsePage(t *testing.T) {
	ctx := context.Background()
	react := func(target, emoji string) *payload.MessageEntryContents {
		return &payload.MessageEntryContents{ReactionAdd: &payload.MessageReactionAdd{MessageSequenceId: ptr.Ptr(target), Emoji: ptr.Ptr(emoji)}}
	}
	unreact := func(target, emoji string) *payload.MessageEntryContents {
		return &payload.MessageEntryContents{ReactionRemove: &payload.MessageReactionRemove{MessageSequenceId: ptr.Ptr(target), Emoji: ptr.Ptr(emoji)}}
	}
	edit := &payload.MessageEntryContents{MessageEdit: &payload.MessageEdit{MessageSequenceId: ptr.Ptr("1802"), UpdatedText: ptr.Ptr("second, edited")}}
	del := &payload.MessageEvent{SequenceId: ptr.Ptr("1809"), ConversationId: ptr.Ptr(dmChat), Detail: &payload.MessageEventDetail{
		MessageDeleteEvent: &payload.MessageDeleteEvent{SequenceIds: []string{"1803"}},
	}}
	other := evt(t, "1001:9999", "1804", annID, 1700000004000, text("elsewhere"), false)
	page := []string{
		evt(t, dmChat, "1806", annID, 1700000006000, react("1801", "👍"), true),
		evt(t, dmChat, "1801", annID, 1700000001000, text("first"), true),
		evt(t, dmChat, "1802", meID, 1700000002000, text("second"), false),
		evt(t, dmChat, "1803", annID, 1700000003000, text("taken back"), true),
		evt(t, dmChat, "1805", meID, 1700000005000, react("1802", "❤️"), true),
		evt(t, dmChat, "1807", meID, 1700000007000, unreact("1802", "❤️"), true),
		evt(t, dmChat, "1808", meID, 1700000008000, edit, true),
		encodeEvent(t, del),
		evt(t, dmChat, "1790", annID, 1700000000000, text("sealed with a key not here"), true),
		other,
		evt(t, dmChat, "1900", annID, 1700000009000, text("at or after before"), false),
		"not base64!",
	}
	// The key of the "1790" message is another version: seal it again with a key under version 51.
	page[8] = func() string {
		e, _ := twittermeow.DecodeMessageEvent(page[8])
		e.Detail.MessageCreateEvent.ConversationKeyVersion = ptr.Ptr("51")
		return encodeEvent(t, e)
	}()
	res := parsePage(ctx, meID, dmChat, false, page, "1900", keysFor(dmChat), func(id string) string { return map[string]string{annID: "Ann Lee"}[id] })
	if res.oldest != "1790" || res.unread != 1 {
		t.Fatalf("oldest %q, unread %d", res.oldest, res.unread)
	}
	got := encode(t, res.messages)
	want := `[{"chat":"1001:2002","group":false,"id":"1801","from":"2002","name":"Ann Lee","mine":false,"ts":1700000001000,"text":"first","media":[],"reactions":[{"from":"2002","emoji":"👍"}]},` +
		`{"chat":"1001:2002","group":false,"id":"1802","from":"1001","name":"","mine":true,"ts":1700000002000,"text":"second, edited","media":[]}]`
	if got != want {
		t.Fatalf("page:\n got %s\nwant %s", got, want)
	}
	if empty := parsePage(ctx, meID, dmChat, false, nil, "", keysFor(dmChat), nil); empty.messages == nil || len(empty.messages) != 0 || empty.oldest != "" {
		t.Fatalf("empty page: %+v", empty)
	}
}

func TestCollector(t *testing.T) {
	c := &collector{me: meID}
	c.add(&types.Message{SequenceID: "10", MessageData: types.MessageData{SenderID: annID}})
	c.add(&types.ConversationRead{SenderID: meID, LastReadEventID: "10"})
	c.add(&types.Message{SequenceID: "12", MessageData: types.MessageData{SenderID: annID, Text: "new"}})
	c.add(&types.Message{SequenceID: "11", MessageData: types.MessageData{SenderID: annID}})
	c.add(&types.ConversationRead{SenderID: annID, LastReadEventID: "12"})
	s := c.summary()
	if s.unread != 2 || s.latest.SequenceID != "12" || s.newest != "12" {
		t.Fatalf("summary: %+v", s)
	}
	// Writing in a chat is reading it.
	c.add(&types.Message{SequenceID: "13", MessageData: types.MessageData{SenderID: meID}})
	if s := c.summary(); s.unread != 0 || s.latest.SequenceID != "13" {
		t.Fatalf("after answering: %+v", s)
	}
}

func TestPointer(t *testing.T) {
	p, err := parsePointer(json.RawMessage(`{"conv":"1001-2002","hash":"hk","key_version":"50","kind":"image"}`))
	if err != nil || p.Conv != dmChat || p.Hash != "hk" || p.Version != "50" {
		t.Fatalf("sealed: %+v %v", p, err)
	}
	p, err = parsePointer(json.RawMessage(`"{\"url\":\"https://pbs.twimg.com/dm/1.jpg\",\"kind\":\"image\"}"`))
	if err != nil || p.URL != "https://pbs.twimg.com/dm/1.jpg" {
		t.Fatalf("string: %+v %v", p, err)
	}
	for _, bad := range []string{`{}`, `null`, `{"url":"http://pbs.twimg.com/x"}`, `{"url":"https://evil.example/x"}`, `{"url":"https://twimg.com.evil.example/x"}`, `{"conv":"1:2/../x","hash":"h"}`, `"nonsense"`, ``} {
		if _, err := parsePointer(json.RawMessage(bad)); err == nil {
			t.Fatalf("%q was taken for a file", bad)
		}
	}
	if avatarName(person{ID: annID, Pic: "https://pbs.twimg.com/a_normal.jpg"}) == avatarName(person{ID: benID, Pic: "https://pbs.twimg.com/a_normal.jpg"}) {
		t.Fatal("two people share a picture name")
	}
	if !publicPicture("https://pbs.twimg.com/a.jpg") || publicPicture("https://x.com/a.jpg") || publicPicture("http://pbs.twimg.com/a.jpg") {
		t.Fatal("public picture")
	}
}

func TestMemoryAndReply(t *testing.T) {
	seen.reset()
	defer seen.reset()
	seen.noteChat(dmChat, chatNote{})
	if !seen.noteMsg("1850", msgNote{chat: dmChat, from: annID, text: "send it?", clientID: "uuid-1"}) || seen.noteMsg("1850", msgNote{chat: dmChat, from: annID, text: "send it??", clientID: "uuid-1"}) {
		t.Fatal("first and second sightings")
	}
	if n, _ := seen.chat(dmChat); n.newest != "1850" {
		t.Fatalf("newest: %+v", n)
	}
	seen.meet(person{ID: annID, Name: "Ann Lee", Pic: "p"})
	seen.meet(person{ID: annID, Handle: "annlee"})
	if p, _ := seen.person(annID); p.Name != "Ann Lee" || p.Handle != "annlee" || p.Pic != "p" {
		t.Fatalf("a later sighting lost what was known: %+v", p)
	}
	r := replyTo(quote{ID: "1850"})
	if r == nil || ptr.Val(r.ReplyingToMessageId) != "uuid-1" || ptr.Val(r.ReplyingToMessageSequenceId) != "1850" || ptr.Val(r.MessageText) != "send it??" || ptr.Val(r.SenderId) != 2002 || ptr.Val(r.SenderDisplayName) != "Ann Lee" {
		t.Fatalf("reply to a message seen: %+v", r)
	}
	r = replyTo(quote{ID: "1700", Author: benID, Text: "t"})
	if r == nil || ptr.Val(r.ReplyingToMessageId) != "1700" || ptr.Val(r.SenderId) != 3003 || ptr.Val(r.MessageText) != "t" {
		t.Fatalf("reply from what the app sent: %+v", r)
	}
	if replyTo(quote{}) != nil {
		t.Fatal("a reply to nothing")
	}
	if !seen.newsOf(person{ID: annID, Name: "Ann Lee"}) || seen.newsOf(person{ID: annID, Name: "Ann Lee"}) {
		t.Fatal("a name is said once")
	}
}

// --- the protocol, driven against a stand-in for X ------------------------------------------------------------------

// lockedBuffer is standard output, as the tests read it.
type lockedBuffer struct {
	sync.Mutex
	b bytes.Buffer
}

func (l *lockedBuffer) Write(p []byte) (int, error) {
	l.Lock()
	defer l.Unlock()
	return l.b.Write(p)
}

func (l *lockedBuffer) lines() []map[string]any {
	l.Lock()
	defer l.Unlock()
	var out []map[string]any
	for _, line := range strings.Split(strings.TrimSpace(l.b.String()), "\n") {
		var m map[string]any
		if json.Unmarshal([]byte(line), &m) == nil {
			out = append(out, m)
		}
	}
	return out
}

// fakeX answers the library's requests as X would: each GraphQL operation by its name.
type fakeX struct {
	sync.Mutex
	answers map[string]string
	asked   []string
	bodies  map[string]string
}

func (f *fakeX) RoundTrip(r *http.Request) (*http.Response, error) {
	op := r.URL.Host + r.URL.Path
	if i := strings.LastIndex(r.URL.Path, "/"); i >= 0 {
		op = r.URL.Path[i+1:]
	}
	var body []byte
	if r.Body != nil {
		body, _ = io.ReadAll(r.Body)
	}
	f.Lock()
	f.asked = append(f.asked, op)
	if f.bodies == nil {
		f.bodies = map[string]string{}
	}
	f.bodies[op] = string(body) + "?" + r.URL.RawQuery
	answer, ok := f.answers[op]
	if r.URL.Host == "pbs.twimg.com" {
		answer, ok = pngBytes(), true
	}
	f.Unlock()
	status := http.StatusOK
	if !ok {
		status, answer = http.StatusNotFound, `{"errors":[{"code":34,"message":"not here"}]}`
	}
	return &http.Response{StatusCode: status, Header: http.Header{}, Body: io.NopCloser(strings.NewReader(answer)), Request: r}, nil
}

func (f *fakeX) wasAsked(op string) bool {
	f.Lock()
	defer f.Unlock()
	for _, a := range f.asked {
		if a == op {
			return true
		}
	}
	return false
}

func pngBytes() string {
	var b bytes.Buffer
	_ = png.Encode(&b, image.NewGray(image.Rect(0, 0, 2, 2)))
	return b.String()
}

// stage signs a test account in, its client speaking to [f], and captures standard output.
func stage(t *testing.T, f *fakeX) (*account, *lockedBuffer) {
	t.Helper()
	seen.reset()
	buf := &lockedBuffer{}
	outLock.Lock()
	out = json.NewEncoder(buf)
	out.SetEscapeHTML(false)
	outLock.Unlock()
	s := testSession(t)
	s.ConvKeys = map[string]map[string]convKey{dmChat: {"50": {Key: convKeyBytes, CreatedAt: time.Now()}}}
	s.Tokens = map[string]string{dmChat: "tok"}
	a := newAccount(s, nil)
	a.cli.HTTP.Transport = f
	mu.Lock()
	acct, connected = a, false
	mu.Unlock()
	t.Cleanup(func() {
		mu.Lock()
		if acct == a {
			acct = nil
		}
		mu.Unlock()
		a.stop()
	})
	return a, buf
}

func users(ids ...string) string {
	names := map[string][2]string{annID: {"Ann Lee", "annlee"}, benID: {"Ben", "ben"}, meID: {"Mo", "mo"}}
	var results []string
	for _, id := range ids {
		n := names[id]
		results = append(results, `{"id":"`+id+`","member_results":{"rest_id":"`+id+`","result":{"rest_id":"`+id+`","core":{"name":"`+n[0]+`","screen_name":"`+n[1]+`"},"avatar":{"image_url":"https://pbs.twimg.com/profile_images/`+id+`/p_normal.jpg"}}}}`)
	}
	return `{"data":{"get_member_results":{"results":[` + strings.Join(results, ",") + `]}}}`
}

func waitFor(t *testing.T, buf *lockedBuffer, what string, ok func([]map[string]any) bool) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		if ok(buf.lines()) {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("never saw %s; output: %v", what, buf.lines())
}

func TestDoWithoutSession(t *testing.T) {
	mu.Lock()
	acct = nil
	mu.Unlock()
	if _, err := do(request{Op: "chats"}); err != errNotLinked {
		t.Fatalf("chats signed out: %v", err)
	}
	if _, err := do(request{Op: "edit"}); err == nil || !strings.Contains(err.Error(), `does not know "edit"`) {
		t.Fatalf("unknown op: %v", err)
	}
	if got, _ := do(request{Op: "status"}); encode(t, got) != `{"connected":false,"handle":"","linked":false,"me":"","name":""}` {
		t.Fatalf("status: %s", encode(t, got))
	}
	// Nothing reaches X before the cookies and the passcode are there.
	if _, err := do(request{Op: "sign_in", Cookies: map[string]string{"ct0": "x"}, Passcode: "1234"}); err == nil || !strings.Contains(err.Error(), "auth_token cookie is missing") {
		t.Fatalf("no auth_token: %v", err)
	}
	if _, err := do(request{Op: "sign_in", Cookies: map[string]string{"auth_token": "a", "ct0": "x"}}); err == nil || err.Error() != wordsNeedPasscode {
		t.Fatalf("no passcode: %v", err)
	}
	if _, err := do(request{Op: "sign_in", Cookies: map[string]string{"auth_token": "a", "ct0": "x"}, Passcode: "12"}); err == nil || !strings.Contains(err.Error(), "four digits") {
		t.Fatalf("short passcode: %v", err)
	}
}

func TestChatsAgainstStandIn(t *testing.T) {
	item := inboxItem(t)
	// The newest message is sealed with the chat's key; the person read up to an older one.
	item.LatestMessageEvents = append(item.LatestMessageEvents, evt(t, dmChat, "1801", annID, 1700000002000, text("sealed hello"), true))
	readEvt := &payload.MessageEvent{SequenceId: ptr.Ptr("1799"), SenderId: ptr.Ptr(meID), ConversationId: ptr.Ptr(dmChat), CreatedAtMsec: ptr.Ptr("1700000000500"),
		Detail: &payload.MessageEventDetail{MarkConversationReadEvent: &payload.MarkConversationReadEvent{SeenUntilSequenceId: ptr.Ptr("1799")}}}
	item.LatestReadEventsPerParticipant = []response.XChatParticipantReadEvent{{ParticipantID: response.XChatParticipantID{RestID: meID}, LatestMarkConversationReadEvent: encodeEvent(t, readEvt)}}
	pageJSON, _ := json.Marshal(map[string]any{"data": map[string]any{"get_initial_chat_page": response.XChatInboxPage{
		Items: []response.XChatInboxItem{*item}, MaxUserSequenceID: ptr.Ptr("1801"), InboxCursor: response.XChatInboxCursor{PullFinished: true},
	}}})
	f := &fakeX{answers: map[string]string{"GetInitialXChatPageQuery": string(pageJSON), "GetUsersByIdsForXChat": users(annID, meID)}}
	a, buf := stage(t, f)

	got, err := do(request{ID: 4, Op: "chats"})
	if err != nil {
		t.Fatal(err)
	}
	list := got.([]chatOut)
	if len(list) != 1 {
		t.Fatalf("chats: %s", encode(t, list))
	}
	c := list[0]
	if c.ID != dmChat || c.Title != "Ann Lee" || c.Group || c.Unread != 2 || c.Last != 1700000002000 || c.Snippet != "sealed hello" || c.SnippetMine == nil || *c.SnippetMine {
		t.Fatalf("chat: %s", encode(t, c))
	}
	if c.Avatar == nil || filepath.Dir(*c.Avatar) != avatarDir() {
		t.Fatalf("avatar: %v", c.Avatar)
	}
	if _, err := os.Stat(*c.Avatar); err != nil {
		t.Fatalf("avatar file: %v", err)
	}
	if a.getMaxSeq() != "1801" {
		t.Fatalf("max seq %q", a.getMaxSeq())
	}
	waitFor(t, buf, "the chat event", func(lines []map[string]any) bool {
		for _, l := range lines {
			if l["ev"] == "chat" && l["id"] == dmChat && l["title"] == "Ann Lee" {
				return true
			}
		}
		return false
	})
	// No message events from a listing.
	for _, l := range buf.lines() {
		if l["ev"] == "message" {
			t.Fatalf("a listing said a message: %v", l)
		}
	}
}

func TestHistoryAgainstStandIn(t *testing.T) {
	events := []string{
		evt(t, dmChat, "1801", annID, 1700000001000, text("first"), true),
		evt(t, dmChat, "1802", meID, 1700000002000, text("second"), true),
		evt(t, dmChat, "1850", annID, 1700000003000, text("the anchor itself"), true),
	}
	pageJSON, _ := json.Marshal(map[string]any{"data": map[string]any{"get_conversation_page": response.XChatConversationPage{EncodedMessageEvents: events, HasMore: true}}})
	f := &fakeX{answers: map[string]string{"GetConversationPageQuery": string(pageJSON), "GetUsersByIdsForXChat": users(annID, meID)}}
	_, buf := stage(t, f)

	got, err := do(request{ID: 5, Op: "history", Chat: "1001-2002", Before: "1850"})
	if err != nil {
		t.Fatal(err)
	}
	res := got.(map[string]any)
	msgs := res["messages"].([]messageOut)
	if res["more"] != true || len(msgs) != 2 || msgs[0].ID != "1801" || msgs[0].Name != "Ann Lee" || msgs[1].Text != "second" || !msgs[1].Mine {
		t.Fatalf("history: %s", encode(t, res))
	}
	f.Lock()
	q := f.bodies["GetConversationPageQuery"]
	f.Unlock()
	if !strings.Contains(q, url.QueryEscape(`"conversation_id":"1001:2002"`)) || !strings.Contains(q, url.QueryEscape(`"min_local_sequence_id":"1850"`)) {
		t.Fatalf("asked X for: %s", q)
	}
	if _, err := do(request{Op: "history", Chat: dmChat, Before: "not-an-id"}); err == nil {
		t.Fatal("a non-numeric anchor was taken")
	}
	waitFor(t, buf, "a name event for Ann", func(lines []map[string]any) bool {
		for _, l := range lines {
			if l["ev"] == "name" && l["id"] == annID && l["handle"] == "annlee" {
				return true
			}
		}
		return false
	})
}

func TestSendAgainstStandIn(t *testing.T) {
	answerEvt := encodeEvent(t, &payload.MessageEvent{SequenceId: ptr.Ptr("1900"), ConversationId: ptr.Ptr(dmChat), CreatedAtMsec: ptr.Ptr("1700000009000"),
		Detail: &payload.MessageEventDetail{MessageCreateEvent: &payload.MessageCreateEvent{}}})
	sendJSON := `{"data":{"xchat_send_create_message_event":{"encoded_message_event":"` + answerEvt + `"}}}`
	f := &fakeX{answers: map[string]string{"SendMessageMutation": sendJSON}}
	a, _ := stage(t, f)
	seen.noteChat(dmChat, chatNote{})
	seen.noteMsg("1850", msgNote{chat: dmChat, from: annID, text: "send it?", clientID: "uuid-1"})

	got, err := do(request{ID: 6, Op: "send", To: "1001-2002", Text: "here", Quote: &quote{ID: "1850"}})
	if err != nil {
		t.Fatal(err)
	}
	if encode(t, got) != `{"id":"1900","ts":1700000009000}` {
		t.Fatalf("send: %s", encode(t, got))
	}
	f.Lock()
	body := f.bodies["SendMessageMutation"]
	f.Unlock()
	if !strings.Contains(body, `"conversation_token":"tok"`) || !strings.Contains(body, `"conversation_id":"1001:2002"`) || strings.Contains(body, "here") {
		t.Fatalf("the message was not sent sealed with the chat's token: %s", body)
	}
	if n, ok := seen.msg("1900"); !ok || n.from != meID || n.text != "here" {
		t.Fatalf("not remembered: %+v", n)
	}
	// The message as X carries it opens with the chat's key back to the words sent and the quote.
	var sent struct {
		Variables struct {
			Encoded string `json:"encoded_message_create_event"`
		} `json:"variables"`
	}
	if err := json.Unmarshal([]byte(strings.SplitN(body, "?", 2)[0]), &sent); err != nil || sent.Variables.Encoded == "" {
		t.Fatalf("send body: %v %s", err, body)
	}
	raw, _ := base64.StdEncoding.DecodeString(sent.Variables.Encoded)
	var mce payload.MessageCreateEvent
	if err := payload.Decode(raw, &mce); err != nil {
		t.Fatal(err)
	}
	entry, version, err := decodeEntry(context.Background(), dmChat, &mce, a.keys.GetConversationKey)
	if err != nil || version != "50" || ptr.Val(entry.Message.MessageText) != "here" || ptr.Val(entry.Message.ReplyingToPreview.ReplyingToMessageSequenceId) != "1850" {
		t.Fatalf("sealed message: %v %q %+v", err, version, entry)
	}

	if _, err := do(request{Op: "send", To: dmChat}); err == nil || err.Error() != "nothing to send" {
		t.Fatalf("empty send: %v", err)
	}
	if _, err := do(request{Op: "send_media", To: dmChat, Path: filepath.Join(t.TempDir(), "none.png")}); err == nil || !strings.Contains(err.Error(), "could not be opened") {
		t.Fatalf("missing file: %v", err)
	}
	doc := filepath.Join(t.TempDir(), "notes.pdf")
	_ = os.WriteFile(doc, []byte("%PDF"), 0o600)
	if _, err := do(request{Op: "send_media", To: dmChat, Path: doc}); err == nil || !strings.Contains(err.Error(), "only pictures") {
		t.Fatalf("a PDF: %v", err)
	}
	if f.wasAsked("InitializeXChatMediaUpload") {
		t.Fatal("a refused file reached X")
	}
}

func TestLiveEvents(t *testing.T) {
	f := &fakeX{answers: map[string]string{"GetUsersByIdsForXChat": users(annID)}}
	a, buf := stage(t, f)
	seen.noteChat(dmChat, chatNote{})
	ctx := context.Background()
	msg := &types.Message{ID: "1900", SequenceID: "1900", ConversationID: dmChat, Time: "1700000009000", MessageData: types.MessageData{SenderID: annID, Text: "live"}}
	if !a.onEvent(ctx, msg) || !a.onEvent(ctx, msg) {
		t.Fatal("an event was refused")
	}
	a.onEvent(ctx, (*types.MessageReactionCreate)(&types.MessageReaction{ConversationID: dmChat, MessageID: "1900", SenderID: annID, EmojiReaction: "😂"}))
	a.onEvent(ctx, &types.ConversationRead{ConversationID: dmChat, SenderID: annID, LastReadEventID: "1900", Time: "1700000009500"})
	a.onEvent(ctx, (*types.MessageEdit)(&types.Message{ConversationID: dmChat, MessageData: types.MessageData{ID: "1900", Text: "live!"}}))
	a.onEvent(ctx, &types.MessageDelete{ConversationID: dmChat, Messages: []types.MessagesDeleted{{MessageID: "1900"}}})
	// While a chat is being read for the inbox, its events are the collector's, not the app's.
	col := &collector{me: meID}
	a.onEvent(context.WithValue(ctx, collectKey{}, col), &types.Message{SequenceID: "1901", ConversationID: dmChat, MessageData: types.MessageData{SenderID: annID}})
	if col.summary().unread != 1 {
		t.Fatal("the collector missed its message")
	}
	waitFor(t, buf, "the live events", func(lines []map[string]any) bool {
		var kinds []string
		for _, l := range lines {
			if ev, _ := l["ev"].(string); ev != "" && ev != "name" {
				kinds = append(kinds, ev)
			}
		}
		return strings.Join(kinds, ",") == "message,reaction,receipt,edited,deleted"
	})
	for _, l := range buf.lines() {
		switch l["ev"] {
		case "message":
			if l["id"] != "1900" || l["chat"] != dmChat || l["text"] != "live" || l["mine"] != false {
				t.Fatalf("message: %v", l)
			}
		case "reaction":
			if l["target"] != "1900" || l["emoji"] != "😂" || l["remove"] != false {
				t.Fatalf("reaction: %v", l)
			}
		case "receipt":
			if l["id"] != "1900" || l["kind"] != "read" || l["ts"] != float64(1700000009500) {
				t.Fatalf("receipt: %v", l)
			}
		case "edited":
			if l["target"] != "1900" || l["text"] != "live!" {
				t.Fatalf("edited: %v", l)
			}
		}
	}
	if a.getMaxSeq() != "1900" {
		t.Fatalf("max seq %q", a.getMaxSeq())
	}
}
