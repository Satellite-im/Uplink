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

	"go.mau.fi/mautrix-meta/pkg/instameow/slidetypes"
	"go.mau.fi/mautrix-meta/pkg/messagix/httpclient"
)

const (
	me    = int64(17840000000000001)
	alice = int64(17840000000000002)
	bob   = int64(17840000000000003)
)

func at(msec int64) jsontime.UnixMilliString {
	return jsontime.UnixMilliString{Time: time.UnixMilli(msec)}
}

func text(id string, from int64, msec int64, words string) *slidetypes.Message {
	return &slidetypes.Message{
		ID: id, SenderFBID: from, TimestampMS: at(msec),
		Content: slidetypes.MessageContentWrapper{TypeName: "SlideMessageText", Content: &slidetypes.MessageContentText{TextBody: words}},
	}
}

func with(id string, from int64, msec int64, content slidetypes.MessageContent) *slidetypes.Message {
	return &slidetypes.Message{ID: id, SenderFBID: from, TimestampMS: at(msec), Content: slidetypes.MessageContentWrapper{Content: content}}
}

func edges(list ...*slidetypes.Message) *slidetypes.SlideMessages {
	page := &slidetypes.SlideMessages{}
	for _, m := range list {
		page.Edges = append(page.Edges, slidetypes.Node[*slidetypes.Message]{Node: m})
	}
	return page
}

func person(fbid int64, username, full string) *slidetypes.User {
	return &slidetypes.User{InteropMessagingUserFBID: fbid, Username: username, FullName: full, ID: fmt.Sprint(fbid % 1000),
		ProfilePicURL: "https://scontent.cdninstagram.com/v/t51/" + username + ".jpg?sig=1"}
}

func TestParseRequest(t *testing.T) {
	r, err := parseRequest([]byte(`{"id":2,"op":"sign_in","cookies":{"sessionid":"s","csrftoken":"c","ds_user_id":"1"}}`))
	if err != nil || r.ID != 2 || r.Op != "sign_in" || r.Cookies["csrftoken"] != "c" || len(r.Cookies) != 3 {
		t.Fatalf("sign_in: %+v %v", r, err)
	}
	r, err = parseRequest([]byte(`{"id":6,"op":"send","to":"340282366841710300949128137443944319108","text":"hi","quote":{"id":"mid.1"}}`))
	if err != nil || r.To == "" || r.Text != "hi" || r.Quote == nil || r.Quote.ID != "mid.1" {
		t.Fatalf("send: %+v %v", r, err)
	}
	// `read` names the message as "upto": "id" is the request's own number and nothing else.
	r, err = parseRequest([]byte(`{"id":8,"op":"read","to":"T1","upto":"mid.9"}`))
	if err != nil || r.ID != 8 || r.To != "T1" || r.Upto != "mid.9" {
		t.Fatalf("read: %+v %v", r, err)
	}
	r, err = parseRequest([]byte(`{"id":9,"op":"read","to":"T1"}`))
	if err != nil || r.Upto != "" {
		t.Fatalf("read without upto: %+v %v", r, err)
	}
	r, err = parseRequest([]byte(`{"id":10,"op":"react","to":"T1","target":"mid.2","emoji":"❤","remove":true}`))
	if err != nil || r.Target != "mid.2" || r.Emoji != "❤" || !r.Remove {
		t.Fatalf("react: %+v %v", r, err)
	}
	r, err = parseRequest([]byte(`{"id":11,"op":"download","pointer":{"url":"https://x.cdninstagram.com/a.jpg"},"path":"/tmp/a"}`))
	if err != nil || r.Path != "/tmp/a" || len(r.Pointer) == 0 {
		t.Fatalf("download: %+v %v", r, err)
	}
	r, err = parseRequest([]byte(`{"id":5,"op":"history","chat":"T1","before":"mid.3"}`))
	if err != nil || r.Chat != "T1" || r.Before != "mid.3" {
		t.Fatalf("history: %+v %v", r, err)
	}
	r, err = parseRequest([]byte(`{"id":12,"op":"who","who":"17840000000000002"}`))
	if err != nil || parsePersonID(r.Who) != alice {
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
	b, _ := json.Marshal(answer(1, nil, nil))
	if string(b) != `{"id":1,"ok":true,"result":null}` {
		t.Fatalf("null result: %s", b)
	}
	b, _ = json.Marshal(answer(3, nil, errors.New("no")))
	if string(b) != `{"error":"no","id":3,"ok":false}` {
		t.Fatalf("error: %s", b)
	}
}

func TestUnknownOpAndNotLinked(t *testing.T) {
	if _, err := do(request{Op: "dance"}); err == nil || !strings.Contains(err.Error(), "dance") {
		t.Fatalf("unknown op: %v", err)
	}
	for _, op := range []string{"chats", "history", "send", "send_media", "read", "react", "delete", "who"} {
		if _, err := do(request{Op: op, To: "T1", Chat: "T1", Text: "x", Target: "m", Emoji: "x", Who: "1"}); !errors.Is(err, errNotLinked) {
			t.Fatalf("%s while signed out: %v", op, err)
		}
	}
	st := status()
	if st["linked"] != false || st["connected"] != false || st["me"] != "" {
		t.Fatalf("status while signed out: %v", st)
	}
}

func TestMissingCookieWords(t *testing.T) {
	if w := missingCookieWords(map[string]string{"sessionid": "s", "csrftoken": "c", "ds_user_id": "1"}); w != "" {
		t.Fatalf("nothing is missing: %q", w)
	}
	w := missingCookieWords(map[string]string{"sessionid": "s", "ds_user_id": "1", "mid": "m"})
	if !strings.Contains(w, "csrftoken") || strings.Contains(w, "sessionid") || strings.Contains(w, "ds_user_id") {
		t.Fatalf("one missing: %q", w)
	}
	w = missingCookieWords(map[string]string{"csrftoken": " "})
	if !strings.Contains(w, "sessionid, csrftoken, ds_user_id") {
		t.Fatalf("all missing, a blank one among them: %q", w)
	}
	clean := cleanCookies(map[string]string{" sessionid ": " s\n", "rur": "", "mid": "m"})
	if clean["sessionid"] != "s" || clean["mid"] != "m" || len(clean) != 2 {
		t.Fatalf("clean: %v", clean)
	}
	// sign_in says so before anything is asked of Instagram.
	_, err := signIn(t.Context(), map[string]string{"sessionid": "s"})
	if err == nil || !strings.Contains(err.Error(), "csrftoken, ds_user_id") {
		t.Fatalf("sign_in with cookies missing: %v", err)
	}
}

func TestRejectionWords(t *testing.T) {
	if w := rejection(fmt.Errorf("failed to load inbox: %w", httpclient.ErrChallengeRequired)); w != wordsChallenge {
		t.Fatalf("challenge: %q", w)
	}
	if w := rejection(httpclient.ErrCheckpointRequired); !strings.Contains(w, "confirm it's you") {
		t.Fatalf("checkpoint: %q", w)
	}
	if w := rejection(httpclient.ErrConsentRequired); w != wordsConsent {
		t.Fatalf("consent: %q", w)
	}
	if w := rejection(httpclient.ErrTokenInvalidatedRedirect); w != wordsSignedOut {
		t.Fatalf("signed out: %q", w)
	}
	if w := rejection(httpclient.ErrAccountSuspended); w != wordsSuspended {
		t.Fatalf("suspended: %q", w)
	}
	if w := rejection(errors.New("dial tcp: no route to host")); w != "" {
		t.Fatalf("no network is not a rejection: %q", w)
	}
	if err := fail("The chats could not be read", httpclient.ErrRateLimited); err.Error() != wordsSlowDown {
		t.Fatalf("rate limit: %v", err)
	}
	if err := fail("The chats could not be read", errors.New("boom")); err.Error() != "The chats could not be read: boom" {
		t.Fatalf("other: %v", err)
	}
}

func TestSessionSaveLoad(t *testing.T) {
	path := filepath.Join(t.TempDir(), "session.json")
	// An older, wider file must not keep its mode.
	if err := os.WriteFile(path, []byte("{}"), 0o644); err != nil {
		t.Fatal(err)
	}
	s := &session{
		Cookies: map[string]string{"sessionid": "s%3Aabc", "csrftoken": "c", "ds_user_id": "42", "mid": "m"},
		Me:      personID(me), IGID: "42", Name: "Matt", Handle: "matt", Saved: 1700000000000,
	}
	if err := saveSession(path, s); err != nil {
		t.Fatal(err)
	}
	st, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if runtime.GOOS != "windows" && st.Mode().Perm() != 0o600 {
		t.Fatalf("mode %o, want 600", st.Mode().Perm())
	}
	if _, err := os.Stat(path + ".tmp"); !os.IsNotExist(err) {
		t.Fatal("the temporary file was left behind")
	}
	got, err := loadSession(path)
	if err != nil || got.Me != s.Me || got.Handle != "matt" || got.Cookies["sessionid"] != "s%3Aabc" || len(got.Cookies) != 4 || got.Saved != s.Saved {
		t.Fatalf("loaded %+v %v", got, err)
	}
	// The kept cookies go into the library's jar under their own names.
	jar := cookieJar(got.Cookies)
	if !jar.IsLoggedIn() || len(jar.GetMissingCookieNames()) != 0 || jar.GetUserID() != 42 {
		t.Fatalf("jar: %v", jar.GetAll())
	}
	if _, err := loadSession(filepath.Join(t.TempDir(), "none.json")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("no file: %v", err)
	}
	_ = saveSession(path, &session{Cookies: map[string]string{"csrftoken": "c"}})
	if _, err := loadSession(path); err == nil {
		t.Fatal("a session without its cookies was taken")
	}
}

func group() *slidetypes.ThreadInfo {
	return &slidetypes.ThreadInfo{
		ID: "9001", ThreadKey: 9001, ThreadFBID: "9001", ThreadID: "340282366841710300949128137443944319108",
		IsGroup: true, ThreadTitle: "Climbing", ThreadImageURL: "https://scontent.cdninstagram.com/v/t51/group.jpg?sig=2",
		Viewer: person(me, "matt", "Matt"), Users: []*slidetypes.User{person(alice, "alice", "Alice A"), person(bob, "bob", "")},
		LastActivityTimestampMS: at(5000),
		SlideMessages:           edges(text("m3", alice, 5000, "see you there"), text("m2", me, 4000, "ok"), text("m1", bob, 3000, "saturday?")),
		SlideReadReceipts: []slidetypes.ReadReceipt{
			{ParticipantFBID: me, WatermarkTimestampMS: at(3500)},
			{ParticipantFBID: alice, WatermarkTimestampMS: at(5000)},
		},
	}
}

func TestChatShape(t *testing.T) {
	chat := chatShape(group(), me, "")
	b, _ := json.Marshal(chat)
	want := `{"avatar":null,"group":true,"id":"9001","last":5000,"members":[{"id":"17840000000000002","name":"Alice A"},{"id":"17840000000000003","name":"bob"}],"snippet":"see you there","snippet_mine":false,"title":"Climbing","unread":1}`
	if string(b) != want {
		t.Fatalf("group:\n got %s\nwant %s", b, want)
	}
	if threadAvatarURL(group()) != "https://scontent.cdninstagram.com/v/t51/group.jpg?sig=2" {
		t.Fatal("a group's picture is its own")
	}

	// A group nobody named is called by its people.
	g := group()
	g.ThreadTitle = ""
	if title := chatShape(g, me, "")["title"]; title != "Alice A, bob" {
		t.Fatalf("unnamed group: %q", title)
	}

	// Two people: the other's name and picture; the person's own last message; nothing unread.
	dm := &slidetypes.ThreadInfo{
		ID: "17840000000000002", ThreadKey: alice, ThreadID: "long-1", Viewer: person(me, "matt", "Matt"),
		Users: []*slidetypes.User{person(alice, "alice", "Alice A")}, LastActivityTimestampMS: at(9000),
		SlideMessages:     edges(text("m9", me, 9000, "on my way")),
		SlideReadReceipts: []slidetypes.ReadReceipt{{ParticipantFBID: me, WatermarkTimestampMS: at(9000)}},
	}
	chat = chatShape(dm, me, "/x/avatars/abc")
	if chat["title"] != "Alice A" || chat["group"] != false || chat["avatar"] != "/x/avatars/abc" || chat["unread"] != 0 ||
		chat["snippet"] != "on my way" || chat["snippet_mine"] != true || chat["last"] != int64(9000) {
		t.Fatalf("dm: %v", chat)
	}
	if threadAvatarURL(dm) != dm.Users[0].ProfilePicURL {
		t.Fatal("a chat of two shows the other person's picture")
	}

	// Marked unread by hand counts one; a picture alone still has a snippet; no listed messages means no snippet.
	dm.MarkedAsUnread = true
	dm.SlideMessages = edges(with("m10", alice, 9500, &slidetypes.MessageContentImage{Attachments: []*slidetypes.Attachment{{AttachmentCDNURL: "https://scontent.cdninstagram.com/v/a.jpg"}}}))
	chat = chatShape(dm, me, "")
	if chat["unread"] != 1 || chat["snippet"] != "Photo" {
		t.Fatalf("marked unread: %v", chat)
	}
	dm.SlideMessages = nil
	if _, has := chatShape(dm, me, "")["snippet"]; has {
		t.Fatal("a snippet was made up")
	}
}

func TestMessageShape(t *testing.T) {
	m := text("mid.5", alice, 1700000000123, "hello")
	m.Sender = &slidetypes.MessageSender{UserDict: *person(alice, "alice", "Alice A")}
	m.RepliedToMessageID = "mid.4"
	m.RepliedToMessage = text("mid.4", me, 1700000000000, "are you there?")
	m.Reactions = []*slidetypes.Reaction{{Reaction: "❤", SenderFBID: me, LogMessageID: "log.1"}}
	shape, ok := messageShape("9001", true, m, me, nil)
	b, _ := json.Marshal(shape)
	want := `{"chat":"9001","from":"17840000000000002","group":true,"id":"mid.5","media":[],"mine":false,"name":"Alice A","quote":{"from":"17840000000000001","id":"mid.4","text":"are you there?"},"reactions":[{"emoji":"❤","from":"17840000000000001","mine":true}],"text":"hello","ts":1700000000123}`
	if !ok || string(b) != want {
		t.Fatalf("message:\n got %s\nwant %s", b, want)
	}

	// The person's own, with the name looked up where the message does not carry it.
	shape, _ = messageShape("9001", true, text("mid.6", me, 2, "mine"), me, func(id int64) string { return "Matt" })
	if shape["mine"] != true || shape["name"] != "Matt" || shape["from"] != personID(me) {
		t.Fatalf("own: %v", shape)
	}
	if _, has := shape["quote"]; has {
		t.Fatal("a quote was made up")
	}

	// Instagram's own lines about a thread are not messages; a call's notice is.
	admin := with("mid.7", alice, 3, &slidetypes.MessageContentAdminText{TextFragments: []slidetypes.TextFragment{{Plaintext: "Alice named the group "}, {Plaintext: "Climbing"}}})
	if _, ok := messageShape("9001", true, admin, me, nil); ok {
		t.Fatal("a notice was said as a message")
	}
	admin.ContentType = "IG_VIDEO_CALL_XMAT"
	if shape, ok := messageShape("9001", true, admin, me, nil); !ok || shape["text"] != "Alice named the group Climbing" {
		t.Fatalf("call notice: %v %v", shape, ok)
	}
	if _, ok := messageShape("9001", true, nil, me, nil); ok {
		t.Fatal("no message was said as one")
	}
}

func TestMedia(t *testing.T) {
	img := with("mid.8", alice, 4, &slidetypes.MessageContentImage{Attachments: []*slidetypes.Attachment{{
		AttachmentFBID: "55", AttachmentCDNURL: "https://scontent.cdninstagram.com/v/t1/photo_1.jpg?oh=sig", PreviewWidth: 1080, PreviewHeight: 1350,
	}}})
	shape, _ := messageShape("T", false, img, me, nil)
	b, _ := json.Marshal(shape["media"])
	want := `[{"height":1350,"mime":"image/jpeg","name":"photo_1.jpg","pointer":{"mime":"image/jpeg","url":"https://scontent.cdninstagram.com/v/t1/photo_1.jpg?oh=sig"},"width":1080}]`
	if string(b) != want || shape["text"] != "" {
		t.Fatalf("image:\n got %s\nwant %s", b, want)
	}
	// What a message's media gave is what `download` takes back.
	raw, _ := json.Marshal(shape["media"].([]map[string]any)[0]["pointer"])
	if p, err := parsePointer(raw); err != nil || p.Mime != "image/jpeg" || !strings.HasPrefix(p.URL, "https://scontent") {
		t.Fatalf("pointer back: %+v %v", p, err)
	}
	for _, bad := range []string{``, `{}`, `{"url":"file:///etc/passwd"}`, `{"url":"http://scontent.cdninstagram.com/a.jpg"}`, `"x"`} {
		if _, err := parsePointer(json.RawMessage(bad)); err == nil {
			t.Fatalf("pointer %q was taken", bad)
		}
	}

	video := with("mid.9", alice, 5, &slidetypes.MessageContentVideo{Videos: []*slidetypes.Attachment{{AttachmentCDNURL: "https://video.cdninstagram.com/v/clip.mp4?x=1", DashManifest: "<MPD/>"}}})
	if r := render(video); len(r.media) != 1 || r.media[0]["mime"] != "video/mp4" {
		t.Fatalf("video: %+v", r)
	}
	voice := with("mid.10", alice, 6, &slidetypes.MessageContentAudio{AudioAttachments: []*slidetypes.AudioAttachment{{AttachmentCDNURL: "https://cdn.fbsbx.com/v/audioclip-1.mp4?oh=1"}}})
	if r := render(voice); len(r.media) != 1 || r.media[0]["mime"] != "audio/mp4" {
		t.Fatalf("voice: %+v", r)
	}
	// An attachment Instagram gave no address for is said in words, never as nothing.
	lost := with("mid.11", alice, 7, &slidetypes.MessageContentImage{Attachments: []*slidetypes.Attachment{{}}})
	if r := render(lost); len(r.media) != 0 || !strings.Contains(r.text, "open Instagram") {
		t.Fatalf("lost: %+v", r)
	}
	// Seen-once pictures are not fetched.
	once := with("mid.12", alice, 8, &slidetypes.MessageContentRavenImage{ViewMode: slidetypes.RavenViewModeViewOnce, Attachment: &slidetypes.Attachment{AttachmentCDNURL: "https://scontent.cdninstagram.com/once.jpg"}})
	if r := render(once); len(r.media) != 0 || !strings.Contains(r.text, "only be viewed once") {
		t.Fatalf("view once: %+v", r)
	}
	kept := with("mid.13", alice, 9, &slidetypes.MessageContentRavenVideo{ViewMode: slidetypes.RavenViewModeKeepInChat, Attachment: &slidetypes.Attachment{AttachmentCDNURL: "https://scontent.cdninstagram.com/kept.mp4"}})
	if r := render(kept); len(r.media) != 1 || r.media[0]["mime"] != "video/mp4" {
		t.Fatalf("kept in chat: %+v", r)
	}
	gif := with("mid.14", alice, 10, &slidetypes.MessageContentAnimatedMedia{AnimatedMedia: []*slidetypes.AnimatedAttachment{{AttachmentWebpURL: "https://media.giphy.com/x/giphy", AttachmentMP4URL: "https://media.giphy.com/x/giphy.mp4"}}})
	if r := render(gif); len(r.media) != 1 || r.media[0]["mime"] != "video/mp4" {
		t.Fatalf("gif: %+v", r)
	}
}

func TestSharedThingsAreNeverEmpty(t *testing.T) {
	xma := func(x *slidetypes.XMAContent, body string) rendered {
		return render(with("mid.x", alice, 1, &slidetypes.MessageContentXMA{XMA: x, XMATextBody: body}))
	}
	r := xma(&slidetypes.XMAContent{TargetID: "1", TargetURL: "https://www.instagram.com/p/Cabc123/", PreviewImage: &slidetypes.XMAPreviewImage{URL: "https://scontent.cdninstagram.com/p.jpg", Width: 640, Height: 640}}, "")
	if r.text != "Shared a post: https://www.instagram.com/p/Cabc123/" || len(r.media) != 1 {
		t.Fatalf("post: %+v", r)
	}
	if r = xma(&slidetypes.XMAContent{TargetID: "2", TargetURL: "/reel/Cxyz/"}, "look at this"); r.text != "Shared a reel: https://www.instagram.com/reel/Cxyz/\nlook at this" {
		t.Fatalf("reel with words: %q", r.text)
	}
	if r = xma(&slidetypes.XMAContent{TargetID: "3", TargetURL: "https://l.instagram.com/?u=https%3A%2F%2Fwww.instagram.com%2Fstories%2Falice%2F123%2F&e=x"}, ""); r.text != "Shared a story: https://www.instagram.com/stories/alice/123/" {
		t.Fatalf("story through the link wrapper: %q", r.text)
	}
	if r = xma(&slidetypes.XMAContent{TargetID: "4", TargetURL: "https://www.instagram.com/alice/"}, ""); r.text != "Shared a profile: https://www.instagram.com/alice/" {
		t.Fatalf("profile: %q", r.text)
	}
	if r = xma(&slidetypes.XMAContent{TargetID: "5", TitleText: "A story that has run out"}, ""); r.text != "Shared from Instagram: A story that has run out" {
		t.Fatalf("no link: %q", r.text)
	}
	if r = xma(&slidetypes.XMAContent{TargetID: "6"}, ""); r.text == "" {
		t.Fatal("a share with nothing known was left empty")
	}
	if r = xma(nil, ""); r.text == "" {
		t.Fatal("a share without its card was left empty")
	}
	// A link the sender typed, with a preview card: their words are the message.
	if r = xma(&slidetypes.XMAContent{TargetURL: "https://example.com/a"}, "read https://example.com/a"); r.text != "read https://example.com/a" || len(r.media) != 0 {
		t.Fatalf("typed link: %+v", r)
	}
	// Content the library has no shape for, and none at all.
	if r = render(with("mid.u", alice, 1, slidetypes.MessageContentUnknown{"__typename": "SlideMessageNew"})); r.text != wordsUnknown {
		t.Fatalf("unknown: %q", r.text)
	}
	bare := &slidetypes.Message{ID: "mid.b", SenderFBID: alice, IGDSnippet: "Sent an attachment"}
	if r = render(bare); r.text != "Sent an attachment" {
		t.Fatalf("no content: %q", r.text)
	}
	if r = render(with("mid.s", alice, 1, &slidetypes.MessageContentSticker{})); r.text == "" {
		t.Fatal("a sticker without its picture was left empty")
	}
	music := &slidetypes.MessageContentMusicSticker{AttributionLink: "https://www.instagram.com/reels/audio/1/"}
	music.AudioTrack.Title, music.AudioTrack.DisplayArtist = "Song", "Band"
	if r = render(with("mid.m", alice, 1, music)); r.text != "Shared a song: Song by Band\nhttps://www.instagram.com/reels/audio/1/" {
		t.Fatalf("song: %q", r.text)
	}
}

// The shapes hold for Instagram's own JSON as the library reads it, not only for hand-built values.
func TestMessageFromInstagramJSON(t *testing.T) {
	raw := `{"id":"mid.$abc","message_id":"mid.$abc","sender_fbid":"17840000000000002","thread_fbid":"9001","timestamp_ms":"1700000000456",
		"content_type":"TEXT","text_body":"hi","content":{"__typename":"SlideMessageText","text_body":"hi"},
		"reactions":[{"reaction":"👍","sender_fbid":"17840000000000003","log_message_id":"log.9","reaction_timestamp_ms":"1700000000999"}],
		"sender":{"name":"Alice A","user_dict":{"interop_messaging_user_fbid":"17840000000000002","username":"alice","full_name":"Alice A"}}}`
	var m slidetypes.Message
	if err := json.Unmarshal([]byte(raw), &m); err != nil {
		t.Fatal(err)
	}
	shape, ok := messageShape("9001", true, &m, me, nil)
	if !ok || shape["id"] != "mid.$abc" || shape["text"] != "hi" || shape["ts"] != int64(1700000000456) || shape["from"] != personID(alice) || shape["name"] != "Alice A" {
		t.Fatalf("from JSON: %v", shape)
	}
	var d slidetypes.Delta
	if err := json.Unmarshal([]byte(`{"__typename":"SlideUQPPReadReceipt","uq_seq_id":"7","thread_fbid":"9001","read_receipt":{"participant_fbid":"17840000000000002","watermark_timestamp_ms":"4000"}}`), &d); err != nil {
		t.Fatal(err)
	}
	rr, ok := d.Data.(*slidetypes.ReadReceiptEvent)
	if !ok || d.ThreadIGID != "9001" || rr.ReadReceipt.ParticipantFBID != alice || rr.ReadReceipt.WatermarkTimestampMS.UnixMilli() != 4000 {
		t.Fatalf("read receipt delta: %+v", d.Data)
	}
}

func TestHistoryShape(t *testing.T) {
	// Instagram lists newest first; the protocol wants oldest first, without Instagram's own notices.
	page := edges(text("m3", alice, 3000, "three"), with("n", alice, 2500, &slidetypes.MessageContentAdminText{}), text("m2", me, 2000, "two"), text("m1", bob, 1000, "one"))
	list := historyShape("9001", true, page.Edges, me, nil)
	if len(list) != 3 || list[0]["id"] != "m1" || list[1]["id"] != "m2" || list[2]["id"] != "m3" || list[1]["mine"] != true {
		t.Fatalf("history: %v", list)
	}
	b, _ := json.Marshal(map[string]any{"messages": historyShape("9001", true, nil, me, nil), "more": false})
	if string(b) != `{"messages":[],"more":false}` {
		t.Fatalf("empty page: %s", b)
	}
}

func TestReactionShape(t *testing.T) {
	// As a CreateReactionEvent carries it.
	evt := &slidetypes.CreateReactionEvent{MessageID: "mid.5", Reaction: slidetypes.Reaction{Reaction: "😂", SenderFBID: alice, LogMessageID: "log.2"}}
	b, _ := json.Marshal(reactionShape("9001", evt.MessageID, evt.Reaction.SenderFBID, evt.Reaction.Reaction, false))
	if string(b) != `{"chat":"9001","emoji":"😂","from":"17840000000000002","remove":false,"target":"mid.5"}` {
		t.Fatalf("reaction: %s", b)
	}
	// Taken off: Instagram names only the reaction's own id, so whose it was is what was noted when it was put on.
	resetMemo(me)
	noteMessages("9001", &slidetypes.Message{ID: "mid.5", TimestampMS: at(1), Reactions: []*slidetypes.Reaction{&evt.Reaction}})
	gone := &slidetypes.DeleteReactionEvent{MessageID: "log.2", Reaction: slidetypes.Reaction{LogMessageID: "log.2"}}
	was, ok := memo.reacts[gone.Reaction.LogMessageID]
	if !ok || was.target != "mid.5" || was.from != alice {
		t.Fatalf("noted reaction: %+v %v", was, ok)
	}
	shape := reactionShape("9001", was.target, was.from, gone.Reaction.Reaction, true)
	if shape["remove"] != true || shape["target"] != "mid.5" || shape["from"] != personID(alice) || shape["emoji"] != "" {
		t.Fatalf("reaction removed: %v", shape)
	}
}

func TestReceiptShape(t *testing.T) {
	var list []seen
	for _, s := range []seen{{"m2", 2000}, {"m1", 1000}, {"m3", 3000}, {"m2", 2000}, {"", 5}} {
		list = noteSeen(list, s)
	}
	if len(list) != 3 || list[0].id != "m1" || list[2].id != "m3" {
		t.Fatalf("seen, in order and once each: %v", list)
	}
	// As a ReadReceiptEvent carries it: a time, turned into the newest message at or before it.
	evt := &slidetypes.ReadReceiptEvent{ReadReceipt: slidetypes.ReadReceipt{ParticipantFBID: alice, WatermarkTimestampMS: at(2500)}}
	b, _ := json.Marshal(receiptShape("9001", evt.ReadReceipt.ParticipantFBID, list, evt.ReadReceipt.WatermarkTimestampMS.UnixMilli()))
	if string(b) != `{"chat":"9001","from":"17840000000000002","id":"m2","kind":"read","ts":2500}` {
		t.Fatalf("receipt: %s", b)
	}
	if got := receiptShape("9001", alice, list, 3000)["id"]; got != "m3" {
		t.Fatalf("read up to the newest: %v", got)
	}
	// Nothing of the thread met yet: the id is left empty, never guessed.
	if got := receiptShape("9001", alice, nil, 2500)["id"]; got != "" {
		t.Fatalf("nothing known: %v", got)
	}
	if got := receiptShape("9001", alice, list, 500)["id"]; got != "" {
		t.Fatalf("read before anything known: %v", got)
	}
	for i := range 500 {
		list = noteSeen(list, seen{fmt.Sprint("x", i), int64(4000 + i)})
	}
	if len(list) != 400 || list[len(list)-1].id != "x499" {
		t.Fatalf("seen is kept short: %d", len(list))
	}
}

func TestNameShapeAndPeople(t *testing.T) {
	b, _ := json.Marshal(nameShape(person(alice, "alice", "Alice A"), ""))
	if string(b) != `{"avatar":null,"handle":"alice","id":"17840000000000002","name":"Alice A"}` {
		t.Fatalf("name: %s", b)
	}
	resetMemo(me)
	u := person(alice, "alice", "Alice A")
	if !notePerson(u) || notePerson(u) {
		t.Fatal("a person is new once")
	}
	// The same picture under a fresh signature is not a change; a new name is.
	again := *u
	again.ProfilePicURL = "https://scontent-2.cdninstagram.com/v/t51/alice.jpg?sig=other"
	if notePerson(&again) {
		t.Fatal("a re-signed picture address was taken for a change")
	}
	again.FullName = "Alice B"
	if !notePerson(&again) || nameOf(alice) != "Alice B" {
		t.Fatal("a new name was missed")
	}
	if notePerson(nil) || notePerson(&slidetypes.User{}) {
		t.Fatal("nobody was noted")
	}
}

func TestAvatarPath(t *testing.T) {
	dir = t.TempDir()
	a := avatarPath("https://scontent.cdninstagram.com/v/t51/alice.jpg?sig=1")
	b := avatarPath("https://scontent-2.cdninstagram.com/v/t51/alice.jpg?sig=2")
	if a == "" || a != b || filepath.Dir(a) != avatarDir() {
		t.Fatalf("one picture, one file: %q %q", a, b)
	}
	if avatarPath("https://scontent.cdninstagram.com/v/t51/bob.jpg") == a || avatarPath("") != "" {
		t.Fatal("pictures are told apart, and none is none")
	}
	if avatarCached("https://scontent.cdninstagram.com/v/t51/alice.jpg?sig=1") != "" {
		t.Fatal("a picture not fetched was said to be kept")
	}
	_ = os.MkdirAll(avatarDir(), 0o700)
	_ = os.WriteFile(a, []byte("jpeg"), 0o600)
	if avatarCached("https://scontent.cdninstagram.com/v/t51/alice.jpg?sig=3") != a {
		t.Fatal("a kept picture was not found")
	}
}
