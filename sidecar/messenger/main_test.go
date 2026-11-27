package main

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"go.mau.fi/whatsmeow/proto/waCommon"
	"go.mau.fi/whatsmeow/proto/waConsumerApplication"
	waTypes "go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
	"google.golang.org/protobuf/proto"

	"go.mau.fi/mautrix-meta/pkg/messagix/httpclient"
	"go.mau.fi/mautrix-meta/pkg/messagix/methods"
	"go.mau.fi/mautrix-meta/pkg/messagix/table"
	"go.mau.fi/mautrix-meta/pkg/messagix/types"
)

const (
	me    = int64(100000000000001)
	ada   = int64(100000000000002)
	grace = int64(100000000000003)
	group = int64(7000000000000001)
)

func TestParseRequest(t *testing.T) {
	r, err := parseRequest([]byte(`{"id":2,"op":"sign_in","cookies":{"c_user":"1","xs":"a","datr":"b"}}`))
	if err != nil || r.ID != 2 || r.Op != "sign_in" || r.Cookies["xs"] != "a" || len(r.Cookies) != 3 {
		t.Fatalf("sign_in: %+v %v", r, err)
	}
	r, err = parseRequest([]byte(`{"id":6,"op":"send","to":"100000000000002","text":"hi","quote":{"id":"mid.$abc"}}`))
	if err != nil || r.To != "100000000000002" || r.Text != "hi" || r.Quote == nil || r.Quote.ID != "mid.$abc" {
		t.Fatalf("send: %+v %v", r, err)
	}
	// The newest message read is "upto": "id" is always the request's own number.
	r, err = parseRequest([]byte(`{"id":8,"op":"read","to":"100000000000002","upto":"mid.$abc"}`))
	if err != nil || r.ID != 8 || r.To != "100000000000002" || r.Upto != "mid.$abc" {
		t.Fatalf("read: %+v %v", r, err)
	}
	r, err = parseRequest([]byte(`{"id":9,"op":"react","to":"1","target":"mid.$abc","emoji":"👍","remove":true}`))
	if err != nil || r.Target != "mid.$abc" || r.Emoji != "👍" || !r.Remove {
		t.Fatalf("react: %+v %v", r, err)
	}
	r, err = parseRequest([]byte(`{"id":11,"op":"download","pointer":{"url":"https://scontent.xx.fbcdn.net/a.jpg"},"path":"/tmp/a"}`))
	if err != nil || r.Path != "/tmp/a" || !strings.Contains(string(r.Pointer), "fbcdn") {
		t.Fatalf("download: %+v %v", r, err)
	}
	r, err = parseRequest([]byte(`{"id":5,"op":"history","chat":"1","before":"mid.$abc"}`))
	if err != nil || r.Chat != "1" || r.Before != "mid.$abc" {
		t.Fatalf("history: %+v %v", r, err)
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

func TestMissingCookies(t *testing.T) {
	if err := missingCookies(map[string]string{"c_user": "1", "xs": "a", "datr": "b", "sb": "c"}); err != nil {
		t.Fatalf("a whole set was refused: %v", err)
	}
	err := missingCookies(map[string]string{"c_user": "1"})
	if err == nil || !strings.HasPrefix(err.Error(), "These cookies are missing: datr, xs.") {
		t.Fatalf("two missing: %v", err)
	}
	// An empty value is as good as none.
	err = missingCookies(map[string]string{"c_user": "1", "xs": "a", "datr": " "})
	if err == nil || !strings.HasPrefix(err.Error(), "This cookie is missing: datr.") {
		t.Fatalf("one missing: %v", err)
	}
}

func TestRefusalWords(t *testing.T) {
	words, fatal, _ := refusal(httpclient.ErrCheckpointRequired, "messenger.com")
	if !fatal || !strings.Contains(words, "confirm it is you") || !strings.Contains(words, "messenger.com") {
		t.Fatalf("checkpoint: %q %v", words, fatal)
	}
	words, fatal, _ = refusal(httpclient.ErrTokenInvalidatedRedirect, "facebook.com")
	if !fatal || !strings.Contains(words, "copy the cookies again") || !strings.Contains(words, "facebook.com") {
		t.Fatalf("signed out: %q %v", words, fatal)
	}
	if _, fatal, _ = refusal(httpclient.ErrUserIDIsZero, "messenger.com"); !fatal {
		t.Fatal("a page with nobody signed in was not taken as signed out")
	}
	if _, fatal, _ = refusal(httpclient.ErrConsentRequired, "messenger.com"); !fatal {
		t.Fatal("consent was not taken as needing the browser")
	}
	if _, fatal, _ = refusal(&types.ErrorResponse{ErrorCode: 1357053}, "messenger.com"); !fatal {
		t.Fatal("Messenger's own signed-out answer was not taken as one")
	}
	// The network being down is no reason to forget the session.
	if words, fatal, _ = refusal(errors.New("dial tcp: no route"), "messenger.com"); fatal || !strings.Contains(words, "could not be reached") {
		t.Fatalf("network: %q %v", words, fatal)
	}
}

func TestSessionKeptPrivately(t *testing.T) {
	d := t.TempDir()
	if loadSession(d) != nil {
		t.Fatal("a session where there is none")
	}
	s := &session{Platform: "messenger", Cookies: map[string]string{"xs": "a", "c_user": "1", "datr": "b"}, Me: "1", Name: "Matt",
		State: json.RawMessage(`{"PacketsSent":3}`), WADevice: 7, Kinds: map[string]int64{"2": 15}}
	if err := saveSession(d, s); err != nil {
		t.Fatal(err)
	}
	if runtime.GOOS != "windows" {
		st, err := os.Stat(sessionPath(d))
		if err != nil || st.Mode().Perm() != 0o600 {
			t.Fatalf("mode: %v %v", st.Mode().Perm(), err)
		}
	}
	if _, err := os.Stat(sessionPath(d) + ".part"); err == nil {
		t.Fatal("the half-written file was left")
	}
	got := loadSession(d)
	if got == nil || got.Cookies["xs"] != "a" || got.Me != "1" || got.Name != "Matt" || got.WADevice != 7 || got.Kinds["2"] != 15 || string(got.State) != `{"PacketsSent":3}` {
		t.Fatalf("read back: %+v", got)
	}
	if err := dropSession(d); err != nil || loadSession(d) != nil {
		t.Fatalf("forget: %v", err)
	}
	if err := dropSession(d); err != nil {
		t.Fatalf("forgetting twice: %v", err)
	}
	// A file that is not a session is no session.
	_ = os.WriteFile(sessionPath(d), []byte("{"), 0o600)
	if loadSession(d) != nil {
		t.Fatal("a broken file was taken")
	}
}

// find is the events of one name, in order.
func find(list []ev, name string) []map[string]any {
	var out []map[string]any
	for _, e := range list {
		if e.Name == name {
			out = append(out, e.Fields)
		}
	}
	return out
}

func asJSON(t *testing.T, v any) string {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func firstTable() *table.LSTable {
	return &table.LSTable{
		LSVerifyContactRowExists: []*table.LSVerifyContactRowExists{
			{ContactId: ada, Name: "Ada Lovelace", SecondaryName: "ada.l", ProfilePictureUrl: "https://scontent.xx.fbcdn.net/v/t1/ada.jpg?oh=1"},
			{ContactId: me, Name: "Matt"},
		},
		LSDeleteThenInsertContact: []*table.LSDeleteThenInsertContact{
			{Id: grace, Name: "Grace Hopper", ProfilePictureUrl: "https://scontent.xx.fbcdn.net/v/t1/grace.jpg"},
		},
		LSDeleteThenInsertThread: []*table.LSDeleteThenInsertThread{
			{ThreadKey: ada, ThreadType: table.ONE_TO_ONE, FolderName: "inbox", LastActivityTimestampMs: 2000, LastReadWatermarkTimestampMs: 1000,
				Snippet: "see you there", SnippetSenderContactId: ada},
			{ThreadKey: group, ThreadType: table.GROUP_THREAD, FolderName: "inbox", ThreadName: "Engines", ThreadPictureUrl: "https://scontent.xx.fbcdn.net/v/t1/engines.jpg",
				LastActivityTimestampMs: 3000, LastReadWatermarkTimestampMs: 3000, Snippet: "ok", SnippetSenderContactId: me, UnreadMessageCount: 0},
			{ThreadKey: 5, ThreadType: table.FOLDER, FolderName: "inbox", ThreadName: "Marketplace"},
		},
		LSAddParticipantIdToGroupThread: []*table.LSAddParticipantIdToGroupThread{
			{ThreadKey: group, ContactId: me}, {ThreadKey: group, ContactId: ada}, {ThreadKey: group, ContactId: grace},
		},
	}
}

func TestThreadsAndContactsBecomeChatsAndNames(t *testing.T) {
	b := newBook(me)
	b.avatar = func(owner, address string) string {
		if address == "" {
			return ""
		}
		return "/avatars/" + owner
	}
	res := b.apply(firstTable())

	names := find(res.Events, "name")
	if len(names) != 3 {
		t.Fatalf("names: %v", names)
	}
	// People first (Messenger's own order of tables is not kept; who is said before the chats they are in).
	if res.Events[0].Name != "name" || res.Events[len(res.Events)-1].Name != "chat" {
		t.Fatalf("order: %v", res.Events)
	}
	var adaName map[string]any
	for _, n := range names {
		if n["id"] == "100000000000002" {
			adaName = n
		}
	}
	if got := asJSON(t, adaName); got != `{"avatar":"/avatars/u100000000000002","handle":"ada.l","id":"100000000000002","name":"Ada Lovelace"}` {
		t.Fatalf("name: %s", got)
	}

	chats := find(res.Events, "chat")
	if len(chats) != 2 {
		t.Fatalf("a folder was said as a chat, or one is missing: %v", chats)
	}
	// Newest first: the group, then Ada.
	if got := asJSON(t, chats[0]); got != `{"avatar":"/avatars/t7000000000000001","encrypted":false,"folder":"inbox","group":true,"id":"7000000000000001","last":3000,"members":[{"id":"100000000000002","name":"Ada Lovelace"},{"id":"100000000000003","name":"Grace Hopper"}],"snippet":"ok","snippet_mine":true,"title":"Engines","unread":0}` {
		t.Fatalf("group: %s", got)
	}
	// With one other person the chat takes their name and picture, and what waits is at least one.
	if got := asJSON(t, chats[1]); got != `{"avatar":"/avatars/u100000000000002","encrypted":false,"folder":"inbox","group":false,"id":"100000000000002","last":2000,"members":[{"id":"100000000000002","name":"Ada Lovelace"}],"snippet":"see you there","snippet_mine":false,"title":"Ada Lovelace","unread":1}` {
		t.Fatalf("one to one: %s", got)
	}
	if list := b.chats(); len(list) != 2 || list[0]["id"] != "7000000000000001" {
		t.Fatalf("chats: %v", list)
	}

	// The same rows again say nothing new about people.
	if again := find(b.apply(&table.LSTable{LSVerifyContactRowExists: firstTable().LSVerifyContactRowExists}).Events, "name"); len(again) != 0 {
		t.Fatalf("said again: %v", again)
	}
	// A group with no name of its own is called by who is in it.
	b.threads[group].Name = ""
	if title := b.chatJSON(b.threads[group])["title"]; title != "Ada Lovelace, Grace Hopper" {
		t.Fatalf("unnamed group: %v", title)
	}
}

func TestMessageWithAttachment(t *testing.T) {
	b := newBook(me)
	b.apply(firstTable())
	res := b.apply(&table.LSTable{
		LSInsertMessage: []*table.LSInsertMessage{{
			ThreadKey: group, MessageId: "mid.$gAAA", SenderId: ada, TimestampMs: 4000, Text: "the plans",
			ReplySourceId: "mid.$gOLD", ReplyMessageText: "send them",
		}},
		LSInsertBlobAttachment: []*table.LSInsertBlobAttachment{
			{MessageId: "mid.$gAAA", AttachmentFbid: "900", Filename: "plans.jpg", Filesize: 2048, AttachmentType: table.AttachmentTypeImage,
				PreviewUrl: "https://scontent.xx.fbcdn.net/v/plans.jpg?oe=1", PreviewUrlMimeType: "image/jpeg", PreviewWidth: 800, PreviewHeight: 600},
			// Messenger sometimes sends the same row twice.
			{MessageId: "mid.$gAAA", AttachmentFbid: "900", Filename: "plans.jpg", PreviewUrl: "https://scontent.xx.fbcdn.net/v/plans.jpg?oe=1"},
		},
	})
	msgs := find(res.Events, "message")
	if len(msgs) != 1 {
		t.Fatalf("messages: %v", res.Events)
	}
	want := `{"chat":"7000000000000001","from":"100000000000002","group":true,"id":"mid.$gAAA","media":[{"height":600,"mime":"image/jpeg","name":"plans.jpg","pointer":{"mime":"image/jpeg","url":"https://scontent.xx.fbcdn.net/v/plans.jpg?oe=1"},"size":2048,"width":800}],"mine":false,"name":"Ada Lovelace","quote":{"id":"mid.$gOLD","text":"send them"},"text":"the plans","ts":4000}`
	if got := asJSON(t, msgs[0]); got != want {
		t.Fatalf("message:\n got %s\nwant %s", got, want)
	}
	// No chat event for a new message (the app counts it), but `chats` is kept current.
	if len(find(res.Events, "chat")) != 0 {
		t.Fatalf("a chat was said for a message: %v", res.Events)
	}
	if c := b.chatJSON(b.threads[group]); c["unread"] != int64(1) || c["last"] != int64(4000) || c["snippet"] != "the plans" || c["snippet_mine"] != false {
		t.Fatalf("chat after: %v", c)
	}

	// The person's own message, a video (a playable address wins over its preview), and the thumbs-up.
	res = b.apply(&table.LSTable{
		LSInsertMessage: []*table.LSInsertMessage{
			{ThreadKey: ada, MessageId: "mid.$cBBB", SenderId: me, TimestampMs: 5000},
			{ThreadKey: ada, MessageId: "mid.$cCCC", SenderId: ada, TimestampMs: 5001, StickerId: 369239263222822},
			{ThreadKey: ada, MessageId: "mid.$cDDD", SenderId: ada, TimestampMs: 5002, IsUnsent: true},
		},
		LSInsertAttachment: []*table.LSInsertAttachment{{
			MessageId: "mid.$cBBB", AttachmentFbid: "901", Filename: "clip.mp4", Filesize: 9000, AttachmentType: table.AttachmentTypeVideo,
			PlayableUrl: "https://video.xx.fbcdn.net/v/clip.mp4", PlayableUrlMimeType: "video/mp4", PreviewUrl: "https://scontent.xx.fbcdn.net/v/clip.jpg",
		}},
		LSInsertStickerAttachment: []*table.LSInsertStickerAttachment{{MessageId: "mid.$cCCC", PreviewUrl: "https://scontent.xx.fbcdn.net/v/thumb.png"}},
	})
	msgs = find(res.Events, "message")
	if len(msgs) != 2 {
		t.Fatalf("an unsent message was said, or one is missing: %v", msgs)
	}
	if m := msgs[0]; m["mine"] != true || m["group"] != false || m["chat"] != "100000000000002" || m["text"] != "" ||
		asJSON(t, m["media"]) != `[{"height":0,"mime":"video/mp4","name":"clip.mp4","pointer":{"mime":"video/mp4","url":"https://video.xx.fbcdn.net/v/clip.mp4"},"size":9000,"width":0}]` {
		t.Fatalf("own video: %s", asJSON(t, m))
	}
	if m := msgs[1]; m["text"] != "👍" || asJSON(t, m["media"]) != `[]` {
		t.Fatalf("thumbs up: %s", asJSON(t, m))
	}
}

func TestLinkPreviewAndShare(t *testing.T) {
	b := newBook(me)
	b.apply(firstTable())
	res := b.apply(&table.LSTable{
		LSInsertMessage: []*table.LSInsertMessage{
			{ThreadKey: ada, MessageId: "mid.$cLINK", SenderId: ada, TimestampMs: 6000, Text: "look https://example.com/a"},
			{ThreadKey: ada, MessageId: "mid.$cPOST", SenderId: ada, TimestampMs: 6001},
		},
		LSInsertXmaAttachment: []*table.LSInsertXmaAttachment{
			{MessageId: "mid.$cLINK", AttachmentFbid: "1", TitleText: "Example", PreviewUrl: "https://external.xx.fbcdn.net/p.jpg"},
			{MessageId: "mid.$cPOST", AttachmentFbid: "2", TitleText: "A post", PreviewUrl: "https://scontent.xx.fbcdn.net/post.jpg", PreviewUrlMimeType: "image/jpeg"},
		},
		LSInsertAttachmentCta: []*table.LSInsertAttachmentCta{
			{AttachmentFbid: "1", Type_: "xma_web_url", ActionUrl: "https://l.facebook.com/l.php?u=https%3A%2F%2Fexample.com%2Fa&h=x"},
			{AttachmentFbid: "2", Type_: "xma_open_native", ActionUrl: "https://www.facebook.com/posts/2", TargetId: 2},
		},
	})
	msgs := find(res.Events, "message")
	if len(msgs) != 2 {
		t.Fatalf("messages: %v", res.Events)
	}
	// A link's preview adds nothing where the words hold the link already.
	if m := msgs[0]; m["text"] != "look https://example.com/a" || asJSON(t, m["media"]) != `[]` {
		t.Fatalf("link: %s", asJSON(t, m))
	}
	// Something shared: its picture, its title and where it leads.
	if m := msgs[1]; m["text"] != "A post\nhttps://www.facebook.com/posts/2" || len(m["media"].([]map[string]any)) != 1 {
		t.Fatalf("share: %s", asJSON(t, m))
	}
}

func TestReactionEditDeleteAndReadMark(t *testing.T) {
	b := newBook(me)
	b.apply(firstTable())
	sent := (&methods.MetaMessageID{ChatType: 'c', ChatID: ada ^ me, Time: time.UnixMilli(1700000000000), TxnID: 1}).String()
	b.apply(&table.LSTable{LSInsertMessage: []*table.LSInsertMessage{
		{ThreadKey: ada, MessageId: "mid.$cONE", SenderId: me, TimestampMs: 7000, Text: "one"},
		{ThreadKey: ada, MessageId: "mid.$cTWO", SenderId: me, TimestampMs: 8000, Text: "two"},
	}})
	res := b.apply(&table.LSTable{
		LSUpsertReaction:    []*table.LSUpsertReaction{{ThreadKey: ada, MessageId: "mid.$cONE", ActorId: ada, Reaction: "❤"}},
		LSDeleteReaction:    []*table.LSDeleteReaction{{ThreadKey: ada, MessageId: "mid.$cTWO", ActorId: ada}},
		LSEditMessage:       []*table.LSEditMessage{{MessageID: "mid.$cTWO", Text: "two!"}, {MessageID: sent, Text: "from its id"}, {MessageID: "unknown", Text: "x"}},
		LSDeleteMessage:     []*table.LSDeleteMessage{{ThreadKey: ada, MessageId: "mid.$cONE"}},
		LSUpdateReadReceipt: []*table.LSUpdateReadReceipt{{ThreadKey: ada, ContactId: ada, ReadWatermarkTimestampMs: 7500}},
		LSDeleteThenInsertMessage: []*table.LSDeleteThenInsertMessage{
			{ThreadKey: ada, MessageId: "mid.$cTWO", IsUnsent: true},
			{ThreadKey: ada, MessageId: "mid.$cKEPT"},
		},
	})
	reactions := find(res.Events, "reaction")
	if len(reactions) != 2 ||
		asJSON(t, reactions[0]) != `{"chat":"100000000000002","emoji":"❤","from":"100000000000002","remove":false,"target":"mid.$cONE"}` ||
		asJSON(t, reactions[1]) != `{"chat":"100000000000002","emoji":"","from":"100000000000002","remove":true,"target":"mid.$cTWO"}` {
		t.Fatalf("reactions: %s", asJSON(t, reactions))
	}
	edits := find(res.Events, "edited")
	// An edit names no chat: it is the one the message was seen in, or the one Meta's id for it says, or unknown.
	if len(edits) != 3 || asJSON(t, edits[0]) != `{"chat":"100000000000002","target":"mid.$cTWO","text":"two!"}` ||
		edits[1]["chat"] != "100000000000002" || edits[2]["chat"] != "" {
		t.Fatalf("edits: %s", asJSON(t, edits))
	}
	deleted := find(res.Events, "deleted")
	if len(deleted) != 2 || asJSON(t, deleted[0]) != `{"chat":"100000000000002","target":"mid.$cONE"}` || deleted[1]["target"] != "mid.$cTWO" {
		t.Fatalf("deleted: %s", asJSON(t, deleted))
	}
	// Read up to a time between the two messages: the first is the one reached.
	receipts := find(res.Events, "receipt")
	if len(receipts) != 1 || asJSON(t, receipts[0]) != `{"chat":"100000000000002","from":"100000000000002","id":"mid.$cONE","kind":"read","ts":7500}` {
		t.Fatalf("receipts: %s", asJSON(t, receipts))
	}

	// The person reads the chat on their phone: nothing waits any more, and the chat is said.
	b.threads[ada].Unread, b.threads[ada].Last = 3, 9000
	res = b.apply(&table.LSTable{LSMarkThreadReadV2: []*table.LSMarkThreadReadV2{{ThreadKey: ada, LastReadWatermarkTimestampMs: 9000}}})
	if chats := find(res.Events, "chat"); len(chats) != 1 || chats[0]["unread"] != int64(0) {
		t.Fatalf("read elsewhere: %v", res.Events)
	}
	if r := find(res.Events, "receipt"); len(r) != 1 || r[0]["from"] != "100000000000001" {
		t.Fatalf("own read mark: %v", r)
	}
}

func TestHistoryIsKeptNotSaid(t *testing.T) {
	b := newBook(me)
	b.apply(firstTable())
	res := b.apply(&table.LSTable{
		LSInsertNewMessageRange: []*table.LSInsertNewMessageRange{{ThreadKey: ada, MinTimestampMs: 100, MaxTimestampMs: 300, MinMessageId: "mid.$cH1", MaxMessageId: "mid.$cH3", HasMoreBefore: true}},
		LSUpsertMessage: []*table.LSUpsertMessage{
			{ThreadKey: ada, MessageId: "mid.$cH3", SenderId: ada, TimestampMs: 300, Text: "three"},
			{ThreadKey: ada, MessageId: "mid.$cH1", SenderId: me, TimestampMs: 100, Text: "one"},
			{ThreadKey: ada, MessageId: "mid.$cH2", SenderId: ada, TimestampMs: 200, Text: "two", IsUnsent: true},
		},
	})
	if len(find(res.Events, "message")) != 0 {
		t.Fatalf("history was said as new messages: %v", res.Events)
	}
	if up := res.Upserts[ada]; up == nil || len(up.Messages) != 3 {
		t.Fatalf("the stretch was not handed on: %v", res.Upserts)
	}
	list, more, ok := b.history(ada, "")
	if !ok || !more || len(list) != 2 || list[0]["id"] != "mid.$cH1" || list[1]["id"] != "mid.$cH3" || list[0]["mine"] != true {
		t.Fatalf("history: %v %v %v", list, more, ok)
	}
	list, _, ok = b.history(ada, "mid.$cH3")
	if !ok || len(list) != 1 || list[0]["id"] != "mid.$cH1" {
		t.Fatalf("before the newest: %v %v", list, ok)
	}
	// Nothing older is kept and Messenger has more: it has to be asked.
	if _, _, ok = b.history(ada, "mid.$cH1"); ok {
		t.Fatal("answered from nothing")
	}
	if _, _, ok = b.history(group, ""); ok {
		t.Fatal("a chat with no history kept was answered")
	}
	// A stretch Messenger sends in answer is given straight on, older than the message asked about.
	list, more = b.stretch(&table.UpsertMessages{
		Range:    &table.LSInsertNewMessageRange{ThreadKey: ada, HasMoreBefore: false},
		Messages: []*table.WrappedMessage{{LSInsertMessage: &table.LSInsertMessage{ThreadKey: ada, MessageId: "mid.$cH0", SenderId: ada, TimestampMs: 50, Text: "zero"}}},
	}, "mid.$cH1")
	if more || len(list) != 1 || list[0]["text"] != "zero" {
		t.Fatalf("stretch: %v %v", list, more)
	}
}

func TestEncryptedThreadsAreKnown(t *testing.T) {
	b := newBook(me)
	res := b.apply(&table.LSTable{
		LSVerifyContactRowExists:   []*table.LSVerifyContactRowExists{{ContactId: ada, Name: "Ada Lovelace"}},
		LSVerifyHybridThreadExists: []*table.LSVerifyHybridThreadExists{{ThreadKey: 555, ThreadJID: ada, ThreadType: table.ENCRYPTED_OVER_WA_ONE_TO_ONE}},
		LSDeleteThenInsertThread: []*table.LSDeleteThenInsertThread{
			{ThreadKey: 555, ThreadType: table.ONE_TO_ONE, FolderName: "inbox", LastActivityTimestampMs: 10},
			{ThreadKey: grace, ThreadType: table.ONE_TO_ONE, FolderName: "e2ee_cutover", LastActivityTimestampMs: 5},
		},
	})
	chats := find(res.Events, "chat")
	// A thread Messenger keeps under another number on its own list is known by its encrypted-side number.
	if len(chats) != 2 || chats[0]["id"] != "100000000000002" || chats[0]["encrypted"] != true || chats[0]["title"] != "Ada Lovelace" {
		t.Fatalf("hybrid: %s", asJSON(t, chats))
	}
	if chats[1]["id"] != "100000000000003" || chats[1]["encrypted"] != true {
		t.Fatalf("cut over: %s", asJSON(t, chats))
	}
	if th := b.threadCopy(ada); th.FBKey != 555 || !th.Type.IsWhatsApp() {
		t.Fatalf("thread: %+v", th)
	}
	if b.kinds[grace] != table.ENCRYPTED_OVER_WA_ONE_TO_ONE {
		t.Fatalf("kinds: %v", b.kinds)
	}
}

func textMessage(text string) *waConsumerApplication.ConsumerApplication {
	return consumerContent(&waConsumerApplication.ConsumerApplication_Content{
		Content: &waConsumerApplication.ConsumerApplication_Content_MessageText{MessageText: &waCommon.MessageText{Text: proto.String(text)}},
	})
}

func TestEncryptedMessages(t *testing.T) {
	b := newBook(me)
	b.apply(&table.LSTable{LSVerifyContactRowExists: []*table.LSVerifyContactRowExists{{ContactId: ada, Name: "Ada Lovelace"}}})
	adaJID := waTypes.JID{User: idString(ada), Server: waTypes.MessengerServer}
	meJID := waTypes.JID{User: idString(me), Device: 3, Server: waTypes.MessengerServer}
	info := waTypes.MessageInfo{MessageSource: waTypes.MessageSource{Chat: adaJID, Sender: adaJID}, ID: "3EB0ABC", Timestamp: time.UnixMilli(12000)}

	met, out := b.sealed(&events.FBMessage{Info: info, Message: textMessage("hello")})
	if !met || len(out) != 1 || out[0].Name != "message" {
		t.Fatalf("text: %v %v", met, out)
	}
	want := `{"chat":"100000000000002","encrypted":true,"from":"100000000000002","group":false,"id":"wa:100000000000002:3EB0ABC","media":[],"mine":false,"name":"Ada Lovelace","text":"hello","ts":12000}`
	if got := asJSON(t, out[0].Fields); got != want {
		t.Fatalf("text:\n got %s\nwant %s", got, want)
	}
	if !b.threadCopy(ada).Type.IsWhatsApp() {
		t.Fatal("the chat was not marked encrypted")
	}

	// The person's own message from their phone, reacting to Ada's: in the key "from me" is false, so between two
	// people the target is the other one's.
	own := waTypes.MessageInfo{MessageSource: waTypes.MessageSource{Chat: adaJID, Sender: meJID, IsFromMe: true}, ID: "R1", Timestamp: time.UnixMilli(13000)}
	met, out = b.sealed(&events.FBMessage{Info: own, Message: consumerContent(&waConsumerApplication.ConsumerApplication_Content{
		Content: &waConsumerApplication.ConsumerApplication_Content_ReactionMessage{ReactionMessage: &waConsumerApplication.ConsumerApplication_ReactionMessage{
			Key: &waCommon.MessageKey{ID: proto.String("3EB0ABC")}, Text: proto.String("👍"),
		}},
	})})
	if met || len(out) != 1 || asJSON(t, out[0].Fields) != `{"chat":"100000000000002","emoji":"👍","from":"100000000000001","remove":false,"target":"wa:100000000000002:3EB0ABC"}` {
		t.Fatalf("reaction: %v %s", met, asJSON(t, out))
	}
	// Ada edits her own message, then unsends it.
	_, out = b.sealed(&events.FBMessage{Info: info, Message: consumerContent(&waConsumerApplication.ConsumerApplication_Content{
		Content: &waConsumerApplication.ConsumerApplication_Content_EditMessage{EditMessage: &waConsumerApplication.ConsumerApplication_EditMessage{
			Key: &waCommon.MessageKey{ID: proto.String("3EB0ABC"), FromMe: proto.Bool(true)}, Message: &waCommon.MessageText{Text: proto.String("hello!")},
		}},
	})})
	if len(out) != 1 || asJSON(t, out[0].Fields) != `{"chat":"100000000000002","target":"wa:100000000000002:3EB0ABC","text":"hello!"}` {
		t.Fatalf("edit: %s", asJSON(t, out))
	}
	_, out = b.sealed(&events.FBMessage{Info: info, Message: &waConsumerApplication.ConsumerApplication{Payload: &waConsumerApplication.ConsumerApplication_Payload{
		Payload: &waConsumerApplication.ConsumerApplication_Payload_ApplicationData{ApplicationData: &waConsumerApplication.ConsumerApplication_ApplicationData{
			ApplicationContent: &waConsumerApplication.ConsumerApplication_ApplicationData_Revoke{Revoke: &waConsumerApplication.ConsumerApplication_RevokeMessage{
				Key: &waCommon.MessageKey{ID: proto.String("3EB0ABC"), FromMe: proto.Bool(true)},
			}},
		}},
	}}})
	if len(out) != 1 || out[0].Name != "deleted" || out[0].Fields["target"] != "wa:100000000000002:3EB0ABC" {
		t.Fatalf("unsend: %s", asJSON(t, out))
	}
	// A setting of the chat is not a message.
	if _, out = b.sealed(&events.FBMessage{Info: info}); len(out) != 0 {
		t.Fatalf("a setting was said: %v", out)
	}

	// Ada's devices say she read the person's message.
	r := b.sealedReceipt(&events.Receipt{MessageSource: waTypes.MessageSource{Chat: adaJID, Sender: adaJID}, MessageIDs: []string{"A", "B"}, Timestamp: time.UnixMilli(14000), Type: waTypes.ReceiptTypeRead})
	if len(r) != 1 || asJSON(t, r[0].Fields) != `{"chat":"100000000000002","from":"100000000000002","id":"wa:100000000000001:B","kind":"read","ts":14000}` {
		t.Fatalf("receipt: %s", asJSON(t, r))
	}

	// Pointing back at a message, for a reaction or an unsend of the helper's own.
	key, err := keyFor(me, chatJID(b.threadCopy(ada)), "wa:100000000000001:99")
	if err != nil || key.GetID() != "99" || !key.GetFromMe() || key.GetRemoteJID() != "100000000000002@msgr" || key.Participant != nil {
		t.Fatalf("key: %v %v", key, err)
	}
	if _, err = keyFor(me, adaJID, "mid.$cONE"); err == nil {
		t.Fatal("an ordinary message's id was taken for an encrypted one's")
	}
	if s, id, ok := parseSealedID("wa:1:a:b"); !ok || s != "1" || id != "a:b" {
		t.Fatalf("id: %q %q %v", s, id, ok)
	}
}

func TestOnlyMetaAddressesAreFetched(t *testing.T) {
	for address, want := range map[string]bool{
		"https://scontent.xx.fbcdn.net/v/a.jpg":  true,
		"https://video.xx.fbcdn.net/v/a.mp4":     true,
		"https://lookaside.fbsbx.com/file/a.pdf": true,
		"http://scontent.xx.fbcdn.net/v/a.jpg":   false,
		"https://fbcdn.net.example.com/a.jpg":    false,
		"https://example.com/a.jpg":              false,
		"file:///etc/passwd":                     false,
	} {
		if metaAddress(address) != want {
			t.Errorf("%s: wanted %v", address, want)
		}
	}
	// A picture's file is named by whose it is and its own name, not by the rest of its address, which changes.
	a := avatarName("u1", "https://scontent.xx.fbcdn.net/v/t1/ada.jpg?oh=1&oe=2")
	if a != avatarName("u1", "https://scontent-lhr.xx.fbcdn.net/v/t2/ada.jpg?oh=3") || a == avatarName("u2", "https://scontent.xx.fbcdn.net/v/t1/ada.jpg") {
		t.Fatal("avatar names")
	}
	if filepath.Base(a) != a || len(a) != 24 {
		t.Fatalf("avatar name: %q", a)
	}
}

func TestSentID(t *testing.T) {
	id, err := sentID(&table.LSTable{LSReplaceOptimsiticMessage: []*table.LSReplaceOptimsiticMessage{
		{OfflineThreadingId: "1", MessageId: "mid.$other"}, {OfflineThreadingId: "42", MessageId: "mid.$mine"},
	}}, 42)
	if err != nil || id != "mid.$mine" {
		t.Fatalf("sent: %q %v", id, err)
	}
	_, err = sentID(&table.LSTable{LSMarkOptimisticMessageFailed: []*table.LSMarkOptimisticMessageFailed{{Message: "You can't message this person"}}}, 42)
	if err == nil || !strings.Contains(err.Error(), "You can't message this person") {
		t.Fatalf("refused: %v", err)
	}
	if _, err = sentID(nil, 42); err == nil || !strings.Contains(err.Error(), "may or may not") {
		t.Fatalf("unconfirmed: %v", err)
	}
}

// The encrypted chats' key store opens (and makes its tables) with whichever SQLite this build has.
func TestKeyStoreOpens(t *testing.T) {
	old := dir
	dir = t.TempDir()
	defer func() { closeKeys(); dir = old }()
	c, err := openKeys(bg())
	if err != nil {
		t.Fatal(err)
	}
	dev := c.NewDevice()
	if dev == nil || dev.IdentityKey == nil {
		t.Fatal("no device keys")
	}
	if all, err := c.GetAllDevices(bg()); err != nil || len(all) != 0 {
		t.Fatalf("devices: %v %v", all, err)
	}
	if runtime.GOOS != "windows" {
		if st, err := os.Stat(keysPath()); err != nil || st.Mode().Perm() != 0o600 {
			t.Fatalf("mode: %v", err)
		}
	}
}

// A picture over the cap is refused and nothing of it kept; one of exactly the cap is kept whole.
func TestAtMostRefusesTheLonger(t *testing.T) {
	d := t.TempDir()
	dest := filepath.Join(d, "u1")
	if err := writeWhole(dest, &atMost{r: strings.NewReader(strings.Repeat("x", 9)), left: 8}); err == nil {
		t.Fatal("a picture past the cap was kept")
	}
	for _, name := range []string{dest, dest + ".part"} {
		if _, err := os.Stat(name); !os.IsNotExist(err) {
			t.Fatalf("%s is left: %v", name, err)
		}
	}
	if err := writeWhole(dest, &atMost{r: strings.NewReader(strings.Repeat("x", 8)), left: 8}); err != nil {
		t.Fatal(err)
	}
	if st, err := os.Stat(dest); err != nil || st.Size() != 8 {
		t.Fatalf("kept: %v %v", st, err)
	}
}
