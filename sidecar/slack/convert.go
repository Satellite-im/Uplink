package main

// What Slack says, put into the protocol's shapes (../ACCOUNT_HELPERS.md). Nothing here reaches the network, so
// all of it is tested with hand-built values (main_test.go).

import (
	"cmp"
	"encoding/json"
	"regexp"
	"strconv"
	"strings"

	"github.com/slack-go/slack"

	"go.mau.fi/mautrix-slack/pkg/emoji"
)

// --- ids ------------------------------------------------------------------------------------------------------------

// A chat's id carries its workspace: "<team>-<channel>", as mautrix-slack names a portal. Slack's own ids are letters
// and digits only, so the dash is never part of one. A person is Slack's user id ("U…", "W…") or, for an app that
// posts without a user, its bot id ("B…"). A message is Slack's own id for it within its channel: its "ts".

// chatID is the id the app knows a channel of workspace [team] by.
func chatID(team, channel string) string { return team + "-" + channel }

// slackIDPattern is the shape of every id Slack gives: a channel, a person, an app, a file.
var slackIDPattern = regexp.MustCompile(`^[A-Z0-9]+$`)

// parseChatID is the channel of chat [id] in workspace [team]. A bare channel id is taken too.
func parseChatID(team, id string) (string, bool) {
	t, ch, ok := strings.Cut(strings.TrimSpace(id), "-")
	if !ok {
		ch, t = t, team
	}
	if t != team || !slackIDPattern.MatchString(ch) {
		return "", false
	}
	return ch, true
}

// tsMillis is a Slack "ts" ("1700000000.000100": seconds, then microseconds) in milliseconds; 0 where it is none.
func tsMillis(ts string) int64 {
	sec, frac, _ := strings.Cut(ts, ".")
	s, err := strconv.ParseInt(sec, 10, 64)
	if err != nil || s <= 0 {
		return 0
	}
	ms := s * 1000
	if len(frac) >= 3 {
		if f, err := strconv.ParseInt(frac[:3], 10, 64); err == nil {
			ms += f
		}
	}
	return ms
}

// inThread is whether [m] is a reply in a thread (not the thread's first message), and the thread's first message.
func inThread(m slack.Msg) (string, bool) {
	if m.ThreadTimestamp != "" && m.ThreadTimestamp != m.Timestamp {
		return m.ThreadTimestamp, true
	}
	return "", false
}

// --- people ---------------------------------------------------------------------------------------------------------

// person is what is known of a member or an app; a field is "" where Slack has not said.
type person struct {
	ID     string
	Name   string
	Handle string
	Pic    string // the address of their picture; Slack's are public
}

// personOfUser reads a member as Slack's own app names them: the display name they chose, else their full name.
func personOfUser(u slack.User) person {
	name := cmp.Or(strings.TrimSpace(u.Profile.DisplayName), strings.TrimSpace(u.Profile.RealName), strings.TrimSpace(u.RealName), u.Name)
	pic := cmp.Or(u.Profile.Image192, u.Profile.Image512, u.Profile.Image72, u.Profile.Image48)
	return person{ID: u.ID, Name: name, Handle: u.Name, Pic: pic}
}

// personOfBot reads an app that posts without a user: its name and icon. An app has no handle.
func personOfBot(b slack.Bot) person {
	return person{ID: b.ID, Name: strings.TrimSpace(b.Name), Pic: cmp.Or(b.Icons.Image72, b.Icons.Image48, b.Icons.Image36)}
}

// senderOf is who sent [m]: its member, else the app that posted it.
func senderOf(m slack.Msg) string {
	return cmp.Or(m.User, m.BotID)
}

// --- words ----------------------------------------------------------------------------------------------------------

// tagPattern finds Slack's markup in a message's text: "<@U…>", "<#C…|name>", "<!here>", "<https://…|words>".
var tagPattern = regexp.MustCompile(`<([^<>]*)>`)

// unescape undoes the three escapes Slack puts on "<", ">" and "&" that are part of the words.
func unescape(s string) string {
	return strings.NewReplacer("&lt;", "<", "&gt;", ">", "&amp;", "&").Replace(s)
}

// plainText turns Slack's markup into words: a mention as "@name", a channel as "#name", a link as its words with
// the address beside, ":shortcode:" as its emoji. Bold and the like (*, _, ~, `) are Slack's marks over the same words
// and are left as written. [user] and [channel] name an id, or "".
func plainText(s string, user, channel func(string) string) string {
	var b strings.Builder
	last := 0
	for _, m := range tagPattern.FindAllStringSubmatchIndex(s, -1) {
		b.WriteString(emoji.ReplaceShortcodesWithUnicode(unescape(s[last:m[0]])))
		b.WriteString(tagText(s[m[2]:m[3]], user, channel))
		last = m[1]
	}
	b.WriteString(emoji.ReplaceShortcodesWithUnicode(unescape(s[last:])))
	return b.String()
}

// tagText is one tag's words, from what stands between its "<" and ">": "target|label", the label optional. A
// mention ("@U…") is "@name", a channel ("#C…") "#name", a special word ("!here", "!subteam^S…|@team") "@here" or
// its label, and anything else a link: its address, or "label (address)" where the label says something else.
func tagText(tag string, user, channel func(string) string) string {
	target, label, _ := strings.Cut(tag, "|")
	label = unescape(label)
	switch {
	case strings.HasPrefix(target, "@"):
		id := target[1:]
		name := ""
		if user != nil {
			name = user(id)
		}
		return "@" + cmp.Or(name, strings.TrimPrefix(label, "@"), id)
	case strings.HasPrefix(target, "#"):
		id := target[1:]
		name := label
		if name == "" && channel != nil {
			name = channel(id)
		}
		return "#" + strings.TrimPrefix(cmp.Or(name, id), "#")
	case strings.HasPrefix(target, "!"):
		word, _, _ := strings.Cut(target[1:], "^")
		switch word {
		case "here", "channel", "everyone":
			return "@" + word
		}
		if label != "" {
			return label
		}
		return "@" + word
	}
	link := unescape(target)
	if label == "" || label == link || "http://"+label == link || "https://"+label == link || "mailto:"+label == link {
		return strings.TrimPrefix(link, "mailto:")
	}
	return label + " (" + link + ")"
}

// --- reactions ------------------------------------------------------------------------------------------------------

// reactionEmoji is the emoji Slack names [name] ("+1", "+1::skin-tone-2"); a workspace's own emoji, which is a
// picture, is given as ":name:".
func reactionEmoji(name string) string {
	if u := emoji.GetUnicode(name); u != "" {
		return u
	}
	return ":" + name + ":"
}

// shortcodePattern is an emoji's name as Slack writes one, with or without its colons, and with a skin tone.
var shortcodePattern = regexp.MustCompile(`^:?([a-z0-9_+'\-]+(?:::skin-tone-[2-6])?):?$`)

// reactionName is Slack's name for [e]: an emoji, or a ":name:" of the workspace's own. "" where it is neither.
func reactionName(e string) string {
	e = strings.TrimSpace(e)
	if name := emoji.GetShortcode(e); name != "" {
		return name
	}
	if m := shortcodePattern.FindStringSubmatch(e); m != nil {
		return m[1]
	}
	return ""
}

// --- chats ----------------------------------------------------------------------------------------------------------

// memberOut is one of a chat's members in a `chat`, the person themself left out.
type memberOut struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

// chatOut is the protocol's `chat`: what `chats` answers with and a `chat` event carries. Avatar is a file's path,
// Last the newest message's time in milliseconds, Snippet that message's words.
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

// counts is what Slack's sidebar knows of a chat: its newest message, and whether anything is unread.
type counts struct {
	Latest   string
	Unreads  bool
	Mentions int
}

// isGroup is whether a chat is anything but a direct message between two.
func isGroup(ch slack.Channel) bool { return !ch.IsIM }

// mpimHandles is who a group DM is with, from its own name ("mpdm-ann--ben--mo-1") where Slack lists no members.
func mpimHandles(name string) []string {
	rest, ok := strings.CutPrefix(name, "mpdm-")
	if !ok {
		return nil
	}
	if i := strings.LastIndex(rest, "-"); i > 0 {
		rest = rest[:i]
	}
	return strings.Split(rest, "--")
}

// view is what the conversion of chats and messages needs to know beyond what it converts.
type view struct {
	team, me string
	person   func(id string) person // "" fields where unknown
	channel  func(id string) string // a channel's name, or ""
	// parent is the words of message [ts] of channel [ch] (a thread's first message), or "".
	parent func(ch, ts string) string
}

// name is the name [id] is known by, or "".
func (v view) name(id string) string {
	if v.person == nil {
		return ""
	}
	return v.person(id).Name
}

// chatOf puts a conversation into the protocol's `chat`. [latest] is its newest message where known; [avatar] makes
// the other person's picture of a chat between two into a file (or "").
func chatOf(v view, ch slack.Channel, c counts, latest *slack.Msg, avatar func(person) string) chatOut {
	out := chatOut{ID: chatID(v.team, ch.ID), Group: isGroup(ch), Members: []memberOut{}}
	switch {
	case ch.IsIM:
		who := person{ID: ch.User}
		if v.person != nil {
			who = v.person(ch.User)
			who.ID = ch.User
		}
		out.Title = cmp.Or(who.Name, who.Handle, ch.User)
		if ch.User != v.me {
			out.Members = append(out.Members, memberOut{ID: ch.User, Name: who.Name})
		}
		if avatar != nil {
			if file := avatar(who); file != "" {
				out.Avatar = &file
			}
		}
	case ch.IsMpIM:
		var names []string
		for _, id := range ch.Members {
			if id == v.me {
				continue
			}
			name := v.name(id)
			out.Members = append(out.Members, memberOut{ID: id, Name: name})
			if name != "" {
				names = append(names, name)
			}
		}
		if len(names) == 0 {
			for _, h := range mpimHandles(ch.Name) {
				if h != "" && (v.person == nil || h != v.person(v.me).Handle) {
					names = append(names, h)
				}
			}
		}
		out.Title = cmp.Or(strings.Join(names, ", "), ch.Name)
	default:
		// A channel's members can be thousands: they are not listed.
		out.Title = "#" + strings.TrimPrefix(cmp.Or(ch.Name, ch.NameNormalized, ch.ID), "#")
	}
	switch {
	case !out.Group && c.Mentions > 0, ch.IsMpIM && c.Mentions > 0:
		// In a direct message every message counts as a mention: that count is the unread one.
		out.Unread = c.Mentions
	case c.Unreads:
		out.Unread = max(1, c.Mentions)
	}
	out.Last = tsMillis(c.Latest)
	if latest != nil {
		mine := senderOf(*latest) == v.me && v.me != ""
		out.Snippet = messageText(v, ch.ID, *latest)
		out.SnippetMine = &mine
		out.Last = max(out.Last, tsMillis(latest.Timestamp))
	}
	return out
}

// --- messages -------------------------------------------------------------------------------------------------------

// pointer is what `download` is handed back: the file's id and the address Slack gave for it. The address stays good
// while the session does; a fresh one is asked of Slack by the id where it does not.
type pointer struct {
	File string `json:"file"`
	URL  string `json:"url,omitempty"`
	Kind string `json:"kind"`
}

// mediaOut is one file of a message: what `download` needs to fetch it, and what the app shows before it has.
type mediaOut struct {
	Pointer pointer `json:"pointer"`
	Mime    string  `json:"mime"`
	Name    string  `json:"name"`
	Size    int64   `json:"size"`
	Width   int     `json:"width"`
	Height  int     `json:"height"`
}

// quoteOut is the message a reply quotes: for Slack, the first message of the thread the reply is in.
type quoteOut struct {
	ID   string `json:"id"`
	Text string `json:"text"`
}

// reactionOut is one person's reaction; Slack's count of an emoji is spread into one of these for each person.
type reactionOut struct {
	From  string `json:"from"`
	Emoji string `json:"emoji"`
}

// messageOut is the protocol's `message`: an entry of `history` and what a `message` event carries. ID is Slack's
// ts, TS the same moment in milliseconds.
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

// shown is whether a message is one to show: not Slack's notes of someone joining or a rename, nor the changes and
// removals it says as messages (those are `edited` and `deleted`).
func shown(m slack.Msg) bool {
	switch m.SubType {
	case "", slack.MsgSubTypeMeMessage, slack.MsgSubTypeBotMessage, slack.MsgSubTypeThreadBroadcast, slack.MsgSubTypeFileShare, "huddle_thread":
		return true
	case slack.MsgSubTypeMessageChanged, slack.MsgSubTypeMessageDeleted, slack.MsgSubTypeMessageReplied,
		slack.MsgSubTypeChannelJoin, slack.MsgSubTypeChannelLeave, slack.MsgSubTypeGroupJoin, slack.MsgSubTypeGroupLeave,
		slack.MsgSubTypeChannelTopic, slack.MsgSubTypeChannelPurpose, slack.MsgSubTypeChannelName,
		slack.MsgSubTypeGroupTopic, slack.MsgSubTypeGroupPurpose, slack.MsgSubTypeGroupName, "tombstone":
		return false
	}
	return !m.Hidden
}

// mentions is everyone a message's words name, to be known before they are put into words.
func mentions(text string) []string {
	var ids []string
	for _, m := range tagPattern.FindAllStringSubmatch(text, -1) {
		target, _, _ := strings.Cut(m[1], "|")
		if id, ok := strings.CutPrefix(target, "@"); ok && id != "" {
			ids = append(ids, id)
		}
	}
	return ids
}

// messageText is a message's words: its text, else what its attachments say (an app's message, a shared message),
// with the address of any file kept outside Slack (a linked Google Drive file, say) beneath.
func messageText(v view, channel string, m slack.Msg) string {
	text := plainText(m.Text, v.name, v.channel)
	if strings.TrimSpace(text) == "" {
		var parts []string
		for _, a := range m.Attachments {
			if s := strings.TrimSpace(cmp.Or(a.Fallback, a.Text, a.Title)); s != "" {
				parts = append(parts, plainText(s, v.name, v.channel))
			}
		}
		text = strings.Join(parts, "\n")
	}
	for _, f := range m.Files {
		if f.IsExternal {
			if link := cmp.Or(f.Permalink, f.URLPrivate); link != "" {
				text = strings.TrimSpace(text + "\n" + link)
			}
		}
	}
	return text
}

// kindOf is the protocol's kind of a file, from its type: image, video, audio, else file.
func kindOf(mime string) string {
	switch {
	case strings.HasPrefix(mime, "image/"):
		return "image"
	case strings.HasPrefix(mime, "video/"):
		return "video"
	case strings.HasPrefix(mime, "audio/"):
		return "audio"
	}
	return "file"
}

// mediaOf lists the files a message carries that Slack keeps (one hidden by the workspace's plan, or deleted, is
// left out; one kept elsewhere is a link in the words).
func mediaOf(m slack.Msg) []mediaOut {
	out := []mediaOut{}
	for _, f := range m.Files {
		if f.ID == "" || f.IsExternal || f.Mode == "tombstone" || f.Mode == "hidden_by_limit" {
			continue
		}
		mime := cmp.Or(f.Mimetype, "application/octet-stream")
		out = append(out, mediaOut{
			Pointer: pointer{File: f.ID, URL: cmp.Or(f.URLPrivateDownload, f.URLPrivate), Kind: kindOf(mime)},
			Mime:    mime,
			Name:    cmp.Or(f.Name, f.Title, "file"),
			Size:    int64(f.Size),
			Width:   f.OriginalW,
			Height:  f.OriginalH,
		})
	}
	return out
}

// messageOf puts a message of [channel] into the protocol's `message`. A reply in a thread quotes the thread's first
// message (README.md, Threads).
func messageOf(v view, channel string, group bool, m slack.Msg) messageOut {
	from := senderOf(m)
	name := v.name(from)
	if m.User == "" {
		// An app's message: the name it posted under.
		if m.BotProfile != nil {
			name = cmp.Or(m.Username, m.BotProfile.Name, name)
		} else {
			name = cmp.Or(m.Username, name)
		}
	}
	out := messageOut{
		Chat:  chatID(v.team, channel),
		Group: group,
		ID:    m.Timestamp,
		From:  from,
		Name:  name,
		Mine:  from != "" && from == v.me,
		TS:    tsMillis(m.Timestamp),
		Text:  messageText(v, channel, m),
		Media: mediaOf(m),
	}
	if root, ok := inThread(m); ok {
		q := &quoteOut{ID: root}
		if v.parent != nil {
			q.Text = v.parent(channel, root)
		}
		out.Quote = q
	}
	for _, r := range m.Reactions {
		e := reactionEmoji(r.Name)
		for _, u := range r.Users {
			out.Reactions = append(out.Reactions, reactionOut{From: u, Emoji: e})
		}
	}
	return out
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
