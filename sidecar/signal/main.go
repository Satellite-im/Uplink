// Uplink's Signal helper (README.md, PROTOCOL.md). AGPL-3.0, as signalmeow, on which it is built.
//
// It links to the person's Signal account as a secondary device, as Signal Desktop does, and speaks JSON lines over
// standard input and output. Requests, each with an "id" its answer carries back:
//
//	{"id":1,"op":"status"}                                   → {"linked":bool,"connected":bool,"aci":"…","number":"…","name":"…"}
//	{"id":2,"op":"link","name":"Uplink"}            → null, then events "qr" (again every 45 s) and "linked" or "link_failed"
//	{"id":3,"op":"unlink"}                                   → null; everything forgotten
//	{"id":4,"op":"contacts"}                                 → [{"aci","name","number","avatar"}…]
//	{"id":5,"op":"groups"}                                   → [{"id","title","members","avatar"}…] (and event "group", the same, when one is first heard from)
//	{"id":6,"op":"send","to":"…","text":"…","quote":{"ts":…,"author":"…"}} → {"ts":…}
//	{"id":7,"op":"send_media","to":"…","path":"…","mime":"…","name":"…","text":"…"} → {"ts":…,"pointer":{…}}
//	{"id":8,"op":"read","to":"…","author":"…","ts":[…]}      → null
//	{"id":9,"op":"react","to":"…","author":"…","ts":…,"emoji":"👍","remove":false} → null
//	{"id":10,"op":"delete","to":"…","ts":…}                  → null
//	{"id":11,"op":"download","pointer":{…},"path":"…"}       → null once written
//	{"id":12,"op":"who","aci":"…","profile":false}           → {"aci","name","number","avatar","about","aboutEmoji"}: the person's Signal profile fetched where nothing names them (always, with "profile":true)
//	{"id":13,"op":"group_info","to":"<group id>"}            → the group in full (groupInfo): title, description, picture, timer, members with roles, who may do what
//	{"id":14,"op":"group_update","to":"…","change":{…}}      → the group in full once changed: any of title, description, avatar (a picture's path, "" none), timer (seconds, 0 off), add, remove, admin, unadmin (ACIs), announcements_only, edit_info and add_members ("members" or "admins"), leave
//	{"id":15,"op":"block","aci":"…","on":true}               → null; blocks the person (false unblocks), here and on their other devices
//	{"id":16,"op":"blocked"}                                 → [{"aci","name","number","avatar"}…]: everyone blocked that this device knows of
//
// Answers: {"id":1,"ok":true,"result":…} or {"id":1,"ok":false,"error":"…"}. Events, unasked, each with "ev": ready,
// qr, linked, link_failed, connected, disconnected, message and edited (each with "mentions":[{"start","length","aci"}]),
// receipt, reaction, deleted, contacts, unlinked, and
// name ({"aci","name","number","avatar"}: someone who wrote with nothing naming them, once their profile is fetched).
package main

import (
	"bufio"
	"bytes"
	"cmp"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"image"
	_ "image/gif"
	_ "image/jpeg"
	_ "image/png"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/google/uuid"
	"github.com/rs/zerolog"
	"go.mau.fi/util/dbutil"
	_ "go.mau.fi/util/dbutil/litestream"
	"google.golang.org/protobuf/encoding/protojson"
	"google.golang.org/protobuf/proto"

	"go.mau.fi/mautrix-signal/pkg/libsignalgo"
	"go.mau.fi/mautrix-signal/pkg/signalmeow"
	"go.mau.fi/mautrix-signal/pkg/signalmeow/events"
	"go.mau.fi/mautrix-signal/pkg/signalmeow/protobuf/signalpb"
	"go.mau.fi/mautrix-signal/pkg/signalmeow/store"
	"go.mau.fi/mautrix-signal/pkg/signalmeow/types"
)

// stamps is a request's "ts": one message time, or a list of them.
type stamps []uint64

// UnmarshalJSON takes a number as a list of one, a list as it is, and null as none.
func (s *stamps) UnmarshalJSON(b []byte) error {
	b = bytes.TrimSpace(b)
	if len(b) > 0 && b[0] == '[' {
		var list []uint64
		if err := json.Unmarshal(b, &list); err != nil {
			return err
		}
		*s = list
		return nil
	}
	if string(b) == "null" {
		*s = nil
		return nil
	}
	var one uint64
	if err := json.Unmarshal(b, &one); err != nil {
		return err
	}
	*s = stamps{one}
	return nil
}

// quote names the message a send answers: its time, as Signal names messages, and its author's ACI.
type quote struct {
	TS     uint64 `json:"ts"`
	Author string `json:"author"`
}

// request is one line the app sends. Fields not used by an op are left empty.
type request struct {
	ID      int64           `json:"id"`
	Op      string          `json:"op"`
	Name    string          `json:"name"`
	To      string          `json:"to"`
	Text    string          `json:"text"`
	Quote   *quote          `json:"quote"`
	Path    string          `json:"path"`
	Mime    string          `json:"mime"`
	Author  string          `json:"author"`
	TS      stamps          `json:"ts"`
	Emoji   string          `json:"emoji"`
	Remove  bool            `json:"remove"`
	Pointer json.RawMessage `json:"pointer"`
	ACI     string          `json:"aci"`
	Change  *groupEdit      `json:"change"`
	On      bool            `json:"on"`
	// Profile asks `who` for the person's Signal profile even where the store names them: for a profile card, whose
	// about line the contact sync never carries.
	Profile bool `json:"profile"`
}

// groupEdit is a change to a group the person asks for (Matt, 2026-11-16: "Add them to a drawer when pressing and
// holding on the group name add support for all supported featues"): each field left out is left as it is.
type groupEdit struct {
	Title             *string  `json:"title"`
	Description       *string  `json:"description"`
	Avatar            *string  `json:"avatar"`
	Timer             *uint32  `json:"timer"`
	Add               []string `json:"add"`
	Remove            []string `json:"remove"`
	Admin             []string `json:"admin"`
	Unadmin           []string `json:"unadmin"`
	AnnouncementsOnly *bool    `json:"announcements_only"`
	EditInfo          *string  `json:"edit_info"`
	AddMembers        *string  `json:"add_members"`
	Leave             bool     `json:"leave"`
}

// dir is the --dir flag: where the store, the log and the avatars are kept. out is standard output, one JSON object a
// line; outLock keeps lines whole when goroutines speak at once.
//
// mu guards the second group. db and container are the open store (nil only while forget swaps it for a fresh one);
// cli is the linked device's client, nil when not linked; connected is the last word said to the app, so "connected"
// and "disconnected" are each said once a change; stopLoops ends the client's connectLoop; linking cancels a link
// still waiting for its scan.
var (
	dir     string
	log     zerolog.Logger
	out     = json.NewEncoder(os.Stdout)
	outLock sync.Mutex

	mu        sync.Mutex
	db        *dbutil.Database
	container *store.Container
	cli       *signalmeow.Client
	connected bool
	stopLoops context.CancelFunc
	linking   context.CancelFunc
)

// say writes one line, an answer or an event, to standard output.
func say(v any) {
	outLock.Lock()
	defer outLock.Unlock()
	_ = out.Encode(v)
}

// event says [name] with [fields] beside "ev".
func event(name string, fields map[string]any) {
	m := map[string]any{"ev": name}
	for k, v := range fields {
		m[k] = v
	}
	say(m)
}

// main opens the store, connects the device linked before (if any), says "ready", then answers requests (each on a
// goroutine of its own) until standard input closes.
func main() {
	flag.StringVar(&dir, "dir", "", "where the Signal store is kept")
	flag.Parse()
	if dir == "" {
		fmt.Fprintln(os.Stderr, "--dir is needed")
		os.Exit(2)
	}
	_ = os.MkdirAll(dir, 0o700)
	// signalmeow's and libsignal's log to standard error, for Uplink's developer log; never standard output. And to
	// signal.log in the store's folder, so a stuck send can be traced on the device afterwards (Matt, 2026-11-16:
	// "Sending signal messages get stuck on sending"): started afresh once it passes a megabyte.
	log = zerolog.New(zerolog.MultiLevelWriter(os.Stderr, logFile())).With().Timestamp().Logger().Level(zerolog.InfoLevel)
	signalmeow.SetLogger(log)
	// The QR address carries "&": kept as it is, not as \u0026.
	out.SetEscapeHTML(false)
	if err := openStore(); err != nil {
		log.Err(err).Msg("open store")
		fmt.Fprintln(os.Stderr, "the Signal store could not be opened:", err)
		os.Exit(1)
	}
	if dev := firstDevice(); dev != nil {
		mu.Lock()
		start(dev)
		mu.Unlock()
	}
	mu.Lock()
	linked := cli != nil
	mu.Unlock()
	event("ready", map[string]any{"linked": linked})

	scan := bufio.NewScanner(os.Stdin)
	scan.Buffer(make([]byte, 1<<20), 8<<20)
	for scan.Scan() {
		r, err := parseRequest(scan.Bytes())
		if err != nil {
			continue
		}
		go handle(r)
	}
	// Uplink closed its end: the app is quitting.
	mu.Lock()
	stop()
	mu.Unlock()
}

// parseRequest reads one line as a request. A line that is not JSON, or names no op, is an error (and is passed over).
func parseRequest(line []byte) (request, error) {
	var r request
	err := json.Unmarshal(line, &r)
	if err == nil && r.Op == "" {
		err = errors.New("no op")
	}
	return r, err
}

// answer is the line that answers request [id]: its result, or what went wrong.
func answer(id int64, result any, err error) map[string]any {
	if err != nil {
		return map[string]any{"id": id, "ok": false, "error": err.Error()}
	}
	return map[string]any{"id": id, "ok": true, "result": result}
}

// handle does one request and says its answer.
func handle(r request) {
	result, err := do(r)
	say(answer(r.ID, result, err))
}

// --- the store ------------------------------------------------------------------------------------------------------

func dbPath() string { return filepath.Join(dir, "signal.db") }

// openStore opens signalmeow's SQLite store (the account's keys, sessions, contacts and groups), bringing its tables
// up to date.
func openStore() error {
	// The store holds the account's keys: readable by the person alone.
	if f, err := os.OpenFile(dbPath(), os.O_CREATE|os.O_RDWR, 0o600); err == nil {
		_ = f.Close()
	}
	raw, err := dbutil.NewWithDialect("file:"+dbPath()+"?_txlock=immediate", "sqlite3-fk-wal")
	if err != nil {
		return err
	}
	raw.Log = dbutil.ZeroLogger(log.With().Str("db_section", "main").Logger())
	c := store.NewStore(raw, dbutil.ZeroLogger(log.With().Str("db_section", "signalmeow").Logger()))
	if err := c.Upgrade(log.WithContext(context.Background())); err != nil {
		_ = raw.Close()
		return err
	}
	mu.Lock()
	db, container = raw, c
	mu.Unlock()
	return nil
}

// firstDevice is the linked device the store holds, or nil: the helper keeps one Signal account.
func firstDevice() *store.Device {
	devs, err := container.GetAllDevices(bg())
	if err != nil {
		log.Err(err).Msg("load devices")
		return nil
	}
	for _, d := range devs {
		if d.IsDeviceLoggedIn() {
			return d
		}
	}
	return nil
}

// bg is a context that carries the helper's log, so signalmeow writes to it.
func bg() context.Context { return log.WithContext(context.Background()) }

// --- the connection -------------------------------------------------------------------------------------------------

// start connects [dev]'s client and follows its connection. Called with mu held.
func start(dev *store.Device) {
	c := signalmeow.NewClient(dev, log.With().Str("component", "signalmeow").Logger(), onEvent)
	// Ask the phone for its contacts (SendContactSyncRequest) once both sockets are up.
	c.SyncContactsOnConnect = true
	cli = c
	ctx, cancel := context.WithCancel(bg())
	stopLoops = cancel
	go connectLoop(ctx, c)
}

// connectLoop starts the receive loops, retrying with a growing wait as the bridge does, and turns their status into
// "connected" / "disconnected" / "unlinked".
func connectLoop(ctx context.Context, c *signalmeow.Client) {
	for retry := 0; ; retry++ {
		statuses, err := c.StartReceiveLoops(ctx)
		if err == nil {
			for s := range statuses {
				switch s.Event {
				case signalmeow.SignalConnectionEventConnected:
					setConnected(c, true)
				case signalmeow.SignalConnectionEventDisconnected, signalmeow.SignalConnectionEventError:
					setConnected(c, false)
				case signalmeow.SignalConnectionEventLoggedOut:
					go unlinked(c)
					return
				case signalmeow.SignalConnectionEventFatalError:
					log.Err(s.Err).Msg("fatal connection error")
					setConnected(c, false)
				}
			}
			return
		}
		log.Err(err).Msg("start receive loops")
		// 2, 4, 8… seconds, never more than two and a half minutes.
		wait := min(time.Duration(2<<min(retry, 7))*time.Second, 150*time.Second)
		select {
		case <-time.After(wait):
		case <-ctx.Done():
			return
		}
	}
}

// isConnected is signalmeow's IsConnected, which panics before the sockets exist.
func isConnected(c *signalmeow.Client) (up bool) {
	defer func() {
		if recover() != nil {
			up = false
		}
	}()
	return c.AuthedWS != nil && c.UnauthedWS != nil && c.IsConnected()
}

// socketsUp is whether each of signalmeow's two sockets is up: the authed one (receiving, plain sends) and the unauthed
// one (sealed-sender sends).
func socketsUp(c *signalmeow.Client) (authed, unauthed bool) {
	defer func() { _ = recover() }()
	return c.AuthedWS != nil && c.AuthedWS.IsConnected(), c.UnauthedWS != nil && c.UnauthedWS.IsConnected()
}

// setConnected tells the app when [c]'s connection comes up or goes down: only on a change, and only while [c] is
// still the client in use.
func setConnected(c *signalmeow.Client, now bool) {
	mu.Lock()
	if cli != c || connected == now {
		mu.Unlock()
		return
	}
	connected = now
	mu.Unlock()
	if now {
		event("connected", nil)
	} else {
		event("disconnected", nil)
	}
}

// stop disconnects the client, if any. Called with mu held.
func stop() {
	if linking != nil {
		linking()
		linking = nil
	}
	if cli == nil {
		return
	}
	if stopLoops != nil {
		stopLoops()
		stopLoops = nil
	}
	if err := cli.StopReceiveLoops(); err != nil {
		log.Debug().Err(err).Msg("stop receive loops")
	}
	cli = nil
	connected = false
}

// unlinked is Signal removing this device: everything is forgotten and the app told.
func unlinked(c *signalmeow.Client) {
	mu.Lock()
	if cli != c {
		mu.Unlock()
		return
	}
	mu.Unlock()
	if err := forget(); err != nil {
		log.Err(err).Msg("forget after unlink")
	}
	event("unlinked", nil)
}

// forget stops the client and wipes the store, then opens a fresh one.
func forget() error {
	mu.Lock()
	stop()
	raw := db
	db, container = nil, nil
	mu.Unlock()
	if raw != nil {
		_ = raw.Close()
	}
	for _, suffix := range []string{"", "-wal", "-shm"} {
		_ = os.Remove(dbPath() + suffix)
	}
	_ = os.RemoveAll(avatarDir())
	return openStore()
}

var errNotLinked = errors.New("not linked to Signal")

// client is the linked client, or errNotLinked. Takes mu itself: never call it with mu held.
func client() (*signalmeow.Client, error) {
	mu.Lock()
	defer mu.Unlock()
	if cli == nil || !cli.IsLoggedIn() {
		return nil, errNotLinked
	}
	return cli, nil
}

// --- requests -------------------------------------------------------------------------------------------------------

// do carries out one request and returns its result.
func do(r request) (any, error) {
	// A send is given a minute, under the app's own wait (lib/inbox/signal.dart), so what went wrong is said to it
	// rather than the app giving up first; a download or an upload has longer.
	limit := 60 * time.Second
	if r.Op == "download" || r.Op == "send_media" || r.Op == "group_update" {
		limit = 170 * time.Second
	}
	ctx, cancel := context.WithTimeout(bg(), limit)
	defer cancel()
	if r.Op != "status" {
		began := time.Now()
		log.Info().Str("op", r.Op).Int64("req", r.ID).Msg("asked")
		defer func() { log.Info().Str("op", r.Op).Int64("req", r.ID).Dur("took", time.Since(began)).Msg("answered") }()
	}
	switch r.Op {
	case "status":
		return status(ctx), nil
	case "link":
		return nil, link(cmp.Or(r.Name, "Uplink"))
	case "unlink":
		if c, err := client(); err == nil {
			if err := c.Unlink(ctx); err != nil {
				log.Err(err).Msg("unlink")
			}
		}
		return nil, forget()
	case "contacts":
		c, err := client()
		if err != nil {
			return nil, err
		}
		return contacts(ctx, c)
	case "who":
		c, err := client()
		if err != nil {
			return nil, err
		}
		aci, err := uuid.Parse(r.ACI)
		if err != nil {
			return nil, errors.New("who: no aci")
		}
		return who(ctx, c, aci, r.Profile)
	case "groups":
		c, err := client()
		if err != nil {
			return nil, err
		}
		return groups(ctx, c)
	case "group_info":
		c, err := client()
		if err != nil {
			return nil, err
		}
		return groupInfo(ctx, c, r.To)
	case "group_update":
		c, err := client()
		if err != nil {
			return nil, err
		}
		if r.Change == nil {
			return nil, errors.New("no change asked for")
		}
		return updateGroup(ctx, c, r.To, r.Change)
	case "block":
		c, err := client()
		if err != nil {
			return nil, err
		}
		aci, err := uuid.Parse(r.ACI)
		if err != nil {
			return nil, errors.New("block: no aci")
		}
		return nil, block(ctx, c, aci, r.On)
	case "blocked":
		c, err := client()
		if err != nil {
			return nil, err
		}
		return blocked(ctx, c)
	case "send":
		c, err := client()
		if err != nil {
			return nil, err
		}
		ts := now()
		dm := &signalpb.DataMessage{Timestamp: proto.Uint64(ts), Body: proto.String(r.Text)}
		if r.Quote != nil && r.Quote.TS != 0 {
			author, err := uuid.Parse(r.Quote.Author)
			if err != nil {
				return nil, fmt.Errorf("quote author: %w", err)
			}
			dm.Quote = &signalpb.DataMessage_Quote{
				Id: proto.Uint64(r.Quote.TS), AuthorAciBinary: author[:], Type: signalpb.DataMessage_Quote_NORMAL.Enum(),
			}
		}
		if err := send(ctx, c, r.To, dm); err != nil {
			return nil, err
		}
		return map[string]any{"ts": ts}, nil
	case "send_media":
		c, err := client()
		if err != nil {
			return nil, err
		}
		att, err := upload(ctx, c, r.Path, r.Mime, r.Name)
		if err != nil {
			return nil, err
		}
		ts := now()
		dm := &signalpb.DataMessage{Timestamp: proto.Uint64(ts), Attachments: []*signalpb.AttachmentPointer{att}}
		if r.Text != "" {
			dm.Body = proto.String(r.Text)
		}
		if err := send(ctx, c, r.To, dm); err != nil {
			return nil, err
		}
		// The pointer sent, with its key, for the app to keep beside its copy (lib/inbox/signal.dart sendFiles): what the
		// sent message's picture is fetched again with should the copy go.
		out := map[string]any{"ts": ts}
		if m := mediaOf(att); m != nil {
			out["pointer"] = m["pointer"]
		}
		return out, nil
	case "read":
		c, err := client()
		if err != nil {
			return nil, err
		}
		author, err := libsignalgo.ServiceIDFromString(cmp.Or(r.Author, r.To))
		if err != nil {
			return nil, fmt.Errorf("author: %w", err)
		}
		// The receipt goes to whoever wrote the messages (the chat itself, where no author is named); none for your own.
		if len(r.TS) == 0 || author.UUID == c.Store.ACI {
			return nil, nil
		}
		res := c.SendMessage(ctx, author, signalmeow.ReadReceptMessageForTimestamps(r.TS))
		return nil, resultErr(res)
	case "react":
		c, err := client()
		if err != nil {
			return nil, err
		}
		author, err := uuid.Parse(r.Author)
		if err != nil {
			return nil, fmt.Errorf("author: %w", err)
		}
		if len(r.TS) == 0 {
			return nil, errors.New("no ts")
		}
		return nil, send(ctx, c, r.To, &signalpb.DataMessage{
			Timestamp:               proto.Uint64(now()),
			RequiredProtocolVersion: proto.Uint32(uint32(signalpb.DataMessage_REACTIONS)),
			Reaction: &signalpb.DataMessage_Reaction{
				Emoji:                 proto.String(r.Emoji),
				Remove:                proto.Bool(r.Remove),
				TargetAuthorAciBinary: author[:],
				TargetSentTimestamp:   proto.Uint64(r.TS[0]),
			},
		})
	case "delete":
		c, err := client()
		if err != nil {
			return nil, err
		}
		if len(r.TS) == 0 {
			return nil, errors.New("no ts")
		}
		return nil, send(ctx, c, r.To, &signalpb.DataMessage{
			Timestamp: proto.Uint64(now()),
			Delete:    &signalpb.DataMessage_Delete{TargetSentTimestamp: proto.Uint64(r.TS[0])},
		})
	case "download":
		ptr, err := parsePointer(r.Pointer)
		if err != nil {
			return nil, err
		}
		return nil, download(ctx, ptr, r.Path)
	}
	return nil, fmt.Errorf("unknown op %q", r.Op)
}

// now is the time in milliseconds: what Signal stamps a message with, and names it by ever after.
func now() uint64 { return uint64(time.Now().UnixMilli()) }

// status is whether a device is linked and connected, and whose account it is.
func status(ctx context.Context) map[string]any {
	mu.Lock()
	c, conn := cli, connected
	mu.Unlock()
	s := map[string]any{"linked": false, "connected": false, "aci": "", "number": "", "name": ""}
	if c == nil || !c.IsLoggedIn() {
		return s
	}
	s["linked"] = true
	s["connected"] = conn && isConnected(c)
	s["aci"] = c.Store.ACI.String()
	s["number"] = c.Store.Number
	s["name"] = ownName(ctx, c)
	return s
}

// ownName is the person's own name: from the account record Signal syncs, else the profile the store holds.
func ownName(ctx context.Context, c *signalmeow.Client) string {
	if ar := c.Store.AccountRecord; ar != nil {
		if n := strings.TrimSpace(ar.GetGivenName() + " " + ar.GetFamilyName()); n != "" {
			return n
		}
	}
	if rc, err := c.Store.RecipientStore.LoadAndUpdateRecipient(ctx, c.Store.ACI, uuid.Nil, nil); err == nil && rc != nil {
		return rc.Profile.Name
	}
	return ""
}

// parseChat is a request's "to": a group id (44 characters of base64), or a person's service id.
func parseChat(to string) (libsignalgo.ServiceID, types.GroupIdentifier, error) {
	if len(to) == 44 {
		return libsignalgo.ServiceID{}, types.GroupIdentifier(to), nil
	}
	sid, err := libsignalgo.ServiceIDFromString(to)
	if err != nil {
		return sid, "", fmt.Errorf("not a Signal chat: %q", to)
	}
	return sid, "", nil
}

// send sends [dm] (words, a reaction, a delete) to a person or a group. A group send that reached at least one member
// counts as sent; one cut short by the request's time limit says so.
func send(ctx context.Context, c *signalmeow.Client, to string, dm *signalpb.DataMessage) error {
	user, group, err := parseChat(to)
	if err != nil {
		return err
	}
	if !isConnected(c) {
		log.Warn().Msg("send: not connected to Signal; trying anyway")
	}
	// Each send's own steps, from signalmeow's debug lines under this send's context (fetching keys, sealed sender
	// refused and sent again, the server's answer, sender keys for a group), marked trace=true so the app's Developer
	// log keeps them: which step a slow send waits on (Matt, 2026-11-16: "Sending signal messages get stuck on
	// sending"). None of them carries the message's words.
	authed, unauthed := socketsUp(c)
	ctx = log.Level(zerolog.DebugLevel).With().Bool("trace", true).Logger().WithContext(ctx)
	zerolog.Ctx(ctx).Info().Bool("authed_ws", authed).Bool("unauthed_ws", unauthed).Msg("send begins")
	content := signalmeow.WrapDataMessage(dm)
	began := time.Now()
	if group != "" {
		log.Info().Str("group", string(group)).Msg("send to group")
		res, err := c.SendGroupMessage(ctx, group, content)
		sentTo, failed := 0, 0
		if res != nil {
			sentTo, failed = len(res.SuccessfullySentTo), len(res.FailedToSendTo)
		}
		log.Info().Err(err).Dur("took", time.Since(began)).Int("sent_to", sentTo).Int("failed", failed).Msg("sent to group")
		if err != nil {
			if ctx.Err() != nil {
				return fmt.Errorf("Signal didn't take the message in time (%w)", err)
			}
			return err
		}
		if len(res.SuccessfullySentTo) == 0 && len(res.FailedToSendTo) > 0 {
			return fmt.Errorf("not sent to anyone in the group: %w", res.FailedToSendTo[0].Error)
		}
		return nil
	}
	log.Info().Stringer("to", user).Msg("send")
	err = resultErr(c.SendMessage(ctx, user, content))
	log.Info().Err(err).Dur("took", time.Since(began)).Msg("sent")
	if err != nil && ctx.Err() != nil {
		return fmt.Errorf("Signal didn't take the message in time (%w)", err)
	}
	return err
}

// resultErr is a send to one person as an error: nil where Signal took it.
func resultErr(res signalmeow.SendMessageResult) error {
	if res.WasSuccessful {
		return nil
	}
	if res.Error != nil {
		return res.Error
	}
	return errors.New("Signal did not take the message")
}

// upload encrypts and uploads the file at [path] and returns the pointer a message carries to it, with its kind
// (read from its first bytes where the app names none), its name and, for a picture, its size in pixels.
func upload(ctx context.Context, c *signalmeow.Client, path, mime, name string) (*signalpb.AttachmentPointer, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	if mime == "" || mime == "application/octet-stream" {
		mime = http.DetectContentType(data)
	}
	if name == "" {
		name = filepath.Base(path)
	}
	att, err := c.UploadAttachment(ctx, data)
	if err != nil {
		return nil, err
	}
	att.ContentType = proto.String(mime)
	att.FileName = proto.String(name)
	if strings.HasPrefix(mime, "image/") {
		if cfg, _, err := image.DecodeConfig(bytes.NewReader(data)); err == nil {
			att.Width, att.Height = proto.Uint32(uint32(cfg.Width)), proto.Uint32(uint32(cfg.Height))
		}
	}
	return att, nil
}

// parsePointer takes back an attachment pointer as an event gave it: a JSON object, or that object as a string.
func parsePointer(raw json.RawMessage) (*signalpb.AttachmentPointer, error) {
	raw = bytes.TrimSpace(raw)
	if len(raw) == 0 || string(raw) == "null" {
		return nil, errors.New("no pointer")
	}
	if raw[0] == '"' {
		var s string
		if err := json.Unmarshal(raw, &s); err != nil {
			return nil, err
		}
		raw = []byte(s)
	}
	var ptr signalpb.AttachmentPointer
	if err := (protojson.UnmarshalOptions{DiscardUnknown: true}).Unmarshal(raw, &ptr); err != nil {
		return nil, fmt.Errorf("not an attachment pointer: %w", err)
	}
	if len(ptr.GetKey()) == 0 {
		return nil, errors.New("the attachment has no key")
	}
	return &ptr, nil
}

// download fetches and decrypts the attachment [ptr] names into [path], by way of a ".part" file beside it, so
// [path] is only ever a whole file.
func download(ctx context.Context, ptr *signalpb.AttachmentPointer, path string) error {
	if path == "" {
		return errors.New("no path")
	}
	tmp := path + ".part"
	f, err := os.OpenFile(tmp, os.O_CREATE|os.O_RDWR|os.O_TRUNC, 0o600)
	if err != nil {
		return err
	}
	_, err = signalmeow.DownloadAttachmentWithPointer(ctx, ptr, nil, f)
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err == nil {
		err = os.Rename(tmp, path)
	}
	if err != nil {
		_ = os.Remove(tmp)
	}
	return err
}

// --- linking --------------------------------------------------------------------------------------------------------

// link provisions this device: a QR address ("qr", a fresh one every 45 seconds as Signal Desktop does, for 15
// minutes), then, once Signal on the phone scans it, the device is kept and connected ("linked").
func link(name string) error {
	mu.Lock()
	stop()
	ctx, cancel := context.WithCancel(bg())
	linking = cancel
	c := container
	mu.Unlock()
	if c == nil {
		cancel()
		return errors.New("the Signal store is not open")
	}
	go func() {
		defer cancel()
		// Twenty codes of 45 seconds each: the fifteen minutes.
		for round := 0; round < 20; round++ {
			roundCtx, roundCancel := context.WithCancel(ctx)
			ch := signalmeow.PerformProvisioning(roundCtx, c, name, false)
			done, failed := provisionRound(ctx, ch)
			roundCancel()
			if done || failed {
				return
			}
			if ctx.Err() != nil {
				return
			}
		}
		event("link_failed", map[string]any{"error": "The QR code was not scanned in time"})
	}()
	return nil
}

// provisionRound follows one provisioning socket: done once linked, failed once said so; neither means "new QR".
func provisionRound(ctx context.Context, ch chan signalmeow.ProvisioningResponse) (done, failed bool) {
	timer := time.NewTimer(45 * time.Second)
	defer timer.Stop()
	for {
		select {
		case resp, ok := <-ch:
			if !ok {
				return false, false
			}
			if resp.Err != nil {
				if ctx.Err() != nil {
					return false, true
				}
				event("link_failed", map[string]any{"error": linkWhy(resp.Err)})
				return false, true
			}
			switch resp.State {
			case signalmeow.StateProvisioningURLReceived:
				event("qr", map[string]any{"url": resp.ProvisioningURL})
			case signalmeow.StateProvisioningDataReceived:
				data := resp.ProvisioningData
				if data == nil || data.ACI == uuid.Nil {
					event("link_failed", map[string]any{"error": "Signal sent no account"})
					return false, true
				}
				linked(data)
				return true, false
			}
		case <-timer.C:
			// Still waiting for the scan: the phone may be scanning this one. Give the socket time to finish if it has
			// the data already, else start again with a new code.
			select {
			case resp, ok := <-ch:
				if ok && resp.State == signalmeow.StateProvisioningDataReceived && resp.ProvisioningData != nil {
					linked(resp.ProvisioningData)
					return true, false
				}
			default:
			}
			return false, false
		case <-ctx.Done():
			return false, true
		}
	}
}

// linked takes the device signalmeow has just kept in the store, connects it and says "linked".
func linked(data *store.DeviceData) {
	mu.Lock()
	c := container
	mu.Unlock()
	dev, err := c.DeviceByACI(bg(), data.ACI)
	if err != nil || dev == nil {
		event("link_failed", map[string]any{"error": fmt.Sprintf("the new device was not kept (%v)", err)})
		return
	}
	mu.Lock()
	linking = nil
	start(dev)
	mu.Unlock()
	event("linked", map[string]any{"aci": data.ACI.String(), "number": data.Number})
}

// linkWhy is a failed link in words a person can act on, by the status Signal's server answered with.
func linkWhy(err error) string {
	var le signalmeow.DeviceLinkError
	if errors.As(err, &le) {
		switch le.StatusCode {
		case http.StatusConflict:
			return "Signal turned the link down: this app lacks something your other devices need. Try again later."
		case http.StatusLengthRequired:
			return "Your Signal account has as many linked devices as it may. Remove one in Signal and try again."
		case http.StatusForbidden:
			return "The QR code was not valid or was used already. Try again."
		case http.StatusTooManyRequests:
			return "Signal asked to wait a few minutes before linking again."
		}
	}
	return "Linking did not finish (" + err.Error() + ")"
}

// --- contacts and groups --------------------------------------------------------------------------------------------

func avatarDir() string { return filepath.Join(dir, "avatars") }

// keepAvatar writes [data] under a name from [key] and says where; an empty string if there is nothing.
func keepAvatar(key string, data []byte) string {
	if len(data) == 0 {
		return ""
	}
	_ = os.MkdirAll(avatarDir(), 0o700)
	sum := sha256.Sum256([]byte(key))
	p := filepath.Join(avatarDir(), hex.EncodeToString(sum[:12]))
	if err := os.WriteFile(p, data, 0o600); err != nil {
		return ""
	}
	return p
}

// keptAvatar is the path of the picture kept under [key], else empty.
func keptAvatar(key string) string {
	sum := sha256.Sum256([]byte(key))
	p := filepath.Join(avatarDir(), hex.EncodeToString(sum[:12]))
	if _, err := os.Stat(p); err == nil {
		return p
	}
	return ""
}

// nullable is [s], or JSON's null for an empty one.
func nullable(s string) any {
	if s == "" {
		return nil
	}
	return s
}

// recipientName is what to call someone: the nickname the person gave them, else their name in the phone's contacts,
// else the name on their Signal profile.
func recipientName(r *types.Recipient) string {
	if r == nil {
		return ""
	}
	return strings.TrimSpace(cmp.Or(r.Nickname, r.ContactName, r.Profile.Name))
}

// contact is someone as the app is told them. Their picture is the one the phone's contact sync sent, else their
// profile's, downloaded once and kept; with a nil [c] or [ctx] nothing is downloaded.
func contact(ctx context.Context, c *signalmeow.Client, r *types.Recipient) map[string]any {
	avatar := ""
	if len(r.ContactAvatar.Image) > 0 {
		key := "contact:" + r.ACI.String() + ":" + r.ContactAvatar.Hash
		if avatar = keptAvatar(key); avatar == "" {
			avatar = keepAvatar(key, r.ContactAvatar.Image)
		}
	} else if r.Profile.AvatarPath != "" && c != nil && ctx != nil {
		key := "profile:" + r.Profile.AvatarPath
		if avatar = keptAvatar(key); avatar == "" {
			if data, err := c.DownloadUserAvatar(ctx, r.Profile.AvatarPath, r.Profile.Key); err == nil {
				avatar = keepAvatar(key, data)
			}
		}
	}
	// Their "about" line and its emoji, as their Signal profile has them: shown on the card a tapped @mention opens (Matt,
	// 2026-11-19: "when using telegram and other outside apps we should proxy through any profile information their APIs
	// make available"). Empty where they wrote none.
	return map[string]any{
		"aci": r.ACI.String(), "name": recipientName(r), "number": r.E164, "avatar": nullable(avatar),
		"about": strings.TrimSpace(r.Profile.About), "aboutEmoji": strings.TrimSpace(r.Profile.AboutEmoji),
	}
}

// contacts is everyone the store knows of but the person themselves.
func contacts(ctx context.Context, c *signalmeow.Client) ([]map[string]any, error) {
	all, err := c.Store.RecipientStore.LoadAllContacts(ctx)
	if err != nil {
		return nil, err
	}
	list := make([]map[string]any, 0, len(all))
	for _, r := range all {
		if r.ACI == uuid.Nil || r.ACI == c.Store.ACI {
			continue
		}
		// Nothing naming them here (the phone's contact sync often has no name, and only a profile key): their
		// Signal profile, fetched with that key (Matt, 2026-11-16: "signal messages are not being properly tied to a
		// username or group name").
		if recipientName(r) == "" && r.Profile.Key != (libsignalgo.ProfileKey{}) {
			if fetched, err := c.ContactByACI(ctx, r.ACI); err == nil && fetched != nil {
				r = fetched
			}
		}
		list = append(list, contact(ctx, c, r))
	}
	return list, nil
}

// block blocks [aci] on Signal itself, or unblocks them (Matt, 2026-11-17: "add the signal helper and do your
// recommendation"): kept in this device's store at once, so the helper drops what they send from now on, and said to
// the person's other devices as Signal Desktop says it, a message-request answer for that one person (BLOCK, or ACCEPT
// to unblock), which the phone applies to its own list and Signal's synced settings. Not the whole blocked list
// (SyncMessage.Blocked): the phone takes that list as complete and would unblock anyone this device does not know of.
func block(ctx context.Context, c *signalmeow.Client, aci uuid.UUID, on bool) error {
	if aci == c.Store.ACI {
		return errors.New("you can't block yourself")
	}
	kind := signalpb.SyncMessage_MessageRequestResponse_ACCEPT
	if on {
		kind = signalpb.SyncMessage_MessageRequestResponse_BLOCK
	}
	res := c.SendMessage(ctx, c.Store.ACIServiceID(), signalmeow.WrapSyncMessage(&signalpb.SyncMessage{
		Content: &signalpb.SyncMessage_MessageRequestResponse_{
			MessageRequestResponse: &signalpb.SyncMessage_MessageRequestResponse{
				ThreadAci:       proto.String(aci.String()),
				ThreadAciBinary: aci[:],
				Type:            kind.Enum(),
			},
		},
	}))
	// Only you on this account (no other device to tell) is no failure: the store below is the block then.
	if err := resultErr(res); err != nil && !strings.Contains(err.Error(), "no devices") {
		return err
	}
	_, err := c.Store.RecipientStore.LoadAndUpdateRecipient(ctx, aci, uuid.Nil, func(r *types.Recipient) (bool, error) {
		if r.Blocked == on {
			return false, nil
		}
		r.Blocked = on
		return true, nil
	})
	return err
}

// blocked is everyone blocked on Signal that this device knows of: blocked here, or on the phone (Signal's synced
// settings bring its list here).
func blocked(ctx context.Context, c *signalmeow.Client) ([]map[string]any, error) {
	all, err := c.Store.RecipientStore.LoadAllContacts(ctx)
	if err != nil {
		return nil, err
	}
	list := make([]map[string]any, 0)
	for _, r := range all {
		if r.Blocked && r.ACI != uuid.Nil && r.ACI != c.Store.ACI {
			list = append(list, contact(ctx, c, r))
		}
	}
	return list, nil
}

// who is [aci] as the app shows them: from the store, and from their Signal profile where the store names them not.
// With [profile] the profile is fetched whatever the store holds (signalmeow keeps one an hour, so a card opened
// again asks Signal nothing).
func who(ctx context.Context, c *signalmeow.Client, aci uuid.UUID, profile bool) (map[string]any, error) {
	r, err := c.Store.RecipientStore.LoadAndUpdateRecipient(ctx, aci, uuid.Nil, nil)
	if err != nil {
		return nil, err
	}
	if r == nil || recipientName(r) == "" || profile {
		if fetched, err := c.ContactByACI(ctx, aci); err == nil && fetched != nil {
			r = fetched
		} else if err != nil {
			log.Debug().Err(err).Str("aci", aci.String()).Msg("profile not fetched")
		}
	}
	if r == nil {
		return map[string]any{"aci": aci.String(), "name": "", "number": "", "avatar": nil}, nil
	}
	return contact(ctx, c, r), nil
}

// announceName fetches the profile of someone who wrote with nothing naming them, once a run, off the receive loop,
// and tells the app the name it found ("name" event).
func announceName(c *signalmeow.Client, aci uuid.UUID) {
	key := "name:" + aci.String()
	announcedMu.Lock()
	if announced[key] {
		announcedMu.Unlock()
		return
	}
	announced[key] = true
	announcedMu.Unlock()
	go func() {
		ctx, cancel := context.WithTimeout(bg(), 30*time.Second)
		defer cancel()
		m, err := who(ctx, c, aci, false)
		if err != nil || m["name"] == "" {
			return
		}
		event("name", m)
	}()
}

// groups is every group the store has a key for, each described afresh from Signal; one that cannot be fetched is
// left out. The ids are read from signalmeow's own table, which it offers no call to list.
func groups(ctx context.Context, c *signalmeow.Client) ([]map[string]any, error) {
	mu.Lock()
	d := db
	mu.Unlock()
	if d == nil {
		return nil, errNotLinked
	}
	rows, err := d.Query(ctx, `SELECT group_identifier FROM signalmeow_groups WHERE account_id=$1`, c.Store.ACI)
	if err != nil {
		return nil, err
	}
	var ids []string
	for rows.Next() {
		var id string
		if rows.Scan(&id) == nil {
			ids = append(ids, id)
		}
	}
	_ = rows.Close()
	list := make([]map[string]any, 0, len(ids))
	for _, id := range ids {
		g, err := describeGroup(ctx, c, id)
		if err != nil {
			log.Debug().Err(err).Str("group", id).Msg("group not fetched")
			continue
		}
		list = append(list, g)
	}
	return list, nil
}

// describeGroup is group [id] as the app has it: its title, members and picture (kept beside the store).
func describeGroup(ctx context.Context, c *signalmeow.Client, id string) (map[string]any, error) {
	g, _, err := c.RetrieveGroupByID(ctx, types.GroupIdentifier(id), 0)
	if err != nil {
		return nil, err
	}
	if g == nil {
		return nil, errors.New("no such group")
	}
	members := make([]string, 0, len(g.Members))
	for _, m := range g.Members {
		members = append(members, m.ACI.String())
	}
	avatar := ""
	if g.AvatarPath != "" {
		key := "group:" + g.AvatarPath
		if avatar = keptAvatar(key); avatar == "" {
			if data, err := c.DownloadGroupAvatar(ctx, g.AvatarPath, g.GroupMasterKey); err == nil {
				avatar = keepAvatar(key, data)
			}
		}
	}
	return map[string]any{"id": id, "title": g.Title, "members": members, "avatar": nullable(avatar)}, nil
}

// access is who may do something in a group, in the app's words: "members" or "admins" ("anyone" for an invite link
// that needs no approval, which the app shows as members).
func access(a signalmeow.AccessControl) string {
	switch a {
	case signalmeow.AccessControl_ADMINISTRATOR:
		return "admins"
	case signalmeow.AccessControl_ANY:
		return "anyone"
	default:
		return "members"
	}
}

// accessOf is access turned round, for a change the app asks for: only "members" and "admins" may be set.
func accessOf(s string) (*signalmeow.AccessControl, error) {
	switch s {
	case "admins":
		a := signalmeow.AccessControl_ADMINISTRATOR
		return &a, nil
	case "members":
		a := signalmeow.AccessControl_MEMBER
		return &a, nil
	}
	return nil, fmt.Errorf("who may do it is \"members\" or \"admins\", not %q", s)
}

// groupInfo is group [id] in full, for the app's group drawer: describeGroup's, and its description, disappearing
// timer, each member with their name, number and role, those invited and those asking to join, who may change its
// details and add people, whether only admins may write, and whether you are an admin.
func groupInfo(ctx context.Context, c *signalmeow.Client, id string) (map[string]any, error) {
	out, err := describeGroup(ctx, c, id)
	if err != nil {
		return nil, err
	}
	g, _, err := c.RetrieveGroupByID(ctx, types.GroupIdentifier(id), 0)
	if err != nil {
		return nil, err
	}
	person := func(aci uuid.UUID) map[string]any {
		m := map[string]any{"aci": aci.String(), "name": "", "number": "", "me": aci == c.Store.ACI}
		if r, err := c.Store.RecipientStore.LoadAndUpdateRecipient(ctx, aci, uuid.Nil, nil); err == nil && r != nil {
			m["name"], m["number"] = recipientName(r), r.E164
		}
		return m
	}
	members := make([]map[string]any, 0, len(g.Members))
	admin := false
	for _, m := range g.Members {
		p := person(m.ACI)
		p["admin"] = m.Role == signalmeow.GroupMember_ADMINISTRATOR
		if m.ACI == c.Store.ACI && m.Role == signalmeow.GroupMember_ADMINISTRATOR {
			admin = true
		}
		members = append(members, p)
	}
	pending := make([]map[string]any, 0, len(g.PendingMembers))
	for _, m := range g.PendingMembers {
		if m.ServiceID.Type == libsignalgo.ServiceIDTypeACI {
			pending = append(pending, person(m.ServiceID.UUID))
		}
	}
	requesting := make([]map[string]any, 0, len(g.RequestingMembers))
	for _, m := range g.RequestingMembers {
		requesting = append(requesting, person(m.ACI))
	}
	editInfo, addMembers := "members", "members"
	if g.AccessControl != nil {
		editInfo, addMembers = access(g.AccessControl.Attributes), access(g.AccessControl.Members)
	}
	out["description"] = g.Description
	out["timer"] = g.DisappearingMessagesDuration
	out["people"] = members
	out["pending"] = pending
	out["requesting"] = requesting
	out["admin"] = admin
	out["edit_info"] = editInfo
	out["add_members"] = addMembers
	out["announcements_only"] = g.AnnouncementsOnly
	out["terminated"] = g.Terminated
	if link, err := g.GetInviteLink(); err == nil {
		out["invite_link"] = link
	}
	return out, nil
}

// updateGroup makes the change [e] to group [id] on Signal, where everyone in it sees it, and answers with the group
// as it is then. Signal refuses what the group's rules do not let you do (only admins may rename it, say).
func updateGroup(ctx context.Context, c *signalmeow.Client, id string, e *groupEdit) (map[string]any, error) {
	gid := types.GroupIdentifier(id)
	gc := &signalmeow.GroupChange{}
	aci := func(s string) (*uuid.UUID, error) {
		u, err := uuid.Parse(s)
		if err != nil {
			return nil, fmt.Errorf("not a Signal id: %q", s)
		}
		return &u, nil
	}
	if e.Title != nil {
		t := strings.TrimSpace(*e.Title)
		if t == "" {
			return nil, errors.New("a group needs a name")
		}
		gc.ModifyTitle = &t
	}
	if e.Description != nil {
		d := strings.TrimSpace(*e.Description)
		gc.ModifyDescription = &d
	}
	if e.Avatar != nil {
		path := ""
		if *e.Avatar != "" {
			data, err := os.ReadFile(*e.Avatar)
			if err != nil {
				return nil, fmt.Errorf("the picture: %w", err)
			}
			if path, err = c.UploadGroupAvatar(ctx, data, gid, ""); err != nil {
				return nil, fmt.Errorf("the picture did not upload: %w", err)
			}
		}
		gc.ModifyAvatar = &path
	}
	if e.Timer != nil {
		gc.ModifyDisappearingMessagesDuration = e.Timer
	}
	for _, s := range e.Add {
		u, err := aci(s)
		if err != nil {
			return nil, err
		}
		gc.AddMembers = append(gc.AddMembers, &signalmeow.AddMember{GroupMember: signalmeow.GroupMember{ACI: *u, Role: signalmeow.GroupMember_DEFAULT}})
	}
	for _, s := range e.Remove {
		u, err := aci(s)
		if err != nil {
			return nil, err
		}
		gc.DeleteMembers = append(gc.DeleteMembers, u)
	}
	for _, s := range e.Admin {
		u, err := aci(s)
		if err != nil {
			return nil, err
		}
		gc.ModifyMemberRoles = append(gc.ModifyMemberRoles, &signalmeow.RoleMember{ACI: *u, Role: signalmeow.GroupMember_ADMINISTRATOR})
	}
	for _, s := range e.Unadmin {
		u, err := aci(s)
		if err != nil {
			return nil, err
		}
		gc.ModifyMemberRoles = append(gc.ModifyMemberRoles, &signalmeow.RoleMember{ACI: *u, Role: signalmeow.GroupMember_DEFAULT})
	}
	if e.AnnouncementsOnly != nil {
		gc.ModifyAnnouncementsOnly = e.AnnouncementsOnly
	}
	if e.EditInfo != nil {
		a, err := accessOf(*e.EditInfo)
		if err != nil {
			return nil, err
		}
		gc.ModifyAttributesAccess = a
	}
	if e.AddMembers != nil {
		a, err := accessOf(*e.AddMembers)
		if err != nil {
			return nil, err
		}
		gc.ModifyMemberAccess = a
	}
	if e.Leave {
		me := c.Store.ACI
		gc.DeleteMembers = append(gc.DeleteMembers, &me)
	}
	if _, err := c.UpdateGroup(ctx, gc, gid); err != nil {
		return nil, err
	}
	if e.Leave {
		return map[string]any{"id": id, "left": true}, nil
	}
	g, err := groupInfo(ctx, c, id)
	if err != nil {
		return nil, err
	}
	event("group", g)
	return g, nil
}

// senderName is a sender's name from what the store knows, without asking Signal.
func senderName(c *signalmeow.Client, aci uuid.UUID) string {
	if aci == uuid.Nil {
		return ""
	}
	ctx, cancel := context.WithTimeout(bg(), 5*time.Second)
	defer cancel()
	r, err := c.Store.RecipientStore.LoadAndUpdateRecipient(ctx, aci, uuid.Nil, nil)
	if err != nil {
		return ""
	}
	return recipientName(r)
}

// --- events ---------------------------------------------------------------------------------------------------------

// onEvent takes what signalmeow hears, on its receive loop, and tells the app. Always true: the event is dealt with,
// so Signal's server need not send it again.
func onEvent(raw events.SignalEvent) bool {
	mu.Lock()
	c := cli
	mu.Unlock()
	switch evt := raw.(type) {
	case *events.ChatEvent:
		if c != nil {
			chatEvent(c, evt)
		}
	case *events.Receipt:
		kind := ""
		switch evt.Content.GetType() {
		case signalpb.ReceiptMessage_DELIVERY:
			kind = "delivered"
		case signalpb.ReceiptMessage_READ:
			kind = "read"
		}
		if kind != "" {
			event("receipt", map[string]any{"chat": evt.Sender.String(), "ts": nonNil(evt.Content.GetTimestamp()), "kind": kind})
		}
	case *events.ContactList:
		if c == nil {
			break
		}
		list := make([]map[string]any, 0, len(evt.Contacts))
		for _, r := range evt.Contacts {
			if r.ACI != uuid.Nil && r.ACI != c.Store.ACI {
				// No avatar downloads here: this is the receive loop.
				list = append(list, contact(nil, nil, r))
			}
		}
		event("contacts", map[string]any{"list": list})
	case *events.LoggedOut:
		if c != nil {
			go unlinked(c)
		}
	case *events.DecryptionError:
		log.Warn().Err(evt.Err).Stringer("sender", evt.Sender).Uint64("ts", evt.Timestamp).Msg("message not decrypted")
	}
	return true
}

// nonNil is [ts], or an empty list for none: so the app is sent [] and never null.
func nonNil(ts []uint64) []uint64 {
	if ts == nil {
		return []uint64{}
	}
	return ts
}

// chatEvent turns something said in a chat into the app's event: "edited", "reaction", "deleted" or "message".
func chatEvent(c *signalmeow.Client, evt *events.ChatEvent) {
	// An edit (Matt, 2026-11-17: "Add support for edited messages on telegram and signal and the ability to see the
	// original message"): which message, by its first time, and its words now; the app keeps what it said before.
	if em, ok := evt.Event.(*signalpb.EditMessage); ok {
		event("edited", map[string]any{
			"chat": evt.Info.ChatID, "from": evt.Info.Sender.String(), "target_ts": em.GetTargetSentTimestamp(),
			"ts": em.GetDataMessage().GetTimestamp(), "text": em.GetDataMessage().GetBody(),
			"mentions": mentionsOf(em.GetDataMessage()),
		})
		return
	}
	dm, ok := evt.Event.(*signalpb.DataMessage)
	if !ok {
		return
	}
	group := dm.GetGroupV2() != nil
	chat := evt.Info.ChatID
	sender := evt.Info.Sender
	// A group heard from for the first time this run: its name, members and picture told to the app, off the receive
	// loop (Matt, 2026-11-16: "the group titles are not coming through"). The app asks for groups once, on linking,
	// when the store has none yet: a group is known only from its first message, which carries its key.
	if group {
		// A change to the group by someone (its name, picture, people, timer): told again, as it now is.
		if len(dm.GetGroupV2().GetGroupChange()) > 0 {
			announcedMu.Lock()
			delete(announced, chat)
			announcedMu.Unlock()
		}
		announceGroup(c, chat)
	}
	switch {
	case dm.Reaction != nil:
		target, _ := signalmeow.ParseStringOrBinaryUUID(dm.Reaction.GetTargetAuthorAci(), dm.Reaction.GetTargetAuthorAciBinary())
		event("reaction", map[string]any{
			"chat": chat, "from": sender.String(), "target_ts": dm.Reaction.GetTargetSentTimestamp(),
			"target_author": target.String(), "emoji": dm.Reaction.GetEmoji(), "remove": dm.Reaction.GetRemove(),
		})
	case dm.Delete != nil:
		event("deleted", map[string]any{"chat": chat, "target_ts": dm.Delete.GetTargetSentTimestamp()})
	case dm.Body != nil || len(dm.Attachments) > 0 || dm.Sticker != nil:
		event("message", message(c, chat, group, sender, dm))
	}
}

// message is a message as the app is told it: who wrote it and where, its words, its attachments (a sticker among
// them), its mentions and the message it quotes. "ts", Signal's name for the message, is in milliseconds.
func message(c *signalmeow.Client, chat string, group bool, sender uuid.UUID, dm *signalpb.DataMessage) map[string]any {
	atts := dm.GetAttachments()
	media := make([]map[string]any, 0, len(atts)+1)
	for _, a := range atts {
		if m := mediaOf(a); m != nil {
			media = append(media, m)
		}
	}
	// A sticker is marked as one, so the app draws it on its own with no bubble behind it (Matt, 2026-11-20:
	// "stickers in telegram chat and others render inside chat bubbles instead of transparent backgrounds").
	if st := dm.GetSticker(); st != nil && st.GetData() != nil {
		if m := mediaOf(st.GetData()); m != nil {
			m["sticker"] = true
			media = append(media, m)
		}
	}
	name := senderName(c, sender)
	// Someone nothing here names yet: their profile fetched, and the name told to the app as it comes. In a chat of
	// two the one written with is the chat itself, also when the message is this account's own from another device.
	if name == "" && sender != c.Store.ACI {
		announceName(c, sender)
	}
	if !group {
		if other, err := uuid.Parse(chat); err == nil && other != c.Store.ACI && other != sender {
			if r, err := c.Store.RecipientStore.LoadAndUpdateRecipient(bg(), other, uuid.Nil, nil); err == nil && recipientName(r) == "" {
				announceName(c, other)
			}
		}
	}
	m := map[string]any{
		"chat": chat, "group": group, "from": sender.String(), "name": name,
		"mine": sender == c.Store.ACI, "ts": dm.GetTimestamp(), "text": dm.GetBody(), "media": media,
		"mentions": mentionsOf(dm),
	}
	if q := dm.GetQuote(); q != nil {
		author, _ := signalmeow.ParseStringOrBinaryUUID(q.GetAuthorAci(), q.GetAuthorAciBinary())
		m["quote"] = map[string]any{"ts": q.GetId(), "author": author.String(), "text": q.GetText()}
	}
	return m
}

// mentionsOf is each @mention in a message's words, as Signal sends them (Matt, 2026-11-19: "when clicking on a @mention
// anywhere including signal and telegram chats show this profile popup"): the body holds U+FFFC where each person is
// named, and a body range says where (start and length in UTF-16 units, as Signal counts) and whose ACI it is. Ranges
// that are only styles (bold, a spoiler) are left out. Never null, so the app always finds a list.
func mentionsOf(dm *signalpb.DataMessage) []map[string]any {
	out := make([]map[string]any, 0)
	for _, r := range dm.GetBodyRanges() {
		if r.GetMentionAci() == "" && len(r.GetMentionAciBinary()) == 0 {
			continue
		}
		aci, err := signalmeow.ParseStringOrBinaryUUID(r.GetMentionAci(), r.GetMentionAciBinary())
		if err != nil || aci == uuid.Nil {
			continue
		}
		out = append(out, map[string]any{"start": r.GetStart(), "length": r.GetLength(), "aci": aci.String()})
	}
	return out
}

// mediaOf is an attachment as the app is told it: what it is, and its pointer (where it is and the key to it), which
// the app hands back to "download" as it is.
func mediaOf(a *signalpb.AttachmentPointer) map[string]any {
	ptr, err := protojson.Marshal(a)
	if err != nil {
		return nil
	}
	return map[string]any{
		"pointer": json.RawMessage(ptr), "mime": a.GetContentType(), "name": a.GetFileName(), "size": a.GetSize(),
		"width": a.GetWidth(), "height": a.GetHeight(),
	}
}

// --- the log file and groups told as they are met -------------------------------------------------------------------

// logFile is signal.log in the store's folder, begun afresh past a megabyte; standard error alone where it can't open.
func logFile() io.Writer {
	path := filepath.Join(dir, "signal.log")
	if st, err := os.Stat(path); err == nil && st.Size() > 1<<20 {
		_ = os.Remove(path)
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		// Not os.Stderr: the logger writes there already, and each line would be written twice.
		return io.Discard
	}
	return f
}

// announced is what has been told to the app this run: group ids (announceGroup) and "name:<aci>" (announceName).
var (
	announcedMu sync.Mutex
	announced   = map[string]bool{}
)

// announceGroup says a "group" event for [chat] (the group's id), once a run, as the "groups" op describes one.
func announceGroup(c *signalmeow.Client, chat string) {
	announcedMu.Lock()
	if announced[chat] {
		announcedMu.Unlock()
		return
	}
	announced[chat] = true
	announcedMu.Unlock()
	go func() {
		ctx, cancel := context.WithTimeout(bg(), 30*time.Second)
		defer cancel()
		g, err := describeGroup(ctx, c, chat)
		if err != nil {
			log.Warn().Err(err).Str("group", chat).Msg("group not described")
			announcedMu.Lock()
			delete(announced, chat)
			announcedMu.Unlock()
			return
		}
		event("group", g)
	}()
}
