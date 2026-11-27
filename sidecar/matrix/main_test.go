package main

import (
	"context"
	"encoding/json"
	"errors"
	"testing"

	"go.mau.fi/util/dbutil"

	"maunium.net/go/mautrix/crypto"
	"maunium.net/go/mautrix/event"
	"maunium.net/go/mautrix/id"
	"maunium.net/go/mautrix/sqlstatestore"
)

// Tests of the helper's parts that need no homeserver: reading requests, shaping answers, what a typed server
// resolves to, room titles, events turned into the app's messages, the store on SQLite, and the rooms kept across a
// restart.

func TestParseRequest(t *testing.T) {
	r, err := parseRequest([]byte(`{"id":8,"op":"send","room":"!r:s","text":"hi","reply_to":"$e"}`))
	if err != nil || r.ID != 8 || r.Op != "send" || r.Room != "!r:s" || r.Text != "hi" || r.ReplyTo != "$e" {
		t.Fatalf("send: %+v %v", r, err)
	}
	r, err = parseRequest([]byte(`{"id":13,"op":"download","mxc":"mxc://s/a","file":{"url":"mxc://s/a"},"path":"/x"}`))
	if err != nil || r.MXC != "mxc://s/a" || string(r.File) != `{"url":"mxc://s/a"}` || r.Path != "/x" {
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
	b, _ := json.Marshal(answer(1, nil, nil))
	if string(b) != `{"id":1,"ok":true,"result":null}` {
		t.Fatalf("null result: %s", b)
	}
	b, _ = json.Marshal(answer(3, nil, errors.New("no")))
	if string(b) != `{"error":"no","id":3,"ok":false}` {
		t.Fatalf("error: %s", b)
	}
}

func TestParseHomeserver(t *testing.T) {
	cases := []struct {
		in                 string
		server, base, user string
		bad                bool
	}{
		{in: "", server: "matrix.org"},
		{in: " Matrix.org ", server: "matrix.org"},
		{in: "@me:matrix.org", server: "matrix.org", user: "@me:matrix.org"},
		{in: "@me:example.com:8448", server: "example.com:8448", user: "@me:example.com:8448"},
		{in: "https://matrix.example.com/", base: "https://matrix.example.com"},
		{in: "@nobody", bad: true},
		{in: "two words", bad: true},
	}
	for _, c := range cases {
		got, err := parseHomeserver(c.in)
		if c.bad {
			if err == nil {
				t.Errorf("%q was taken: %+v", c.in, got)
			}
			continue
		}
		if err != nil || got.Server != c.server || got.Base != c.base || got.User != c.user {
			t.Errorf("%q: %+v %v", c.in, got, err)
		}
	}
}

func TestSSOURLAndIdentifier(t *testing.T) {
	got := ssoURL("https://matrix-client.matrix.org/", "http://127.0.0.1:5123/done?x=1")
	want := "https://matrix-client.matrix.org/_matrix/client/v3/login/sso/redirect?redirectUrl=http%3A%2F%2F127.0.0.1%3A5123%2Fdone%3Fx%3D1"
	if got != want {
		t.Fatalf("sso: %s", got)
	}
	if loginIdentifier(" @me:matrix.org ") != "@me:matrix.org" || loginIdentifier("me") != "me" {
		t.Fatal("identifier")
	}
}

func TestRoomTitle(t *testing.T) {
	jo, sam, riley, kim := id.UserID("@jo:s"), id.UserID("@sam:s"), id.UserID("@riley:s"), id.UserID("@kim:s")
	names := map[id.UserID]string{jo: "Jo Park", sam: "Sam"}
	if s := roomTitle("Weekend crew", "#crew:s", []id.UserID{jo}, names, false); s != "Weekend crew" {
		t.Fatal(s)
	}
	if s := roomTitle("", "#crew:s", []id.UserID{jo}, names, false); s != "#crew:s" {
		t.Fatal(s)
	}
	if s := roomTitle("", "", []id.UserID{jo}, names, true); s != "Jo Park" {
		t.Fatal(s)
	}
	if s := roomTitle("", "", []id.UserID{riley}, names, true); s != "riley" {
		t.Fatal("no display name: the localpart, never blank:", s)
	}
	if s := roomTitle("", "", []id.UserID{jo, sam}, names, false); s != "Jo Park and Sam" {
		t.Fatal(s)
	}
	if s := roomTitle("", "", []id.UserID{jo, sam, riley, kim}, names, false); s != "Jo Park, Sam and 2 others" {
		t.Fatal(s)
	}
	if s := roomTitle("", "", nil, names, true); s != "Matrix contact" {
		t.Fatal(s)
	}
}

// parsed is [raw], an event as a homeserver sends it, read into mautrix's type.
func parsed(t *testing.T, raw string) *event.Event {
	t.Helper()
	var evt event.Event
	if err := json.Unmarshal([]byte(raw), &evt); err != nil {
		t.Fatal(err)
	}
	return &evt
}

func TestMessageOf(t *testing.T) {
	me := id.UserID("@me:s")
	text := parsed(t, `{"type":"m.room.message","event_id":"$1","room_id":"!r:s","sender":"@jo:s","origin_server_ts":1763200000000,
		"content":{"msgtype":"m.text","body":"> <@me:s> are you coming?\n\non my way","m.relates_to":{"m.in_reply_to":{"event_id":"$0"}}}}`)
	m := messageOf(text, me, "Jo Park")
	if m["text"] != "on my way" || m["reply_to"] != "$0" || m["mine"] != false || m["name"] != "Jo Park" || m["ts"] != int64(1763200000000) {
		t.Fatalf("reply: %v", m)
	}
	mine := parsed(t, `{"type":"m.room.message","event_id":"$2","room_id":"!r:s","sender":"@me:s","origin_server_ts":5,"content":{"msgtype":"m.emote","body":"waves"}}`)
	if m := messageOf(mine, me, ""); m["mine"] != true || m["text"] != "* waves" {
		t.Fatalf("emote: %v", m)
	}
	pic := parsed(t, `{"type":"m.room.message","event_id":"$3","room_id":"!r:s","sender":"@jo:s","origin_server_ts":6,
		"content":{"msgtype":"m.image","body":"look at this","filename":"beach.jpg","info":{"mimetype":"image/jpeg","w":800,"h":600,"size":2048},
		"file":{"url":"mxc://s/abc","v":"v2","key":{"kty":"oct","key_ops":["encrypt","decrypt"],"alg":"A256CTR","k":"qcHVMSgYg-71CauWBezXI5qkaRb0LuIy-Wx5kIaHMIA","ext":true},"iv":"X85+XgHN+HEAAAAAAAAAAA","hashes":{"sha256":"5qG4fFnbbVdlAB1Q72JDKwCagV6Dbkx9uds4rSak37c"}}}}`)
	m = messageOf(pic, me, "")
	media := m["media"].([]any)
	if len(media) != 1 || m["text"] != "look at this" {
		t.Fatalf("picture: %v", m)
	}
	first := media[0].(map[string]any)
	if first["mxc"] != "mxc://s/abc" || first["mime"] != "image/jpeg" || first["width"] != 800 || first["name"] != "beach.jpg" || first["file"] == nil {
		t.Fatalf("picture media: %v", first)
	}
	// The key goes back to download as it came, and is read there.
	b, _ := json.Marshal(first["file"])
	var back event.EncryptedFileInfo
	if err := json.Unmarshal(b, &back); err != nil || back.URL != "mxc://s/abc" || back.PrepareForDecryption() != nil {
		t.Fatalf("file round trip: %s %v", b, err)
	}
	edit := parsed(t, `{"type":"m.room.message","event_id":"$4","room_id":"!r:s","sender":"@jo:s","origin_server_ts":7,
		"content":{"msgtype":"m.text","body":"* fixed","m.new_content":{"msgtype":"m.text","body":"fixed"},"m.relates_to":{"rel_type":"m.replace","event_id":"$1"}}}`)
	if m := messageOf(edit, me, ""); m["replaces"] != "$1" || m["text"] != "fixed" {
		t.Fatalf("edit: %v", m)
	}
	gone := parsed(t, `{"type":"m.room.message","event_id":"$5","room_id":"!r:s","sender":"@jo:s","origin_server_ts":8,"content":{},
		"unsigned":{"redacted_because":{"type":"m.room.redaction","event_id":"$6","sender":"@jo:s","origin_server_ts":9,"content":{}}}}`)
	if m := messageOf(gone, me, ""); m != nil {
		t.Fatalf("redacted: %v", m)
	}
	state := parsed(t, `{"type":"m.room.name","state_key":"","event_id":"$7","room_id":"!r:s","sender":"@jo:s","origin_server_ts":9,"content":{"name":"x"}}`)
	if m := messageOf(state, me, ""); m != nil {
		t.Fatalf("state: %v", m)
	}
	u := undecryptable(parsed(t, `{"type":"m.room.encrypted","event_id":"$8","room_id":"!r:s","sender":"@jo:s","origin_server_ts":10,"content":{}}`), me, "Jo")
	if u["undecryptable"] != true || u["text"] != "" || u["id"] != "$8" {
		t.Fatalf("undecryptable: %v", u)
	}
}

func TestReactionsAndRedactions(t *testing.T) {
	r := reactionOf(parsed(t, `{"type":"m.reaction","event_id":"$r","room_id":"!r:s","sender":"@jo:s","origin_server_ts":1,
		"content":{"m.relates_to":{"rel_type":"m.annotation","event_id":"$1","key":"👍"}}}`))
	if r["target"] != "$1" || r["emoji"] != "👍" || r["id"] != "$r" || r["from"] != "@jo:s" {
		t.Fatalf("reaction: %v", r)
	}
	if reactionOf(parsed(t, `{"type":"m.room.message","event_id":"$1","room_id":"!r:s","sender":"@jo:s","origin_server_ts":1,"content":{"body":"x"}}`)) != nil {
		t.Fatal("a message taken for a reaction")
	}
	v11 := parsed(t, `{"type":"m.room.redaction","event_id":"$x","room_id":"!r:s","sender":"@jo:s","origin_server_ts":1,"content":{"redacts":"$1"}}`)
	old := parsed(t, `{"type":"m.room.redaction","event_id":"$y","room_id":"!r:s","sender":"@jo:s","origin_server_ts":1,"redacts":"$2","content":{}}`)
	if redactedOf(v11) != "$1" || redactedOf(old) != "$2" {
		t.Fatalf("redacts: %s %s", redactedOf(v11), redactedOf(old))
	}
	if mediaKind("image/png") != event.MsgImage || mediaKind("audio/mp4") != event.MsgAudio || mediaKind("application/pdf") != event.MsgFile {
		t.Fatal("media kinds")
	}
}

// The store under mautrix's own schema: the crypto store and the state store both upgrade on the driver the build
// uses (modernc.org/sqlite with CGO off, mautrix's mattn driver with it on; `go test` with each proves both).
func TestStoreOnSQLite(t *testing.T) {
	dir = t.TempDir()
	raw, err := openDB()
	if err != nil {
		t.Fatal(err)
	}
	defer raw.Close()
	ctx := context.Background()
	cs := crypto.NewSQLCryptoStore(raw, dbutil.NoopLogger, "", "DEVICE", []byte("pickle"))
	if err := cs.DB.Upgrade(ctx); err != nil {
		t.Fatalf("crypto store: %v", err)
	}
	ss := sqlstatestore.NewSQLStateStore(raw, dbutil.NoopLogger, false)
	if err := ss.Upgrade(ctx); err != nil {
		t.Fatalf("state store: %v", err)
	}
	if err := cs.SaveNextBatch(ctx, "@me:s", "s1"); err != nil {
		t.Fatal(err)
	}
	if nb, err := cs.LoadNextBatch(ctx, "@me:s"); err != nil || nb != "s1" {
		t.Fatalf("next batch: %q %v", nb, err)
	}
	if err := ss.SetEncryptionEvent(ctx, "!r:s", &event.EncryptionEventContent{Algorithm: id.AlgorithmMegolmV1}); err != nil {
		t.Fatal(err)
	}
	if enc, err := ss.IsEncrypted(ctx, "!r:s"); err != nil || !enc {
		t.Fatalf("encrypted: %v %v", enc, err)
	}
}

func TestRoomsKeptAcrossARestart(t *testing.T) {
	dir = t.TempDir()
	rooms = map[id.RoomID]*roomInfo{"!a:s": {ID: "!a:s", Name: "Crew", Unread: 2, LastTS: 9}}
	direct = map[id.RoomID]id.UserID{"!b:s": "@jo:s"}
	saveRooms()
	rooms, direct = map[id.RoomID]*roomInfo{}, map[id.RoomID]id.UserID{}
	loadRooms()
	if rooms["!a:s"] == nil || rooms["!a:s"].Name != "Crew" || rooms["!a:s"].Unread != 2 || direct["!b:s"] != "@jo:s" {
		t.Fatalf("kept: %+v %v", rooms, direct)
	}
	j := roomJSON("!a:s")
	if j["title"] != "Crew" || j["unread"] != 2 || j["is_direct"] != false {
		t.Fatalf("room json: %v", j)
	}
}
