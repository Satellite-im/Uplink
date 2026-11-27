// The pure part of the Instagram helper: Instagram's threads, messages, reactions and seen marks, as instameow gives
// them, turned into the shapes ../ACCOUNT_HELPERS.md names. Nothing here touches the network or the helper's state, so
// all of it is tested with hand-built values (main_test.go).
package main

import (
	"cmp"
	"fmt"
	"net/url"
	"path"
	"slices"
	"sort"
	"strconv"
	"strings"

	"go.mau.fi/mautrix-meta/pkg/instameow/slidetypes"
	"go.mau.fi/mautrix-meta/pkg/messagix/cookies"
)

// Words for what this helper cannot show. They say where the thing can be seen, since a message is never left empty.
const (
	wordsUnknown  = "Sent something this app can't show yet: open Instagram to see it"
	wordsNoMedia  = "Sent a %s this app could not get: open Instagram to see it"
	wordsViewOnce = "Sent a %s that can only be %s once: open Instagram to see it"
)

// missingCookies names the cookies Instagram needs that [given] lacks, in the library's own order.
func missingCookies(given map[string]string) []string {
	var missing []string
	for _, name := range cookies.IGRequiredCookies {
		if strings.TrimSpace(given[string(name)]) == "" {
			missing = append(missing, string(name))
		}
	}
	return missing
}

// missingCookieWords says which cookies are missing in words a person can act on; "" where none is.
func missingCookieWords(given map[string]string) string {
	missing := missingCookies(given)
	switch len(missing) {
	case 0:
		return ""
	case 1:
		return "The Instagram cookie " + missing[0] + " is missing: copy it from a browser signed in to instagram.com and try again"
	}
	return "These Instagram cookies are missing: " + strings.Join(missing, ", ") + ": copy them from a browser signed in to instagram.com and try again"
}

// cleanCookies keeps the cookies that have a value, trimmed: a pasted value often carries a space or a line end.
func cleanCookies(given map[string]string) map[string]string {
	clean := make(map[string]string, len(given))
	for name, value := range given {
		name, value = strings.TrimSpace(name), strings.TrimSpace(value)
		if name != "" && value != "" {
			clean[name] = value
		}
	}
	return clean
}

// personID is a person's id as the protocol carries it: the number Instagram's messages name their sender by
// (interop_messaging_user_fbid), not the profile's own id. "" for none.
func personID(fbid int64) string {
	if fbid == 0 {
		return ""
	}
	return strconv.FormatInt(fbid, 10)
}

// parsePersonID reads a person's id back into Instagram's number; 0 where it is not one.
func parsePersonID(id string) int64 {
	n, _ := strconv.ParseInt(strings.TrimSpace(id), 10, 64)
	return n
}

// userName is what to call a person: their full name, else their username; "" for nobody.
func userName(u *slidetypes.User) string {
	if u == nil {
		return ""
	}
	return cmp.Or(u.FullName, u.Username)
}

// messageID is the id Instagram's own requests and events name a message by.
func messageID(m *slidetypes.Message) string {
	return cmp.Or(m.ID, m.MessageID)
}

// isGroup is true for a thread of more than two: Instagram's own flag, or more than one other person.
func isGroup(t *slidetypes.ThreadInfo) bool {
	return t.IsGroup || len(t.Users) > 1
}

// threadTitle is a group's name, or the other person's for two. A group nobody named is called by its people.
func threadTitle(t *slidetypes.ThreadInfo) string {
	if !isGroup(t) {
		if len(t.Users) == 1 {
			return cmp.Or(userName(t.Users[0]), t.ThreadTitle)
		}
		// Nobody else in it: the person's notes to themselves.
		return cmp.Or(t.ThreadTitle, userName(t.Viewer))
	}
	if t.ThreadTitle != "" {
		return t.ThreadTitle
	}
	var names []string
	for _, u := range t.Users {
		if n := userName(u); n != "" {
			names = append(names, n)
		}
	}
	return strings.Join(names, ", ")
}

// threadAvatarURL is where the thread's picture is: the group's own, or the other person's for two.
func threadAvatarURL(t *slidetypes.ThreadInfo) string {
	if isGroup(t) {
		return t.ThreadImageURL
	}
	if len(t.Users) == 1 && t.Users[0] != nil {
		return t.Users[0].ProfilePicURL
	}
	return ""
}

// newest is the thread's latest listed message that this helper shows, or nil.
func newest(t *slidetypes.ThreadInfo) *slidetypes.Message {
	if t.SlideMessages == nil {
		return nil
	}
	var latest *slidetypes.Message
	for _, edge := range t.SlideMessages.Edges {
		m := edge.Node
		if m == nil || render(m).skip {
			continue
		}
		if latest == nil || m.TimestampMS.After(latest.TimestampMS.Time) {
			latest = m
		}
	}
	return latest
}

// unreadCount counts the listed messages from others that are newer than the person's own seen mark. Instagram lists
// only a thread's last few messages in the inbox, so the count stops there. A thread marked unread by hand counts one.
func unreadCount(t *slidetypes.ThreadInfo, me int64) int {
	count := 0
	for _, rr := range t.SlideReadReceipts {
		if rr.ParticipantFBID != me || t.SlideMessages == nil {
			continue
		}
		for _, edge := range t.SlideMessages.Edges {
			m := edge.Node
			if m != nil && m.SenderFBID != me && m.TimestampMS.After(rr.WatermarkTimestampMS.Time) && !render(m).skip {
				count++
			}
		}
		break
	}
	if count == 0 && t.MarkedAsUnread {
		count = 1
	}
	return count
}

// chatShape is a thread as a `chat` event carries it. [avatar] is a file under avatars/, or "" for none yet.
func chatShape(t *slidetypes.ThreadInfo, me int64, avatar string) map[string]any {
	members := make([]map[string]any, 0, len(t.Users))
	for _, u := range t.Users {
		if u == nil || u.InteropMessagingUserFBID == 0 {
			continue
		}
		members = append(members, map[string]any{"id": personID(u.InteropMessagingUserFBID), "name": userName(u)})
	}
	chat := map[string]any{
		"id":      t.ID,
		"title":   threadTitle(t),
		"group":   isGroup(t),
		"members": members,
		"avatar":  nullable(avatar),
		"unread":  unreadCount(t, me),
		"last":    ms(t.LastActivityTimestampMS.UnixMilli()),
	}
	if m := newest(t); m != nil {
		r := render(m)
		snippet := r.text
		if snippet == "" {
			snippet = cmp.Or(m.IGDSnippet, mediaWords(r.media))
		}
		chat["snippet"] = snippet
		chat["snippet_mine"] = m.SenderFBID == me && me != 0
	}
	return chat
}

// ms keeps a time that was never set (the zero time's huge negative count) out of the protocol.
func ms(unixMilli int64) int64 {
	if unixMilli < 0 {
		return 0
	}
	return unixMilli
}

// nullable is [s], or JSON's null where it is empty.
func nullable(s string) any {
	if s == "" {
		return nil
	}
	return s
}

// mediaWords are a snippet's words for a message that is only a picture, video or sound.
func mediaWords(media []map[string]any) string {
	if len(media) == 0 {
		return ""
	}
	mime, _ := media[0]["mime"].(string)
	switch strings.Split(mime, "/")[0] {
	case "video":
		return "Video"
	case "audio":
		return "Voice message"
	}
	return "Photo"
}

// rendered is a message's words and files as the protocol carries them. skip is true for the notices Instagram writes
// into a thread itself ("X named the group"), which are not messages from anybody.
type rendered struct {
	text  string
	media []map[string]any
	skip  bool
}

// mimeFor reads a file's type from its address where the address ends in one, and otherwise says the usual type for
// its [kind] ("image", "video", "audio"): Instagram does not name the type beside the address.
func mimeFor(address, kind string) string {
	ext := ""
	if u, err := url.Parse(address); err == nil {
		ext = strings.ToLower(path.Ext(u.Path))
	}
	switch ext {
	case ".jpg", ".jpeg":
		return "image/jpeg"
	case ".png":
		return "image/png"
	case ".webp":
		return "image/webp"
	case ".gif":
		return "image/gif"
	case ".heic":
		return "image/heic"
	case ".mp4", ".m4v":
		if kind == "audio" {
			return "audio/mp4"
		}
		return "video/mp4"
	case ".mov":
		return "video/quicktime"
	case ".webm":
		return "video/webm"
	case ".m4a", ".aac":
		return "audio/mp4"
	case ".mp3":
		return "audio/mpeg"
	case ".ogg", ".opus":
		return "audio/ogg"
	case ".wav":
		return "audio/wav"
	}
	switch kind {
	case "video":
		return "video/mp4"
	case "audio":
		return "audio/mp4"
	}
	return "image/jpeg"
}

// mediaItem is one file of a message. The pointer is given back to `download` as it is; Instagram's media addresses
// are signed and need no cookies, but they stop working after a while (a later `history` gives fresh ones).
func mediaItem(address, kind, name string, width, height int) map[string]any {
	mime := mimeFor(address, kind)
	if name == "" {
		if u, err := url.Parse(address); err == nil {
			name = path.Base(u.Path)
		}
		if name == "" || name == "." || name == "/" {
			name = kind
		}
	}
	item := map[string]any{
		"pointer": map[string]any{"url": address, "mime": mime},
		"mime":    mime,
		"name":    name,
	}
	if width > 0 && height > 0 {
		item["width"] = width
		item["height"] = height
	}
	return item
}

// attachmentKind is whether an attachment is a "video" or an "image": by what Instagram calls it, else by the
// ending of its address, else [fallback].
func attachmentKind(att *slidetypes.Attachment, fallback string) string {
	if att.DashManifest != "" || strings.Contains(att.Typename, "Video") {
		return "video"
	}
	if u, err := url.Parse(cmp.Or(att.AttachmentCDNURL, att.PreviewCDNURL)); err == nil {
		switch strings.ToLower(path.Ext(u.Path)) {
		case ".mp4", ".mov", ".m4v", ".webm":
			return "video"
		case ".jpg", ".jpeg", ".png", ".webp", ".gif", ".heic":
			return "image"
		}
	}
	return fallback
}

// noun is what a kind of media is called in the words for one this app cannot show.
func noun(kind string) string {
	switch kind {
	case "video":
		return "video"
	case "audio":
		return "voice message"
	}
	return "photo"
}

// attachments turns Instagram's pictures and videos into media, and says so in words for any it gave no address for.
func attachments(list []*slidetypes.Attachment, fallback string) rendered {
	var r rendered
	for _, att := range list {
		if att == nil {
			continue
		}
		kind := attachmentKind(att, fallback)
		// As the bridge does: the file itself, or its preview where Instagram gave only that.
		address := cmp.Or(att.AttachmentCDNURL, att.PreviewCDNURL)
		if address == "" {
			r.text = fmt.Sprintf(wordsNoMedia, noun(kind))
			continue
		}
		r.media = append(r.media, mediaItem(address, kind, "", att.PreviewWidth, att.PreviewHeight))
	}
	if len(r.media) == 0 && r.text == "" {
		r.text = fmt.Sprintf(wordsNoMedia, noun(fallback))
	}
	return r
}

// unshim undoes Instagram's and Facebook's link wrapper (l.instagram.com/?u=…) and completes a link given without
// its host, so the link shown is the one the sender shared.
func unshim(target string) string {
	target = strings.TrimSpace(target)
	if target == "" {
		return ""
	}
	if strings.HasPrefix(target, "/") && !strings.HasPrefix(target, "//") {
		return "https://www.instagram.com" + target
	}
	u, err := url.Parse(target)
	if err != nil {
		return target
	}
	if u.Host == "l.facebook.com" || u.Host == "l.instagram.com" {
		if real := u.Query().Get("u"); real != "" {
			return real
		}
	}
	return target
}

// sharedWhat names what a shared link points at, from the shape of Instagram's own addresses.
func sharedWhat(link string) string {
	u, err := url.Parse(link)
	if err != nil || !strings.HasSuffix(u.Hostname(), "instagram.com") {
		return "a link"
	}
	p := u.Path
	switch {
	case strings.Contains(p, "/reel/") || strings.Contains(p, "/reels/"):
		return "a reel"
	case strings.Contains(p, "/stories/"):
		return "a story"
	case strings.Contains(p, "/p/") || strings.Contains(p, "/tv/"):
		return "a post"
	case strings.Trim(p, "/") != "" && !strings.Contains(strings.Trim(p, "/"), "/"):
		return "a profile"
	}
	return "a link"
}

// shared renders a shared post, reel, story or link (Instagram calls these XMA). It always has words: "Shared a post:
// <link>" where the link is known, the card's title where only that is, and the sender's own words after them.
func shared(c *slidetypes.MessageContentXMA) rendered {
	x := c.XMA
	// A plain link the sender typed, with a preview card: their words are the message.
	if c.XMATextBody != "" && (x == nil || x.TargetID == "") {
		return rendered{text: c.XMATextBody}
	}
	if x == nil {
		return rendered{text: wordsUnknown}
	}
	var r rendered
	link := unshim(x.TargetURL)
	title := cmp.Or(x.TitleText, x.XMATitle, x.HeaderTitleText)
	switch {
	case link != "":
		r.text = "Shared " + sharedWhat(link) + ": " + link
	case title != "":
		r.text = "Shared from Instagram: " + title
	default:
		r.text = "Shared something from Instagram: open Instagram to see it"
	}
	if c.XMATextBody != "" {
		r.text += "\n" + c.XMATextBody
	}
	if img := cmp.Or(x.PreviewImage, x.XMAPreviewImage); img != nil && img.URL != "" {
		r.media = append(r.media, mediaItem(img.URL, "image", "", img.Width, img.Height))
	}
	return r
}

// viewOnce renders a picture or video sent to be seen once or twice. Those are not fetched here: seeing one is an act
// Instagram counts, and it belongs to the person in Instagram's own app.
func viewOnce(c *slidetypes.MessageContentRavenImage, kind string) rendered {
	if how := c.ViewMode.ViewType(); how != "" {
		return rendered{text: fmt.Sprintf(wordsViewOnce, noun(kind), how)}
	}
	if c.Attachment == nil {
		return rendered{text: fmt.Sprintf(wordsNoMedia, noun(kind))}
	}
	return attachments([]*slidetypes.Attachment{c.Attachment}, kind)
}

// render reads a message's words and files, by the kind of content Instagram says it is (as the bridge's
// msgconv/igconv does).
func render(m *slidetypes.Message) rendered {
	var r rendered
	switch c := m.Content.Content.(type) {
	case *slidetypes.MessageContentText:
		r.text = cmp.Or(c.TextBody, m.TextBody)
	case *slidetypes.MessageContentAdminText:
		var words strings.Builder
		for _, f := range c.TextFragments {
			words.WriteString(f.Plaintext)
		}
		r.text = cmp.Or(words.String(), m.IGDSnippet)
		// Only a call's notice is a message to show; the rest are Instagram's own lines about the thread.
		r.skip = m.ContentType != "IG_VIDEO_CALL_XMAT"
	case *slidetypes.MessageContentImage:
		r = attachments(c.Attachments, "image")
	case *slidetypes.MessageContentVideo:
		r = attachments(c.Videos, "video")
	case *slidetypes.MessageContentMultiMedia:
		r = attachments(c.Attachments, "image")
	case *slidetypes.MessageContentAudio:
		for _, att := range c.AudioAttachments {
			if att != nil && att.AttachmentCDNURL != "" {
				r.media = append(r.media, mediaItem(att.AttachmentCDNURL, "audio", "", 0, 0))
			}
		}
		if len(r.media) == 0 {
			r.text = fmt.Sprintf(wordsNoMedia, noun("audio"))
		}
	case *slidetypes.MessageContentAnimatedMedia:
		for _, att := range c.AnimatedMedia {
			if att == nil {
				continue
			}
			// As the bridge chooses: a sticker's still-or-moving WebP, else a GIF's video, else its preview.
			switch {
			case att.AttachmentWebpURL != "" && (att.IsSticker || att.AttachmentMP4URL == ""):
				item := mediaItem(att.AttachmentWebpURL, "image", att.AltText, att.PreviewWidth, att.PreviewHeight)
				item["mime"] = "image/webp"
				item["pointer"].(map[string]any)["mime"] = "image/webp"
				r.media = append(r.media, item)
			case att.AttachmentMP4URL != "":
				r.media = append(r.media, mediaItem(att.AttachmentMP4URL, "video", "", att.PreviewWidth, att.PreviewHeight))
			case att.PreviewCDNURL != "":
				r.media = append(r.media, mediaItem(att.PreviewCDNURL, "image", "", att.PreviewWidth, att.PreviewHeight))
			}
		}
		if len(r.media) == 0 {
			r.text = "Sent a GIF this app could not get: open Instagram to see it"
		}
	case *slidetypes.MessageContentRavenImage:
		r = viewOnce(c, "image")
	case *slidetypes.MessageContentRavenVideo:
		r = viewOnce((*slidetypes.MessageContentRavenImage)(c), "video")
	case *slidetypes.MessageContentSticker:
		if c.PreviewURL != "" {
			r.media = append(r.media, mediaItem(c.PreviewURL, "image", c.AltText, c.PreviewWidth, c.PreviewHeight))
		} else {
			r.text = "Sent a sticker"
		}
	case *slidetypes.MessageContentMusicSticker:
		song := c.AudioTrack.Title
		if song != "" && c.AudioTrack.DisplayArtist != "" {
			song += " by " + c.AudioTrack.DisplayArtist
		}
		r.text = "Shared a song"
		if song != "" {
			r.text += ": " + song
		}
		if link := unshim(c.AttributionLink); link != "" {
			r.text += "\n" + link
		}
	case *slidetypes.MessageContentXMA:
		r = shared(c)
	case *slidetypes.MessageContentAIRichResponse:
		r.text = c.UnifiedResponse
	case *slidetypes.MessageContentAISearchResponse:
		r.text = c.MessageTextBody
	default:
		// Content Instagram named a kind for that the library does not know, or none at all: its own words where it
		// sent any (the text beside the content, or the inbox's line for it).
		r.text = cmp.Or(m.TextBody, m.IGDSnippet)
	}
	if r.text == "" && len(r.media) == 0 {
		r.text = cmp.Or(m.TextBody, m.IGDSnippet, wordsUnknown)
	}
	return r
}

// messageShape is a message as a `message` event (and `history`) carries it; ok is false for one of Instagram's own
// notices. [nameOf] gives a sender's name where the message itself does not carry it; it may be nil.
func messageShape(chat string, group bool, m *slidetypes.Message, me int64, nameOf func(int64) string) (shape map[string]any, ok bool) {
	if m == nil {
		return nil, false
	}
	r := render(m)
	if r.skip {
		return nil, false
	}
	name := ""
	if m.Sender != nil {
		name = cmp.Or(userName(&m.Sender.UserDict), m.Sender.Name)
	}
	if name == "" && nameOf != nil {
		name = nameOf(m.SenderFBID)
	}
	media := r.media
	if media == nil {
		media = []map[string]any{}
	}
	shape = map[string]any{
		"chat":  chat,
		"group": group,
		"id":    messageID(m),
		"from":  personID(m.SenderFBID),
		"name":  name,
		"mine":  me != 0 && m.SenderFBID == me,
		"ts":    ms(m.TimestampMS.UnixMilli()),
		"text":  r.text,
		"media": media,
	}
	if m.RepliedToMessageID != "" {
		quote := map[string]any{"id": m.RepliedToMessageID, "text": ""}
		if q := m.RepliedToMessage; q != nil {
			qr := render(q)
			quote["text"] = cmp.Or(qr.text, q.IGDSnippet, mediaWords(qr.media))
			// Who wrote the one answered: the app names them over the quote (GMFB-44).
			if from := personID(q.SenderFBID); from != "" {
				quote["from"] = from
			}
		}
		shape["quote"] = quote
	}
	// Not in the shared protocol: the reactions a message already has, which `history` would otherwise lose.
	if len(m.Reactions) > 0 {
		reactions := make([]map[string]any, 0, len(m.Reactions))
		for _, react := range m.Reactions {
			if react == nil || react.Reaction == "" {
				continue
			}
			reactions = append(reactions, map[string]any{
				"from": personID(react.SenderFBID), "emoji": react.Reaction, "mine": me != 0 && react.SenderFBID == me,
			})
		}
		if len(reactions) > 0 {
			shape["reactions"] = reactions
		}
	}
	return shape, true
}

// historyShape is a page of a thread, oldest first, without Instagram's own notices.
func historyShape(chat string, group bool, edges []slidetypes.Node[*slidetypes.Message], me int64, nameOf func(int64) string) []map[string]any {
	list := make([]map[string]any, 0, len(edges))
	for _, edge := range edges {
		if shape, ok := messageShape(chat, group, edge.Node, me, nameOf); ok {
			list = append(list, shape)
		}
	}
	sort.SliceStable(list, func(i, j int) bool { return list[i]["ts"].(int64) < list[j]["ts"].(int64) })
	return list
}

// reactionShape is a reaction put on, or taken off, the message [target].
func reactionShape(chat, target string, from int64, emoji string, remove bool) map[string]any {
	return map[string]any{"chat": chat, "from": personID(from), "target": target, "emoji": emoji, "remove": remove}
}

// seen is one message the helper has met in a thread: enough to turn Instagram's seen marks, which are times, into the
// message ids the protocol names.
type seen struct {
	id string
	ts int64
}

// noteSeen keeps [list] in time order with [s] in it, and no longer than the last few hundred.
func noteSeen(list []seen, s seen) []seen {
	if s.id == "" {
		return list
	}
	if slices.ContainsFunc(list, func(o seen) bool { return o.id == s.id }) {
		return list
	}
	at := sort.Search(len(list), func(i int) bool { return list[i].ts > s.ts })
	list = slices.Insert(list, at, s)
	if len(list) > 400 {
		list = slices.Clone(list[len(list)-400:])
	}
	return list
}

// readUpTo is the newest known message at or before [watermark] (ms); "" where the helper has met none.
func readUpTo(list []seen, watermark int64) string {
	at := sort.Search(len(list), func(i int) bool { return list[i].ts > watermark })
	if at == 0 {
		return ""
	}
	return list[at-1].id
}

// receiptShape is a seen mark. Instagram says only the time someone has read up to; `id` is the newest message known
// at or before it (empty where the helper has met none of the thread yet) and `ts` the time itself.
func receiptShape(chat string, from int64, list []seen, watermark int64) map[string]any {
	return map[string]any{"chat": chat, "from": personID(from), "id": readUpTo(list, watermark), "kind": "read", "ts": ms(watermark)}
}

// nameShape is a person as a `name` event and `who` carry them.
func nameShape(u *slidetypes.User, avatar string) map[string]any {
	return map[string]any{
		"id": personID(u.InteropMessagingUserFBID), "name": userName(u), "handle": u.Username, "avatar": nullable(avatar),
	}
}
