// Uplink's Google Messages sidecar (README.md). AGPL-3.0, as libgm, on which it is built.
//
// Requests, one JSON object a line on standard input, each with an "id" its answer carries back:
//
//	{"id":1,"op":"status"}                          → {"paired":bool,"connected":bool,"phone":string}
//	{"id":2,"op":"pair"}                            → {} then events "qr" (again every 30 s) and "paired"
//	{"id":3,"op":"conversations","count":100}       → {"items":[conversation…]}
//	{"id":4,"op":"messages","conv":"…","count":50}  → {"items":[message…]}
//	{"id":5,"op":"send","conv":"…","text":"…"}      → {"tmp":"…"}
//	{"id":6,"op":"react","conv":"…","msg":"…","emoji":"👍","remove":false} → {}
//	{"id":7,"op":"read","conv":"…","msg":"…"}       → {}
//	{"id":8,"op":"media","media":"…","key":"<base64>","path":"…"} → {"path":"…"}
//	{"id":9,"op":"unpair"}                          → {}
//	{"id":11,"op":"send_media","conv":"…","path":"…","text":"…"} → {"media":"…","mime":"…"} (a picture or video, with words; the uploaded file's id and kind)
//	{"id":12,"op":"pair_google","cookies":{"SID":"…",…}} → {} then events "emoji" (tap it in Google Messages on the
//	                                                phone) and "paired", or "pair_failed": Google-account pairing, which
//	                                                is what Google Messages offers now that QR pairing is gone.
//	{"id":13,"op":"rename","conv":"…","name":"…"}  → {} (an RCS group's name, for everyone in it)
//	{"id":10,"op":"activate"}                       → {} (this becomes Google Messages' active web session)
//
// Answers: {"id":1,"ok":{…}} or {"id":1,"error":"…"}. Events, unasked: {"ev":"ready"}, {"ev":"qr","url":"…"},
// {"ev":"paired"}, {"ev":"message","data":message}, {"ev":"conversation","data":conversation},
// {"ev":"phone","responding":bool}, {"ev":"unpaired","why":"…"}, {"ev":"inactive"} (another web session, on a
// computer or messages.google.com, took over: Google Messages has one active at a time) and {"ev":"active"}.
//
// With --takeover (Uplink on the phone, which owns the session) an inactive session takes itself back after a short
// wait, as mautrix-gmessages' bridge does.
package main

import (
	"bufio"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/rs/zerolog"
	"go.mau.fi/util/exhttp"

	"go.mau.fi/mautrix-gmessages/pkg/libgm"
	"go.mau.fi/mautrix-gmessages/pkg/libgm/events"
	"go.mau.fi/mautrix-gmessages/pkg/libgm/gmproto"
)

// request is one line Uplink sends. Fields an op does not use are left empty.
type request struct {
	ID     int64  `json:"id"`
	Op     string `json:"op"`
	Count  int64  `json:"count"`
	Conv   string `json:"conv"`
	Msg    string `json:"msg"`
	Text   string `json:"text"`
	Emoji  string `json:"emoji"`
	Remove bool   `json:"remove"`
	Media  string `json:"media"`
	Key    string `json:"key"`
	Path    string            `json:"path"`
	Mime    string            `json:"mime"`
	Name    string            `json:"name"`
	Cookies map[string]string `json:"cookies"`
}

// dir holds session.json; takeover is the --takeover flag. out is standard output, one JSON object a line; outLock
// keeps lines whole when goroutines speak at once.
//
// mu guards the second group: the client and its session, the phone's SIMs, the conversations seen so far (by id, for
// the SIM and participant a send needs) and the cancel of a pairing still under way.
var (
	dir      string
	takeover bool
	log     zerolog.Logger
	out     = json.NewEncoder(os.Stdout)
	outLock sync.Mutex

	mu      sync.Mutex
	cli     *libgm.Client
	auth    *libgm.AuthData
	sims    []*gmproto.SIMCard
	convs   = map[string]*gmproto.Conversation{}
	pairing context.CancelFunc
)

// say writes one line, an answer or an event, to standard output.
func say(v any) {
	outLock.Lock()
	defer outLock.Unlock()
	_ = out.Encode(v)
}

// event says the unasked event [name], with [data] under "data" when there is any.
func event(name string, data any) {
	m := map[string]any{"ev": name}
	if data != nil {
		m["data"] = data
	}
	say(m)
}

// main resumes a kept session, says "ready", then answers requests (each on a goroutine of its own) until standard
// input closes.
func main() {
	flag.StringVar(&dir, "dir", "", "where the session is kept")
	flag.BoolVar(&takeover, "takeover", false, "take the active session back when another takes it")
	flag.Parse()
	if dir == "" {
		fmt.Fprintln(os.Stderr, "--dir is needed")
		os.Exit(2)
	}
	_ = os.MkdirAll(dir, 0o700)
	// libgm's log to standard error, for Uplink's developer log; never standard output, which is the conversation.
	log = zerolog.New(os.Stderr).With().Timestamp().Logger().Level(zerolog.InfoLevel)
	if loaded := loadSession(); loaded != nil {
		auth = loaded
		connect()
	}
	event("ready", nil)
	// A Google-account session's cookies change as Google answers: kept every few minutes as well as at events.
	go func() {
		for range time.Tick(5 * time.Minute) {
			mu.Lock()
			if auth != nil {
				saveSession()
			}
			mu.Unlock()
		}
	}()
	// A request line may be long (a Google sign-in's cookies): up to 8 MB.
	scan := bufio.NewScanner(os.Stdin)
	scan.Buffer(make([]byte, 1<<20), 8<<20)
	for scan.Scan() {
		var r request
		if err := json.Unmarshal(scan.Bytes(), &r); err != nil {
			continue
		}
		go handle(r)
	}
	// Uplink closed its end: the app is quitting.
	mu.Lock()
	if cli != nil {
		saveSession()
		cli.Disconnect()
	}
	mu.Unlock()
}

func sessionPath() string { return filepath.Join(dir, "session.json") }

// loadSession reads the kept session, or nil when there is none or it cannot be read.
func loadSession() *libgm.AuthData {
	f, err := os.Open(sessionPath())
	if err != nil {
		return nil
	}
	defer f.Close()
	var a libgm.AuthData
	if json.NewDecoder(f).Decode(&a) != nil {
		return nil
	}
	return &a
}

// saveSession keeps the session in a file only this user can read, written beside it and renamed into place so a
// crash never leaves half a file. Called with mu held.
func saveSession() {
	if auth == nil {
		return
	}
	tmp := sessionPath() + ".tmp"
	f, err := os.OpenFile(tmp, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
	if err != nil {
		return
	}
	if json.NewEncoder(f).Encode(auth) == nil && f.Close() == nil {
		_ = os.Rename(tmp, sessionPath())
	}
}

// connect starts the client for a paired session. Called with mu held, or before anything else runs.
func connect() {
	cli = libgm.NewClient(auth, nil, log, exhttp.SensibleClientSettings)
	cli.SetEventHandler(onEvent)
	c := cli
	go func() {
		if err := c.Connect(context.Background()); err != nil {
			log.Err(err).Msg("connect")
			return
		}
		event("connected", nil)
	}()
}

// onEvent takes what libgm hears from Google Messages: remembers SIMs and conversations, and passes messages,
// conversations and the session's ups and downs on to Uplink as events.
func onEvent(raw any) {
	switch evt := raw.(type) {
	case *events.ClientReady:
		mu.Lock()
		for _, c := range evt.Conversations {
			convs[c.ConversationID] = c
		}
		mu.Unlock()
		event("connected", nil)
	case *events.AuthTokenRefreshed:
		mu.Lock()
		saveSession()
		mu.Unlock()
	case *gmproto.Settings:
		mu.Lock()
		sims = evt.GetSIMCards()
		mu.Unlock()
	case *gmproto.Conversation:
		mu.Lock()
		convs[evt.ConversationID] = evt
		mu.Unlock()
		event("conversation", conversation(evt))
	case *libgm.WrappedMessage:
		event("message", message(evt.Message))
	case *gmproto.Message:
		event("message", message(evt))
	case *gmproto.UserAlertEvent:
		switch evt.GetAlertType() {
		case gmproto.AlertType_BROWSER_INACTIVE:
			event("inactive", nil)
			if takeover {
				go func() {
					time.Sleep(10 * time.Second)
					if c, err := client(); err == nil {
						_ = c.SetActiveSession(context.Background())
					}
				}()
			}
		case gmproto.AlertType_BROWSER_ACTIVE:
			// libgm sends no ClientReady any more: this alert is what says the session is up (mautrix-gmessages'
			// bridge treats it so too). Uplink reads "connected" and fetches the conversations.
			event("active", nil)
			event("connected", nil)
		}
	case *events.PhoneNotResponding:
		say(map[string]any{"ev": "phone", "responding": false})
	case *events.PhoneRespondingAgain:
		say(map[string]any{"ev": "phone", "responding": true})
	case *events.ListenFatalError:
		unpaired("Google Messages ended this computer's session")
	case *events.GaiaLoggedOut:
		unpaired("Signed out of Google")
	}
}

// unpaired forgets the session, in memory and on disk, and tells Uplink why.
func unpaired(why string) {
	mu.Lock()
	if cli != nil {
		cli.Disconnect()
	}
	cli, auth = nil, nil
	convs = map[string]*gmproto.Conversation{}
	_ = os.Remove(sessionPath())
	mu.Unlock()
	say(map[string]any{"ev": "unpaired", "why": why})
}

// handle does one request and says its answer: "ok" (an empty object when there is nothing to tell) or "error".
func handle(r request) {
	data, err := do(r)
	if err != nil {
		say(map[string]any{"id": r.ID, "error": err.Error()})
		return
	}
	if data == nil {
		data = map[string]any{}
	}
	say(map[string]any{"id": r.ID, "ok": data})
}

var errNotPaired = errors.New("not paired with Google Messages")

// client is the paired, signed-in client, or errNotPaired. Takes mu itself: never call it with mu held.
func client() (*libgm.Client, error) {
	mu.Lock()
	defer mu.Unlock()
	if cli == nil || auth == nil || !cli.IsLoggedIn() {
		return nil, errNotPaired
	}
	return cli, nil
}

// do carries out one request, with a minute to finish, and returns what its answer holds.
func do(r request) (any, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	switch r.Op {
	case "status":
		mu.Lock()
		defer mu.Unlock()
		phone := ""
		if len(sims) > 0 {
			phone = sims[0].GetSIMData().GetFormattedPhoneNumber()
		}
		return map[string]any{"paired": cli != nil && cli.IsLoggedIn(), "connected": cli != nil && cli.IsConnected(), "phone": phone}, nil
	case "pair":
		return nil, pair()
	case "pair_google":
		return nil, pairGoogle(r.Cookies)
	case "unpair":
		c, err := client()
		if err != nil {
			return nil, err
		}
		_ = c.Unpair(ctx)
		unpaired("Unpaired on this computer")
		return nil, nil
	case "conversations":
		c, err := client()
		if err != nil {
			return nil, err
		}
		count := r.Count
		if count <= 0 {
			count = 100
		}
		resp, err := c.ListConversations(ctx, &gmproto.ListConversationsRequest{Count: count, Folder: gmproto.ListConversationsRequest_INBOX})
		if err != nil {
			return nil, err
		}
		items := make([]any, 0, len(resp.GetConversations()))
		mu.Lock()
		for _, cv := range resp.GetConversations() {
			convs[cv.ConversationID] = cv
			items = append(items, conversation(cv))
		}
		mu.Unlock()
		return map[string]any{"items": items}, nil
	case "messages":
		c, err := client()
		if err != nil {
			return nil, err
		}
		count := r.Count
		if count <= 0 {
			count = 50
		}
		resp, err := c.FetchMessages(ctx, r.Conv, count, nil)
		if err != nil {
			return nil, err
		}
		items := make([]any, 0, len(resp.GetMessages()))
		for _, m := range resp.GetMessages() {
			items = append(items, message(m))
		}
		return map[string]any{"items": items}, nil
	case "send":
		c, err := client()
		if err != nil {
			return nil, err
		}
		return sendInfo(ctx, c, r.Conv, []*gmproto.MessageInfo{{Data: &gmproto.MessageInfo_MessageContent{MessageContent: &gmproto.MessageContent{Content: r.Text}}}})
	case "send_media":
		c, err := client()
		if err != nil {
			return nil, err
		}
		data, err := os.ReadFile(r.Path)
		if err != nil {
			return nil, err
		}
		// The kind the app says it is (Android's own word for the picked file), else read from its first bytes; and its
		// own name, so the other side's app shows it as what it is.
		mime := r.Mime
		if mime == "" || mime == "application/octet-stream" {
			mime = http.DetectContentType(data)
		}
		name := r.Name
		if name == "" {
			name = filepath.Base(r.Path)
		}
		uploaded, err := c.UploadMedia(ctx, data, name, mime)
		if err != nil {
			return nil, err
		}
		info := []*gmproto.MessageInfo{{Data: &gmproto.MessageInfo_MediaContent{MediaContent: uploaded}}}
		if r.Text != "" {
			info = append(info, &gmproto.MessageInfo{Data: &gmproto.MessageInfo_MessageContent{MessageContent: &gmproto.MessageContent{Content: r.Text}}})
		}
		if _, err := sendInfo(ctx, c, r.Conv, info); err != nil {
			return nil, err
		}
		// The uploaded file's id: the app keeps its own copy as that picture, so its preview never waits on a download.
		return map[string]any{"media": uploaded.GetMediaID(), "mime": mime}, nil
	case "react":
		c, err := client()
		if err != nil {
			return nil, err
		}
		action := gmproto.SendReactionRequest_ADD
		if r.Remove {
			action = gmproto.SendReactionRequest_REMOVE
		}
		mu.Lock()
		cv := convs[r.Conv]
		mu.Unlock()
		sim := simFor("")
		if cv != nil {
			sim = simFor(cv.DefaultOutgoingID)
		}
		_, err = c.SendReaction(ctx, &gmproto.SendReactionRequest{
			MessageID:    r.Msg,
			ReactionData: gmproto.MakeReactionData(r.Emoji),
			Action:       action,
			SIMPayload:   sim.GetSIMData().GetSIMPayload(),
		})
		return nil, err
	case "activate":
		c, err := client()
		if err != nil {
			return nil, err
		}
		return nil, c.SetActiveSession(ctx)
	// A conversation archived or brought back (remove), as messages.google.com's Archive does.
	case "archive_conv":
		c, err := client()
		if err != nil {
			return nil, err
		}
		status := gmproto.ConversationStatus_ARCHIVED
		if r.Remove {
			status = gmproto.ConversationStatus_ACTIVE
		}
		_, err = c.UpdateConversation(ctx, &gmproto.UpdateConversationRequest{
			ConversationID: r.Conv,
			Data: &gmproto.UpdateConversationRequest_UpdateData{UpdateData: &gmproto.UpdateConversationData{
				ConversationID: r.Conv,
				Data:           &gmproto.UpdateConversationData_Status{Status: status},
			}},
		})
		return nil, err
	// An RCS group renamed for everyone in it, as Google Messages' Group details does (MMS groups have no name).
	case "rename":
		c, err := client()
		if err != nil {
			return nil, err
		}
		resp, err := c.UpdateConversation(ctx, &gmproto.UpdateConversationRequest{
			Action:         gmproto.ConversationActionStatus_RENAME_GROUP,
			ConversationID: r.Conv,
			Data:           &gmproto.UpdateConversationRequest_RenameData{RenameData: &gmproto.RenameGroupData{Name: r.Name}},
		})
		if err != nil {
			return nil, err
		}
		if !resp.GetSuccess() {
			return nil, errors.New("Google Messages would not rename the group")
		}
		return map[string]any{}, nil
	// One message deleted, as messages.google.com's Delete does.
	case "delete_msg":
		c, err := client()
		if err != nil {
			return nil, err
		}
		_, err = c.DeleteMessage(ctx, r.Msg)
		return nil, err
	// A conversation deleted, as messages.google.com's Delete does: from the phone and every device.
	case "delete_conv":
		c, err := client()
		if err != nil {
			return nil, err
		}
		return nil, c.DeleteConversation(ctx, r.Conv, "")
	case "read":
		c, err := client()
		if err != nil {
			return nil, err
		}
		return nil, c.MarkRead(ctx, r.Conv, r.Msg)
	case "media":
		c, err := client()
		if err != nil {
			return nil, err
		}
		key, err := base64.StdEncoding.DecodeString(r.Key)
		if err != nil {
			return nil, err
		}
		body, err := c.DownloadMedia(ctx, r.Media, key)
		if err != nil {
			return nil, err
		}
		defer body.Close()
		f, err := os.OpenFile(r.Path, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
		if err != nil {
			return nil, err
		}
		_, err = io.Copy(f, body)
		if cerr := f.Close(); err == nil {
			err = cerr
		}
		if err != nil {
			_ = os.Remove(r.Path)
			return nil, err
		}
		return map[string]any{"path": r.Path}, nil
	}
	return nil, fmt.Errorf("unknown op %q", r.Op)
}

// sendInfo sends [info] (words, a picture) to [conv], from the SIM and participant the conversation sends from.
func sendInfo(ctx context.Context, c *libgm.Client, conv string, info []*gmproto.MessageInfo) (any, error) {
	mu.Lock()
	cv := convs[conv]
	mu.Unlock()
	if cv == nil {
		var err error
		if cv, err = c.GetConversation(ctx, conv); err != nil {
			return nil, err
		}
	}
	// An id of our own making, answered to Uplink: the sent message comes back as an event carrying it ("tmp").
	tmp := fmt.Sprintf("tmp_%d", time.Now().UnixNano())
	resp, err := c.SendMessage(ctx, &gmproto.SendMessageRequest{
		ConversationID: conv,
		MessagePayload: &gmproto.MessagePayload{TmpID: tmp, ConversationID: conv, ParticipantID: cv.DefaultOutgoingID, TmpID2: tmp, MessageInfo: info},
		SIMPayload:     simFor(cv.DefaultOutgoingID).GetSIMData().GetSIMPayload(),
		TmpID:          tmp,
	})
	if err != nil {
		return nil, err
	}
	if resp.GetStatus() != gmproto.SendMessageResponse_SUCCESS {
		return nil, fmt.Errorf("Google Messages did not send it (%s)", resp.GetStatus())
	}
	return map[string]any{"tmp": tmp}, nil
}

// simFor is the SIM a conversation sends from: the one whose participant is its outgoing one, else the first.
func simFor(participant string) *gmproto.SIMCard {
	mu.Lock()
	defer mu.Unlock()
	for _, s := range sims {
		if participant != "" && s.GetSIMParticipant().GetID() == participant {
			return s
		}
	}
	if len(sims) > 0 {
		return sims[0]
	}
	return nil
}

// pair shows a QR code (event "qr", a fresh one every 30 seconds, for five minutes) until Google Messages on the
// phone scans it; then the session is kept and the client connected ("paired").
func pair() error {
	mu.Lock()
	if pairing != nil {
		pairing()
	}
	if cli != nil {
		cli.Disconnect()
	}
	a := libgm.NewAuthData()
	c := libgm.NewClient(a, nil, log, exhttp.SensibleClientSettings)
	c.SetEventHandler(func(any) {})
	done := make(chan *gmproto.PairedData, 1)
	callback := func(data *gmproto.PairedData) { done <- data }
	c.PairCallback.Store(&callback)
	ctx, cancel := context.WithCancel(context.Background())
	pairing = cancel
	mu.Unlock()
	if err := c.FetchConfig(ctx); err != nil {
		cancel()
		return err
	}
	qr, err := c.StartLogin(ctx)
	if err != nil {
		cancel()
		return err
	}
	say(map[string]any{"ev": "qr", "url": qr})
	go func() {
		defer cancel()
		for i := 0; i < 10; i++ {
			select {
			case <-done:
				c.Disconnect()
				// Google Messages keeps the pairing a moment before the session may connect again.
				time.Sleep(2 * time.Second)
				mu.Lock()
				auth = a
				saveSession()
				connect()
				mu.Unlock()
				event("paired", nil)
				return
			case <-time.After(30 * time.Second):
				next, err := c.RefreshPhoneRelay()
				if err != nil {
					say(map[string]any{"ev": "pair_failed", "why": err.Error()})
					c.Disconnect()
					return
				}
				say(map[string]any{"ev": "qr", "url": next})
			case <-ctx.Done():
				c.Disconnect()
				return
			}
		}
		say(map[string]any{"ev": "pair_failed", "why": "The QR code was not scanned in time"})
		c.Disconnect()
	}()
	return nil
}

// pairGoogle pairs by the person's Google account, from the cookies of a browser signed in to it (messages.google.com
// /web/config, in a private window): Google Messages on the phone shows emoji, and the person taps the one this says
// ("emoji"). Then the session, cookies and all, is kept and the client connected ("paired").
func pairGoogle(cookies map[string]string) error {
	need := []string{"SID", "HSID", "SSID", "OSID", "APISID", "SAPISID"}
	for _, n := range need {
		if cookies[n] == "" {
			return fmt.Errorf("the sign-in is missing the %s cookie: copy the whole request again", n)
		}
	}
	mu.Lock()
	if pairing != nil {
		pairing()
	}
	if cli != nil {
		cli.Disconnect()
	}
	a := libgm.NewAuthData()
	a.SetCookies(cookies)
	c := libgm.NewClient(a, nil, log, exhttp.SensibleClientSettings)
	c.SetEventHandler(onEvent)
	ctx, cancel := context.WithCancel(context.Background())
	pairing = cancel
	mu.Unlock()
	go func() {
		defer cancel()
		err := c.DoGaiaPairing(ctx, func(emoji string) {
			say(map[string]any{"ev": "emoji", "emoji": emoji})
		})
		if err != nil {
			c.Disconnect()
			say(map[string]any{"ev": "pair_failed", "why": gaiaWhy(err)})
			return
		}
		mu.Lock()
		auth, cli = a, c
		saveSession()
		mu.Unlock()
		event("paired", nil)
		// Connected as soon as libgm's own reconnect is up, whether or not its alert comes (it may have come already).
		go func() {
			for i := 0; i < 30; i++ {
				time.Sleep(time.Second)
				if c.IsConnected() && c.IsLoggedIn() {
					event("connected", nil)
					return
				}
			}
		}()
	}()
	return nil
}

// gaiaWhy is a Google-account pairing's failure in words a person can act on.
func gaiaWhy(err error) string {
	switch {
	case errors.Is(err, libgm.ErrNoDevicesFound):
		return "Google found no phone with Google Messages signed in to this account"
	case errors.Is(err, context.Canceled):
		return "Pairing was stopped"
	default:
		return "Google didn't accept the pairing (" + err.Error() + "). Sign in again in a new private window and copy the request again."
	}
}

// conversation is a conversation as Uplink reads it: its people, last line and flags. "time" is in milliseconds
// (Google Messages counts in microseconds).
func conversation(c *gmproto.Conversation) map[string]any {
	people := make([]map[string]any, 0, len(c.GetParticipants()))
	for _, p := range c.GetParticipants() {
		people = append(people, map[string]any{
			"id": p.GetID().GetParticipantID(), "name": p.GetFullName(), "number": p.GetID().GetNumber(),
			"formatted": p.GetFormattedNumber(), "me": p.GetIsMe(),
		})
	}
	return map[string]any{
		"id": c.GetConversationID(), "name": c.GetName(), "group": c.GetIsGroupChat(), "unread": c.GetUnread(),
		"time": c.GetLastMessageTimestamp() / 1000, "snippet": c.GetLatestMessage().GetDisplayContent(),
		"fromMe": c.GetLatestMessage().GetFromMe() != 0, "rcs": c.GetType() == gmproto.ConversationType_RCS,
		"pinned": c.GetPinned(), "outgoing": c.GetDefaultOutgoingID(), "people": people,
		"archived": c.GetStatus() == gmproto.ConversationStatus_ARCHIVED,
	}
}

// message is a message as Uplink reads it: its words joined, each attachment with the id and key the "media" op
// needs to fetch it, its reactions, and Google Messages' status in lower case. "time" is in milliseconds.
func message(m *gmproto.Message) map[string]any {
	var text []string
	media := []map[string]any{}
	for _, info := range m.GetMessageInfo() {
		if t := info.GetMessageContent().GetContent(); t != "" {
			text = append(text, t)
		}
		if mc := info.GetMediaContent(); mc != nil {
			media = append(media, map[string]any{
				"id": mc.GetMediaID(), "key": base64.StdEncoding.EncodeToString(mc.GetDecryptionKey()),
				"thumb": mc.GetThumbnailMediaID(), "thumbKey": base64.StdEncoding.EncodeToString(mc.GetThumbnailDecryptionKey()),
				"mime": mc.GetMimeType(), "name": mc.GetMediaName(), "size": mc.GetSize(),
				"width": mc.GetDimensions().GetWidth(), "height": mc.GetDimensions().GetHeight(),
			})
		}
	}
	reactions := []map[string]any{}
	for _, r := range m.GetReactions() {
		reactions = append(reactions, map[string]any{"emoji": r.GetData().GetUnicode(), "from": r.GetParticipantIDs()})
	}
	status := m.GetMessageStatus().GetStatus().String()
	// Google Messages' own lines about the conversation ("Texting with Jade (SMS/MMS)", a switch to RCS) are tombstones,
	// not texts (Matt, 2026-11-17): marked so every client can leave them out.
	if strings.Contains(strings.ToLower(status), "tombstone") {
		status = "tombstone"
	}
	return map[string]any{
		"id": m.GetMessageID(), "conv": m.GetConversationID(), "from": m.GetParticipantID(),
		"me": strings.HasPrefix(status, "OUTGOING"), "text": strings.Join(text, "\n"),
		"time": m.GetTimestamp() / 1000, "status": strings.ToLower(status), "tmp": m.GetTmpID(),
		"media": media, "reactions": reactions,
	}
}
