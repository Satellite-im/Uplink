package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"go.mau.fi/util/jsontime"

	"go.mau.fi/mautrix-linkedin/pkg/linkedingo"
)

const (
	meProfile = "ACoAAme"
	meURN     = participantPrefix + meProfile
	annURN    = participantPrefix + "ACoAAann"
	benURN    = participantPrefix + "ACoAAben"
	chatURN   = "urn:li:msg_conversation:(urn:li:fsd_profile:ACoAAme,2-thread==)"
	msgURN    = "urn:li:msg_message:(urn:li:fsd_profile:ACoAAme,2-msg1==)"
)

func at(ms int64) jsontime.UnixMilli { return jsontime.UM(time.UnixMilli(ms)) }

func member(urn, first, last, profileURL string, pic *linkedingo.VectorImage) linkedingo.MessagingParticipant {
	return linkedingo.MessagingParticipant{
		EntityURN: linkedingo.NewURN(urn),
		ParticipantType: linkedingo.ParticipantType{Member: &linkedingo.MemberParticipantInfo{
			FirstName:      linkedingo.AttributedText{Text: first},
			LastName:       linkedingo.AttributedText{Text: last},
			ProfileURL:     profileURL,
			ProfilePicture: pic,
		}},
	}
}

var (
	me  = member(meURN, "Mo", "Example", "https://www.linkedin.com/in/mo-example", nil)
	ann = member(annURN, "Ann", "Lee", "https://www.linkedin.com/in/ann-lee-123/", &linkedingo.VectorImage{
		RootURL: "https://media.licdn.com/dms/image/abc/profile-displayphoto-shrink_",
		Artifacts: []linkedingo.VectorArtifact{
			{Width: 100, Height: 100, FileIdentifyingURLPathSegment: "100_100/0/1?e=1&t=x"},
			{Width: 200, Height: 200, FileIdentifyingURLPathSegment: "200_200/0/1?e=1&t=x"},
			{Width: 800, Height: 800, FileIdentifyingURLPathSegment: "800_800/0/1?e=1&t=x"},
		},
	})
	ben = member(benURN, "Ben", "Okoro", "https://www.linkedin.com/in/ACoAAben", nil)
)

func encode(t *testing.T, v any) string {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func TestParseRequest(t *testing.T) {
	r, err := parseRequest([]byte(`{"id":2,"op":"sign_in","cookies":{"li_at":"AQED","JSESSIONID":"\"ajax:1\""}}`))
	if err != nil || r.ID != 2 || r.Op != "sign_in" || r.Cookies["li_at"] != "AQED" || r.Cookies["JSESSIONID"] != `"ajax:1"` {
		t.Fatalf("sign_in: %+v %v", r, err)
	}
	r, err = parseRequest([]byte(`{"id":5,"op":"history","chat":"` + chatURN + `","before":"` + msgURN + `","before_ts":1700000000000}`))
	if err != nil || r.Chat != chatURN || r.Before != msgURN || r.BeforeTS != 1700000000000 {
		t.Fatalf("history: %+v %v", r, err)
	}
	r, err = parseRequest([]byte(`{"id":6,"op":"send","to":"` + chatURN + `","text":"hi","quote":{"id":"` + msgURN + `"}}`))
	if err != nil || r.To != chatURN || r.Text != "hi" || r.Quote == nil || r.Quote.ID != msgURN {
		t.Fatalf("send: %+v %v", r, err)
	}
	// `id` is the request's own number; the newest message read is `upto`.
	r, err = parseRequest([]byte(`{"id":8,"op":"read","to":"` + chatURN + `","upto":"` + msgURN + `"}`))
	if err != nil || r.ID != 8 || r.To != chatURN || r.Upto != msgURN {
		t.Fatalf("read: %+v %v", r, err)
	}
	r, err = parseRequest([]byte(`{"id":9,"op":"react","to":"c","target":"m","emoji":"👍","remove":true}`))
	if err != nil || r.Target != "m" || r.Emoji != "👍" || !r.Remove {
		t.Fatalf("react: %+v %v", r, err)
	}
	r, err = parseRequest([]byte(`{"id":11,"op":"download","pointer":{"url":"https://media.licdn.com/x","kind":"file"},"path":"/tmp/x"}`))
	if err != nil || r.Path != "/tmp/x" || len(r.Pointer) == 0 {
		t.Fatalf("download: %+v %v", r, err)
	}
	r, err = parseRequest([]byte(`{"id":12,"op":"who","who":"` + annURN + `"}`))
	if err != nil || r.Who != annURN {
		t.Fatalf("who: %+v %v", r, err)
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
	if got := encode(t, answer(2, map[string]any{"id": msgURN, "ts": int64(5)}, nil)); got != `{"id":2,"ok":true,"result":{"id":"`+msgURN+`","ts":5}}` {
		t.Fatalf("result: %s", got)
	}
	if got := encode(t, answer(3, nil, errors.New("no"))); got != `{"error":"no","id":3,"ok":false}` {
		t.Fatalf("error: %s", got)
	}
}

func TestCookiesMissing(t *testing.T) {
	cases := []struct {
		cookies map[string]string
		want    string
	}{
		{map[string]string{"JSESSIONID": "ajax:1"}, "the li_at cookie is missing"},
		{map[string]string{"li_at": "AQED"}, "the JSESSIONID cookie is missing"},
		{map[string]string{"li_at": "AQED", "JSESSIONID": "  "}, "the JSESSIONID cookie is missing"},
		{map[string]string{"bcookie": "v=2"}, "the li_at and JSESSIONID cookies are missing"},
		{nil, "the li_at and JSESSIONID cookies are missing"},
	}
	for _, c := range cases {
		_, err := cookieHeader(c.cookies)
		if err == nil || !strings.HasPrefix(err.Error(), c.want) || !strings.Contains(err.Error(), "copy the cookies again") {
			t.Fatalf("%v: %v", c.cookies, err)
		}
	}
}

func TestCookieHeaderAndJar(t *testing.T) {
	cookies := map[string]string{"li_at": " AQED ", "jsessionid": `"ajax:123"`, "bcookie": "v=2&x", "bad;name": "x", "empty": ""}
	header, err := cookieHeader(cookies)
	if err != nil || header != `JSESSIONID="ajax:123"; bcookie=v=2&x; li_at=AQED` {
		t.Fatalf("header: %q %v", header, err)
	}
	jar, err := cookieJar(cookies)
	if err != nil {
		t.Fatal(err)
	}
	// The quotes a browser shows round JSESSIONID are not part of the token LinkedIn wants back.
	if got := jar.GetCookie("JSESSIONID"); got != "ajax:123" {
		t.Fatalf("JSESSIONID: %q", got)
	}
	if jar.GetCookie("li_at") != "AQED" || jar.GetCookie("bcookie") != "v=2&x" {
		t.Fatalf("jar: %s", encode(t, jar))
	}
}

func TestSessionRoundTrip(t *testing.T) {
	path := filepath.Join(t.TempDir(), "session.json")
	if loadSession(path) != nil {
		t.Fatal("a session where there is no file")
	}
	jar, err := cookieJar(map[string]string{"li_at": "AQED", "JSESSIONID": "ajax:9"})
	if err != nil {
		t.Fatal(err)
	}
	// A file already there and readable by others must not stay so.
	if err := os.WriteFile(path, []byte("{}"), 0o644); err != nil {
		t.Fatal(err)
	}
	if loadSession(path) != nil {
		t.Fatal("a session without cookies was taken")
	}
	if err := saveSession(path, session{Me: meProfile, Name: "Mo Example", Handle: "mo-example", Cookies: jar}); err != nil {
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
	s := loadSession(path)
	if s == nil || s.Me != meProfile || s.Name != "Mo Example" || s.Handle != "mo-example" {
		t.Fatalf("loaded: %+v", s)
	}
	if s.Cookies.GetCookie("li_at") != "AQED" || s.Cookies.GetCookie("JSESSIONID") != "ajax:9" {
		t.Fatalf("cookies: %s", encode(t, s.Cookies))
	}
	// A session whose sign-in cookie is gone is no session.
	if err := os.WriteFile(path, []byte(`{"me":"ACoAAme","cookies":[{"Name":"JSESSIONID","Value":"ajax:9"}]}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if loadSession(path) != nil {
		t.Fatal("a session without li_at was taken")
	}
}

func TestWords(t *testing.T) {
	status := func(code int) error { return fmt.Errorf("GET /me: %w", &linkedingo.ResponseError{StatusCode: code}) }
	if !rejected(status(401)) || !rejected(status(302)) || !rejected(fmt.Errorf("x: %w", linkedingo.ErrTokenInvalidated)) {
		t.Fatal("a rejected session was not seen as one")
	}
	if rejected(status(403)) || rejected(status(429)) || rejected(status(500)) || rejected(errors.New("dial tcp")) {
		t.Fatal("a passing trouble was taken for the session ending")
	}
	if endedWords(status(401)) != wordsSignedOut || endedWords(status(302)) != wordsCheck {
		t.Fatal("ended words")
	}
	if got := signInWords(status(999)).Error(); got != wordsCheck {
		t.Fatalf("sign in, blocked: %s", got)
	}
	if got := signInWords(status(401)).Error(); !strings.Contains(got, "did not take those cookies") {
		t.Fatalf("sign in, 401: %s", got)
	}
	if got := plain(status(429)).Error(); !strings.Contains(got, "too many requests") {
		t.Fatalf("429: %s", got)
	}
	if got := plain(status(418)).Error(); !strings.Contains(got, "418") {
		t.Fatalf("418: %s", got)
	}
	if err := errors.New("nothing to send"); plain(err) != err {
		t.Fatal("words already plain were changed")
	}
}

func TestPersonOf(t *testing.T) {
	p := personOf(ann)
	if p.ID != annURN || p.Name != "Ann Lee" || p.Handle != "ann-lee-123" || p.Pic == nil {
		t.Fatalf("member: %+v", p)
	}
	// LinkedIn gave the profile's address by id: that is no username.
	if p := personOf(ben); p.Handle != "" || p.Name != "Ben Okoro" {
		t.Fatalf("member without a username: %+v", p)
	}
	org := linkedingo.MessagingParticipant{
		EntityURN:       linkedingo.NewURN("urn:li:msg_messagingParticipant:urn:li:fsd_company:99"),
		ParticipantType: linkedingo.ParticipantType{Organization: &linkedingo.OrganizationParticipantInfo{Name: linkedingo.AttributedText{Text: "Acme"}}},
	}
	if p := personOf(org); p.ID != "urn:li:msg_messagingParticipant:urn:li:fsd_company:99" || p.Name != "Acme" || p.Handle != "" {
		t.Fatalf("organization: %+v", p)
	}
	if !isMine(meProfile, me) || isMine(meProfile, ann) || isMine("", linkedingo.MessagingParticipant{}) {
		t.Fatal("mine")
	}
}

func TestChatOf(t *testing.T) {
	conv := linkedingo.Conversation{
		EntityURN:                linkedingo.NewURN(chatURN),
		LastActivityAt:           at(1700000002000),
		ConversationParticipants: []linkedingo.MessagingParticipant{me, ann},
		Categories:               []string{"INBOX", "PRIMARY_INBOX"},
		Messages: linkedingo.CollectionResponse[any, linkedingo.Message]{Elements: []linkedingo.Message{
			{EntityURN: linkedingo.NewURN(msgURN), Sender: ann, DeliveredAt: at(1700000001000), Body: linkedingo.AttributedText{Text: "older"}},
			{EntityURN: linkedingo.NewURN(msgURN + "2"), Sender: me, DeliveredAt: at(1700000002000), Body: linkedingo.AttributedText{Text: "see you then"}},
		}},
	}
	var asked []string
	got := encode(t, chatOf(meProfile, conv, func(p person) string {
		asked = append(asked, p.ID)
		return "/d/avatars/aa"
	}))
	want := `{"id":"` + chatURN + `","title":"Ann Lee","group":false,"members":[{"id":"` + annURN + `","name":"Ann Lee"}],"avatar":"/d/avatars/aa","unread":1,"last":1700000002000,"snippet":"see you then","snippet_mine":true}`
	if got != want {
		t.Fatalf("chat between two:\n got %s\nwant %s", got, want)
	}
	if len(asked) != 1 || asked[0] != annURN {
		t.Fatalf("avatar asked of %v", asked)
	}

	group := linkedingo.Conversation{
		EntityURN:                linkedingo.NewURN(chatURN),
		GroupChat:                true,
		Read:                     true,
		ConversationParticipants: []linkedingo.MessagingParticipant{ann, me, ben},
	}
	got = encode(t, chatOf(meProfile, group, func(person) string { t.Fatal("a group has no one picture"); return "" }))
	want = `{"id":"` + chatURN + `","title":"Ann Lee, Ben Okoro","group":true,"members":[{"id":"` + annURN + `","name":"Ann Lee"},{"id":"` + benURN + `","name":"Ben Okoro"}],"avatar":null,"unread":0,"last":0}`
	if got != want {
		t.Fatalf("group:\n got %s\nwant %s", got, want)
	}
	group.Title = "Planning"
	if c := chatOf(meProfile, group, nil); c.Title != "Planning" {
		t.Fatalf("a named group: %q", c.Title)
	}

	// As an event the chat keeps its shape, with "ev" beside.
	f := fields(chatOf(meProfile, conv, nil))
	if f["id"] != chatURN || f["avatar"] != nil || f["group"] != false || encode(t, f["last"]) != "1700000002000" {
		t.Fatalf("fields: %v", f)
	}
}

func TestListed(t *testing.T) {
	urn := linkedingo.NewURN(chatURN)
	if !listed(linkedingo.Conversation{EntityURN: urn, Categories: []string{"INBOX"}}) || !listed(linkedingo.Conversation{EntityURN: urn}) {
		t.Fatal("an inbox conversation was left out")
	}
	if listed(linkedingo.Conversation{EntityURN: urn, Categories: []string{"INBOX", "SPAM"}}) || listed(linkedingo.Conversation{EntityURN: urn, Categories: []string{"ARCHIVE"}}) || listed(linkedingo.Conversation{}) {
		t.Fatal("spam, an archived conversation or an empty one was listed")
	}
}

func TestMessageOf(t *testing.T) {
	quotedURN := "urn:li:msg_message:(urn:li:fsd_profile:ACoAAme,2-msg0==)"
	msg := linkedingo.Message{
		EntityURN:   linkedingo.NewURN(msgURN),
		Sender:      ann,
		DeliveredAt: at(1700000001000),
		Body:        linkedingo.AttributedText{Text: "here it is"},
		RenderContent: []linkedingo.RenderContent{
			{RepliedMessageContent: &linkedingo.RepliedMessage{OriginalMessage: linkedingo.Message{EntityURN: linkedingo.NewURN(quotedURN), Body: linkedingo.AttributedText{Text: "send the deck?"}}}},
			{File: &linkedingo.FileAttachment{URL: "https://www.linkedin.com/dms/prv/file/1", MediaType: "application/pdf", Name: "deck.pdf", ByteSize: 4096}},
			{VectorImage: &linkedingo.VectorImage{RootURL: "https://media.licdn.com/dms/image/pic/", Artifacts: []linkedingo.VectorArtifact{
				{Width: 100, Height: 50, FileIdentifyingURLPathSegment: "small?t=1"},
				{Width: 1200, Height: 600, FileIdentifyingURLPathSegment: "large?t=1", ExpiresAt: at(1800000000000)},
			}}},
		},
	}
	got := encode(t, messageOf(meProfile, chatURN, false, msg))
	want := `{"chat":"` + chatURN + `","group":false,"id":"` + msgURN + `","from":"` + annURN + `","name":"Ann Lee","mine":false,"ts":1700000001000,"text":"here it is",` +
		`"media":[{"pointer":{"url":"https://www.linkedin.com/dms/prv/file/1","kind":"file"},"mime":"application/pdf","name":"deck.pdf","size":4096,"width":0,"height":0},` +
		`{"pointer":{"url":"https://media.licdn.com/dms/image/pic/large?t=1","kind":"image","expires":1800000000000},"mime":"","name":"image","size":0,"width":1200,"height":600}],` +
		`"quote":{"id":"` + quotedURN + `","text":"send the deck?"}}`
	if got != want {
		t.Fatalf("message:\n got %s\nwant %s", got, want)
	}

	own := messageOf(meProfile, chatURN, true, linkedingo.Message{EntityURN: linkedingo.NewURN(msgURN), Sender: me, Body: linkedingo.AttributedText{Text: "ok"}})
	if got := encode(t, own); got != `{"chat":"`+chatURN+`","group":true,"id":"`+msgURN+`","from":"`+meURN+`","name":"Mo Example","mine":true,"ts":0,"text":"ok","media":[]}` {
		t.Fatalf("own message: %s", got)
	}
}

func TestMessageTextAndMedia(t *testing.T) {
	inmail := linkedingo.Message{Subject: "A role", Body: linkedingo.AttributedText{Text: "Are you free?"}}
	if got := messageText(inmail); got != "A role\n\nAre you free?" {
		t.Fatalf("subject: %q", got)
	}
	forwarded := linkedingo.Message{Body: linkedingo.AttributedText{Text: "look"}, RenderContent: []linkedingo.RenderContent{{ForwardedMessage: &linkedingo.ForwardedMessage{
		OriginalSender: ann,
		ForwardedBody:  linkedingo.AttributedText{Text: "one\ntwo"},
		FooterText:     linkedingo.AttributedText{Text: "Forwarded"},
	}}}}
	if got := messageText(forwarded); got != "look\n> Ann Lee:\n> one\n> two\nForwarded" {
		t.Fatalf("forwarded: %q", got)
	}
	post := linkedingo.Message{RenderContent: []linkedingo.RenderContent{{HostURNData: &linkedingo.HostURNData{
		Type:    "FEED_UPDATE",
		HostURN: linkedingo.NewURN("urn:li:fsd_update:(urn:li:activity:71,MESSAGING_RESHARE,EMPTY,DEFAULT,false)"),
	}}}}
	if got := messageText(post); got != "https://www.linkedin.com/feed/update/urn:li:activity:71" {
		t.Fatalf("shared post: %q", got)
	}

	media := mediaOf(linkedingo.Message{RenderContent: []linkedingo.RenderContent{
		{Audio: &linkedingo.AudioMetadata{URL: "https://www.linkedin.com/dms/prv/audio/1"}},
		{ExternalMedia: &linkedingo.ExternalMedia{Title: "wave", Media: linkedingo.ExternalProxyImage{URL: "https://media.licdn.com/gif", OriginalWidth: 320, OriginalHeight: 240}}},
		{Video: &linkedingo.VideoPlayMetadata{ProgressiveStreams: []linkedingo.ProgressiveDownloadMetadata{{MediaType: "video/mp4", Width: 640, Height: 360, Size: 9000, StreamingLocations: []linkedingo.StreamingLocation{{URL: "https://dms.licdn.com/v"}}}}}},
		{Video: &linkedingo.VideoPlayMetadata{}},
		{File: &linkedingo.FileAttachment{Name: "no address"}},
	}})
	want := `[{"pointer":{"url":"https://www.linkedin.com/dms/prv/audio/1","kind":"audio"},"mime":"","name":"voice_message","size":0,"width":0,"height":0},` +
		`{"pointer":{"url":"https://media.licdn.com/gif","kind":"gif"},"mime":"image/gif","name":"wave","size":0,"width":320,"height":240},` +
		`{"pointer":{"url":"https://dms.licdn.com/v","kind":"video"},"mime":"video/mp4","name":"video","size":9000,"width":640,"height":360}]`
	if got := encode(t, media); got != want {
		t.Fatalf("media:\n got %s\nwant %s", got, want)
	}
}

func TestConversationOf(t *testing.T) {
	if got := conversationOf(meProfile, linkedingo.Message{Conversation: linkedingo.Conversation{EntityURN: linkedingo.NewURN(chatURN)}}); got != chatURN {
		t.Fatalf("from the conversation: %q", got)
	}
	if got := conversationOf(meProfile, linkedingo.Message{ConversationURN: linkedingo.NewURN(chatURN)}); got != chatURN {
		t.Fatalf("from conversationUrn: %q", got)
	}
	if got := conversationOf(meProfile, linkedingo.Message{BackendConversationURN: linkedingo.NewURN("urn:li:messagingThread:2-thread==")}); got != chatURN {
		t.Fatalf("from the thread: %q", got)
	}
	if got := conversationOf(meProfile, linkedingo.Message{}); got != "" {
		t.Fatalf("from nothing: %q", got)
	}
}

func TestPointerAndAvatarName(t *testing.T) {
	p, err := parsePointer(json.RawMessage(`{"url":"https://media.licdn.com/x?t=1","kind":"image","expires":5}`))
	if err != nil || p.URL != "https://media.licdn.com/x?t=1" || p.Kind != "image" || p.Expires != 5 {
		t.Fatalf("object: %+v %v", p, err)
	}
	p, err = parsePointer(json.RawMessage(`"{\"url\":\"https://media.licdn.com/y\",\"kind\":\"file\"}"`))
	if err != nil || p.URL != "https://media.licdn.com/y" {
		t.Fatalf("string: %+v %v", p, err)
	}
	for _, bad := range []string{`{}`, `null`, `{"url":"http://media.licdn.com/x"}`, `{"url":"file:///etc/passwd"}`, `"nonsense"`, ``} {
		if _, err := parsePointer(json.RawMessage(bad)); err == nil {
			t.Fatalf("%q was taken for a file", bad)
		}
	}

	who := personOf(ann)
	art := artifactNear(*who.Pic, 200)
	if art.Width != 200 {
		t.Fatalf("artifact near 200: %+v", art)
	}
	if big := artifactNear(*who.Pic, 5000); big.Width != 800 {
		t.Fatalf("no size is wide enough: %+v", big)
	}
	// The same picture signed anew is the same file; another person's, or another size, is not.
	name := avatarName(who, art)
	resigned := art
	resigned.FileIdentifyingURLPathSegment = "200_200/0/1?e=2&t=y"
	if avatarName(who, resigned) != name || len(name) != 24 {
		t.Fatalf("avatar name: %s", name)
	}
	other := who
	other.ID = benURN
	if avatarName(other, art) == name || avatarName(who, artifactNear(*who.Pic, 800)) == name {
		t.Fatal("two pictures share a name")
	}
}

func TestMemoryAndQuoted(t *testing.T) {
	seen.reset()
	defer seen.reset()
	if !seen.noteMsg(msgURN, msgNote{chat: chatURN, from: annURN, text: "send the deck?", ts: 1700000001000}) {
		t.Fatal("a first sight was not new")
	}
	if seen.noteMsg(msgURN, msgNote{chat: chatURN, from: annURN, text: "send the deck??", ts: 1700000001000}) {
		t.Fatal("a second sight was new")
	}
	q := quoted(quote{ID: msgURN})
	if q == nil || q.OriginalSenderURN.String() != annURN || q.OriginalMessageURN.String() != msgURN || q.OriginalSendAt.UnixMilli() != 1700000001000 || q.MessageBody.Text != "send the deck??" {
		t.Fatalf("a quote of a message seen: %+v", q)
	}
	if quoted(quote{ID: "urn:li:msg_message:(x,unseen)"}) != nil {
		t.Fatal("a quote was made of a message no one knows")
	}
	if q := quoted(quote{ID: "urn:li:msg_message:(x,unseen)", Author: benURN, TS: 7, Text: "t"}); q == nil || q.OriginalSenderURN.String() != benURN {
		t.Fatalf("a quote from what the app sent: %+v", q)
	}

	seen.meet(personOf(ann))
	seen.meet(person{ID: annURN, Name: "Ann Lee"})
	if p, ok := seen.person(annURN); !ok || p.Pic == nil || p.Handle != "ann-lee-123" {
		t.Fatalf("a later sighting lost what was known: %+v", p)
	}
	if !seen.newsOf(personOf(ann)) || seen.newsOf(personOf(ann)) {
		t.Fatal("a name is said once")
	}
}
