package main

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"go.mau.fi/util/dbutil"

	"maunium.net/go/mautrix"
	"maunium.net/go/mautrix/crypto/attachment"
	"maunium.net/go/mautrix/crypto/backup"
	"maunium.net/go/mautrix/crypto/cryptohelper"
	"maunium.net/go/mautrix/event"
	"maunium.net/go/mautrix/id"
)

// The helper's working parts: the session and its store, signing in, the sync that feeds the app's events, the rooms
// as the app has them, and each request's doing. main.go holds the protocol; shape.go the shapes that need no network.

// session is what signing in leaves: kept in session.json, readable by the person alone.
type session struct {
	Homeserver  string      `json:"homeserver"`
	UserID      id.UserID   `json:"user_id"`
	DeviceID    id.DeviceID `json:"device_id"`
	AccessToken string      `json:"access_token"`
	// PickleKey encrypts the account's keys in the store.
	PickleKey []byte `json:"pickle_key"`
	// Verified is set once the person's recovery key has signed this device.
	Verified bool `json:"verified"`
}

// roomInfo is what the helper keeps of a room between syncs (rooms.json): what a sync tells once and never again.
type roomInfo struct {
	ID        id.RoomID   `json:"id"`
	Name      string      `json:"name,omitempty"`
	Alias     string      `json:"alias,omitempty"`
	AvatarMXC string      `json:"avatar_mxc,omitempty"`
	Heroes    []id.UserID `json:"heroes,omitempty"`
	Joined    int         `json:"joined,omitempty"`
	Invite    bool        `json:"invite,omitempty"`
	Inviter   id.UserID   `json:"inviter,omitempty"`
	// InviteDirect is the inviter's word that an invite is to a direct chat (is_direct on the member event).
	InviteDirect bool           `json:"invite_direct,omitempty"`
	Encrypted    bool           `json:"encrypted,omitempty"`
	Unread       int            `json:"unread"`
	Last         map[string]any `json:"last,omitempty"`
	LastTS       int64          `json:"last_ts,omitempty"`
}

// mu guards everything in this block, the resuming pair and changed. sess, cli, helper and db are set together by
// start and cleared together by stop: all nil when signed out. firstSync is true from a start until its first sync is
// through: that one says "synced", not a "room" each.
var (
	mu       sync.Mutex
	sess     *session
	cli      *mautrix.Client
	helper   *cryptohelper.CryptoHelper
	db       *dbutil.Database
	stopSync context.CancelFunc
	rooms    = map[id.RoomID]*roomInfo{}
	// direct is m.direct turned round: each direct room and the person it is with.
	direct = map[id.RoomID]id.UserID{}
	// pendingBase is the homeserver an SSO sign-in was begun on, for login_token.
	pendingBase string
	firstSync   bool
)

// bg is a context that carries the helper's log, so mautrix writes to it.
func bg() context.Context { return log.WithContext(context.Background()) }

// Where each thing is kept under --dir.
func sessionPath() string { return filepath.Join(dir, "session.json") }
func dbPath() string      { return filepath.Join(dir, "matrix.db") }
func roomsPath() string   { return filepath.Join(dir, "rooms.json") }
func avatarDir() string   { return filepath.Join(dir, "avatars") }

// readSession reads the kept session: nil with no error for a file that lacks a token, user or device.
func readSession() (*session, error) {
	b, err := os.ReadFile(sessionPath())
	if err != nil {
		return nil, err
	}
	var s session
	if err := json.Unmarshal(b, &s); err != nil {
		return nil, err
	}
	if s.AccessToken == "" || s.UserID == "" || s.DeviceID == "" {
		return nil, nil
	}
	return &s, nil
}

// writeSession keeps [s], written beside the file and renamed into place so a crash never leaves half of it.
func writeSession(s *session) error {
	b, err := json.Marshal(s)
	if err != nil {
		return err
	}
	tmp := sessionPath() + ".tmp"
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, sessionPath())
}

// loggedIn is whether a client is started, with its encryption.
func loggedIn() bool {
	mu.Lock()
	defer mu.Unlock()
	return cli != nil && helper != nil
}

// openDB opens the store (end-to-end keys, the state of each room, the sync position) in SQLite: pure Go on the
// computers (db_purego.go), mautrix's own driver on the phone (db_cgo.go).
func openDB() (*dbutil.Database, error) {
	// Made here first, so the file is the person's alone to read before SQLite writes any key into it.
	if f, err := os.OpenFile(dbPath(), os.O_CREATE|os.O_RDWR, 0o600); err == nil {
		_ = f.Close()
	}
	raw, err := dbutil.NewWithDialect(sqliteURI(dbPath()), sqliteDriver)
	if err != nil {
		return nil, err
	}
	raw.Log = dbutil.ZeroLogger(log.With().Str("db_section", "main").Logger())
	return raw, nil
}

// resuming is a kept session waiting for the network to start; resumingUser whose it is.
var (
	resuming     bool
	resumingUser id.UserID
)

func isResuming() bool {
	mu.Lock()
	defer mu.Unlock()
	return resuming
}

// resumeOrRetry starts the session kept from before. Starting asks the server about this device's keys, so with no
// network it fails: it is tried again every half minute until it starts, the server says the device is signed out, or
// the person signs in afresh.
func resumeOrRetry(s *session) {
	err := resume(s)
	if err == nil {
		return
	}
	if errors.Is(err, mautrix.MUnknownToken) {
		forget()
		emit("logged_out", map[string]any{"error": "Your Matrix server signed this device out. Sign in again to carry on."})
		return
	}
	log.Err(err).Msg("resume; trying again in 30 s")
	mu.Lock()
	resuming, resumingUser = true, s.UserID
	mu.Unlock()
	go func() {
		for {
			time.Sleep(30 * time.Second)
			mu.Lock()
			still := resuming && cli == nil
			mu.Unlock()
			if !still {
				return
			}
			err := resume(s)
			if err == nil {
				mu.Lock()
				resuming = false
				mu.Unlock()
				return
			}
			if errors.Is(err, mautrix.MUnknownToken) {
				forget()
				emit("logged_out", map[string]any{"error": "Your Matrix server signed this device out. Sign in again to carry on."})
				return
			}
		}
	}()
}

// resume starts the client [s] left, with its keys.
func resume(s *session) error {
	c, err := mautrix.NewClient(s.Homeserver, s.UserID, s.AccessToken)
	if err != nil {
		return err
	}
	c.DeviceID = s.DeviceID
	return start(c, s)
}

// start sets up end-to-end encryption on [c], hooks its sync to the app's events and begins syncing.
func start(c *mautrix.Client, s *session) error {
	c.Log = log.With().Str("component", "mautrix").Logger()
	c.DefaultHTTPRetries = 2
	raw, err := openDB()
	if err != nil {
		return err
	}
	syncer := &appSyncer{DefaultSyncer: mautrix.NewDefaultSyncer()}
	// Twenty messages a room on the first sync: enough for each chat's last words without bringing down everything.
	syncer.FilterJSON = &mautrix.Filter{Room: &mautrix.RoomFilter{Timeline: &mautrix.FilterPart{Limit: 20}}}
	c.Syncer = syncer
	h, err := cryptohelper.NewCryptoHelper(c, s.PickleKey, raw)
	if err != nil {
		_ = raw.Close()
		return err
	}
	// A new message this device has no key for still reaches the app, marked undecryptable.
	h.DecryptErrorCallback = func(evt *event.Event, err error) {
		if evt.Mautrix.EventSource&event.SourceTimeline == 0 {
			return
		}
		m := undecryptable(evt, c.UserID, memberName(evt.RoomID, evt.Sender))
		noteLast(evt.RoomID, m)
		emit("message", m)
	}
	if err := h.Init(bg()); err != nil {
		_ = raw.Close()
		return err
	}
	c.Crypto = h
	syncer.OnSync(onSync)
	syncer.OnEventType(event.EventMessage, onMessage)
	syncer.OnEventType(event.EventSticker, onMessage)
	syncer.OnEventType(event.EventReaction, onReaction)
	syncer.OnEventType(event.EventRedaction, onRedaction)
	syncer.OnEventType(event.EphemeralEventReceipt, onReceipt)
	syncer.OnEventType(event.AccountDataDirectChats, onDirect)
	loadRooms()

	mu.Lock()
	cli, helper, db, sess = c, h, raw, s
	firstSync = true
	ctx, cancel := context.WithCancel(bg())
	stopSync = cancel
	mu.Unlock()
	// The homeserver's versions, so media goes by the authenticated routes where it has them.
	go func() { _, _ = c.Versions(ctx) }()
	go syncLoop(ctx, c)
	return nil
}

// syncLoop syncs until [ctx] ends, starting again ten seconds after a failure; a token the server no longer knows
// signs the device out instead.
func syncLoop(ctx context.Context, c *mautrix.Client) {
	for {
		err := c.SyncWithContext(ctx)
		if ctx.Err() != nil {
			return
		}
		if errors.Is(err, mautrix.MUnknownToken) {
			go loggedOut(c, "Your Matrix server signed this device out. Sign in again to carry on.")
			return
		}
		log.Err(err).Msg("sync")
		select {
		case <-time.After(10 * time.Second):
		case <-ctx.Done():
			return
		}
	}
}

// stop ends syncing and closes the store. Called with mu held.
func stop() {
	if stopSync != nil {
		stopSync()
		stopSync = nil
	}
	if cli != nil {
		cli.StopSync()
	}
	if helper != nil {
		_ = helper.Close()
	}
	cli, helper, db, sess = nil, nil, nil, nil
}

// shutdown keeps the rooms and stops, leaving the session and store for the next run.
func shutdown() {
	saveRooms()
	mu.Lock()
	stop()
	mu.Unlock()
}

// forget stops everything and wipes the store, the session and the rooms kept.
func forget() {
	mu.Lock()
	stop()
	resuming = false
	rooms = map[id.RoomID]*roomInfo{}
	direct = map[id.RoomID]id.UserID{}
	mu.Unlock()
	for _, suffix := range []string{"", "-wal", "-shm"} {
		_ = os.Remove(dbPath() + suffix)
	}
	_ = os.Remove(sessionPath())
	_ = os.Remove(roomsPath())
	_ = os.RemoveAll(avatarDir())
}

// loggedOut forgets everything and tells the app [why], unless [c] is no longer the client in use (the person has
// signed in again since).
func loggedOut(c *mautrix.Client, why string) {
	mu.Lock()
	same := cli == c
	mu.Unlock()
	if !same {
		return
	}
	forget()
	emit("logged_out", map[string]any{"error": why})
}

var errNotSignedIn = errors.New("not signed in to Matrix")

// client is the started client and its encryption, or errNotSignedIn. Takes mu itself: never call it with mu held.
func client() (*mautrix.Client, *cryptohelper.CryptoHelper, error) {
	mu.Lock()
	defer mu.Unlock()
	if cli == nil || helper == nil {
		return nil, nil, errNotSignedIn
	}
	return cli, helper, nil
}

// --- signing in -----------------------------------------------------------------------------------------------------

// resolve finds the client API's address for what the person typed: .well-known first, else the server itself.
func resolve(ctx context.Context, in string) (base string, parsed homeserverInput, err error) {
	parsed, err = parseHomeserver(in)
	if err != nil {
		return "", parsed, err
	}
	if parsed.Base != "" {
		return parsed.Base, parsed, nil
	}
	wk, wkErr := mautrix.DiscoverClientAPI(ctx, parsed.Server)
	if wkErr == nil && wk != nil && wk.Homeserver.BaseURL != "" {
		return strings.TrimRight(wk.Homeserver.BaseURL, "/"), parsed, nil
	}
	return "https://" + parsed.Server, parsed, nil
}

// loginWith signs in at [base] with [req] as a new device named "Uplink", keeps the session with a fresh
// key for its store, starts syncing and answers the status.
func loginWith(ctx context.Context, base string, req *mautrix.ReqLogin) (map[string]any, error) {
	if loggedIn() {
		return nil, errors.New("already signed in to Matrix: sign out first")
	}
	// A fresh store for a fresh device: keys left from another account would not match it.
	forget()
	c, err := mautrix.NewClient(base, "", "")
	if err != nil {
		return nil, err
	}
	c.Log = log.With().Str("component", "mautrix").Logger()
	req.InitialDeviceDisplayName = "Uplink"
	req.StoreCredentials = true
	req.StoreHomeserverURL = true
	if _, err := c.Login(ctx, req); err != nil {
		return nil, loginWhy(err)
	}
	key := make([]byte, 32)
	_, _ = rand.Read(key)
	s := &session{Homeserver: c.HomeserverURL.String(), UserID: c.UserID, DeviceID: c.DeviceID, AccessToken: c.AccessToken, PickleKey: key}
	if err := writeSession(s); err != nil {
		return nil, err
	}
	if err := start(c, s); err != nil {
		forget()
		return nil, err
	}
	return status(ctx), nil
}

// loginWhy is a failed sign-in in the person's words.
func loginWhy(err error) error {
	var re mautrix.HTTPError
	if errors.As(err, &re) && re.RespError != nil {
		switch re.RespError.ErrCode {
		case "M_FORBIDDEN":
			return errors.New("that user name and password didn't work")
		case "M_UNRECOGNIZED", "M_UNKNOWN":
			return errors.New("this server doesn't take passwords here: sign in with your browser instead")
		case "M_USER_DEACTIVATED":
			return errors.New("that account has been deactivated")
		case "M_LIMIT_EXCEEDED":
			return errors.New("too many tries: wait a minute and try again")
		}
		if re.RespError.Err != "" {
			return errors.New(re.RespError.Err)
		}
	}
	return err
}

// loginPassword signs in with a user name and password. The server may be left out when the user is a whole
// "@name:server" id, and the user when the homeserver field holds one.
func loginPassword(ctx context.Context, r request) (map[string]any, error) {
	field := r.Homeserver
	if field == "" && strings.HasPrefix(r.User, "@") {
		field = r.User
	}
	base, parsed, err := resolve(ctx, field)
	if err != nil {
		return nil, err
	}
	user := r.User
	if user == "" {
		user = parsed.User
	}
	if user == "" || r.Password == "" {
		return nil, errors.New("a user name and password are needed")
	}
	return loginWith(ctx, base, &mautrix.ReqLogin{
		Type:       mautrix.AuthTypePassword,
		Identifier: mautrix.UserIdentifier{Type: mautrix.IdentifierTypeUser, User: loginIdentifier(user)},
		Password:   r.Password,
	})
}

// beginSSO answers the address to open in a browser for the server's own sign-in page, which comes back to
// [r.Redirect] with a token for login_token. Refused where the server offers no browser sign-in.
func beginSSO(ctx context.Context, r request) (map[string]any, error) {
	if r.Redirect == "" {
		return nil, errors.New("no redirect address")
	}
	base, _, err := resolve(ctx, r.Homeserver)
	if err != nil {
		return nil, err
	}
	c, err := mautrix.NewClient(base, "", "")
	if err != nil {
		return nil, err
	}
	flows, err := c.GetLoginFlows(ctx)
	if err != nil {
		return nil, fmt.Errorf("couldn't reach %s: %w", base, err)
	}
	if !flows.HasFlow(mautrix.AuthTypeSSO, mautrix.AuthTypeToken) {
		return nil, errors.New("this server doesn't offer signing in with a browser: use your password")
	}
	mu.Lock()
	pendingBase = base
	mu.Unlock()
	return map[string]any{"url": ssoURL(base, r.Redirect), "homeserver": base, "password": flows.HasFlow(mautrix.AuthTypePassword)}, nil
}

// loginToken finishes a browser sign-in with the token it came back with, on the server beginSSO was asked about
// unless the request names one.
func loginToken(ctx context.Context, r request) (map[string]any, error) {
	mu.Lock()
	base := pendingBase
	mu.Unlock()
	if r.Homeserver != "" {
		b, _, err := resolve(ctx, r.Homeserver)
		if err != nil {
			return nil, err
		}
		base = b
	}
	if base == "" || r.Token == "" {
		return nil, errors.New("no sign-in to finish: start again")
	}
	return loginWith(ctx, base, &mautrix.ReqLogin{Type: mautrix.AuthTypeToken, Token: r.Token})
}

// status is who is signed in and whether the device is verified; signed out, whether a kept session is still
// waiting for the network. The display name is asked of the server each time.
func status(ctx context.Context) map[string]any {
	mu.Lock()
	c, s := cli, sess
	mu.Unlock()
	if c == nil || s == nil {
		mu.Lock()
		defer mu.Unlock()
		if resuming {
			return map[string]any{"logged_in": false, "resuming": true, "user_id": string(resumingUser)}
		}
		return map[string]any{"logged_in": false, "resuming": false}
	}
	name := ""
	if resp, err := c.GetOwnDisplayName(ctx); err == nil && resp != nil {
		name = resp.DisplayName
	}
	return map[string]any{
		"logged_in": true, "user_id": string(s.UserID), "device_id": string(s.DeviceID),
		"homeserver": s.Homeserver, "name": name, "verified": s.Verified,
	}
}

// verifyRecoveryKey unlocks secret storage with the person's recovery key (Element's Security Key): the account's
// cross-signing keys sign this device, so their other devices trust it, and the key backup comes down, so messages
// from before this device decrypt.
func verifyRecoveryKey(ctx context.Context, key string) (map[string]any, error) {
	c, h, err := client()
	if err != nil {
		return nil, err
	}
	mach := h.Machine()
	keyID, keyData, err := mach.SSSS.GetDefaultKeyData(ctx)
	if err != nil {
		return nil, fmt.Errorf("this account has no secret storage to unlock: set up recovery in Element first (%w)", err)
	}
	ssssKey, err := keyData.VerifyRecoveryKey(keyID, strings.TrimSpace(key))
	if err != nil && ssssKey == nil {
		return nil, errors.New("that recovery key isn't this account's")
	}
	if err := mach.FetchCrossSigningKeysFromSSSS(ctx, ssssKey); err != nil {
		return nil, fmt.Errorf("couldn't read the cross-signing keys: %w", err)
	}
	if err := mach.SignOwnDevice(ctx, mach.OwnIdentity()); err != nil {
		return nil, fmt.Errorf("couldn't sign this device: %w", err)
	}
	if err := mach.SignOwnMasterKey(ctx); err != nil {
		log.Warn().Err(err).Msg("sign own master key")
	}
	mu.Lock()
	if sess != nil && cli == c {
		sess.Verified = true
		_ = writeSession(sess)
	}
	mu.Unlock()
	// The device is verified from here on. The key backup is a second, separate gain: failing to fetch it is told
	// in "backup_error", not as a failed request.
	result := map[string]any{"verified": true, "backup_version": nil}
	raw, err := mach.SSSS.GetDecryptedAccountData(ctx, event.AccountDataMegolmBackupKey, ssssKey)
	if err != nil {
		result["backup_error"] = "no key backup in secret storage"
		return result, nil
	}
	bk, err := backup.MegolmBackupKeyFromBytes(raw)
	if err != nil {
		result["backup_error"] = err.Error()
		return result, nil
	}
	version, err := mach.DownloadAndStoreLatestKeyBackup(ctx, bk)
	if err != nil {
		result["backup_error"] = err.Error()
		return result, nil
	}
	result["backup_version"] = string(version)
	return result, nil
}

// --- sync -----------------------------------------------------------------------------------------------------------

// appSyncer is mautrix's syncer, telling the app which rooms changed once each sync is through.
type appSyncer struct {
	*mautrix.DefaultSyncer
}

// changed is the rooms touched since the last sync was through. Guarded by mu.
var changed = map[id.RoomID]bool{}

// ProcessResponse runs mautrix's handling of a sync (which fills changed through the handlers below), keeps the rooms,
// then says "synced" after the first sync of a start and a "room" for each changed room after every later one.
func (s *appSyncer) ProcessResponse(ctx context.Context, res *mautrix.RespSync, since string) error {
	err := s.DefaultSyncer.ProcessResponse(ctx, res, since)
	mu.Lock()
	first := firstSync
	firstSync = false
	ids := make([]id.RoomID, 0, len(changed))
	for r := range changed {
		ids = append(ids, r)
	}
	changed = map[id.RoomID]bool{}
	mu.Unlock()
	saveRooms()
	if first {
		emit("synced", map[string]any{"initial": since == ""})
		go fetchAvatars()
	} else {
		for _, r := range ids {
			if room := roomJSON(r); room != nil {
				emit("room", room)
			}
		}
	}
	return err
}

// stateOf reads a room's name, alias, picture and encryption out of [evts] into [info], and returns who invited the
// person and whether as a direct chat, where an invite to them is among the events. Called with mu held.
func stateOf(evts []*event.Event, info *roomInfo) (inviter id.UserID, inviteDirect bool) {
	me := ownIDLocked()
	for _, evt := range evts {
		if evt.StateKey == nil {
			continue
		}
		_ = evt.Content.ParseRaw(evt.Type)
		switch evt.Type.Type {
		case event.StateRoomName.Type:
			if c := evt.Content.AsRoomName(); c != nil {
				info.Name = c.Name
			}
		case event.StateCanonicalAlias.Type:
			if c := evt.Content.AsCanonicalAlias(); c != nil {
				info.Alias = string(c.Alias)
			}
		case event.StateRoomAvatar.Type:
			if c := evt.Content.AsRoomAvatar(); c != nil {
				info.AvatarMXC = string(c.URL)
			}
		case event.StateEncryption.Type:
			info.Encrypted = true
		case event.StateMember.Type:
			if c := evt.Content.AsMember(); c != nil && id.UserID(*evt.StateKey) == me && c.Membership == event.MembershipInvite {
				inviter, inviteDirect = evt.Sender, c.IsDirect
			}
		}
	}
	return
}

// onSync keeps what each sync says of the rooms: their names, pictures, people, unread counts, and invites.
func onSync(ctx context.Context, res *mautrix.RespSync, since string) bool {
	mu.Lock()
	defer mu.Unlock()
	for rid, j := range res.Rooms.Join {
		info := rooms[rid]
		if info == nil {
			info = &roomInfo{ID: rid}
			rooms[rid] = info
		}
		info.Invite = false
		if len(j.Summary.Heroes) > 0 {
			info.Heroes = j.Summary.Heroes
		}
		if j.Summary.JoinedMemberCount != nil {
			info.Joined = *j.Summary.JoinedMemberCount
		}
		if j.UnreadNotifications != nil {
			info.Unread = j.UnreadNotifications.NotificationCount
		}
		stateOf(j.State.Events, info)
		if j.StateAfter != nil {
			stateOf(j.StateAfter.Events, info)
		}
		stateOf(j.Timeline.Events, info)
		changed[rid] = true
	}
	for rid, inv := range res.Rooms.Invite {
		info := rooms[rid]
		if info == nil {
			info = &roomInfo{ID: rid}
			rooms[rid] = info
		}
		info.Invite = true
		inviter, isDirect := stateOf(inv.State.Events, info)
		info.Inviter, info.InviteDirect = inviter, isDirect
		if info.LastTS == 0 {
			info.LastTS = time.Now().UnixMilli()
		}
		changed[rid] = true
	}
	for rid := range res.Rooms.Leave {
		if _, ok := rooms[rid]; ok {
			delete(rooms, rid)
			delete(changed, rid)
			go emit("room_gone", map[string]any{"room": string(rid)})
		}
	}
	return true
}

// ownID is the signed-in person's id, empty when signed out. Not called with mu held: the event handlers and the ops
// ask it while stop may be clearing sess.
func ownID() id.UserID {
	mu.Lock()
	defer mu.Unlock()
	return ownIDLocked()
}

// ownIDLocked is ownID for a caller that holds mu.
func ownIDLocked() id.UserID {
	if sess != nil {
		return sess.UserID
	}
	return ""
}

// memberName is someone's display name in a room, as the state store has it.
func memberName(room id.RoomID, user id.UserID) string {
	mu.Lock()
	c := cli
	mu.Unlock()
	if c == nil || c.StateStore == nil {
		return ""
	}
	m, err := c.StateStore.TryGetMember(bg(), room, user)
	if err != nil || m == nil {
		return ""
	}
	return m.Displayname
}

// noteLast keeps [m] as the room's last message when it is newer than the one kept.
func noteLast(room id.RoomID, m map[string]any) {
	ts, _ := m["ts"].(int64)
	mu.Lock()
	defer mu.Unlock()
	info := rooms[room]
	if info == nil {
		info = &roomInfo{ID: room}
		rooms[room] = info
	}
	if ts >= info.LastTS {
		info.LastTS = ts
		info.Last = map[string]any{"id": m["id"], "from": m["from"], "text": m["text"], "ts": ts, "mine": m["mine"], "media": len(m["media"].([]any)) > 0, "undecryptable": m["undecryptable"] == true}
	}
	changed[room] = true
}

// onMessage tells the app of a message or sticker new in a room's timeline (state and other sources are passed
// over). An edit is told too, but does not become the room's last message.
func onMessage(ctx context.Context, evt *event.Event) {
	if evt.Mautrix.EventSource&event.SourceTimeline == 0 {
		return
	}
	m := messageOf(evt, ownID(), memberName(evt.RoomID, evt.Sender))
	if m == nil {
		return
	}
	if m["replaces"] == nil {
		noteLast(evt.RoomID, m)
	}
	emit("message", m)
}

// onReaction tells the app of a reaction new in a room's timeline.
func onReaction(ctx context.Context, evt *event.Event) {
	if evt.Mautrix.EventSource&event.SourceTimeline == 0 {
		return
	}
	if r := reactionOf(evt); r != nil {
		emit("reaction", r)
	}
}

// onRedaction tells the app which event (a message, or a reaction taken back) was removed, and by whom.
func onRedaction(ctx context.Context, evt *event.Event) {
	if evt.Mautrix.EventSource&event.SourceTimeline == 0 {
		return
	}
	if target := redactedOf(evt); target != "" {
		emit("redacted", map[string]any{"room": string(evt.RoomID), "target": string(target), "from": string(evt.Sender)})
	}
}

// onReceipt tells the app of read receipts others send (each event someone has read up to).
func onReceipt(ctx context.Context, evt *event.Event) {
	c := evt.Content.AsReceipt()
	if c == nil {
		return
	}
	me := ownID()
	for eventID, receipts := range *c {
		for kind, users := range receipts {
			if kind != event.ReceiptTypeRead {
				continue
			}
			for user := range users {
				if user == me {
					continue
				}
				emit("receipt", map[string]any{"room": string(evt.RoomID), "id": string(eventID), "from": string(user)})
			}
		}
	}
}

// onDirect takes the account's m.direct (person → rooms) whole, replacing what was kept, and marks each room in it
// changed.
func onDirect(ctx context.Context, evt *event.Event) {
	c := evt.Content.AsDirectChats()
	if c == nil {
		return
	}
	mu.Lock()
	direct = map[id.RoomID]id.UserID{}
	for user, list := range *c {
		for _, r := range list {
			direct[r] = user
			changed[r] = true
		}
	}
	mu.Unlock()
}

// --- rooms, as the app has them -------------------------------------------------------------------------------------

// loadRooms reads rooms.json into rooms and direct: a restart syncs from where it left off, so what the first sync
// said of each room would otherwise be lost.
func loadRooms() {
	b, err := os.ReadFile(roomsPath())
	if err != nil {
		return
	}
	var kept struct {
		Rooms  []*roomInfo             `json:"rooms"`
		Direct map[id.RoomID]id.UserID `json:"direct"`
	}
	if json.Unmarshal(b, &kept) != nil {
		return
	}
	mu.Lock()
	defer mu.Unlock()
	for _, r := range kept.Rooms {
		rooms[r.ID] = r
	}
	if kept.Direct != nil {
		direct = kept.Direct
	}
}

// saveRooms writes rooms and direct to rooms.json. Takes mu itself.
func saveRooms() {
	mu.Lock()
	list := make([]*roomInfo, 0, len(rooms))
	for _, r := range rooms {
		list = append(list, r)
	}
	b, err := json.Marshal(map[string]any{"rooms": list, "direct": direct})
	mu.Unlock()
	if err != nil {
		return
	}
	tmp := roomsPath() + ".tmp"
	if os.WriteFile(tmp, b, 0o600) == nil {
		_ = os.Rename(tmp, roomsPath())
	}
}

// others is everyone in [room] but the person: those joined or invited, else the heroes the server named.
func others(c *mautrix.Client, info *roomInfo, me id.UserID) []id.UserID {
	var list []id.UserID
	if c != nil && c.StateStore != nil && !info.Invite {
		members, _ := c.StateStore.GetRoomJoinedOrInvitedMembers(bg(), info.ID)
		for _, m := range members {
			if m != me {
				list = append(list, m)
			}
		}
	}
	if len(list) == 0 {
		for _, h := range info.Heroes {
			if h != me {
				list = append(list, h)
			}
		}
	}
	if len(list) == 0 && info.Invite && info.Inviter != "" {
		list = append(list, info.Inviter)
	}
	sort.Slice(list, func(i, j int) bool { return list[i] < list[j] })
	return list
}

// roomJSON is a room as the "rooms" op and "room" event give it; nil for one not known.
func roomJSON(rid id.RoomID) map[string]any {
	mu.Lock()
	c := cli
	me := ownIDLocked()
	info := rooms[rid]
	var cp roomInfo
	if info != nil {
		cp = *info
	}
	with, isDirect := direct[rid]
	mu.Unlock()
	if info == nil {
		return nil
	}
	// An invite is not in m.direct yet: the inviter's word stands in for it.
	if !isDirect && cp.Invite && cp.InviteDirect {
		with, isDirect = cp.Inviter, true
	}
	people := others(c, &cp, me)
	names := map[id.UserID]string{}
	for _, u := range people {
		names[u] = memberName(rid, u)
	}
	if isDirect && with != "" {
		if _, ok := names[with]; !ok {
			names[with] = memberName(rid, with)
		}
	}
	titlePeople := people
	if isDirect && with != "" {
		titlePeople = []id.UserID{with}
	}
	// A direct chat is one with one other person, by m.direct, or a room of two with no name.
	if !isDirect && cp.Name == "" && cp.Alias == "" && len(people) == 1 && cp.Joined <= 2 {
		isDirect, with = true, people[0]
	}
	// A direct chat with no picture of its own wears the other person's.
	avatarMXC := cp.AvatarMXC
	if avatarMXC == "" && isDirect && with != "" && c != nil && c.StateStore != nil {
		if m, err := c.StateStore.TryGetMember(bg(), rid, with); err == nil && m != nil {
			avatarMXC = string(m.AvatarURL)
		}
	}
	members := make([]string, 0, len(people))
	for _, u := range people {
		members = append(members, string(u))
	}
	out := map[string]any{
		"id":        string(rid),
		"title":     roomTitle(cp.Name, cp.Alias, titlePeople, names, isDirect),
		"avatar":    nil,
		"members":   members,
		"is_direct": isDirect,
		"with":      nullable(string(with)),
		"invite":    cp.Invite,
		"inviter":   nullable(string(cp.Inviter)),
		"encrypted": cp.Encrypted,
		"unread":    cp.Unread,
		"last":      cp.Last,
		"ts":        cp.LastTS,
	}
	if avatarMXC != "" {
		if p := keptAvatar(avatarMXC); p != "" {
			out["avatar"] = p
		}
		out["avatar_mxc"] = avatarMXC
	}
	return out
}

// nullable is [s], or JSON's null for an empty one.
func nullable(s string) any {
	if s == "" {
		return nil
	}
	return s
}

// roomList is every room known, the one with the newest message first.
func roomList() []map[string]any {
	mu.Lock()
	ids := make([]id.RoomID, 0, len(rooms))
	for r := range rooms {
		ids = append(ids, r)
	}
	mu.Unlock()
	list := make([]map[string]any, 0, len(ids))
	for _, r := range ids {
		if j := roomJSON(r); j != nil {
			list = append(list, j)
		}
	}
	sort.Slice(list, func(i, j int) bool { return list[i]["ts"].(int64) > list[j]["ts"].(int64) })
	return list
}

// avatarFile is where the picture at [mxc] is kept: named by a hash of its address, so a changed picture is a new
// file.
func avatarFile(mxc string) string {
	sum := sha256.Sum256([]byte(mxc))
	return filepath.Join(avatarDir(), hex.EncodeToString(sum[:12])+".img")
}

// keptAvatar is the path of the picture at [mxc] when it has been fetched, else empty.
func keptAvatar(mxc string) string {
	p := avatarFile(mxc)
	if _, err := os.Stat(p); err == nil {
		return p
	}
	return ""
}

// avatarsBusy lets one fetchAvatars run at a time: a second, asked for meanwhile, returns at once.
var avatarsBusy sync.Mutex

// fetchAvatars brings down a small picture of each room (or the other person, in a direct chat) not yet here, and
// tells the app of each room whose picture arrived.
func fetchAvatars() {
	if !avatarsBusy.TryLock() {
		return
	}
	defer avatarsBusy.Unlock()
	c, _, err := client()
	if err != nil {
		return
	}
	_ = os.MkdirAll(avatarDir(), 0o700)
	for _, room := range roomList() {
		mxc, _ := room["avatar_mxc"].(string)
		if mxc == "" || room["avatar"] != nil {
			continue
		}
		uri, err := id.ParseContentURI(mxc)
		if err != nil {
			continue
		}
		ctx, cancel := context.WithTimeout(bg(), 30*time.Second)
		resp, err := c.DownloadThumbnail(ctx, uri, 96, 96, mautrix.DownloadThumbnailExtra{Method: "crop"})
		if err == nil {
			data, rerr := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
			_ = resp.Body.Close()
			if rerr == nil && len(data) > 0 {
				p := avatarFile(mxc)
				if os.WriteFile(p+".tmp", data, 0o600) == nil && os.Rename(p+".tmp", p) == nil {
					if j := roomJSON(id.RoomID(room["id"].(string))); j != nil {
						emit("room", j)
					}
				}
			}
		}
		cancel()
	}
}

// --- requests -------------------------------------------------------------------------------------------------------

// do carries out one request and returns its result. A minute for most; nearly three for the ops that move files
// or bring down the key backup.
func do(r request) (any, error) {
	limit := 60 * time.Second
	if r.Op == "download" || r.Op == "send_media" || r.Op == "verify_recovery_key" {
		limit = 170 * time.Second
	}
	ctx, cancel := context.WithTimeout(bg(), limit)
	defer cancel()
	// Each request and how long it took, in the developer log; not status, which the app asks often.
	if r.Op != "status" {
		began := time.Now()
		log.Info().Str("op", r.Op).Int64("req", r.ID).Msg("asked")
		defer func() { log.Info().Str("op", r.Op).Int64("req", r.ID).Dur("took", time.Since(began)).Msg("answered") }()
	}
	switch r.Op {
	case "status":
		return status(ctx), nil
	case "login_password":
		return loginPassword(ctx, r)
	case "sso_url":
		return beginSSO(ctx, r)
	case "login_token":
		return loginToken(ctx, r)
	case "logout":
		if c, _, err := client(); err == nil {
			if _, err := c.Logout(ctx); err != nil {
				log.Warn().Err(err).Msg("logout")
			}
		}
		forget()
		return nil, nil
	case "verify_recovery_key":
		return verifyRecoveryKey(ctx, r.Key)
	case "rooms":
		if _, _, err := client(); err != nil {
			return nil, err
		}
		go fetchAvatars()
		return roomList(), nil
	case "messages":
		return messages(ctx, r)
	case "send":
		return send(ctx, r)
	case "send_media":
		return sendMedia(ctx, r)
	case "read":
		c, _, err := client()
		if err != nil {
			return nil, err
		}
		if r.Event != "" {
			if err := c.SetReadMarkers(ctx, id.RoomID(r.Room), &mautrix.ReqSetReadMarkers{Read: id.EventID(r.Event), FullyRead: id.EventID(r.Event)}); err != nil {
				return nil, err
			}
		}
		mu.Lock()
		if info := rooms[id.RoomID(r.Room)]; info != nil {
			info.Unread = 0
		}
		mu.Unlock()
		return nil, nil
	case "react":
		c, _, err := client()
		if err != nil {
			return nil, err
		}
		resp, err := c.SendReaction(ctx, id.RoomID(r.Room), id.EventID(r.Event), r.Emoji)
		if err != nil {
			return nil, err
		}
		return map[string]any{"id": string(resp.EventID)}, nil
	case "redact":
		c, _, err := client()
		if err != nil {
			return nil, err
		}
		_, err = c.RedactEvent(ctx, id.RoomID(r.Room), id.EventID(r.Event))
		return nil, err
	case "download":
		return nil, download(ctx, r)
	case "join":
		c, _, err := client()
		if err != nil {
			return nil, err
		}
		_, err = c.JoinRoomByID(ctx, id.RoomID(r.Room))
		if err == nil {
			// A direct chat accepted: kept in m.direct, as Element does, so it shows as one everywhere.
			mu.Lock()
			info := rooms[id.RoomID(r.Room)]
			var inviter id.UserID
			isDirect := false
			if info != nil {
				inviter, isDirect = info.Inviter, info.InviteDirect
				info.Invite = false
			}
			mu.Unlock()
			if isDirect && inviter != "" {
				go markDirect(c, id.RoomID(r.Room), inviter)
			}
		}
		return nil, err
	case "leave":
		c, _, err := client()
		if err != nil {
			return nil, err
		}
		_, err = c.LeaveRoom(ctx, id.RoomID(r.Room))
		if err == nil {
			mu.Lock()
			delete(rooms, id.RoomID(r.Room))
			mu.Unlock()
			saveRooms()
		}
		return nil, err
	}
	return nil, fmt.Errorf("unknown op %q", r.Op)
}

// markDirect adds [room] to the account's m.direct under [with], unless it is there already.
func markDirect(c *mautrix.Client, room id.RoomID, with id.UserID) {
	ctx, cancel := context.WithTimeout(bg(), 30*time.Second)
	defer cancel()
	var dc event.DirectChatsEventContent
	if err := c.GetAccountData(ctx, event.AccountDataDirectChats.Type, &dc); err != nil {
		dc = event.DirectChatsEventContent{}
	}
	for _, r := range dc[with] {
		if r == room {
			return
		}
	}
	dc[with] = append(dc[with], room)
	if err := c.SetAccountData(ctx, event.AccountDataDirectChats.Type, &dc); err != nil {
		log.Warn().Err(err).Msg("set m.direct")
	}
}

// messages is a room's timeline, newest first from [r.From] (the latest when empty), each encrypted one decrypted
// where this device has its key.
func messages(ctx context.Context, r request) (map[string]any, error) {
	c, h, err := client()
	if err != nil {
		return nil, err
	}
	limit := r.Limit
	if limit <= 0 || limit > 100 {
		limit = 30
	}
	rid := id.RoomID(r.Room)
	resp, err := c.Messages(ctx, rid, r.From, "", mautrix.DirectionBackward, nil, limit)
	if err != nil {
		return nil, err
	}
	me := ownID()
	msgs := []map[string]any{}
	reactions := []map[string]any{}
	for _, evt := range resp.Chunk {
		evt.RoomID = rid
		if evt.Unsigned.RedactedBecause != nil {
			continue
		}
		if evt.Type == event.EventEncrypted {
			_ = evt.Content.ParseRaw(evt.Type)
			dec, derr := h.Decrypt(ctx, evt)
			if derr != nil {
				msgs = append(msgs, undecryptable(evt, me, memberName(rid, evt.Sender)))
				continue
			}
			evt = dec
		}
		if m := messageOf(evt, me, memberName(rid, evt.Sender)); m != nil {
			msgs = append(msgs, m)
		} else if x := reactionOf(evt); x != nil {
			reactions = append(reactions, x)
		}
	}
	return map[string]any{"messages": msgs, "reactions": reactions, "end": resp.End}, nil
}

// ensureMembers fetches an encrypted room's full membership before a send, so its key goes to everyone in it.
func ensureMembers(ctx context.Context, c *mautrix.Client, rid id.RoomID) {
	if enc, _ := c.StateStore.IsEncrypted(ctx, rid); !enc {
		return
	}
	if done, _ := c.StateStore.HasFetchedMembers(ctx, rid); done {
		return
	}
	if _, err := c.Members(ctx, rid); err == nil {
		_ = c.StateStore.MarkMembersFetched(ctx, rid)
	}
}

// send sends [r.Text] to a room, as a reply when [r.ReplyTo] names an event, and keeps it as the room's last message.
// mautrix encrypts it where the room is encrypted.
func send(ctx context.Context, r request) (map[string]any, error) {
	c, _, err := client()
	if err != nil {
		return nil, err
	}
	rid := id.RoomID(r.Room)
	ensureMembers(ctx, c, rid)
	content := &event.MessageEventContent{MsgType: event.MsgText, Body: r.Text}
	if r.ReplyTo != "" {
		content.RelatesTo = (&event.RelatesTo{}).SetReplyTo(id.EventID(r.ReplyTo))
	}
	resp, err := c.SendMessageEvent(ctx, rid, event.EventMessage, content)
	if err != nil {
		return nil, err
	}
	m := map[string]any{"id": string(resp.EventID), "from": string(ownID()), "text": r.Text, "ts": time.Now().UnixMilli(), "mine": true, "media": []any{}}
	noteLast(rid, m)
	return map[string]any{"id": string(resp.EventID)}, nil
}

// sendMedia uploads the file at [r.Path] and sends it to a room, with [r.Text] as its caption. For an encrypted room
// the file is encrypted here first, and its key travels in the message.
func sendMedia(ctx context.Context, r request) (map[string]any, error) {
	c, _, err := client()
	if err != nil {
		return nil, err
	}
	data, err := os.ReadFile(r.Path)
	if err != nil {
		return nil, err
	}
	rid := id.RoomID(r.Room)
	ensureMembers(ctx, c, rid)
	name := r.Name
	if name == "" {
		name = filepath.Base(r.Path)
	}
	mime := r.Mime
	if mime == "" {
		mime = "application/octet-stream"
	}
	content := &event.MessageEventContent{MsgType: mediaKind(mime), Body: name, FileName: name, Info: &event.FileInfo{MimeType: mime, Size: len(data)}}
	if r.Text != "" {
		content.Body = r.Text
	}
	encrypted, _ := c.StateStore.IsEncrypted(ctx, rid)
	if encrypted {
		file := attachment.NewEncryptedFile()
		file.EncryptInPlace(data)
		up, err := c.UploadMedia(ctx, mautrix.ReqUploadMedia{ContentBytes: data, ContentType: "application/octet-stream", FileName: name})
		if err != nil {
			return nil, err
		}
		content.File = &event.EncryptedFileInfo{EncryptedFile: *file, URL: up.ContentURI.CUString()}
	} else {
		up, err := c.UploadMedia(ctx, mautrix.ReqUploadMedia{ContentBytes: data, ContentType: mime, FileName: name})
		if err != nil {
			return nil, err
		}
		content.URL = up.ContentURI.CUString()
	}
	resp, err := c.SendMessageEvent(ctx, rid, event.EventMessage, content)
	if err != nil {
		return nil, err
	}
	return map[string]any{"id": string(resp.EventID), "media": mediaOf(content)}, nil
}

// download writes the file at [r.MXC] to [r.Path], decrypting it with [r.File]'s key where it came from an encrypted
// room.
func download(ctx context.Context, r request) error {
	c, _, err := client()
	if err != nil {
		return err
	}
	var file *event.EncryptedFileInfo
	if len(r.File) > 0 && string(r.File) != "null" {
		var raw string
		// The file object, or that object as a string.
		if json.Unmarshal(r.File, &raw) == nil {
			r.File = json.RawMessage(raw)
		}
		file = &event.EncryptedFileInfo{}
		if err := json.Unmarshal(r.File, file); err != nil {
			return fmt.Errorf("the file's key couldn't be read: %w", err)
		}
	}
	mxc := r.MXC
	if mxc == "" && file != nil {
		mxc = string(file.URL)
	}
	uri, err := id.ParseContentURI(mxc)
	if err != nil {
		return err
	}
	// The server can only make a thumbnail of a file it can read: an encrypted one comes down whole.
	var data []byte
	if r.Thumb && file == nil {
		resp, err := c.DownloadThumbnail(ctx, uri, 320, 320, mautrix.DownloadThumbnailExtra{Method: "scale"})
		if err != nil {
			return err
		}
		data, err = io.ReadAll(resp.Body)
		_ = resp.Body.Close()
		if err != nil {
			return err
		}
	} else {
		data, err = c.DownloadBytes(ctx, uri)
		if err != nil {
			return err
		}
	}
	if file != nil {
		if err := file.PrepareForDecryption(); err != nil {
			return err
		}
		if err := file.DecryptInPlace(data); err != nil {
			return err
		}
	}
	if err := os.MkdirAll(filepath.Dir(r.Path), 0o700); err != nil {
		return err
	}
	tmp := r.Path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, r.Path)
}
