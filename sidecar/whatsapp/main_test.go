package main

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"google.golang.org/protobuf/proto"

	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/proto/waAdv"
	"go.mau.fi/whatsmeow/proto/waCommon"
	"go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/proto/waHistorySync"
	"go.mau.fi/whatsmeow/proto/waWeb"
	"go.mau.fi/whatsmeow/store/sqlstore"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
)

// Tests of the helper's parts that need no WhatsApp account: reading requests, shaping answers, media pointers there
// and back, and WhatsApp's messages and history turned into the app's events.

func TestParseRequest(t *testing.T) {
	r, err := parseRequest([]byte(`{"id":9,"op":"read","to":"15550100@s.whatsapp.net","author":"15550101@s.whatsapp.net","ids":["A1","B2"]}`))
	if err != nil || r.ID != 9 || r.Op != "read" || len(r.IDs) != 2 || r.IDs[1] != "B2" {
		t.Fatalf("read: %+v %v", r, err)
	}
	r, err = parseRequest([]byte(`{"id":7,"op":"send","to":"x@g.us","text":"hi","quote":{"id":"Q1","author":"y@s.whatsapp.net","text":"was"}}`))
	if err != nil || r.Quote == nil || r.Quote.ID != "Q1" || r.Quote.Author != "y@s.whatsapp.net" || r.Quote.Text != "was" {
		t.Fatalf("send: %+v %v", r, err)
	}
	r, err = parseRequest([]byte(`{"id":3,"op":"pair_phone","phone":"+1 555 0100"}`))
	if err != nil || r.Phone != "+1 555 0100" {
		t.Fatalf("pair_phone: %+v %v", r, err)
	}
	r, err = parseRequest([]byte(`{"id":14,"op":"block","jid":"15550100@s.whatsapp.net","on":true}`))
	if err != nil || !r.On || r.JID == "" {
		t.Fatalf("block: %+v %v", r, err)
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
	b, _ = json.Marshal(answer(2, map[string]any{"code": "ABCD-EFGH"}, nil))
	if string(b) != `{"id":2,"ok":true,"result":{"code":"ABCD-EFGH"}}` {
		t.Fatalf("result: %s", b)
	}
	b, _ = json.Marshal(answer(3, nil, errors.New("no")))
	if string(b) != `{"error":"no","id":3,"ok":false}` {
		t.Fatalf("error: %s", b)
	}
}

func TestParseJID(t *testing.T) {
	for in, want := range map[string]string{
		"15550100@s.whatsapp.net": "15550100@s.whatsapp.net",
		"120363000000000001@g.us": "120363000000000001@g.us",
		"+1 (555) 010-0199":       "15550100199@s.whatsapp.net",
		"123456789012345@lid":     "123456789012345@lid",
	} {
		got, err := parseJID(in)
		if err != nil || got.String() != want {
			t.Fatalf("%q → %v %v, want %s", in, got, err, want)
		}
	}
	for _, bad := range []string{"", "nope", "12"} {
		if _, err := parseJID(bad); err == nil {
			t.Fatalf("%q taken as a chat", bad)
		}
	}
}

func TestPointerRoundTrip(t *testing.T) {
	im := &waE2E.ImageMessage{
		DirectPath: proto.String("/v/t62/abc"), MediaKey: []byte{1, 2, 3}, FileSHA256: []byte{4}, FileEncSHA256: []byte{5},
		FileLength: proto.Uint64(9), Mimetype: proto.String("image/jpeg"), JPEGThumbnail: []byte{9, 9, 9},
	}
	p := pointerOf("image", im)
	line, err := json.Marshal(p)
	if err != nil {
		t.Fatal(err)
	}
	for _, raw := range []json.RawMessage{line, mustQuote(line)} {
		got, err := parsePointer(raw)
		if err != nil {
			t.Fatal(err)
		}
		back := got.(*waE2E.ImageMessage)
		if back.GetDirectPath() != "/v/t62/abc" || string(back.GetMediaKey()) != string([]byte{1, 2, 3}) || back.GetFileLength() != 9 {
			t.Fatalf("pointer changed: %v", back)
		}
		if len(back.GetJPEGThumbnail()) != 0 {
			t.Fatal("the thumbnail was kept in the pointer")
		}
	}
	if len(im.GetJPEGThumbnail()) == 0 {
		t.Fatal("making a pointer changed the message")
	}
	if _, err := parsePointer(json.RawMessage(`{"kind":"image","msg":{"directPath":"/x"}}`)); err == nil {
		t.Fatal("a pointer without a key was taken")
	}
	if _, err := parsePointer(json.RawMessage(`{"kind":"poll","msg":{}}`)); err == nil {
		t.Fatal("an unknown kind was taken")
	}
}

// mustQuote is [b] as a JSON string: a pointer as the app sends it when it kept the object as text.
func mustQuote(b []byte) json.RawMessage {
	q, _ := json.Marshal(string(b))
	return q
}

func TestTextMessageQuote(t *testing.T) {
	plain := textMessage("hi", nil)
	if plain.GetConversation() != "hi" || plain.GetExtendedTextMessage() != nil {
		t.Fatalf("plain: %v", plain)
	}
	r := textMessage("yes", &quote{ID: "Q1", Author: "15550100@s.whatsapp.net", Text: "coming?"})
	ci := r.GetExtendedTextMessage().GetContextInfo()
	if r.GetExtendedTextMessage().GetText() != "yes" || ci.GetStanzaID() != "Q1" || ci.GetParticipant() != "15550100@s.whatsapp.net" || ci.GetQuotedMessage().GetConversation() != "coming?" {
		t.Fatalf("reply: %v", r)
	}
}

func TestContent(t *testing.T) {
	text, media, _ := content(&waE2E.Message{ImageMessage: &waE2E.ImageMessage{Caption: proto.String("beach"), Mimetype: proto.String("image/jpeg"), MediaKey: []byte{1}, Width: proto.Uint32(800), Height: proto.Uint32(600)}})
	if text != "beach" || len(media) != 1 || media[0]["mime"] != "image/jpeg" || media[0]["width"] != uint32(800) {
		t.Fatalf("image: %q %v", text, media)
	}
	text, _, ci := content(&waE2E.Message{ExtendedTextMessage: &waE2E.ExtendedTextMessage{Text: proto.String("sure"), ContextInfo: &waE2E.ContextInfo{StanzaID: proto.String("Q")}}})
	if text != "sure" || ci.GetStanzaID() != "Q" {
		t.Fatalf("extended: %q %v", text, ci)
	}
	if text, media, _ := content(&waE2E.Message{}); text != "" || len(media) != 0 {
		t.Fatal("an empty message has content")
	}
}

func TestMediaKind(t *testing.T) {
	for mime, want := range map[string]string{"image/jpeg": "image", "image/webp": "document", "video/mp4": "video", "audio/ogg": "audio", "application/pdf": "document"} {
		if got := mediaKind(mime); got != want {
			t.Fatalf("%s → %s, want %s", mime, got, want)
		}
	}
}

// testClient is a whatsmeow client on an in-memory store, linked as +15550100199, never connected.
func testClient(t *testing.T) *whatsmeow.Client {
	t.Helper()
	ct, err := sqlstore.New(context.Background(), "sqlite3", "file:"+t.Name()+"?mode=memory&cache=shared&_foreign_keys=on", nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = ct.Close() })
	dev := ct.NewDevice()
	own := types.NewJID("15550100199", types.DefaultUserServer)
	dev.ID = &own
	dev.Account = &waAdv.ADVSignedDeviceIdentity{Details: []byte{0}, AccountSignature: make([]byte, 64), AccountSignatureKey: make([]byte, 32), DeviceSignature: make([]byte, 64)}
	if err := ct.PutDevice(context.Background(), dev); err != nil {
		t.Fatal(err)
	}
	return whatsmeow.NewClient(dev, nil)
}

func TestMessagesReactionsAndDeletes(t *testing.T) {
	c := testClient(t)
	jo := types.NewJID("15550100", types.DefaultUserServer)
	info := types.MessageInfo{MessageSource: types.MessageSource{Chat: jo, Sender: jo}, ID: "M1", PushName: "Jo", Timestamp: time.UnixMilli(1763200000000)}
	m := messageMap(c, &events.Message{Info: info, Message: &waE2E.Message{ExtendedTextMessage: &waE2E.ExtendedTextMessage{
		Text: proto.String("yes!"), ContextInfo: &waE2E.ContextInfo{StanzaID: proto.String("M0"), QuotedMessage: &waE2E.Message{Conversation: proto.String("coming?")}},
	}}}, false)
	if m["ev"] != "message" || m["chat"] != "15550100@s.whatsapp.net" || m["id"] != "M1" || m["text"] != "yes!" || m["name"] != "Jo" || m["mine"] != false || m["ts"] != int64(1763200000000) {
		t.Fatalf("message: %v", m)
	}
	q := m["quote"].(map[string]any)
	if q["id"] != "M0" || q["author"] != "15550100@s.whatsapp.net" || q["text"] != "coming?" {
		t.Fatalf("quote: %v", q)
	}
	r := messageMap(c, &events.Message{Info: info, Message: &waE2E.Message{ReactionMessage: &waE2E.ReactionMessage{
		Key: &waCommon.MessageKey{ID: proto.String("M9"), FromMe: proto.Bool(true)}, Text: proto.String("👍"),
	}}}, false)
	if r["ev"] != "reaction" || r["target_id"] != "M9" || r["emoji"] != "👍" || r["remove"] != false || r["from"] != "15550100@s.whatsapp.net" {
		t.Fatalf("reaction: %v", r)
	}
	d := messageMap(c, &events.Message{Info: info, Message: &waE2E.Message{ProtocolMessage: &waE2E.ProtocolMessage{
		Type: waE2E.ProtocolMessage_REVOKE.Enum(), Key: &waCommon.MessageKey{ID: proto.String("M1")},
	}}}, false)
	if d["ev"] != "deleted" || d["target_id"] != "M1" {
		t.Fatalf("delete: %v", d)
	}
	mine := info
	mine.IsFromMe = true
	mine.Sender = *c.Store.ID
	if s := messageMap(c, &events.Message{Info: mine, Message: &waE2E.Message{Conversation: proto.String("on my way")}}, false); s["mine"] != true || s["from"] != "15550100199@s.whatsapp.net" || s["name"] != "" {
		t.Fatalf("mine: %v", s)
	}
	group := types.NewJID("120363000000000001", types.GroupServer)
	if s := messageMap(c, &events.Message{Info: types.MessageInfo{MessageSource: types.MessageSource{Chat: group, Sender: jo, IsGroup: true}, ID: "G1"}, Message: &waE2E.Message{Conversation: proto.String("hello all")}}, false); s["group"] != true || s["chat"] != "120363000000000001@g.us" || s["from"] != "15550100@s.whatsapp.net" {
		t.Fatalf("group: %v", s)
	}
	if s := messageMap(c, &events.Message{Info: types.MessageInfo{MessageSource: types.MessageSource{Chat: types.StatusBroadcastJID, Sender: jo}}, Message: &waE2E.Message{Conversation: proto.String("status")}}, false); s != nil {
		t.Fatalf("a status update was shown: %v", s)
	}
}

func TestHistoryConversation(t *testing.T) {
	c := testClient(t)
	key := func(id string, me bool) *waCommon.MessageKey {
		return &waCommon.MessageKey{RemoteJID: proto.String("15550100@s.whatsapp.net"), FromMe: proto.Bool(me), ID: proto.String(id)}
	}
	conv := &waHistorySync.Conversation{
		ID: proto.String("15550100@s.whatsapp.net"), Name: proto.String("Jo Park"), UnreadCount: proto.Uint32(1), LastMsgTimestamp: proto.Uint64(1763200100),
		Messages: []*waHistorySync.HistorySyncMsg{
			{Message: &waWeb.WebMessageInfo{Key: key("H2", false), MessageTimestamp: proto.Uint64(1763200100), Message: &waE2E.Message{Conversation: proto.String("are you coming?")},
				Reactions: []*waWeb.Reaction{{Key: &waCommon.MessageKey{FromMe: proto.Bool(true)}, Text: proto.String("❤️")}}}},
			{Message: &waWeb.WebMessageInfo{Key: key("H1", true), MessageTimestamp: proto.Uint64(1763200000), Message: &waE2E.Message{Conversation: proto.String("hi Jo")}}},
		},
	}
	m := conversation(c, conv)
	if m == nil || m["chat"] != "15550100@s.whatsapp.net" || m["group"] != false || m["name"] != "Jo Park" || m["unread"] != uint32(1) || m["last"] != int64(1763200100000) {
		t.Fatalf("conversation: %v", m)
	}
	msgs := m["messages"].([]map[string]any)
	if len(msgs) != 2 || msgs[0]["id"] != "H1" || msgs[0]["mine"] != true || msgs[1]["text"] != "are you coming?" || msgs[1]["history"] != true {
		t.Fatalf("messages: %v", msgs)
	}
	if r := msgs[1]["reactions"].(map[string]string); r["15550100199@s.whatsapp.net"] != "❤️" {
		t.Fatalf("reactions: %v", r)
	}
	if conversation(c, &waHistorySync.Conversation{ID: proto.String("status@broadcast")}) != nil {
		t.Fatal("the status list was taken as a chat")
	}
}

// A download that can't be moved into place (here a folder stands where the file should go) leaves no ".part" behind.
func TestWriteWholeLeavesNoPart(t *testing.T) {
	d := t.TempDir()
	good := filepath.Join(d, "a.jpg")
	if err := writeWhole(good, []byte("abc")); err != nil {
		t.Fatal(err)
	}
	if b, _ := os.ReadFile(good); string(b) != "abc" {
		t.Fatalf("written: %q", b)
	}
	taken := filepath.Join(d, "taken")
	if err := os.MkdirAll(filepath.Join(taken, "in"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := writeWhole(taken, []byte("abc")); err == nil {
		t.Fatal("written over a folder")
	}
	if _, err := os.Stat(taken + ".part"); !os.IsNotExist(err) {
		t.Fatalf("the .part is left: %v", err)
	}
}
