package main

import (
	"go.mau.fi/mautrix-signal/pkg/signalmeow"
	"encoding/json"
	"errors"
	"testing"

	"google.golang.org/protobuf/proto"

	"go.mau.fi/mautrix-signal/pkg/signalmeow/protobuf/signalpb"
)

// Tests of the helper's parts that need no Signal account: reading requests, shaping answers, attachment pointers
// there and back, the words for a group's rules, and a message's mentions.

func TestParseRequestTimes(t *testing.T) {
	r, err := parseRequest([]byte(`{"id":8,"op":"read","to":"a","author":"b","ts":[1,2,3]}`))
	if err != nil || r.ID != 8 || r.Op != "read" || len(r.TS) != 3 || r.TS[2] != 3 {
		t.Fatalf("read: %+v %v", r, err)
	}
	r, err = parseRequest([]byte(`{"id":10,"op":"delete","to":"a","ts":1731700000000}`))
	if err != nil || len(r.TS) != 1 || r.TS[0] != 1731700000000 {
		t.Fatalf("delete: %+v %v", r, err)
	}
	r, err = parseRequest([]byte(`{"id":6,"op":"send","to":"a","text":"hi","quote":{"ts":5,"author":"x"}}`))
	if err != nil || r.Quote == nil || r.Quote.TS != 5 || r.Quote.Author != "x" {
		t.Fatalf("send: %+v %v", r, err)
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
	b, _ = json.Marshal(answer(2, map[string]any{"ts": 7}, nil))
	if string(b) != `{"id":2,"ok":true,"result":{"ts":7}}` {
		t.Fatalf("result: %s", b)
	}
	b, _ = json.Marshal(answer(3, nil, errors.New("no")))
	if string(b) != `{"error":"no","id":3,"ok":false}` {
		t.Fatalf("error: %s", b)
	}
}

func TestPointerRoundTrip(t *testing.T) {
	a := &signalpb.AttachmentPointer{
		AttachmentIdentifier: &signalpb.AttachmentPointer_CdnKey{CdnKey: "abc"},
		Key:                  []byte{1, 2, 3}, Digest: []byte{4, 5}, Size: proto.Uint32(9),
		CdnNumber: proto.Uint32(3), ContentType: proto.String("image/png"),
	}
	m := mediaOf(a)
	line, err := json.Marshal(m)
	if err != nil {
		t.Fatal(err)
	}
	var back struct {
		Pointer json.RawMessage `json:"pointer"`
	}
	if err := json.Unmarshal(line, &back); err != nil {
		t.Fatal(err)
	}
	for _, raw := range []json.RawMessage{back.Pointer, mustQuote(back.Pointer)} {
		got, err := parsePointer(raw)
		if err != nil {
			t.Fatal(err)
		}
		if !proto.Equal(got, a) {
			t.Fatalf("pointer changed: %v", got)
		}
	}
	if _, err := parsePointer(json.RawMessage(`{"local":"/x"}`)); err == nil {
		t.Fatal("a pointer without a key was taken")
	}
}

// mustQuote is [b] as a JSON string: a pointer as the app sends it when it kept the object as text.
func mustQuote(b []byte) json.RawMessage {
	q, _ := json.Marshal(string(b))
	return q
}

func TestParseChat(t *testing.T) {
	_, g, err := parseChat("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=")
	if err != nil || g == "" {
		t.Fatalf("group: %v %q", err, g)
	}
	u, g, err := parseChat("8a1c2b3d-0000-4000-8000-000000000001")
	if err != nil || g != "" || u.UUID.String() != "8a1c2b3d-0000-4000-8000-000000000001" {
		t.Fatalf("person: %v %v %q", err, u, g)
	}
	if _, _, err := parseChat("nope"); err == nil {
		t.Fatal("nonsense taken as a chat")
	}
}

// Who may do what in a group, in the app's words and back (group_info, group_update).
func TestGroupAccessWords(t *testing.T) {
	if access(signalmeow.AccessControl_ADMINISTRATOR) != "admins" || access(signalmeow.AccessControl_MEMBER) != "members" || access(signalmeow.AccessControl_ANY) != "anyone" {
		t.Fatal("access words")
	}
	for _, w := range []string{"admins", "members"} {
		a, err := accessOf(w)
		if err != nil || access(*a) != w {
			t.Fatalf("%s round trip: %v %v", w, a, err)
		}
	}
	if _, err := accessOf("everyone"); err == nil {
		t.Fatal("an unknown word is refused")
	}
}

// A change asked for arrives as the app sends it.
func TestGroupEditParses(t *testing.T) {
	r, err := parseRequest([]byte(`{"id":3,"op":"group_update","to":"g1","change":{"title":"Crew","timer":3600,"add":["a"],"edit_info":"admins","announcements_only":true,"leave":false}}`))
	if err != nil || r.Change == nil || *r.Change.Title != "Crew" || *r.Change.Timer != 3600 || r.Change.Add[0] != "a" || *r.Change.EditInfo != "admins" || !*r.Change.AnnouncementsOnly || r.Change.Description != nil {
		t.Fatalf("parsed %+v %v", r.Change, err)
	}
}

func TestBlockRequestParses(t *testing.T) {
	var r request
	if err := json.Unmarshal([]byte(`{"id":7,"op":"block","aci":"5c6c3c8e-3b0f-4b5a-9a0e-1f2a3b4c5d6e","on":true}`), &r); err != nil {
		t.Fatal(err)
	}
	if r.Op != "block" || !r.On || r.ACI == "" {
		t.Fatalf("parsed %+v", r)
	}
	var u request
	if err := json.Unmarshal([]byte(`{"id":8,"op":"block","aci":"x"}`), &u); err != nil || u.On {
		t.Fatalf("unblock should parse with on false: %+v %v", u, err)
	}
}

// A message's @mentions go to the app as Signal sends them: where in the words (UTF-16, the U+FFFC each stands on) and
// whose ACI, by string or by its 16 bytes; style ranges are left out, and a message with none says so with an empty list.
func TestMentionsOf(t *testing.T) {
	a := "5c6c3c8e-3b0f-4b5a-9a0e-1f2a3b4c5d6e"
	b := "8a1c2b3d-0000-4000-8000-000000000001"
	bBytes := []byte{0x8a, 0x1c, 0x2b, 0x3d, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, 1}
	dm := &signalpb.DataMessage{
		Body: proto.String("hi ￼ and ￼!"),
		BodyRanges: []*signalpb.BodyRange{
			{Start: proto.Uint32(3), Length: proto.Uint32(1), AssociatedValue: &signalpb.BodyRange_MentionAci{MentionAci: a}},
			{Start: proto.Uint32(0), Length: proto.Uint32(2), AssociatedValue: &signalpb.BodyRange_Style_{Style: signalpb.BodyRange_BOLD}},
			{Start: proto.Uint32(9), Length: proto.Uint32(1), AssociatedValue: &signalpb.BodyRange_MentionAciBinary{MentionAciBinary: bBytes}},
		},
	}
	got := mentionsOf(dm)
	line, _ := json.Marshal(got)
	want := `[{"aci":"` + a + `","length":1,"start":3},{"aci":"` + b + `","length":1,"start":9}]`
	if string(line) != want {
		t.Fatalf("mentions: %s", line)
	}
	if line, _ := json.Marshal(mentionsOf(&signalpb.DataMessage{Body: proto.String("plain")})); string(line) != "[]" {
		t.Fatalf("none: %s", line)
	}
}

// who's profile flag arrives, and is off unless asked.
func TestWhoProfileFlag(t *testing.T) {
	r, err := parseRequest([]byte(`{"id":12,"op":"who","aci":"x","profile":true}`))
	if err != nil || !r.Profile {
		t.Fatalf("profile: %+v %v", r, err)
	}
	if r, _ := parseRequest([]byte(`{"id":12,"op":"who","aci":"x"}`)); r.Profile {
		t.Fatal("profile on without asking")
	}
}
