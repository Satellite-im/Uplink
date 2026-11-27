package main

// What Discord says, put into the protocol's shapes (../ACCOUNT_HELPERS.md). Nothing here reaches the network, so
// all of it is tested with hand-built values (main_test.go).

import (
	"cmp"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/bwmarrin/discordgo"
)

// --- chat ids -------------------------------------------------------------------------------------------------------

// guildPrefix begins the id of a server's channel: "guild:<server id>:<channel id>". A direct message or a group's
// id is Discord's channel id alone. Discord's ids never collide, but the server's is needed beside the channel's
// to ask for it as Discord's own app does.
const guildPrefix = "guild:"

// chatRef is where a chat is on Discord: a channel, and the server it is in ("" for a direct message or a group).
type chatRef struct {
	Guild   string
	Channel string
}

// id is the chat id the app knows the chat by.
func (c chatRef) id() string { return chatID(c.Guild, c.Channel) }

// chatID is the chat id of a channel: the channel's own id, behind guildPrefix and the server's where it is in one.
func chatID(guild, channel string) string {
	if guild == "" {
		return channel
	}
	return guildPrefix + guild + ":" + channel
}

// snowflake is whether [s] is one of Discord's ids: digits only, not too long.
func snowflake(s string) bool {
	if s == "" || len(s) > 20 {
		return false
	}
	_, err := strconv.ParseUint(s, 10, 64)
	return err == nil
}

// parseChat reads a chat id back into where the chat is.
func parseChat(id string) (chatRef, error) {
	if id == "" {
		return chatRef{}, errors.New("no chat was named")
	}
	if rest, ok := strings.CutPrefix(id, guildPrefix); ok {
		guild, channel, _ := strings.Cut(rest, ":")
		if snowflake(guild) && snowflake(channel) {
			return chatRef{Guild: guild, Channel: channel}, nil
		}
	} else if snowflake(id) {
		return chatRef{Channel: id}, nil
	}
	return chatRef{}, fmt.Errorf("%q is not a Discord chat", id)
}

// snowflakeMS is the time inside one of Discord's ids, in ms; 0 for no id.
func snowflakeMS(id string) int64 {
	if !snowflake(id) {
		return 0
	}
	t, err := discordgo.SnowflakeTimestamp(id)
	if err != nil {
		return 0
	}
	return t.UnixMilli()
}

// newer is whether message id [a] is later than [b] (ids grow with time; "" is before everything).
func newer(a, b string) bool {
	if len(a) != len(b) {
		return len(a) > len(b)
	}
	return a > b
}

// --- people ---------------------------------------------------------------------------------------------------------

// person is what is known of someone on Discord; a field is "" where it has not been said.
type person struct {
	ID     string
	Name   string
	Handle string
	// Avatar is the hash Discord names the person's picture by; "" for the default picture.
	Avatar string
}

// personOf reads a Discord user, with their nickname in a server where [member] gives one.
func personOf(u *discordgo.User, member *discordgo.Member) person {
	if u == nil {
		return person{}
	}
	p := person{ID: u.ID, Name: u.DisplayName(), Avatar: u.Avatar}
	if u.Username != "" {
		p.Handle = u.String()
	}
	if member != nil && member.Nick != "" {
		p.Name = member.Nick
	}
	return p
}

// --- chats ----------------------------------------------------------------------------------------------------------

// memberOut is one of a chat's members in a `chat`, the person themself left out.
type memberOut struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

// chatOut is the protocol's `chat`: what `chats` answers with and a `chat` event carries. Avatar is a file's path,
// Last the newest message's time in milliseconds. Discord's channels carry no words of their newest message, so
// Snippet is left empty.
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

// readMark is how far the person has read a channel, as Discord keeps it.
type readMark struct {
	Last     string // the newest message read
	Mentions int    // in a direct message or a group, every unread message counts as one
}

// private is whether [ch] is a direct message or a group: the chats Discord lists first.
func private(ch *discordgo.Channel) bool {
	return ch != nil && (ch.Type == discordgo.ChannelTypeDM || ch.Type == discordgo.ChannelTypeGroupDM)
}

// textChannel is whether [ch] is a server channel that holds messages to read.
func textChannel(ch *discordgo.Channel) bool {
	return ch != nil && (ch.Type == discordgo.ChannelTypeGuildText || ch.Type == discordgo.ChannelTypeGuildNews)
}

// guildTitle is a server channel's title: "Server › #channel".
func guildTitle(guild *discordgo.Guild, ch *discordgo.Channel) string {
	name := "#" + ch.Name
	if guild == nil || guild.Name == "" {
		return name
	}
	return guild.Name + " › " + name
}

// icon says whose picture a chat's avatar is, for [chatOf]'s caller to fetch.
type icon struct {
	URL string // the picture's address at Discord
	Key string // what names its file: who it is and which picture
}

// chatOf puts a channel into the protocol's `chat`. [read] is how far it has been read, where Discord said;
// [avatar] turns a picture into a file (or "").
func chatOf(me string, ch *discordgo.Channel, guild *discordgo.Guild, read *readMark, avatar func(icon) string) chatOut {
	out := chatOut{Members: []memberOut{}, Last: snowflakeMS(ch.LastMessageID)}
	var pic icon
	inGuild := ch.GuildID != "" || guild != nil
	if inGuild {
		gid := cmp.Or(ch.GuildID, guildID(guild))
		out.ID, out.Group, out.Title = chatID(gid, ch.ID), true, guildTitle(guild, ch)
		if guild != nil && guild.Icon != "" {
			pic = icon{URL: discordgo.EndpointGuildIcon(guild.ID, guild.Icon) + "?size=128", Key: "g" + guild.ID + "/" + guild.Icon}
		}
	} else {
		out.ID, out.Group, out.Title = ch.ID, ch.Type == discordgo.ChannelTypeGroupDM, strings.TrimSpace(ch.Name)
		var names []string
		for _, u := range ch.Recipients {
			if u == nil || u.ID == me {
				continue
			}
			p := personOf(u, nil)
			out.Members = append(out.Members, memberOut{ID: p.ID, Name: p.Name})
			names = append(names, p.Name)
			if !out.Group && p.Avatar != "" {
				pic = userIcon(p)
			}
		}
		if out.Title == "" {
			out.Title = strings.Join(names, ", ")
		}
		if out.Group && ch.Icon != "" {
			pic = icon{URL: discordgo.EndpointGroupIcon(ch.ID, ch.Icon) + "?size=128", Key: "c" + ch.ID + "/" + ch.Icon}
		}
	}
	if read != nil && ch.LastMessageID != "" && newer(ch.LastMessageID, read.Last) {
		// A server channel's unread messages are not counted by Discord, only its mentions: 1 says "something new".
		out.Unread = 1
		if !inGuild {
			out.Unread = max(read.Mentions, 1)
		}
	}
	if pic.URL != "" && avatar != nil {
		if p := avatar(pic); p != "" {
			out.Avatar = &p
		}
	}
	return out
}

// guildID is a server's id, "" for none.
func guildID(g *discordgo.Guild) string {
	if g == nil {
		return ""
	}
	return g.ID
}

// userIcon is a person's picture at the size the app shows.
func userIcon(p person) icon {
	if p.Avatar == "" {
		return icon{}
	}
	return icon{URL: discordgo.EndpointUserAvatar(p.ID, p.Avatar) + "?size=128", Key: "u" + p.ID + "/" + p.Avatar}
}

// newestFirst orders private channels as Discord's own list does: the latest message first.
func newestFirst(chans []*discordgo.Channel) []*discordgo.Channel {
	out := slices.Clone(chans)
	slices.SortStableFunc(out, func(a, b *discordgo.Channel) int {
		switch {
		case newer(a.LastMessageID, b.LastMessageID):
			return -1
		case newer(b.LastMessageID, a.LastMessageID):
			return 1
		}
		return 0
	})
	return out
}

// --- messages -------------------------------------------------------------------------------------------------------

// pointer is what `download` is given back: where the file is, and what to ask Discord for a fresh address with
// (attachment addresses are signed and run out after about a day).
type pointer struct {
	URL        string `json:"url"`
	Chat       string `json:"chat,omitempty"`
	Message    string `json:"message,omitempty"`
	Attachment string `json:"attachment,omitempty"`
}

// mediaOut is one file or sticker of a message: what `download` needs to fetch it, and what the app shows before
// it has.
type mediaOut struct {
	Pointer pointer `json:"pointer"`
	Mime    string  `json:"mime"`
	Name    string  `json:"name"`
	Size    int64   `json:"size"`
	Width   int     `json:"width"`
	Height  int     `json:"height"`
}

// quoteOut is the message a reply answers, with what Discord sent along of it: its words, who wrote it, and for one
// with no words what kind of thing its first file is (GMFB-44: a reply to a picture read "A message", and no reply
// said whom it answered). The app says the rest from the message itself where it holds it.
type quoteOut struct {
	ID   string `json:"id"`
	Text string `json:"text,omitempty"`
	From string `json:"from,omitempty"`
	Name string `json:"name,omitempty"`
	Mime string `json:"mime,omitempty"`
}

// quoteOf is the quote of [q], the message a reply in [chat] answers.
func quoteOf(chat string, q *discordgo.Message) *quoteOut {
	out := &quoteOut{ID: q.ID, Text: messageText(q)}
	if q.Author != nil {
		who := personOf(q.Author, q.Member)
		out.From, out.Name = who.ID, who.Name
	}
	if out.Text != "" {
		return out
	}
	// No words of its own: a link's or a bot's card says what it was, else its first file's kind does.
	for _, e := range q.Embeds {
		if e != nil && cmp.Or(e.Title, e.Description) != "" {
			out.Text = cmp.Or(e.Title, e.Description)
			return out
		}
	}
	if media := mediaOf(chat, q); len(media) > 0 {
		out.Mime = cmp.Or(media[0].Mime, "application/octet-stream")
	}
	return out
}

// reactionOut is one person's reaction to a message.
type reactionOut struct {
	From  string `json:"from"`
	Emoji string `json:"emoji"`
}

// messageOut is the protocol's `message`: an entry of `history` and what a `message` event carries. TS is in
// milliseconds.
type messageOut struct {
	Chat      string        `json:"chat"`
	Group     bool          `json:"group"`
	ID        string        `json:"id"`
	From      string        `json:"from"`
	Name      string        `json:"name,omitempty"`
	Mine      bool          `json:"mine"`
	TS        int64         `json:"ts"`
	Text      string        `json:"text"`
	Media     []mediaOut    `json:"media"`
	Quote     *quoteOut     `json:"quote,omitempty"`
	Reactions []reactionOut `json:"reactions,omitempty"`
}

// shown is whether a message is one a person wrote (or a bot's answer), not one of Discord's notes in a channel
// (someone joined, a call, a pin).
func shown(m *discordgo.Message) bool {
	switch m.Type {
	case discordgo.MessageTypeDefault, discordgo.MessageTypeReply, discordgo.MessageTypeChatInputCommand, discordgo.MessageTypeContextMenuCommand:
		return true
	}
	return false
}

// Discord's markup inside a message's words: a server's own emoji (<:name:id>, <a:name:id>) and a mention of a
// person (<@id>, <@!id>).
var (
	customEmoji = regexp.MustCompile(`<a?:([A-Za-z0-9_~]+):[0-9]+>`)
	userMention = regexp.MustCompile(`<@!?([0-9]+)>`)
)

// plainText is a message's words as a person reads them: mentions by name, a server's own emoji by its :name:.
func plainText(content string, mentions []*discordgo.User) string {
	content = customEmoji.ReplaceAllString(content, ":$1:")
	return userMention.ReplaceAllStringFunc(content, func(s string) string {
		id := userMention.FindStringSubmatch(s)[1]
		for _, u := range mentions {
			if u != nil && u.ID == id {
				return "@" + u.DisplayName()
			}
		}
		return s
	})
}

// messageText is what a message says: its words, and a forwarded message's under them.
func messageText(m *discordgo.Message) string {
	text := plainText(m.Content, m.Mentions)
	for _, snap := range m.MessageSnapshots {
		if snap.Message == nil || snap.Message.Content == "" {
			continue
		}
		fwd := "> " + strings.ReplaceAll(plainText(snap.Message.Content, snap.Message.Mentions), "\n", "\n> ")
		text = strings.TrimSpace(text + "\n" + fwd)
	}
	return text
}

// mediaOf is a message's files and stickers. A sticker drawn as an animation of Discord's own (Lottie) has no
// picture to give and is left out.
func mediaOf(chat string, m *discordgo.Message) []mediaOut {
	out := []mediaOut{}
	atts := m.Attachments
	for _, snap := range m.MessageSnapshots {
		if snap.Message != nil {
			atts = append(slices.Clone(atts), snap.Message.Attachments...)
		}
	}
	for _, a := range atts {
		if a == nil || a.URL == "" {
			continue
		}
		mime, _, _ := strings.Cut(a.ContentType, ";")
		out = append(out, mediaOut{
			Pointer: pointer{URL: a.URL, Chat: chat, Message: m.ID, Attachment: a.ID},
			Mime:    strings.TrimSpace(mime),
			Name:    cmp.Or(a.Filename, "file"),
			Size:    int64(a.Size),
			Width:   a.Width,
			Height:  a.Height,
		})
	}
	for _, s := range m.StickerItems {
		if s == nil {
			continue
		}
		mime := "image/png"
		switch s.FormatType {
		case discordgo.StickerFormatTypeLottie:
			continue
		case discordgo.StickerFormatTypeGIF:
			mime = "image/gif"
		}
		out = append(out, mediaOut{Pointer: pointer{URL: s.URL()}, Mime: mime, Name: cmp.Or(s.Name, "sticker"), Width: 160, Height: 160})
	}
	return out
}

// emojiText is a reaction's emoji as the app shows it: the emoji itself, or a server's own one as :name:.
func emojiText(e discordgo.Emoji) string {
	if e.ID != "" {
		return ":" + e.Name + ":"
	}
	return e.Name
}

// messageOf puts a message into the protocol's `message`.
func messageOf(me, chat string, group bool, m *discordgo.Message) messageOut {
	out := messageOut{Chat: chat, Group: group, ID: m.ID, Text: messageText(m), Media: mediaOf(chat, m)}
	if !m.Timestamp.IsZero() {
		out.TS = m.Timestamp.UnixMilli()
	} else {
		out.TS = snowflakeMS(m.ID)
	}
	if m.Author != nil {
		who := personOf(m.Author, m.Member)
		out.From, out.Name, out.Mine = who.ID, who.Name, who.ID == me && me != ""
	}
	if ref := m.MessageReference; ref != nil && ref.Type == discordgo.MessageReferenceTypeDefault && ref.MessageID != "" {
		out.Quote = &quoteOut{ID: ref.MessageID}
		if q := m.ReferencedMessage; q != nil {
			out.Quote = quoteOf(chat, q)
			out.Quote.ID = ref.MessageID
		}
	}
	for _, r := range m.Reactions {
		// Discord says who reacted only as a count, and whether the person themselves is among them.
		if r != nil && r.Me && r.Emoji != nil && me != "" {
			out.Reactions = append(out.Reactions, reactionOut{From: me, Emoji: emojiText(*r.Emoji)})
		}
	}
	return out
}

// mentionsMe is whether a server message is for the person: it names them, or answers one of theirs.
func mentionsMe(me string, m *discordgo.Message) bool {
	if me == "" {
		return false
	}
	for _, u := range m.Mentions {
		if u != nil && u.ID == me {
			return true
		}
	}
	return m.ReferencedMessage != nil && m.ReferencedMessage.Author != nil && m.ReferencedMessage.Author.ID == me
}

// fields is a value as the JSON object an event carries beside "ev".
func fields(v any) map[string]any {
	b, _ := json.Marshal(v)
	m := map[string]any{}
	d := json.NewDecoder(strings.NewReader(string(b)))
	d.UseNumber()
	_ = d.Decode(&m)
	return m
}

// nonce is what Discord's own app sends beside a new message, so the same one is not sent twice: an id made of
// the time alone.
func nonce(now time.Time) string {
	const discordEpoch = 1420070400000
	return strconv.FormatInt((now.UnixMilli()-discordEpoch)<<22, 10)
}
