package main

// What Messenger says, in the shapes the app is told (../ACCOUNT_HELPERS.md). Messenger's website keeps a small
// database in the browser and the server sends rows for it ("Lightspeed" tables: threads, contacts, messages,
// reactions, read marks). The book below is the little of that database the helper needs to turn rows into events:
// who is who, which thread is which kind, and when each message was sent. Nothing here touches the network, so it is
// tested with rows made by hand.

import (
	"cmp"
	"net/url"
	"slices"
	"sort"
	"strconv"
	"strings"
	"sync"

	"go.mau.fi/mautrix-meta/pkg/messagix/methods"
	"go.mau.fi/mautrix-meta/pkg/messagix/table"
)

// Folders whose threads are not chats a person would look for.
var hiddenFolders = map[string]bool{"montage": true, "hidden": true, "disabled": true, "spam": true}

// Messenger's thumbs-up button sends a sticker; it is shown as the emoji, as encrypted chats show it.
var thumbsUpStickers = map[int64]bool{369239263222822: true, 369239343222814: true, 369239383222810: true}

// How many messages' times are remembered for each chat (to name the message a read mark reaches).
const stampsKept = 300

// thread is what the book holds of one of Messenger's threads (a chat, or a folder and the like: see listable).
// Key is the number the app knows it by; Last and Read are times in ms.
type thread struct {
	Key         int64
	Type        table.ThreadType
	Name        string
	Picture     string
	Folder      string
	Last        int64
	Read        int64
	Unread      int64
	Snippet     string
	SnippetFrom int64
	SyncGroup   int64
	Members     map[int64]bool
	// FBKey is Facebook's own key for a thread that lives on the encrypted side under another number.
	FBKey int64
}

// contact is a person, as Messenger's contact rows give them. Picture is an address, not a file.
type contact struct {
	ID       int64
	Name     string
	Username string
	Picture  string
}

// stamp is when a message was sent (ms) and by whom: each thread's are kept in order of time.
type stamp struct {
	ID   string
	TS   int64
	From int64
}

// msgRef is what is remembered of a message by its id: its thread, when it was sent (ms) and by whom.
type msgRef struct {
	Thread int64
	TS     int64
	From   int64
}

// page is the newest stretch of a thread's history Messenger has sent: what `history` answers with before asking for
// more.
type page struct {
	Messages []*table.WrappedMessage
	More     bool
}

// ev is an event for the app, made under the book's lock and said once it is let go.
type ev struct {
	Name   string
	Fields map[string]any
}

// book is the little of Messenger's database the helper keeps, for one account (me). mu guards every field. hybrid
// gives, for a thread's number on Facebook's side, its number on the encrypted side; stamps holds each thread's
// newest message times and msgs the same messages by id; pages holds each thread's newest stretch of history.
type book struct {
	mu       sync.Mutex
	me       int64
	threads  map[int64]*thread
	contacts map[int64]*contact
	hybrid   map[int64]int64
	stamps   map[int64][]stamp
	msgs     map[string]msgRef
	pages    map[int64]*page
	// kinds outlives a restart (session.json): the kind of every thread met, so a chat Messenger has not listed
	// this time is still sent to the right way (encrypted or not).
	kinds map[int64]table.ThreadType
	// avatar gives the file an address's picture is kept in, or "" while there is none yet.
	avatar func(owner string, address string) string
}

// newBook is an empty book for the person [me]. It gives no pictures until avatar is set.
func newBook(me int64) *book {
	return &book{
		me:       me,
		threads:  map[int64]*thread{},
		contacts: map[int64]*contact{},
		hybrid:   map[int64]int64{},
		stamps:   map[int64][]stamp{},
		msgs:     map[string]msgRef{},
		pages:    map[int64]*page{},
		kinds:    map[int64]table.ThreadType{},
		avatar:   func(string, string) string { return "" },
	}
}

// idString is one of Meta's numbers as the protocol carries ids: in decimal.
func idString(n int64) string { return strconv.FormatInt(n, 10) }

// parseID reads an id back into Meta's number; false for anything that is not one, 0 included.
func parseID(s string) (int64, bool) {
	n, err := strconv.ParseInt(strings.TrimSpace(s), 10, 64)
	return n, err == nil && n != 0
}

// nullable is [s], or JSON's null where it is empty.
func nullable(s string) any {
	if s == "" {
		return nil
	}
	return s
}

// isGroup is whether a thread's kind is a group's: any known kind that is not between two people.
func isGroup(t table.ThreadType) bool { return t != table.UNKNOWN_THREAD_TYPE && !t.IsOneToOne() }

// listable is whether a thread is a chat: folders and the like are rows of the same table.
func listable(t *thread) bool {
	switch t.Type {
	case table.FOLDER, table.COMMUNITY_FOLDER, table.COMMUNITY_CHANNEL_CATEGORY, table.PINNED, table.MONTAGE:
		return false
	}
	return !hiddenFolders[t.Folder]
}

// key is the number the app knows a thread by: its encrypted-side number where Messenger has given one.
func (b *book) key(k int64) int64 {
	if w, ok := b.hybrid[k]; ok && w != 0 {
		return w
	}
	return k
}

// thread is the thread [k], begun (with the kind kept for it from before) where the book does not hold it yet.
func (b *book) thread(k int64) *thread {
	t := b.threads[k]
	if t == nil {
		t = &thread{Key: k, Type: b.kinds[k], Members: map[int64]bool{}}
		b.threads[k] = t
	}
	return t
}

// setKind notes a thread's folder (where one is given) and its kind. An unknown kind changes nothing, and an
// encrypted thread is never made an unencrypted one again.
func (b *book) setKind(t *thread, kind table.ThreadType, folder string) {
	if folder != "" {
		t.Folder = folder
	}
	// A thread moved to the encrypted side keeps its old kind in some rows: once encrypted, it stays so.
	if strings.HasPrefix(t.Folder, "e2ee_cutover") && kind == table.ONE_TO_ONE {
		kind = table.ENCRYPTED_OVER_WA_ONE_TO_ONE
	}
	if kind == table.UNKNOWN_THREAD_TYPE || (t.Type.IsWhatsApp() && !kind.IsWhatsApp()) {
		return
	}
	t.Type = kind
	b.kinds[t.Key] = kind
}

// name is a person's name; "" where the book has not met them.
func (b *book) name(id int64) string {
	if c := b.contacts[id]; c != nil {
		return c.Name
	}
	return ""
}

// remember keeps when a message was sent and by whom.
func (b *book) remember(k int64, id string, ts, from int64) {
	if id == "" {
		return
	}
	if _, known := b.msgs[id]; known {
		return
	}
	b.msgs[id] = msgRef{Thread: k, TS: ts, From: from}
	list := append(b.stamps[k], stamp{ID: id, TS: ts, From: from})
	sort.SliceStable(list, func(i, j int) bool { return list[i].TS < list[j].TS })
	if len(list) > stampsKept {
		for _, old := range list[:len(list)-stampsKept] {
			delete(b.msgs, old.ID)
		}
		list = slices.Clone(list[len(list)-stampsKept:])
	}
	b.stamps[k] = list
}

// reached is the newest message known in a thread sent at or before [ts]: the one a read mark of that time reaches.
func (b *book) reached(k, ts int64) string {
	list := b.stamps[k]
	for i := len(list) - 1; i >= 0; i-- {
		if list[i].TS <= ts {
			return list[i].ID
		}
	}
	return ""
}

// threadOf is the thread a message is in: remembered, or read out of Meta's own id ("mid.$c…" holds the two
// people's numbers folded together, "mid.$g…" the group's).
func (b *book) threadOf(id string) (int64, bool) {
	if r, ok := b.msgs[id]; ok {
		return r.Thread, true
	}
	full, err := methods.ParseMessageIDFull(id)
	if err != nil || full.ChatID == 0 {
		return 0, false
	}
	switch full.ChatType {
	case 'c':
		return b.key(full.ChatID ^ b.me), true
	case 'g':
		return b.key(full.ChatID), true
	}
	return 0, false
}

// sentAt is when a message was sent, in ms: remembered, or read out of Meta's own id.
func (b *book) sentAt(id string) int64 {
	if r, ok := b.msgs[id]; ok {
		return r.TS
	}
	ts, err := methods.ParseMessageID(id)
	if err != nil {
		return 0
	}
	return ts
}

// --- chats and people -----------------------------------------------------------------------------------------------

// personJSON is a person as the app is told them: what a `name` event carries and `who` answers. Called with the
// book's lock held.
func (b *book) personJSON(c *contact) map[string]any {
	return map[string]any{
		"id":     idString(c.ID),
		"name":   c.Name,
		"handle": c.Username,
		"avatar": nullable(b.avatar("u"+idString(c.ID), c.Picture)),
	}
}

// chatJSON is a thread as the protocol's `chat`. A group with no name is titled with its people's names. Called
// with the book's lock held.
func (b *book) chatJSON(t *thread) map[string]any {
	group := isGroup(t.Type)
	members := []map[string]any{}
	title := t.Name
	picture := t.Picture
	owner := "t" + idString(t.Key)
	if group {
		ids := make([]int64, 0, len(t.Members))
		for id := range t.Members {
			if id != b.me {
				ids = append(ids, id)
			}
		}
		slices.Sort(ids)
		var names []string
		for _, id := range ids {
			members = append(members, map[string]any{"id": idString(id), "name": b.name(id)})
			if n := b.name(id); n != "" {
				names = append(names, n)
			}
		}
		if title == "" {
			title = strings.Join(names, ", ")
		}
	} else {
		// With one other person the thread's number is theirs, and their name and picture are the chat's.
		if t.Key != b.me {
			members = append(members, map[string]any{"id": idString(t.Key), "name": b.name(t.Key)})
		}
		if c := b.contacts[t.Key]; c != nil {
			title = cmp.Or(c.Name, title)
			picture = cmp.Or(c.Picture, picture)
			owner = "u" + idString(c.ID)
		}
	}
	m := map[string]any{
		"id":        idString(t.Key),
		"title":     title,
		"group":     group,
		"members":   members,
		"avatar":    nullable(b.avatar(owner, picture)),
		"unread":    t.Unread,
		"last":      t.Last,
		"encrypted": t.Type.IsWhatsApp(),
	}
	if t.Folder != "" {
		m["folder"] = t.Folder
	}
	if t.Snippet != "" {
		m["snippet"] = t.Snippet
		m["snippet_mine"] = t.SnippetFrom == b.me
	}
	return m
}

// chats is every chat known, newest first.
func (b *book) chats() []map[string]any {
	b.mu.Lock()
	defer b.mu.Unlock()
	list := make([]*thread, 0, len(b.threads))
	for _, t := range b.threads {
		// A thread only heard of by its kind (a row that says "it exists") has nothing to show yet.
		if listable(t) && (t.Last != 0 || t.Name != "" || b.contacts[t.Key] != nil) {
			list = append(list, t)
		}
	}
	sort.Slice(list, func(i, j int) bool {
		if list[i].Last != list[j].Last {
			return list[i].Last > list[j].Last
		}
		return list[i].Key < list[j].Key
	})
	out := make([]map[string]any, 0, len(list))
	for _, t := range list {
		out = append(out, b.chatJSON(t))
	}
	return out
}

// unreadOf is how many messages wait in a thread. Messenger gives a count in some rows only; elsewhere all that is
// known is whether anything is newer than the last one read, said as one.
func unreadOf(count, last, read int64) int64 {
	if count > 0 {
		return count
	}
	if last > read {
		return 1
	}
	return 0
}

// --- messages -------------------------------------------------------------------------------------------------------

// unwrapLink is the address behind Facebook's link shim (facebook.com/l.php?u=…).
func unwrapLink(addr string) string {
	if parsed, err := url.Parse(addr); err == nil && parsed.Path == "/l.php" {
		if u := parsed.Query().Get("u"); u != "" {
			return u
		}
	}
	return addr
}

// isLinkPreview is whether something shared is only the preview card of a link in the message: a card that opens
// a web address through Facebook's link shim and nothing of Meta's own.
func isLinkPreview(x *table.WrappedXMA) bool {
	return x.CTA != nil && x.CTA.Type_ == "xma_web_url" && x.CTA.TargetId == 0 && x.CTA.NativeUrl == "" &&
		strings.Contains(x.CTA.ActionUrl, "/l.php?")
}

// media is one file of a message: where Meta's servers keep it (an address that stops working after some days;
// asking for the chat's history again gives a new one) and what is known of it.
func media(address, mime, name string, size, width, height int64) map[string]any {
	return map[string]any{
		"pointer": map[string]any{"url": address, "mime": mime},
		"mime":    mime,
		"name":    name,
		"size":    size,
		"width":   width,
		"height":  height,
	}
}

// file picks a row's playable address (a video, a sound, a document) or else its preview (a picture).
func file(playable, playableMime, attachmentMime, preview, previewMime, name string, size, width, height int64) map[string]any {
	if playable != "" {
		return media(playable, cmp.Or(playableMime, attachmentMime), name, size, 0, 0)
	}
	if preview != "" {
		return media(preview, cmp.Or(previewMime, attachmentMime), name, size, width, height)
	}
	return nil
}

// messageJSON is a message as the app is told it, or nil for one that says nothing (unsent).
func (b *book) messageJSON(m *table.WrappedMessage) map[string]any {
	if m == nil || m.LSInsertMessage == nil || m.IsUnsent || m.MessageId == "" {
		return nil
	}
	k := b.key(m.ThreadKey)
	group := false
	if t := b.threads[k]; t != nil && t.Type != table.UNKNOWN_THREAD_TYPE {
		group = isGroup(t.Type)
	} else if strings.HasPrefix(m.MessageId, "mid.$g") {
		group = true
	}
	text := m.Text
	files := []map[string]any{}
	var extra []string
	seen := map[string]bool{}
	for _, a := range m.BlobAttachments {
		// Messenger sometimes sends the same row twice.
		if a.AttachmentFbid != "" && seen[a.AttachmentFbid] {
			continue
		}
		seen[a.AttachmentFbid] = true
		if f := file(a.PlayableUrl, a.PlayableUrlMimeType, a.AttachmentMimeType, a.PreviewUrl, a.PreviewUrlMimeType, a.Filename, a.Filesize, a.PreviewWidth, a.PreviewHeight); f != nil {
			files = append(files, f)
		}
	}
	for _, a := range m.Attachments {
		once := a.AttachmentType == table.AttachmentTypeEphemeralImage || a.AttachmentType == table.AttachmentTypeEphemeralVideo
		if once && a.EphemeralMediaViewMode != table.EphemeralMediaPermanent {
			// Sent to be seen once: opening it here would not tell the sender, so it is left to Messenger.
			extra = append(extra, "A photo or video to view once: open it in Messenger.")
			continue
		}
		if f := file(a.PlayableUrl, a.PlayableUrlMimeType, a.AttachmentMimeType, a.PreviewUrl, a.PreviewUrlMimeType, a.Filename, a.Filesize, a.PreviewWidth, a.PreviewHeight); f != nil {
			files = append(files, f)
		}
	}
	for _, s := range m.Stickers {
		if thumbsUpStickers[m.StickerId] && len(m.Stickers) == 1 {
			text = "👍"
			continue
		}
		if f := file(s.PlayableUrl, s.PlayableUrlMimeType, "", s.PreviewUrl, s.PreviewUrlMimeType, s.AccessibilitySummaryText, 0, s.PreviewWidth, s.PreviewHeight); f != nil {
			files = append(files, f)
		}
	}
	for _, x := range m.XMAAttachments {
		if x == nil || x.LSInsertXmaAttachment == nil {
			continue
		}
		link := ""
		if x.CTA != nil {
			link = unwrapLink(x.CTA.ActionUrl)
		}
		if isLinkPreview(x) {
			// A link's preview card: the link is the message. It is added only where the words lack it.
			if link != "" && !strings.Contains(text, link) {
				extra = append(extra, link)
			}
			continue
		}
		// Something shared (a post, a reel, a place): its picture where there is one, its title and its link.
		if f := file(x.PlayableUrl, x.PlayableUrlMimeType, "", x.PreviewUrl, x.PreviewUrlMimeType, x.Filename, x.Filesize, x.PreviewWidth, x.PreviewHeight); f != nil {
			files = append(files, f)
		}
		if x.TitleText != "" {
			extra = append(extra, x.TitleText)
		}
		if link != "" && strings.HasPrefix(link, "http") {
			extra = append(extra, link)
		}
	}
	for _, line := range extra {
		if text == "" {
			text = line
		} else if !strings.Contains(text, line) {
			text += "\n" + line
		}
	}
	out := map[string]any{
		"chat":  idString(k),
		"group": group,
		"id":    m.MessageId,
		"from":  idString(m.SenderId),
		"name":  b.name(m.SenderId),
		"mine":  m.SenderId == b.me,
		"ts":    m.TimestampMs,
		"text":  text,
		"media": files,
	}
	if m.IsAdminMessage {
		// "Ada named the group", "Ada left": Messenger's own line, not anyone's words.
		out["system"] = true
	}
	if m.ReplySourceId != "" {
		quote := map[string]any{"id": m.ReplySourceId, "text": cmp.Or(m.ReplyMessageText, m.ReplySnippet)}
		// Who wrote the one answered, where Messenger says: the app names them over the quote (GMFB-44).
		if m.ReplyToUserId != 0 {
			quote["from"] = idString(m.ReplyToUserId)
		}
		out["quote"] = quote
	}
	return out
}

// sortOldestFirst orders messages by when they were sent, and by Messenger's own sort key where two share a time.
func sortOldestFirst(list []*table.WrappedMessage) {
	sort.SliceStable(list, func(i, j int) bool {
		if list[i].TimestampMs != list[j].TimestampMs {
			return list[i].TimestampMs < list[j].TimestampMs
		}
		return list[i].PrimarySortKey < list[j].PrimarySortKey
	})
}

// messagesJSON is a stretch of history, oldest first, without what was unsent.
func (b *book) messagesJSON(list []*table.WrappedMessage) []map[string]any {
	list = slices.Clone(list)
	sortOldestFirst(list)
	out := make([]map[string]any, 0, len(list))
	seen := map[string]bool{}
	for _, m := range list {
		if j := b.messageJSON(m); j != nil && !seen[m.MessageId] {
			seen[m.MessageId] = true
			out = append(out, j)
		}
	}
	return out
}

// --- a table of rows → events ---------------------------------------------------------------------------------------

// applied is what a table came to: the events to say, in order, and what `history` requests wait on: the
// stretches of history it carried, by thread, and Messenger's rows about a stretch already sent.
type applied struct {
	Events  []ev
	Upserts map[int64]*table.UpsertMessages
	Ranges  []*table.LSUpdateExistingMessageRange
}

// putContact takes in a contact row. Where it changes what is known of the person, a `name` event is added to
// [out], and their chat (between two people) is marked in [touched] to be said again.
func (b *book) putContact(id int64, name, username, picture string, out *[]ev, touched map[int64]bool) {
	if id == 0 {
		return
	}
	c := b.contacts[id]
	if c == nil {
		c = &contact{ID: id}
		b.contacts[id] = c
	}
	// A row that only checks the contact exists can carry less than is known already: nothing is emptied by it.
	next := contact{ID: id, Name: cmp.Or(name, c.Name), Username: cmp.Or(username, c.Username), Picture: cmp.Or(picture, c.Picture)}
	if next == *c {
		return
	}
	*c = next
	*out = append(*out, ev{"name", b.personJSON(c)})
	// The person's name is their chat's title.
	if t := b.threads[id]; t != nil && !isGroup(t.Type) {
		touched[id] = true
	}
}

// apply takes in a table Messenger sent and gives what the app should be told, in order: people, messages, edits,
// deletions, reactions, read marks, and last the chats that changed. History (rows Messenger marks as a stretch of a
// thread's past) is kept for the `history` request and not told as new messages.
func (b *book) apply(tbl *table.LSTable) applied {
	b.mu.Lock()
	defer b.mu.Unlock()
	var out []ev
	touched := map[int64]bool{}

	for _, row := range tbl.LSUpdateThreadAuthorityAndMappingWithOTIDFromJID {
		b.hybrid[row.ThreadKey] = row.ThreadJID
	}
	for _, row := range tbl.LSVerifyHybridThreadExists {
		b.hybrid[row.ThreadKey] = row.ThreadJID
		t := b.thread(row.ThreadJID)
		t.FBKey = row.ThreadKey
		kind := row.ThreadType
		if !kind.IsWhatsApp() {
			kind = table.ENCRYPTED_OVER_WA_ONE_TO_ONE
			if row.IsGroupThread {
				kind = table.ENCRYPTED_OVER_WA_GROUP
			}
		}
		b.setKind(t, kind, "")
		delete(b.threads, row.ThreadKey)
	}

	for _, row := range tbl.LSDeleteThenInsertContact {
		b.putContact(row.Id, row.Name, row.GetUsername(), row.GetAvatarURL(), &out, touched)
	}
	for _, row := range tbl.LSVerifyContactRowExists {
		b.putContact(row.ContactId, row.Name, row.GetUsername(), row.ProfilePictureUrl, &out, touched)
	}

	whole := map[int64]bool{}
	for _, row := range tbl.LSDeleteThenInsertThread {
		k := b.key(row.ThreadKey)
		t := b.thread(k)
		if k != row.ThreadKey {
			t.FBKey = row.ThreadKey
		}
		b.setKind(t, row.ThreadType, row.FolderName)
		t.Name, t.Picture = row.ThreadName, row.ThreadPictureUrl
		t.Last, t.Read = row.LastActivityTimestampMs, row.LastReadWatermarkTimestampMs
		t.Unread = unreadOf(row.UnreadMessageCount, t.Last, t.Read)
		t.Snippet, t.SnippetFrom = row.Snippet, row.SnippetSenderContactId
		t.SyncGroup = row.SyncGroup
		whole[k], touched[k] = true, true
	}
	for _, row := range tbl.LSUpdateOrInsertThread {
		k := b.key(row.ThreadKey)
		if whole[k] {
			continue
		}
		t := b.thread(k)
		if k != row.ThreadKey {
			t.FBKey = row.ThreadKey
		}
		b.setKind(t, row.ThreadType, row.FolderName)
		t.Name, t.Picture = row.ThreadName, row.ThreadPictureUrl
		t.Last, t.Read = row.LastActivityTimestampMs, row.LastReadWatermarkTimestampMs
		t.Unread = unreadOf(0, t.Last, t.Read)
		t.Snippet, t.SnippetFrom = row.Snippet, row.SnippetSenderContactId
		t.SyncGroup = cmp.Or(row.SyncGroup, t.SyncGroup)
		touched[k] = true
	}
	for _, row := range tbl.LSVerifyThreadExists {
		t := b.thread(b.key(row.ThreadKey))
		b.setKind(t, row.ThreadType, row.FolderName)
		t.SyncGroup = cmp.Or(row.SyncGroup, t.SyncGroup)
	}
	for _, row := range tbl.LSMoveThreadToE2EECutoverFolder {
		t := b.thread(b.key(row.ThreadKey))
		b.setKind(t, cmp.Or(t.Type, table.ONE_TO_ONE), "e2ee_cutover")
		touched[t.Key] = true
	}
	for _, row := range tbl.LSAddParticipantIdToGroupThread {
		k := b.key(row.ThreadKey)
		t := b.thread(k)
		if !t.Members[row.ContactId] {
			t.Members[row.ContactId] = true
			touched[k] = true
		}
	}
	for _, row := range tbl.LSRemoveParticipantFromThread {
		k := b.key(row.ThreadKey)
		if t := b.threads[k]; t != nil && t.Members[row.ParticipantId] {
			delete(t.Members, row.ParticipantId)
			touched[k] = true
		}
	}
	for _, row := range tbl.LSSyncUpdateThreadName {
		t := b.thread(b.key(row.ThreadKey))
		t.Name = row.ThreadName
		touched[t.Key] = true
	}
	for _, row := range tbl.LSSetThreadImageURL {
		t := b.thread(b.key(row.ThreadKey))
		t.Picture = row.ImageURL
		touched[t.Key] = true
	}
	for _, row := range tbl.LSDeleteThread {
		k := b.key(row.ThreadKey)
		if !whole[k] {
			delete(b.threads, k)
			delete(touched, k)
		}
	}

	upserts, inserts := tbl.WrapMessages()
	for fbKey, up := range upserts {
		if up == nil || up.Range == nil {
			continue
		}
		k := b.key(fbKey)
		for _, m := range up.Messages {
			b.remember(k, m.MessageId, m.TimestampMs, m.SenderId)
		}
		b.keepPage(k, up)
	}
	for _, m := range inserts {
		k := b.key(m.ThreadKey)
		b.remember(k, m.MessageId, m.TimestampMs, m.SenderId)
		j := b.messageJSON(m)
		if j == nil {
			continue
		}
		out = append(out, ev{"message", j})
		// Kept current for `chats`; the app counts a new message itself, so no chat event is said for it.
		if t := b.threads[k]; t != nil && m.TimestampMs >= t.Last {
			t.Last = m.TimestampMs
			t.Snippet, t.SnippetFrom = j["text"].(string), m.SenderId
			if m.SenderId != b.me {
				t.Unread++
			} else {
				t.Unread, t.Read = 0, m.TimestampMs
			}
		}
		if p := b.pages[k]; p != nil {
			p.Messages = append(p.Messages, m)
		}
	}

	for _, row := range tbl.LSEditMessage {
		fields := map[string]any{"chat": "", "target": row.MessageID, "text": row.Text}
		if k, ok := b.threadOf(row.MessageID); ok {
			fields["chat"] = idString(k)
			if p := b.pages[k]; p != nil {
				for _, m := range p.Messages {
					if m.MessageId == row.MessageID {
						m.Text = row.Text
					}
				}
			}
		}
		out = append(out, ev{"edited", fields})
	}
	gone := func(threadKey int64, id string) {
		k := b.key(threadKey)
		out = append(out, ev{"deleted", map[string]any{"chat": idString(k), "target": id}})
		if p := b.pages[k]; p != nil {
			p.Messages = slices.DeleteFunc(p.Messages, func(m *table.WrappedMessage) bool { return m.MessageId == id })
		}
	}
	for _, row := range tbl.LSDeleteMessage {
		gone(row.ThreadKey, row.MessageId)
	}
	for _, row := range tbl.LSDeleteThenInsertMessage {
		if row.IsUnsent {
			gone(row.ThreadKey, row.MessageId)
		}
	}
	for _, row := range tbl.LSUpsertReaction {
		out = append(out, ev{"reaction", map[string]any{
			"chat": idString(b.key(row.ThreadKey)), "from": idString(row.ActorId), "target": row.MessageId,
			"emoji": row.Reaction, "remove": row.Reaction == "",
		}})
	}
	for _, row := range tbl.LSDeleteReaction {
		out = append(out, ev{"reaction", map[string]any{
			"chat": idString(b.key(row.ThreadKey)), "from": idString(row.ActorId), "target": row.MessageId,
			"emoji": "", "remove": true,
		}})
	}
	// Messenger marks reading by time, not by message: `id` is the newest message known at or before that time
	// (empty where the helper has not seen the chat's messages), and `ts` the time itself.
	receipt := func(threadKey, who, ts int64, kind string) {
		if ts <= 0 {
			return
		}
		k := b.key(threadKey)
		out = append(out, ev{"receipt", map[string]any{
			"chat": idString(k), "from": idString(who), "id": b.reached(k, ts), "ts": ts, "kind": kind,
		}})
	}
	for _, row := range tbl.LSUpdateReadReceipt {
		receipt(row.ThreadKey, row.ContactId, row.ReadWatermarkTimestampMs, "read")
	}
	for _, row := range tbl.LSUpdateDeliveryReceipt {
		receipt(row.ThreadKey, row.ContactId, row.DeliveredWatermarkTimestampMs, "delivered")
	}
	// The person read the chat somewhere else: nothing waits in it any more.
	selfRead := func(threadKey, ts int64) {
		k := b.key(threadKey)
		if t := b.threads[k]; t != nil && ts >= t.Read {
			t.Read = ts
			if ts >= t.Last && t.Unread != 0 {
				t.Unread = 0
				touched[k] = true
			}
		}
		receipt(threadKey, b.me, ts, "read")
	}
	for _, row := range tbl.LSMarkThreadRead {
		selfRead(row.ThreadKey, row.LastReadWatermarkTimestampMs)
	}
	for _, row := range tbl.LSMarkThreadReadV2 {
		selfRead(row.ThreadKey, row.LastReadWatermarkTimestampMs)
	}

	keys := make([]int64, 0, len(touched))
	for k := range touched {
		keys = append(keys, k)
	}
	sort.Slice(keys, func(i, j int) bool {
		a, c := b.threads[keys[i]], b.threads[keys[j]]
		if a != nil && c != nil && a.Last != c.Last {
			return a.Last > c.Last
		}
		return keys[i] < keys[j]
	})
	for _, k := range keys {
		if t := b.threads[k]; t != nil && listable(t) {
			out = append(out, ev{"chat", b.chatJSON(t)})
		}
	}
	return applied{Events: out, Upserts: upserts, Ranges: tbl.LSUpdateExistingMessageRange}
}

// keepPage keeps the newest stretch of a thread's history Messenger has sent. Older stretches are asked for one at a
// time and answered straight from what comes back, never kept.
func (b *book) keepPage(k int64, up *table.UpsertMessages) {
	p := b.pages[k]
	if p != nil && len(p.Messages) > 0 {
		sortOldestFirst(p.Messages)
		if len(up.Messages) == 0 || up.Range.MaxTimestampMs < p.Messages[len(p.Messages)-1].TimestampMs {
			return
		}
	}
	b.pages[k] = &page{Messages: slices.Clone(up.Messages), More: up.Range.HasMoreBefore}
}

// olderThan is the messages of [list] sent before the message [before] (all of them where it is ""), oldest first.
func (b *book) olderThan(list []*table.WrappedMessage, before string) []map[string]any {
	if before != "" {
		limit := b.sentAt(before)
		list = slices.DeleteFunc(slices.Clone(list), func(m *table.WrappedMessage) bool {
			return m.MessageId == before || (limit != 0 && m.TimestampMs >= limit)
		})
	}
	return b.messagesJSON(list)
}

// history answers from the newest stretch kept: the messages older than [before], and whether Messenger has more
// before them. ok is false where Messenger has to be asked.
func (b *book) history(k int64, before string) (list []map[string]any, more bool, ok bool) {
	b.mu.Lock()
	defer b.mu.Unlock()
	p := b.pages[k]
	if p == nil {
		return nil, false, false
	}
	if before == "" {
		return b.messagesJSON(p.Messages), p.More, true
	}
	list = b.olderThan(p.Messages, before)
	if len(list) > 0 {
		return list, p.More, true
	}
	// Nothing older is kept. That is an answer only where the stretch kept reaches the thread's start and the
	// message asked about is within it.
	sortOldestFirst(p.Messages)
	within := len(p.Messages) > 0 && b.sentAt(before) >= p.Messages[0].TimestampMs
	return []map[string]any{}, false, !p.More && within
}

// stretch is a stretch of history Messenger sent in answer to a request, as `history` answers.
func (b *book) stretch(up *table.UpsertMessages, before string) (list []map[string]any, more bool) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.olderThan(up.Messages, before), up.Range != nil && up.Range.HasMoreBefore
}
