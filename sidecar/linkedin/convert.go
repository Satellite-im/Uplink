package main

// What LinkedIn says, put into the protocol's shapes (../ACCOUNT_HELPERS.md). Nothing here reaches the network, so
// all of it is tested with hand-built values (main_test.go).

import (
	"encoding/json"
	"fmt"
	"net/url"
	"slices"
	"strings"

	"go.mau.fi/mautrix-linkedin/pkg/linkedingo"
)

// participantPrefix begins the id LinkedIn's messaging gives a member. The person's own id is written the same way,
// so the app can compare `me` with a message's `from`.
const participantPrefix = "urn:li:msg_messagingParticipant:urn:li:fsd_profile:"

// urnText is [u] as a string, and "" for one LinkedIn left out (whose String would be a lone colon).
func urnText(u linkedingo.URN) string {
	if u.IsEmpty() {
		return ""
	}
	return u.String()
}

// isMine is whether [p] is the signed-in person. LinkedIn names one member under several prefixes (fs_miniProfile
// in the profile, fsd_profile in messaging); the last part is the same in all of them, and is what [me] holds.
func isMine(me string, p linkedingo.MessagingParticipant) bool {
	return me != "" && p.EntityURN.ID() == me
}

// person is what is known of someone on LinkedIn. ID is their messaging URN; Pic, where there is one, is their
// picture in the sizes LinkedIn keeps.
type person struct {
	ID     string
	Name   string
	Handle string
	Pic    *linkedingo.VectorImage
}

// personOf reads a member, a company page, or one of LinkedIn's own senders (sponsored mail, its assistant).
func personOf(p linkedingo.MessagingParticipant) person {
	out := person{ID: urnText(p.EntityURN)}
	switch t := p.ParticipantType; {
	case t.Member != nil:
		out.Name = strings.TrimSpace(t.Member.FirstName.Text + " " + t.Member.LastName.Text)
		out.Handle = handleFromProfileURL(t.Member.ProfileURL, p.EntityURN.ID())
		out.Pic = t.Member.ProfilePicture
	case t.Organization != nil:
		out.Name = strings.TrimSpace(t.Organization.Name.Text)
		out.Pic = t.Organization.Logo
	case t.Custom != nil:
		out.Name = strings.TrimSpace(t.Custom.Name.Text)
		out.Pic = t.Custom.Image
	case t.Agent != nil:
		out.Name = strings.TrimSpace(t.Agent.Name.Text)
		out.Pic = t.Agent.ProfilePicture
	}
	return out
}

// handleFromProfileURL is the name in linkedin.com/in/<name>. Where LinkedIn gives the address by the member's id
// instead, there is no username to show and the handle is empty.
func handleFromProfileURL(profileURL, id string) string {
	u, err := url.Parse(profileURL)
	if err != nil {
		return ""
	}
	rest, ok := strings.CutPrefix(u.Path, "/in/")
	if !ok {
		return ""
	}
	handle := strings.Trim(rest, "/")
	if handle == id || strings.Contains(handle, "/") {
		return ""
	}
	return handle
}

// memberOut is one of a chat's members in a `chat`, the person themself left out.
type memberOut struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

// chatOut is the protocol's `chat`: what `chats` answers with and a `chat` event carries. Avatar is a file's path,
// Last the newest activity's time in milliseconds, Snippet the newest message's words.
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

// listed is whether a conversation belongs in the inbox the app shows: not spam, and, where LinkedIn says which
// folders it is in, in the inbox (archived and "other" ones are left to the website).
func listed(conv linkedingo.Conversation) bool {
	if conv.EntityURN.IsEmpty() || slices.Contains(conv.Categories, "SPAM") {
		return false
	}
	return len(conv.Categories) == 0 || slices.Contains(conv.Categories, "INBOX") || slices.Contains(conv.Categories, "PRIMARY_INBOX")
}

// chatOf puts a conversation into the protocol's `chat`. [avatar] turns a person's picture into a file (or ""); it
// is asked only for the other person of a chat between two.
func chatOf(me string, conv linkedingo.Conversation, avatar func(person) string) chatOut {
	out := chatOut{ID: urnText(conv.EntityURN), Title: strings.TrimSpace(conv.Title), Group: conv.GroupChat, Members: []memberOut{}}
	var others []person
	for _, p := range conv.ConversationParticipants {
		if isMine(me, p) {
			continue
		}
		who := personOf(p)
		others = append(others, who)
		out.Members = append(out.Members, memberOut{ID: who.ID, Name: who.Name})
	}
	if out.Title == "" {
		var names []string
		for _, o := range others {
			if o.Name != "" {
				names = append(names, o.Name)
			}
		}
		out.Title = strings.Join(names, ", ")
	}
	if !conv.GroupChat && len(others) == 1 && avatar != nil {
		if file := avatar(others[0]); file != "" {
			out.Avatar = &file
		}
	}
	// LinkedIn says only whether a conversation is read, not how many messages are not: one stands for "some".
	if !conv.Read {
		out.Unread = 1
	}
	if !conv.LastActivityAt.IsZero() {
		out.Last = conv.LastActivityAt.UnixMilli()
	}
	var newest *linkedingo.Message
	for i, m := range conv.Messages.Elements {
		if m.MessageBodyRenderFormat == linkedingo.MessageBodyRenderFormatRecalled || m.MessageBodyRenderFormat == linkedingo.MessageBodyRenderFormatSystem {
			continue
		}
		if newest == nil || m.DeliveredAt.After(newest.DeliveredAt.Time) {
			newest = &conv.Messages.Elements[i]
		}
	}
	if newest != nil {
		mine := isMine(me, newest.Sender)
		out.Snippet = messageText(*newest)
		out.SnippetMine = &mine
		if out.Last == 0 && !newest.DeliveredAt.IsZero() {
			out.Last = newest.DeliveredAt.UnixMilli()
		}
	}
	return out
}

// pointer is what `download` is handed back: where LinkedIn keeps the file. The addresses are signed and run out
// (`expires`, ms, where LinkedIn says when); asking the chat's history again gives fresh ones.
type pointer struct {
	URL     string `json:"url"`
	Kind    string `json:"kind"`
	Expires int64  `json:"expires,omitempty"`
}

// mediaOut is one thing a message carries: what `download` needs to fetch it, and what the app shows before it has.
type mediaOut struct {
	Pointer pointer `json:"pointer"`
	Mime    string  `json:"mime"`
	Name    string  `json:"name"`
	Size    int64   `json:"size"`
	Width   int     `json:"width"`
	Height  int     `json:"height"`
}

// quoteOut is the message a reply answers, with its words.
type quoteOut struct {
	ID   string `json:"id"`
	Text string `json:"text"`
}

// messageOut is the protocol's `message`: an entry of `history` and what a `message` event carries. TS is when it
// was delivered, in milliseconds. Reactions are not listed: they reach the app as `reaction` events alone.
type messageOut struct {
	Chat  string     `json:"chat"`
	Group bool       `json:"group"`
	ID    string     `json:"id"`
	From  string     `json:"from"`
	Name  string     `json:"name"`
	Mine  bool       `json:"mine"`
	TS    int64      `json:"ts"`
	Text  string     `json:"text"`
	Media []mediaOut `json:"media"`
	Quote *quoteOut  `json:"quote,omitempty"`
}

// feedUpdateLink is the address of a post shared into a chat, from
// "urn:li:fsd_update:(urn:li:activity:<id>,MESSAGING_RESHARE,…)".
func feedUpdateLink(host linkedingo.URN) string {
	s := host.String()
	open := strings.Index(s, "(")
	if open < 0 {
		return ""
	}
	inner := s[open+1:]
	comma := strings.Index(inner, ",")
	if comma <= 0 {
		return ""
	}
	return "https://www.linkedin.com/feed/update/" + inner[:comma]
}

// messageText is a message's words: an InMail's subject over its body, a forwarded message quoted beneath, and a
// shared post as its address. Bold, links and mentions are LinkedIn's marks over the same text and are left off.
func messageText(msg linkedingo.Message) string {
	var parts []string
	if s := strings.TrimSpace(msg.Subject); s != "" {
		parts = append(parts, s)
	}
	if msg.Body.Text != "" {
		parts = append(parts, msg.Body.Text)
	}
	text := strings.Join(parts, "\n\n")
	for _, rc := range msg.RenderContent {
		switch {
		case rc.ForwardedMessage != nil:
			lines := []string{}
			if from := personOf(rc.ForwardedMessage.OriginalSender).Name; from != "" {
				lines = append(lines, "> "+from+":")
			}
			for _, l := range strings.Split(rc.ForwardedMessage.ForwardedBody.Text, "\n") {
				lines = append(lines, "> "+l)
			}
			if foot := rc.ForwardedMessage.FooterText.Text; foot != "" {
				lines = append(lines, foot)
			}
			text = strings.TrimPrefix(text+"\n"+strings.Join(lines, "\n"), "\n")
		case rc.HostURNData != nil && rc.HostURNData.Type == "FEED_UPDATE":
			if link := feedUpdateLink(rc.HostURNData.HostURN); link != "" {
				text = strings.TrimSpace(text + " " + link)
			}
		}
	}
	return text
}

// mediaOf lists what a message carries. A picture's and a voice message's kind of file LinkedIn says only when the
// file is asked for: `mime` is left empty here for the caller to find out (fillMedia).
func mediaOf(msg linkedingo.Message) []mediaOut {
	out := []mediaOut{}
	for _, rc := range msg.RenderContent {
		switch {
		case rc.Audio != nil && rc.Audio.URL != "":
			out = append(out, mediaOut{Pointer: pointer{URL: rc.Audio.URL, Kind: "audio"}, Name: "voice_message"})
		case rc.ExternalMedia != nil && rc.ExternalMedia.Media.URL != "":
			// A GIF from LinkedIn's picker.
			m := rc.ExternalMedia
			out = append(out, mediaOut{Pointer: pointer{URL: m.Media.URL, Kind: "gif"}, Mime: "image/gif", Name: m.Title, Width: m.Media.OriginalWidth, Height: m.Media.OriginalHeight})
		case rc.File != nil && rc.File.URL != "":
			f := rc.File
			out = append(out, mediaOut{Pointer: pointer{URL: f.URL, Kind: "file"}, Mime: f.MediaType, Name: f.Name, Size: int64(f.ByteSize)})
		case rc.VectorImage != nil && len(rc.VectorImage.Artifacts) > 0:
			a := rc.VectorImage.GetLargestArtifact()
			p := pointer{URL: rc.VectorImage.GetLargestArtifactURL(), Kind: "image"}
			if !a.ExpiresAt.IsZero() {
				p.Expires = a.ExpiresAt.UnixMilli()
			}
			out = append(out, mediaOut{Pointer: p, Name: "image", Width: a.Width, Height: a.Height})
		case rc.Video != nil && len(rc.Video.ProgressiveStreams) > 0 && len(rc.Video.ProgressiveStreams[0].StreamingLocations) > 0:
			s := rc.Video.ProgressiveStreams[0]
			out = append(out, mediaOut{Pointer: pointer{URL: s.StreamingLocations[0].URL, Kind: "video"}, Mime: s.MediaType, Name: "video", Size: int64(s.Size), Width: s.Width, Height: s.Height})
		}
	}
	return out
}

// conversationOf is the chat a message says it is in, or "". A message in the live stream carries its conversation;
// one in a page of history, or under a reaction or a receipt, may carry only the thread's own id, from which the
// conversation's is made (the person's profile and that thread).
func conversationOf(me string, msg linkedingo.Message) string {
	if id := urnText(msg.Conversation.EntityURN); id != "" {
		return id
	}
	if id := urnText(msg.ConversationURN); id != "" {
		return id
	}
	if thread := msg.BackendConversationURN.ID(); thread != "" && me != "" {
		return fmt.Sprintf("urn:li:msg_conversation:(urn:li:fsd_profile:%s,%s)", me, thread)
	}
	return ""
}

// messageOf puts a message into the protocol's `message`, in [chat].
func messageOf(me, chat string, group bool, msg linkedingo.Message) messageOut {
	sender := personOf(msg.Sender)
	out := messageOut{
		Chat:  chat,
		Group: group,
		ID:    urnText(msg.EntityURN),
		From:  sender.ID,
		Name:  sender.Name,
		Mine:  isMine(me, msg.Sender),
		Text:  messageText(msg),
		Media: mediaOf(msg),
	}
	if !msg.DeliveredAt.IsZero() {
		out.TS = msg.DeliveredAt.UnixMilli()
	}
	for _, rc := range msg.RenderContent {
		if rc.RepliedMessageContent != nil {
			orig := rc.RepliedMessageContent.OriginalMessage
			if id := urnText(orig.EntityURN); id != "" {
				out.Quote = &quoteOut{ID: id, Text: orig.Body.Text}
			}
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
