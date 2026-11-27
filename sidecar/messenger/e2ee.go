package main

// End-to-end encrypted chats, which most Messenger chats between two people now are. Their messages do not come
// down Messenger's ordinary connection: Meta runs them over WhatsApp's protocol, each device with keys of its own.
// The helper registers itself as one more device of the account (as a browser signing in to messenger.com does),
// keeps its keys in e2ee.db beside the session, and reads and writes those chats through whatsmeow, the way
// mautrix-meta's bridge does.

import (
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/proto/waArmadilloApplication"
	"go.mau.fi/whatsmeow/proto/waCommon"
	"go.mau.fi/whatsmeow/proto/waConsumerApplication"
	"go.mau.fi/whatsmeow/proto/waMediaTransport"
	"go.mau.fi/whatsmeow/proto/waMsgApplication"
	"go.mau.fi/whatsmeow/store"
	"go.mau.fi/whatsmeow/store/sqlstore"
	waTypes "go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
	waLog "go.mau.fi/whatsmeow/util/log"
	"google.golang.org/protobuf/proto"

	"go.mau.fi/mautrix-meta/pkg/messagix"
	"go.mau.fi/mautrix-meta/pkg/messagix/methods"
	"go.mau.fi/mautrix-meta/pkg/messagix/socket"
	"go.mau.fi/mautrix-meta/pkg/messagix/table"
)

// An encrypted message has no id of Meta's making that says where it is from: the helper's id for one is
// "wa:<sender's id>:<the id its sender gave it>", which is all that reacting to it or unsending it needs.
const sealedPrefix = "wa:"

// isEncryptedID is whether a message id is one the helper made for an encrypted message.
func isEncryptedID(id string) bool { return strings.HasPrefix(id, sealedPrefix) }

// sealedID is the helper's id for an encrypted message, from its sender's id and the id its sender gave it.
func sealedID(sender, stanza string) string { return sealedPrefix + sender + ":" + stanza }

// parseSealedID takes such an id apart again; ok is false for any other id.
func parseSealedID(id string) (sender, stanza string, ok bool) {
	parts := strings.SplitN(id, ":", 3)
	if len(parts) != 3 || parts[0]+":" != sealedPrefix || parts[1] == "" || parts[2] == "" {
		return "", "", false
	}
	return parts[1], parts[2], true
}

// How many times one connection registers a device anew after Meta drops the one it had: each try adds a device to
// the account, so not many.
const keyTries = 2

// The store of the device's keys (e2ee.db), opened once and shared by every connection of this run.
var (
	keysLock sync.Mutex
	keys     *sqlstore.Container
)

// keysPath is where the device's keys are kept, beside the session. (SQLite may keep -wal and -shm files by it.)
func keysPath() string { return filepath.Join(dir, "e2ee.db") }

// openKeys is the key store, opened (and made, for the person alone to read) at its first use.
func openKeys(ctx context.Context) (*sqlstore.Container, error) {
	keysLock.Lock()
	defer keysLock.Unlock()
	if keys != nil {
		return keys, nil
	}
	// The store holds the device's keys: readable by the person alone.
	if f, err := os.OpenFile(keysPath(), os.O_CREATE|os.O_RDWR, 0o600); err == nil {
		_ = f.Close()
	}
	c, err := sqlstore.New(ctx, sqliteDriver, sqliteURI(keysPath()), waLog.Zerolog(log.With().Str("component", "keys").Logger()))
	if err != nil {
		return nil, err
	}
	keys = c
	return c, nil
}

// closeKeys closes the key store, before the helper exits or its file is removed. It opens again when next used.
func closeKeys() {
	keysLock.Lock()
	defer keysLock.Unlock()
	if keys != nil {
		_ = keys.Close()
		keys = nil
	}
}

// startKeys connects the encrypted side once Messenger's own connection is up. A failure here leaves ordinary chats
// working; it is tried again a few times, further and further apart.
func (c *conn) startKeys() {
	c.e2mu.Lock()
	if c.e2Started {
		c.e2mu.Unlock()
		return
	}
	c.e2Started = true
	c.e2mu.Unlock()
	wait := 5 * time.Second
	for attempt := 0; attempt < 6 && c.current(); attempt++ {
		err := c.connectKeys()
		if err == nil {
			return
		}
		log.Err(err).Msg("connect the encrypted side")
		if errors.Is(err, messagix.ErrICDCUnauthorized) {
			// Meta would not register the device with this page's token: a page loaded anew has a new one.
			go reload(c, "the encrypted side was refused")
			return
		}
		select {
		case <-time.After(wait):
		case <-c.ctx.Done():
			return
		}
		wait *= 3
	}
}

// connectKeys makes one try at the encrypted side: the device kept for this account is read, or a new one made
// and registered with Meta (its number then kept in the session), and whatsmeow's client connected with it.
func (c *conn) connectKeys() error {
	ctx := log.WithContext(c.ctx)
	container, err := openKeys(ctx)
	if err != nil {
		return fmt.Errorf("open the key store: %w", err)
	}
	mu.Lock()
	if sess == nil || bk == nil {
		mu.Unlock()
		return errors.New("no session")
	}
	me, deviceID := bk.me, sess.WADevice
	mu.Unlock()

	var dev *store.Device
	if deviceID != 0 {
		dev, err = container.GetDevice(ctx, waTypes.JID{User: idString(me), Device: deviceID, Server: waTypes.MessengerServer})
		if err != nil {
			return fmt.Errorf("read the device's keys: %w", err)
		}
	}
	fresh := dev == nil
	if fresh {
		dev = container.NewDevice()
	}
	c.cli.SetDevice(dev)
	if fresh {
		log.Info().Msg("registering a device for encrypted chats")
		if err = c.cli.RegisterE2EE(ctx, me); err != nil {
			return fmt.Errorf("register the device: %w", err)
		}
		if err = dev.Save(ctx); err != nil {
			return fmt.Errorf("keep the device's keys: %w", err)
		}
		mu.Lock()
		if sess != nil {
			sess.WADevice = dev.ID.Device
		}
		mu.Unlock()
		keep(c, true)
	}
	e2, err := c.cli.PrepareE2EEClient()
	if err != nil {
		return err
	}
	e2.AddEventHandler(func(evt any) { c.onSealed(e2, dev, evt) })
	c.e2mu.Lock()
	if !c.current() {
		c.e2mu.Unlock()
		return nil
	}
	c.e2 = e2
	c.e2mu.Unlock()
	if err = e2.Connect(); err != nil {
		c.e2mu.Lock()
		c.e2 = nil
		c.e2mu.Unlock()
		return fmt.Errorf("connect: %w", err)
	}
	return nil
}

// dropDevice forgets the device Meta no longer knows and registers a new one, a couple of times at most.
func (c *conn) dropDevice(e2 *whatsmeow.Client, dev *store.Device) {
	c.e2mu.Lock()
	if c.e2 != e2 {
		c.e2mu.Unlock()
		return
	}
	c.e2 = nil
	c.e2Tries++
	again := c.e2Tries <= keyTries
	c.e2Started = !again
	c.e2mu.Unlock()
	e2.Disconnect()
	if err := dev.Delete(log.WithContext(c.ctx)); err != nil {
		log.Err(err).Msg("forget the device's keys")
	}
	mu.Lock()
	if sess != nil {
		sess.WADevice = 0
	}
	mu.Unlock()
	keep(c, true)
	if again && c.current() {
		go c.startKeys()
	}
}

// onSealed is whatsmeow's handler: decrypted messages and receipts are said as events, and what it says of the
// connection is logged or acted on (a device Meta dropped is registered anew, a token grown old means a new page).
func (c *conn) onSealed(e2 *whatsmeow.Client, dev *store.Device, raw any) {
	if !c.current() {
		return
	}
	switch evt := raw.(type) {
	case *events.FBMessage:
		mu.Lock()
		b := bk
		mu.Unlock()
		if b == nil {
			return
		}
		met, out := b.sealed(evt)
		if met {
			go c.introduce(b, evt.Info.Chat)
		}
		for _, e := range out {
			event(e.Name, e.Fields)
		}
	case *events.Receipt:
		mu.Lock()
		b := bk
		mu.Unlock()
		if b != nil {
			for _, e := range b.sealedReceipt(evt) {
				event(e.Name, e.Fields)
			}
		}
	case *events.Connected:
		log.Info().Msg("the encrypted side is connected")
	case *events.Disconnected:
		log.Info().Msg("the encrypted side dropped; it connects again by itself")
	case *events.CATRefreshError:
		log.Err(evt.Error).Msg("the encrypted side's token could not be renewed")
		go reload(c, "the encrypted side's token grew old")
	case *events.LoggedOut:
		log.Warn().Str("why", evt.PermanentDisconnectDescription()).Msg("Meta dropped the encrypted side's device")
		go c.dropDevice(e2, dev)
	case *events.ConnectFailure:
		log.Warn().Str("why", evt.PermanentDisconnectDescription()).Msg("the encrypted side would not connect")
		if evt.Reason == events.ConnectFailureNotFound {
			go c.dropDevice(e2, dev)
		} else {
			go reload(c, "the encrypted side would not connect")
		}
	case events.PermanentDisconnect:
		log.Warn().Str("why", evt.PermanentDisconnectDescription()).Msg("the encrypted side is closed")
	}
}

// introduce says a chat first met through an encrypted message: Messenger's tables had not listed it.
func (c *conn) introduce(b *book, chat waTypes.JID) {
	k, ok := parseID(chat.User)
	if !ok {
		return
	}
	ctx, cancel := context.WithTimeout(log.WithContext(c.ctx), 30*time.Second)
	defer cancel()
	if chat.Server == waTypes.GroupServer {
		if e2 := c.sealedClient(); e2 != nil {
			if info, err := e2.GetGroupInfo(ctx, chat); err == nil && info != nil {
				b.mu.Lock()
				t := b.thread(k)
				t.Name = info.Name
				for _, p := range info.Participants {
					if id, ok := parseID(p.JID.User); ok {
						t.Members[id] = true
					}
				}
				b.mu.Unlock()
			}
		}
	} else if b.threadCopy(k).Key == k {
		b.mu.Lock()
		known := b.contacts[k] != nil
		b.mu.Unlock()
		if !known {
			if tbl, err := tasks(ctx, c, &socket.GetContactsFullTask{ContactID: k}); err == nil {
				c.take(tbl, true)
			}
		}
	}
	b.mu.Lock()
	var said map[string]any
	if t := b.threads[k]; t != nil {
		said = b.chatJSON(t)
	}
	b.mu.Unlock()
	if said != nil {
		event("chat", said)
	}
}

// sealedClient is the encrypted side's client, nil while there is none; it may not be connected yet.
func (c *conn) sealedClient() *whatsmeow.Client {
	c.e2mu.Lock()
	defer c.e2mu.Unlock()
	return c.e2
}

// sealedReady is the encrypted side once it is connected, waiting a while for it where it is still coming up.
func (c *conn) sealedReady(ctx context.Context) (*whatsmeow.Client, error) {
	end := time.Now().Add(30 * time.Second)
	for {
		if e2 := c.sealedClient(); e2 != nil && e2.IsConnected() && e2.IsLoggedIn() {
			return e2, nil
		}
		if time.Now().After(end) || ctx.Err() != nil {
			return nil, errors.New("The encrypted side of Messenger is not connected yet; try again in a moment")
		}
		time.Sleep(300 * time.Millisecond)
	}
}

// --- encrypted messages → events ------------------------------------------------------------------------------------

// sealed is the file of an encrypted message: where its sealed bytes are on Meta's servers and what opens them.
type sealed struct {
	Path string `json:"path"`
	Key  string `json:"key"`
	Hash string `json:"sha256"`
	Enc  string `json:"enc_sha256"`
	Kind string `json:"kind"`
}

// b64 writes bytes as a pointer carries them.
func b64(b []byte) string { return base64.StdEncoding.EncodeToString(b) }

// sealedMedia is one file of an encrypted message as the protocol's `media` lists it, its pointer holding what
// `download` needs to fetch and open it; nil where Meta gave no place to fetch it from.
func sealedMedia(t *waMediaTransport.WAMediaTransport, kind whatsmeow.MediaType, name string, width, height uint32) map[string]any {
	in, an := t.GetIntegral(), t.GetAncillary()
	if in.GetDirectPath() == "" {
		return nil
	}
	return map[string]any{
		"pointer": map[string]any{"e2ee": sealed{
			Path: in.GetDirectPath(), Key: b64(in.GetMediaKey()), Hash: b64(in.GetFileSHA256()), Enc: b64(in.GetFileEncSHA256()), Kind: string(kind),
		}},
		"mime":   an.GetMimetype(),
		"name":   name,
		"size":   int64(an.GetFileLength()),
		"width":  int64(width),
		"height": int64(height),
	}
}

// keyID is the helper's id for the message a key points at (the target of a reaction, an edit, an unsend), read as
// mautrix-meta reads it: "from me" in a key means from whoever sent the message that carries the key.
func keyID(me int64, info waTypes.MessageInfo, key *waCommon.MessageKey) string {
	if key.GetID() == "" {
		return ""
	}
	sender := info.Sender.User
	if !key.GetFromMe() {
		if p := key.GetParticipant(); p != "" {
			jid, err := waTypes.ParseJID(p)
			if err != nil {
				return ""
			}
			sender = jid.User
		} else if info.Chat.Server != waTypes.GroupServer {
			// Between two people the other one is whoever did not send this.
			if sender == idString(me) {
				sender = info.Chat.User
			} else {
				sender = idString(me)
			}
		} else {
			return ""
		}
	}
	return sealedID(sender, key.GetID())
}

// cannotShow stands in for the words of an encrypted message this helper cannot read (it is marked `unsupported`).
const cannotShow = "This kind of message can't be shown here yet. Open it in Messenger."

// sealed turns a decrypted message into what the app is told. met is true where the chat had not been heard of.
func (b *book) sealed(evt *events.FBMessage) (met bool, out []ev) {
	info := evt.Info
	k, ok := parseID(info.Chat.User)
	if !ok {
		return false, nil
	}
	from := info.Sender.User
	fromID, _ := parseID(from)
	group := info.Chat.Server == waTypes.GroupServer
	chat := idString(k)
	b.mu.Lock()
	defer b.mu.Unlock()
	mine := info.IsFromMe || fromID == b.me
	t := b.threads[k]
	met = t == nil || !t.Type.IsWhatsApp()
	t = b.thread(k)
	if group {
		b.setKind(t, table.ENCRYPTED_OVER_WA_GROUP, "")
	} else {
		b.setKind(t, table.ENCRYPTED_OVER_WA_ONE_TO_ONE, "")
	}

	app, isConsumer := evt.Message.(*waConsumerApplication.ConsumerApplication)
	if evt.Message == nil {
		// A setting of the chat (disappearing messages), not a message.
		return met, nil
	}
	if !isConsumer {
		// What devices tell each other (a chat deleted on another one, say) is not a message either.
		if arm, ok := evt.Message.(*waArmadilloApplication.Armadillo); ok && arm.GetPayload().GetContent() == nil {
			return met, nil
		}
		return met, []ev{{"message", b.sealedMessage(k, chat, group, info, from, fromID, mine, cannotShow, nil, evt.FBApplication, true)}}
	}
	if data := app.GetPayload().GetApplicationData(); data != nil {
		if revoke := data.GetRevoke(); revoke != nil {
			if target := keyID(b.me, info, revoke.GetKey()); target != "" {
				return met, []ev{{"deleted", map[string]any{"chat": chat, "target": target}}}
			}
		}
		return met, nil
	}
	content := app.GetPayload().GetContent()
	if content == nil {
		return met, nil
	}
	var text string
	var files []map[string]any
	unknown := false
	switch c := content.GetContent().(type) {
	case *waConsumerApplication.ConsumerApplication_Content_MessageText:
		text = c.MessageText.GetText()
	case *waConsumerApplication.ConsumerApplication_Content_ExtendedTextMessage:
		text = c.ExtendedTextMessage.GetText().GetText()
	case *waConsumerApplication.ConsumerApplication_Content_EditMessage:
		target := keyID(b.me, info, c.EditMessage.GetKey())
		if target == "" {
			return met, nil
		}
		return met, []ev{{"edited", map[string]any{"chat": chat, "target": target, "text": c.EditMessage.GetMessage().GetText()}}}
	case *waConsumerApplication.ConsumerApplication_Content_ReactionMessage:
		target := keyID(b.me, info, c.ReactionMessage.GetKey())
		if target == "" {
			return met, nil
		}
		emoji := c.ReactionMessage.GetText()
		return met, []ev{{"reaction", map[string]any{"chat": chat, "from": from, "target": target, "emoji": emoji, "remove": emoji == ""}}}
	case *waConsumerApplication.ConsumerApplication_Content_ImageMessage:
		text = c.ImageMessage.GetCaption().GetText()
		if tr, err := c.ImageMessage.Decode(); err == nil {
			files = append(files, sealedMedia(tr.GetIntegral().GetTransport(), whatsmeow.MediaImage, "image", tr.GetAncillary().GetWidth(), tr.GetAncillary().GetHeight()))
		}
	case *waConsumerApplication.ConsumerApplication_Content_VideoMessage:
		text = c.VideoMessage.GetCaption().GetText()
		if tr, err := c.VideoMessage.Decode(); err == nil {
			files = append(files, sealedMedia(tr.GetIntegral().GetTransport(), whatsmeow.MediaVideo, "video", tr.GetAncillary().GetWidth(), tr.GetAncillary().GetHeight()))
		}
	case *waConsumerApplication.ConsumerApplication_Content_AudioMessage:
		if tr, err := c.AudioMessage.Decode(); err == nil {
			files = append(files, sealedMedia(tr.GetIntegral().GetTransport(), whatsmeow.MediaAudio, "audio", 0, 0))
		}
	case *waConsumerApplication.ConsumerApplication_Content_DocumentMessage:
		if tr, err := c.DocumentMessage.Decode(); err == nil {
			files = append(files, sealedMedia(tr.GetIntegral().GetTransport(), whatsmeow.MediaDocument, c.DocumentMessage.GetFileName(), 0, 0))
		}
	case *waConsumerApplication.ConsumerApplication_Content_LocationMessage:
		loc := c.LocationMessage.GetLocation()
		text = strings.TrimSpace(strings.TrimSpace(loc.GetName()+"\n"+c.LocationMessage.GetAddress()) +
			fmt.Sprintf("\nhttps://www.google.com/maps?q=%f,%f", loc.GetDegreesLatitude(), loc.GetDegreesLongitude()))
	default:
		unknown = true
	}
	var kept []map[string]any
	for _, f := range files {
		if f != nil {
			kept = append(kept, f)
		}
	}
	if text == "" && len(kept) == 0 {
		// A sticker, a contact card, a file whose keys could not be read.
		unknown = true
		text = cannotShow
	}
	return met, []ev{{"message", b.sealedMessage(k, chat, group, info, from, fromID, mine, text, kept, evt.FBApplication, unknown)}}
}

// sealedMessage is a `message` event for an encrypted message. Called with the book's lock held.
func (b *book) sealedMessage(k int64, chat string, group bool, info waTypes.MessageInfo, from string, fromID int64, mine bool, text string, files []map[string]any, app *waMsgApplication.MessageApplication, unknown bool) map[string]any {
	id := sealedID(from, info.ID)
	ts := info.Timestamp.UnixMilli()
	b.remember(k, id, ts, fromID)
	if t := b.threads[k]; t != nil && ts >= t.Last {
		t.Last, t.Snippet, t.SnippetFrom = ts, text, fromID
		if mine {
			t.Unread = 0
		} else {
			t.Unread++
		}
	}
	if files == nil {
		files = []map[string]any{}
	}
	out := map[string]any{
		"chat": chat, "group": group, "id": id, "from": from, "name": b.name(fromID), "mine": mine,
		"ts": ts, "text": text, "media": files, "encrypted": true,
	}
	if unknown {
		out["unsupported"] = true
	}
	if q := app.GetMetadata().GetQuotedMessage(); q.GetStanzaID() != "" {
		// Who wrote the quoted message is named where Meta says; without it the id cannot be made.
		if jid, err := waTypes.ParseJID(q.GetParticipant()); err == nil && jid.User != "" {
			out["quote"] = map[string]any{"id": sealedID(jid.User, q.GetStanzaID())}
		}
	}
	return out
}

// sealedReceipt is a read or delivered mark from the encrypted side: it names the messages it is about.
func (b *book) sealedReceipt(evt *events.Receipt) []ev {
	var kind string
	switch evt.Type {
	case waTypes.ReceiptTypeRead, waTypes.ReceiptTypeReadSelf:
		kind = "read"
	case waTypes.ReceiptTypeDelivered:
		kind = "delivered"
	default:
		return nil
	}
	if len(evt.MessageIDs) == 0 || evt.Chat.User == "" {
		return nil
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	// A mark from someone else is about the person's own messages; the person's own mark names whose it read.
	author := idString(b.me)
	if !evt.MessageSender.IsEmpty() {
		author = evt.MessageSender.User
	} else if evt.Sender.User == idString(b.me) && evt.Chat.Server != waTypes.GroupServer {
		author = evt.Chat.User
	}
	return []ev{{"receipt", map[string]any{
		"chat": evt.Chat.User, "from": evt.Sender.User, "id": sealedID(author, evt.MessageIDs[len(evt.MessageIDs)-1]),
		"ts": evt.Timestamp.UnixMilli(), "kind": kind,
	}}}
}

// --- requests in encrypted chats ------------------------------------------------------------------------------------

// chatJID is an encrypted thread's address on the WhatsApp side: a group's, or the other person's.
func chatJID(t thread) waTypes.JID {
	if t.Type == table.ENCRYPTED_OVER_WA_GROUP {
		return waTypes.JID{User: idString(t.Key), Server: waTypes.GroupServer}
	}
	return waTypes.JID{User: idString(t.Key), Server: waTypes.MessengerServer}
}

// userJID is a person's address on the WhatsApp side, from their Facebook id.
func userJID(id string) waTypes.JID { return waTypes.JID{User: id, Server: waTypes.MessengerServer} }

// keyFor points at a message of an encrypted chat, for a reaction or an unsend.
func keyFor(me int64, chat waTypes.JID, id string) (*waCommon.MessageKey, error) {
	sender, stanza, ok := parseSealedID(id)
	if !ok {
		return nil, errors.New("That is not a message of an encrypted chat")
	}
	key := &waCommon.MessageKey{RemoteJID: proto.String(chat.String()), ID: proto.String(stanza)}
	if sender == idString(me) {
		key.FromMe = proto.Bool(true)
	}
	if chat.Server == waTypes.GroupServer {
		key.Participant = proto.String(userJID(sender).String())
	}
	return key, nil
}

// consumerContent wraps a message's content (words, a reaction) in the envelope Messenger's encrypted chats send.
func consumerContent(content *waConsumerApplication.ConsumerApplication_Content) *waConsumerApplication.ConsumerApplication {
	return &waConsumerApplication.ConsumerApplication{Payload: &waConsumerApplication.ConsumerApplication_Payload{
		Payload: &waConsumerApplication.ConsumerApplication_Payload_Content{Content: content},
	}}
}

// sendEncrypted sends words to an encrypted chat (files are not sent there yet). The id answered is the helper's
// own for the message, made from the person's id and an id chosen here.
func sendEncrypted(ctx context.Context, c *conn, b *book, t thread, text string, q *quote) (any, error) {
	if strings.TrimSpace(text) == "" {
		return nil, errors.New("Files can't be sent in end-to-end encrypted Messenger chats from here yet")
	}
	e2, err := c.sealedReady(ctx)
	if err != nil {
		return nil, err
	}
	msg := consumerContent(&waConsumerApplication.ConsumerApplication_Content{
		Content: &waConsumerApplication.ConsumerApplication_Content_MessageText{MessageText: &waCommon.MessageText{Text: proto.String(text)}},
	})
	meta := &waMsgApplication.MessageApplication_Metadata{}
	if q != nil && q.ID != "" {
		if sender, stanza, ok := parseSealedID(q.ID); ok {
			meta.QuotedMessage = &waMsgApplication.MessageApplication_Metadata_QuotedMessage{
				StanzaID: proto.String(stanza), Participant: proto.String(userJID(sender).String()),
			}
		}
	}
	stanza := strconv.FormatInt(methods.GenerateEpochID(), 10)
	resp, err := e2.SendFBMessage(ctx, chatJID(t), msg, meta, whatsmeow.SendRequestExtra{ID: stanza})
	if err != nil {
		log.Err(err).Msg("send to an encrypted chat")
		return nil, fmt.Errorf("Messenger did not take the message: %w", err)
	}
	ts := resp.Timestamp.UnixMilli()
	if resp.Timestamp.IsZero() {
		ts = time.Now().UnixMilli()
	}
	id := sealedID(idString(b.me), stanza)
	b.mu.Lock()
	b.remember(t.Key, id, ts, b.me)
	b.mu.Unlock()
	return map[string]any{"id": id, "ts": ts}, nil
}

// reactEncrypted puts the person's reaction on a message of an encrypted chat; an empty [emoji] takes it off.
func reactEncrypted(ctx context.Context, c *conn, b *book, t thread, target, emoji string) error {
	key, err := keyFor(b.me, chatJID(t), target)
	if err != nil {
		return err
	}
	e2, err := c.sealedReady(ctx)
	if err != nil {
		return err
	}
	msg := consumerContent(&waConsumerApplication.ConsumerApplication_Content{
		Content: &waConsumerApplication.ConsumerApplication_Content_ReactionMessage{ReactionMessage: &waConsumerApplication.ConsumerApplication_ReactionMessage{
			Key: key, Text: proto.String(emoji), SenderTimestampMS: proto.Int64(time.Now().UnixMilli()),
		}},
	})
	if _, err = e2.SendFBMessage(ctx, chatJID(t), msg, nil); err != nil {
		return fmt.Errorf("Messenger did not take the reaction: %w", err)
	}
	return nil
}

// unsendEncrypted takes back the person's own message in an encrypted chat, for everyone.
func unsendEncrypted(ctx context.Context, c *conn, b *book, t thread, target string) error {
	if sender, _, ok := parseSealedID(target); ok && sender != idString(b.me) {
		return errors.New("Only your own messages can be unsent")
	}
	key, err := keyFor(b.me, chatJID(t), target)
	if err != nil {
		return err
	}
	e2, err := c.sealedReady(ctx)
	if err != nil {
		return err
	}
	msg := &waConsumerApplication.ConsumerApplication{Payload: &waConsumerApplication.ConsumerApplication_Payload{
		Payload: &waConsumerApplication.ConsumerApplication_Payload_ApplicationData{ApplicationData: &waConsumerApplication.ConsumerApplication_ApplicationData{
			ApplicationContent: &waConsumerApplication.ConsumerApplication_ApplicationData_Revoke{Revoke: &waConsumerApplication.ConsumerApplication_RevokeMessage{Key: key}},
		}},
	}}
	stanza := strconv.FormatInt(methods.GenerateEpochID(), 10)
	if _, err = e2.SendFBMessage(ctx, chatJID(t), msg, &waMsgApplication.MessageApplication_Metadata{}, whatsmeow.SendRequestExtra{ID: stanza}); err != nil {
		return fmt.Errorf("Messenger did not unsend the message: %w", err)
	}
	return nil
}

// readEncrypted marks an encrypted chat read up to a message: to its sender's devices, and on Messenger's own list
// where the chat has a row there under another number.
func readEncrypted(ctx context.Context, c *conn, b *book, t thread, upto string) error {
	// Messenger's own list first, whatever is known of the chat's messages: the list is what says a chat is unread
	// when the app next starts, and it was told only where the chat had a row there under another number, and only
	// once a message of the chat's had been found. Every other encrypted chat came back unread at each start (Matt,
	// 2026-11-25: "all of my facebook messages are coming through as unread I suspect \"mark as read\" is only
	// marking them as read locally and restarting the app is clearing that out").
	now := time.Now()
	row := t.Key
	if t.FBKey != 0 {
		row = t.FBKey
	}
	group := t.SyncGroup
	if group == 0 {
		group = 95
	}
	if _, err := tasks(ctx, c, &socket.ThreadMarkReadTask{ThreadId: row, LastReadWatermarkTs: now.UnixMilli(), SyncGroup: group}); err != nil {
		log.Err(err).Msg("mark the chat read on Messenger's list")
	} else {
		b.mu.Lock()
		if live := b.threads[t.Key]; live != nil {
			live.Unread, live.Read = 0, now.UnixMilli()
		}
		b.mu.Unlock()
	}
	if upto == "" {
		// The newest message of someone else's that is known.
		b.mu.Lock()
		list := b.stamps[t.Key]
		for i := len(list) - 1; i >= 0 && upto == ""; i-- {
			if list[i].From != b.me && isEncryptedID(list[i].ID) {
				upto = list[i].ID
			}
		}
		b.mu.Unlock()
		if upto == "" {
			return nil
		}
	}
	sender, stanza, ok := parseSealedID(upto)
	if !ok {
		// A message from before the chat was encrypted: the list has been told, and there is no one's device to tell.
		return nil
	}
	if sender == idString(b.me) {
		return nil
	}
	e2, err := c.sealedReady(ctx)
	if err != nil {
		return err
	}
	// Between two people the mark names no one; in a group it names whose message was read.
	var author waTypes.JID
	if t.Type == table.ENCRYPTED_OVER_WA_GROUP {
		author = userJID(sender)
	}
	if err = e2.MarkRead(ctx, []waTypes.MessageID{stanza}, now, chatJID(t), author); err != nil {
		return fmt.Errorf("Messenger did not take the read mark: %w", err)
	}
	return nil
}

// unb64 reads a pointer's bytes back; nil where they are not base64.
func unb64(s string) []byte {
	b, _ := base64.StdEncoding.DecodeString(s)
	return b
}

// downloadSealed fetches a file of an encrypted chat, opens it with the keys its pointer carries, and writes it to
// [dest] whole or not at all.
func downloadSealed(ctx context.Context, c *conn, s *sealed, dest string) error {
	e2, err := c.sealedReady(ctx)
	if err != nil {
		return err
	}
	data, err := e2.DownloadMediaWithPath(ctx, s.Path, unb64(s.Enc), unb64(s.Hash), unb64(s.Key), whatsmeow.MediaType(s.Kind), "", false)
	if err != nil {
		log.Err(err).Msg("fetch a file of an encrypted chat")
		return errors.New("The file could not be fetched or opened; it may be gone from Messenger's servers")
	}
	if err := os.WriteFile(dest+".part", data, 0o600); err != nil {
		return fmt.Errorf("The file could not be written: %w", err)
	}
	return os.Rename(dest+".part", dest)
}
