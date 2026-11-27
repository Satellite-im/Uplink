package main

// What X says, put into the protocol's shapes (../ACCOUNT_HELPERS.md). Nothing here reaches the network, so all of
// it is tested with hand-built values (main_test.go). Keys are asked for through a function, so decryption is tested
// too.

import (
	"cmp"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"mime"
	"path/filepath"
	"slices"
	"sort"
	"strconv"
	"strings"

	"go.mau.fi/util/ptr"

	"go.mau.fi/mautrix-twitter/pkg/twittermeow"
	"go.mau.fi/mautrix-twitter/pkg/twittermeow/crypto"
	"go.mau.fi/mautrix-twitter/pkg/twittermeow/data/payload"
	"go.mau.fi/mautrix-twitter/pkg/twittermeow/data/response"
	"go.mau.fi/mautrix-twitter/pkg/twittermeow/data/types"
	"go.mau.fi/mautrix-twitter/pkg/twittermeow/methods"
)

// keyFunc gives the key of a chat at a key version: the store's GetConversationKey.
type keyFunc func(ctx context.Context, conv, version string) (*crypto.ConversationKey, error)

// normalizeChat is a chat id as X Chat writes it: a two-person chat is "<id>:<id>"; X's older API wrote "<id>-<id>",
// and some links still do. A group's id begins with "g" and is kept as it is.
func normalizeChat(id string) string {
	id = strings.TrimSpace(id)
	if strings.HasPrefix(id, "g") {
		return id
	}
	return strings.ReplaceAll(id, "-", ":")
}

// isGroupChat is whether a chat id names a group.
func isGroupChat(id string) bool { return strings.HasPrefix(id, "g") }

// dmMembers is the two people of a two-person chat id, false for a group or an id that is not one.
func dmMembers(id string) ([]string, bool) {
	id = normalizeChat(id)
	if isGroupChat(id) {
		return nil, false
	}
	parts := strings.Split(id, ":")
	if len(parts) != 2 || parts[0] == "" || parts[1] == "" {
		return nil, false
	}
	return parts, true
}

// compareSeq orders two of X's sequence ids (decimal numbers too long for some languages), "" first.
func compareSeq(a, b string) int {
	a, b = strings.TrimLeft(a, "0"), strings.TrimLeft(b, "0")
	if len(a) != len(b) {
		return cmp.Compare(len(a), len(b))
	}
	return strings.Compare(a, b)
}

// isDigits is whether [s] is a decimal number, as X's user ids and sequence ids are; false for "".
func isDigits(s string) bool {
	if s == "" {
		return false
	}
	for _, c := range s {
		if c < '0' || c > '9' {
			return false
		}
	}
	return true
}

// ms reads a time X gives as milliseconds in a string; 0 where there is none.
func ms(s string) int64 {
	n, err := strconv.ParseInt(strings.TrimSpace(s), 10, 64)
	if err != nil || n < 0 {
		return 0
	}
	return n
}

// --- people ---------------------------------------------------------------------------------------------------------

// person is what is known of someone on X. Any field but ID may be empty.
type person struct {
	ID     string
	Name   string
	Handle string
	Pic    string // the address of their picture, as X gives it
}

// personOfUser reads a person from the library's user; the empty person for nil.
func personOfUser(u *types.User) person {
	if u == nil {
		return person{}
	}
	return person{
		ID:     u.IDStr,
		Name:   strings.TrimSpace(u.Name),
		Handle: strings.TrimSpace(u.ScreenName),
		Pic:    cmp.Or(u.ProfileImageURLHTTPS, u.ProfileImageURL),
	}
}

// personOfResult reads one of the people an inbox item lists; ID alone where X gave only that.
func personOfResult(r response.XChatUserResult) person {
	id := strings.TrimSpace(r.RestID)
	if r.Result == nil {
		return person{ID: id}
	}
	p := personOfUser(twittermeow.ConvertXChatUserToUser(r.Result))
	p.ID = cmp.Or(id, p.ID)
	return p
}

// peopleOfItem is everyone an inbox item names, in its order, each once.
func peopleOfItem(item *response.XChatInboxItem) []person {
	d := item.ConversationDetail
	var all []response.XChatUserResult
	all = append(all, d.ParticipantsResults...)
	all = append(all, d.GroupMembersResults...)
	all = append(all, d.GroupAdminsResults...)
	index := map[string]int{}
	var out []person
	for _, r := range all {
		p := personOfResult(r)
		if p.ID == "" {
			continue
		}
		if i, ok := index[p.ID]; ok {
			out[i] = merge(out[i], p)
			continue
		}
		index[p.ID] = len(out)
		out = append(out, p)
	}
	return out
}

// merge is what is known of someone from two sightings, the newer one's where both say.
func merge(old, p person) person {
	p.Name = cmp.Or(p.Name, old.Name)
	p.Handle = cmp.Or(p.Handle, old.Handle)
	p.Pic = cmp.Or(p.Pic, old.Pic)
	return p
}

// avatarURL is a picture address at 200 pixels rather than the 48 X lists people with.
func avatarURL(pic string) string {
	if strings.Contains(pic, "_normal.") {
		return strings.Replace(pic, "_normal.", "_200x200.", 1)
	}
	return pic
}

// --- chats ----------------------------------------------------------------------------------------------------------

// memberOut is one of a chat's people other than the person themselves, as the protocol's `chat` lists them.
type memberOut struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

// chatOut is the protocol's `chat`. Avatar is a file's path, null where there is none; Last is in milliseconds.
type chatOut struct {
	ID          string      `json:"id"`
	Title       string      `json:"title"`
	Group       bool        `json:"group"`
	Members     []memberOut `json:"members"`
	Avatar      *string     `json:"avatar"`
	Unread      int         `json:"unread"`
	Last        int64       `json:"last"`
	Snippet     string      `json:"snippet,omitempty"`
	SnippetMine *bool       `json:"snippet_mine,omitempty"`
}

// itemIsGroup is whether an inbox item is a group: by its id, or by X sending group details with it.
func itemIsGroup(item *response.XChatInboxItem) bool {
	d := item.ConversationDetail
	return isGroupChat(d.ConversationID) || d.GroupMetadata != nil || len(d.GroupMembersResults) > 0 || len(d.GroupAdminsResults) > 0
}

// itemTrusted is whether X counts an inbox item as accepted (not a message request), from the newest of its events
// that says; nil where none does.
func itemTrusted(item *response.XChatInboxItem) *bool {
	var encoded []string
	encoded = append(encoded, item.LatestMessageEvents...)
	encoded = append(encoded, item.EncodedMessageEvents...)
	encoded = append(encoded, item.LatestConversationKeyChangeEvents...)
	if item.LatestNotifiableMessageCreateEvent != "" {
		encoded = append(encoded, item.LatestNotifiableMessageCreateEvent)
	}
	var trusted *bool
	newest := ""
	for _, e := range encoded {
		evt, err := twittermeow.DecodeMessageEvent(e)
		if err != nil || evt.IsTrusted == nil {
			continue
		}
		seq := ptr.Val(evt.SequenceId)
		if trusted != nil && compareSeq(seq, newest) < 0 {
			continue
		}
		v := *evt.IsTrusted
		trusted, newest = &v, seq
	}
	return trusted
}

// decryptGroupName opens a group's name: X writes it sealed with the chat's key, "<key version>:<base64>", or plain.
// "" where it cannot be opened, never the sealed bytes.
func decryptGroupName(ctx context.Context, conv, sealed string, keys keyFunc, latest keyFunc) string {
	if sealed == "" {
		return ""
	}
	version, body := "", sealed
	if v, rest, ok := strings.Cut(sealed, ":"); ok && v != "" {
		version, body = v, rest
	}
	raw, err := base64.StdEncoding.DecodeString(body)
	if err != nil {
		raw, err = base64.RawStdEncoding.DecodeString(body)
	}
	// A name that is not base64 of at least a nonce and a tag was never sealed.
	if err != nil || len(raw) < 40 {
		if version == "" {
			return sealed
		}
		return ""
	}
	var k *crypto.ConversationKey
	if version != "" {
		k, err = keys(ctx, conv, version)
	} else if latest != nil {
		k, err = latest(ctx, conv, "")
	} else {
		err = crypto.ErrKeyNotFound
	}
	if err != nil || k == nil || len(k.Key) == 0 {
		return ""
	}
	plain, err := crypto.SecretboxDecrypt(raw, k.Key)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(plain))
}

// inboxSummary is what the events listed with a chat say of it: its newest message, how many of the others'
// messages come after the person's own read mark, and its latest group name (sealed).
type inboxSummary struct {
	latest *types.Message
	unread int
	// The newest message id of the chat, for a read mark with no `upto`.
	newest string
}

// chatOf puts an inbox item into the protocol's `chat`. [who] fills in people X listed by id alone; [avatar] turns a
// person's picture into a file (or "") and is asked only for the other person of a chat between two.
func chatOf(me string, item *response.XChatInboxItem, who func(person) person, groupName string, sum inboxSummary, avatar func(person) string) chatOut {
	id := item.ConversationDetail.ConversationID
	out := chatOut{ID: id, Group: itemIsGroup(item), Members: []memberOut{}}
	people := peopleOfItem(item)
	if !out.Group {
		// X sometimes lists a two-person chat with nobody in it: the id names both.
		if ids, ok := dmMembers(id); ok {
			for _, pid := range ids {
				if !slices.ContainsFunc(people, func(p person) bool { return p.ID == pid }) {
					people = append(people, person{ID: pid})
				}
			}
		}
	}
	var others []person
	for _, p := range people {
		if who != nil {
			p = merge(who(p), p)
		}
		if p.ID == me {
			continue
		}
		others = append(others, p)
		out.Members = append(out.Members, memberOut{ID: p.ID, Name: p.Name})
	}
	out.Title = strings.TrimSpace(groupName)
	if out.Title == "" {
		var names []string
		for _, o := range others {
			if n := cmp.Or(o.Name, o.Handle); n != "" {
				names = append(names, n)
			}
		}
		out.Title = strings.Join(names, ", ")
	}
	if out.Title == "" && len(others) == 0 && who != nil {
		// A chat with oneself (X's notes to self): named after the person.
		self := who(person{ID: me})
		out.Title = cmp.Or(self.Name, self.Handle)
	}
	if !out.Group && len(others) == 1 && avatar != nil {
		if file := avatar(others[0]); file != "" {
			out.Avatar = &file
		}
	}
	out.Unread = sum.unread
	if g := item.ConversationDetail.GroupMetadata; g != nil {
		out.Last = ms(g.UpdatedAtMsec)
	}
	if m := sum.latest; m != nil {
		mine := m.MessageData.SenderID == me
		out.Snippet = messageText(m.MessageData)
		if out.Snippet != "" || mine {
			out.SnippetMine = &mine
		}
		if t := ms(m.Time); t > out.Last {
			out.Last = t
		}
	}
	return out
}

// --- messages -------------------------------------------------------------------------------------------------------

// pointer is what `download` is handed back. A picture, video or voice message of an encrypted chat is named by the
// chat, X's hash of the file and the key version it was sealed with; anything older by its address.
type pointer struct {
	Conv    string `json:"conv,omitempty"`
	Hash    string `json:"hash,omitempty"`
	Version string `json:"key_version,omitempty"`
	URL     string `json:"url,omitempty"`
	Kind    string `json:"kind"`
}

// mediaOut is one file of a message, as the protocol lists it: what `download` needs to fetch it, and what is known
// of it before it is fetched.
type mediaOut struct {
	Pointer pointer `json:"pointer"`
	Mime    string  `json:"mime"`
	Name    string  `json:"name"`
	Size    int64   `json:"size"`
	Width   int     `json:"width"`
	Height  int     `json:"height"`
}

// quoteOut is the message a message answers, and who wrote it where X says (GMFB-44: the app names them).
type quoteOut struct {
	ID   string `json:"id"`
	Text string `json:"text"`
	From string `json:"from,omitempty"`
}

// reactionOut is one person's reaction to a message.
type reactionOut struct {
	From  string `json:"from"`
	Emoji string `json:"emoji"`
}

// messageOut is the protocol's `message`: what `history` lists and the `message` event carries. ID is X's sequence
// id; TS is in milliseconds.
type messageOut struct {
	Chat      string        `json:"chat"`
	Group     bool          `json:"group"`
	ID        string        `json:"id"`
	From      string        `json:"from"`
	Name      string        `json:"name"`
	Mine      bool          `json:"mine"`
	TS        int64         `json:"ts"`
	Text      string        `json:"text"`
	Media     []mediaOut    `json:"media"`
	Quote     *quoteOut     `json:"quote,omitempty"`
	Reactions []reactionOut `json:"reactions,omitempty"`
}

// attachmentsOf is what a message carries: X writes a list, or (its older form) one attachment alone.
func attachmentsOf(msg types.MessageData) []*types.Attachment {
	if len(msg.Attachments) > 0 {
		return msg.Attachments
	}
	if msg.Attachment != nil {
		return []*types.Attachment{msg.Attachment}
	}
	return nil
}

// messageText is a message's words, with the address of a post shared into the chat after them. (A link's card is
// already written into the words by the library.)
func messageText(msg types.MessageData) string {
	text := msg.Text
	for _, a := range attachmentsOf(msg) {
		if a == nil || a.Tweet == nil {
			continue
		}
		if link := a.Tweet.ExpandedURL; link != "" && !strings.Contains(text, link) {
			text = strings.TrimSpace(text + "\n" + link)
		}
	}
	return text
}

// mimeOf is the kind of file a picture, video or voice message is: from its name where that says, else the kind X's
// website makes (X sends voice messages as MP4 files).
func mimeOf(kind, name string) string {
	if ext := strings.ToLower(filepath.Ext(name)); ext != "" {
		if m := mime.TypeByExtension(ext); m != "" {
			m, _, _ = strings.Cut(m, ";")
			return m
		}
	}
	switch kind {
	case "video":
		return "video/mp4"
	case "gif":
		return "image/gif"
	case "audio":
		return "audio/mp4"
	}
	return "image/jpeg"
}

// mediaOf lists the pictures, videos, GIFs and voice messages a message carries, in its order.
func mediaOf(conv string, msg types.MessageData) []mediaOut {
	out := []mediaOut{}
	for _, a := range attachmentsOf(msg) {
		if a == nil {
			continue
		}
		var info *types.AttachmentInfo
		kind := ""
		switch {
		case a.Photo != nil:
			info, kind = a.Photo, "image"
		case a.AnimatedGif != nil:
			info, kind = a.AnimatedGif, "gif"
		case a.Video != nil && a.Video.AudioOnly:
			info, kind = a.Video, "audio"
		case a.Video != nil:
			info, kind = a.Video, "video"
		case a.Media != nil:
			info, kind = a.Media, "image"
		default:
			continue
		}
		m := mediaOut{
			Name:   info.Filename,
			Size:   info.FilesizeBytes,
			Width:  info.OriginalInfo.Width,
			Height: info.OriginalInfo.Height,
		}
		switch {
		case info.MediaHashKey != "":
			m.Pointer = pointer{Conv: conv, Hash: info.MediaHashKey, Version: msg.ConversationKeyVersion, Kind: kind}
		case info.MediaURLHTTPS != "" || info.MediaURL != "":
			m.Pointer = pointer{URL: cmp.Or(info.MediaURLHTTPS, info.MediaURL), Kind: kind}
			if v, err := info.VideoInfo.GetHighestBitrateVariant(); err == nil && v.URL != "" && kind != "image" {
				m.Pointer.URL = v.URL
			}
		default:
			continue
		}
		if m.Name == "" {
			m.Name = map[string]string{"image": "image", "gif": "gif", "video": "video", "audio": "voice_message"}[kind]
		}
		m.Mime = mimeOf(kind, m.Name)
		out = append(out, m)
	}
	return out
}

// messageOf puts a message into the protocol's `message`, in [chat]. [name] gives a sender's name where known.
func messageOf(me, chat string, group bool, msg *types.Message, name func(string) string) messageOut {
	data := msg.MessageData
	id := cmp.Or(msg.SequenceID, msg.ID, data.ID)
	out := messageOut{
		Chat:  chat,
		Group: group,
		ID:    id,
		From:  data.SenderID,
		Mine:  me != "" && data.SenderID == me,
		TS:    ms(cmp.Or(msg.Time, data.Time)),
		Text:  messageText(data),
		Media: mediaOf(chat, data),
	}
	if out.TS == 0 && isDigits(id) {
		out.TS = methods.ParseSnowflake(id).UnixMilli()
	}
	if name != nil {
		out.Name = name(data.SenderID)
	}
	if r := data.ReplyData; r.ID != "" {
		out.Quote = &quoteOut{ID: r.ID, Text: r.Text, From: r.SenderID}
	}
	return out
}

// --- a page of history ----------------------------------------------------------------------------------------------

// decodeEntry opens what a MessageCreateEvent carries: sealed with the chat's key where it names a key version,
// plain otherwise.
func decodeEntry(ctx context.Context, conv string, mce *payload.MessageCreateEvent, keys keyFunc) (*payload.MessageEntryContents, string, error) {
	if mce == nil || len(mce.Contents) == 0 {
		return nil, "", errors.New("empty")
	}
	version := ptr.Val(mce.ConversationKeyVersion)
	if version == "" {
		e, err := crypto.ParseMessageEntryContentsBytes(mce.Contents)
		return e, "", err
	}
	k, err := keys(ctx, conv, version)
	if err != nil {
		return nil, version, err
	}
	if k == nil || len(k.Key) == 0 {
		return nil, version, crypto.ErrKeyNotFound
	}
	e, err := crypto.DecryptMessageEntryContentsBytes(mce.Contents, k.Key)
	return e, version, err
}

// pageResult is a page of a chat's history put into messages: oldest first, with the reactions, edits and take-backs
// on the same page already applied to them.
type pageResult struct {
	messages []messageOut
	// The oldest event id on the page: where the next page begins.
	oldest string
	// How many messages could not be opened (no key here, or not readable).
	unread int
}

// parsePage reads the events of a page of a chat's history. Events at or after [before] (when given) are left out,
// as X may give the anchor again.
func parsePage(ctx context.Context, me, conv string, group bool, encoded []string, before string, keys keyFunc, name func(string) string) pageResult {
	type reactKey struct{ target, from, emoji string }
	var res pageResult
	var msgs []messageOut
	byID := map[string]int{}
	type edit struct {
		seq, text string
	}
	edits := map[string]edit{}
	deleted := map[string]bool{}
	reactions := map[reactKey]string{} // → the seq of the newest add, or "" once removed after it
	var reactOrder []reactKey
	removed := map[reactKey]string{}

	for _, e := range encoded {
		evt, err := twittermeow.DecodeMessageEvent(e)
		if err != nil || evt == nil {
			continue
		}
		if c := ptr.Val(evt.ConversationId); c != "" && normalizeChat(c) != conv {
			continue
		}
		evt.ConversationId = ptr.Ptr(conv)
		seq := ptr.Val(evt.SequenceId)
		if before != "" && seq != "" && compareSeq(seq, before) >= 0 {
			continue
		}
		if seq != "" && (res.oldest == "" || compareSeq(seq, res.oldest) < 0) {
			res.oldest = seq
		}
		if evt.Detail == nil {
			continue
		}
		switch {
		case evt.Detail.MessageDeleteEvent != nil:
			for _, id := range evt.Detail.MessageDeleteEvent.SequenceIds {
				deleted[id] = true
			}
			continue
		case evt.Detail.MessageCreateEvent == nil:
			continue
		}
		entry, version, err := decodeEntry(ctx, conv, evt.Detail.MessageCreateEvent, keys)
		if err != nil || entry == nil {
			res.unread++
			continue
		}
		sender := ptr.Val(evt.SenderId)
		switch {
		case entry.Message != nil && (entry.Message.MessageText != nil || len(entry.Message.Attachments) > 0):
			msg := twittermeow.ConvertXChatMessageContentsToMessage(evt, entry.Message, version)
			if msg == nil {
				continue
			}
			m := messageOf(me, conv, group, msg, name)
			if m.ID == "" {
				continue
			}
			if _, dup := byID[m.ID]; dup {
				continue
			}
			byID[m.ID] = len(msgs)
			msgs = append(msgs, m)
		case entry.ReactionAdd != nil:
			k := reactKey{ptr.Val(entry.ReactionAdd.MessageSequenceId), sender, ptr.Val(entry.ReactionAdd.Emoji)}
			if k.target == "" || k.emoji == "" {
				continue
			}
			if old, ok := reactions[k]; !ok || compareSeq(seq, old) > 0 {
				if !ok {
					reactOrder = append(reactOrder, k)
				}
				reactions[k] = seq
			}
		case entry.ReactionRemove != nil:
			k := reactKey{ptr.Val(entry.ReactionRemove.MessageSequenceId), sender, ptr.Val(entry.ReactionRemove.Emoji)}
			if old := removed[k]; compareSeq(seq, old) > 0 {
				removed[k] = seq
			}
		case entry.MessageEdit != nil:
			target := ptr.Val(entry.MessageEdit.MessageSequenceId)
			if target == "" {
				continue
			}
			if old, ok := edits[target]; !ok || compareSeq(seq, old.seq) > 0 {
				edits[target] = edit{seq: seq, text: ptr.Val(entry.MessageEdit.UpdatedText)}
			}
		}
	}

	for target, e := range edits {
		if i, ok := byID[target]; ok {
			msgs[i].Text = e.text
		}
	}
	for _, k := range reactOrder {
		added := reactions[k]
		if r, ok := removed[k]; ok && compareSeq(r, added) > 0 {
			continue
		}
		if i, ok := byID[k.target]; ok {
			msgs[i].Reactions = append(msgs[i].Reactions, reactionOut{From: k.from, Emoji: k.emoji})
		}
	}
	res.messages = []messageOut{}
	for _, m := range msgs {
		if !deleted[m.ID] {
			res.messages = append(res.messages, m)
		}
	}
	sort.SliceStable(res.messages, func(i, j int) bool {
		if res.messages[i].TS != res.messages[j].TS {
			return res.messages[i].TS < res.messages[j].TS
		}
		return compareSeq(res.messages[i].ID, res.messages[j].ID) < 0
	})
	return res
}

// fields is [v]'s JSON object as a map, for an event to carry beside its "ev".
func fields(v any) map[string]any {
	var m map[string]any
	b, err := json.Marshal(v)
	if err == nil {
		_ = json.Unmarshal(b, &m)
	}
	return m
}
