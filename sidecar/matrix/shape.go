package main

// What can be worked out without a server: where a homeserver is, the SSO address, a room's title, and an event as
// the app is told it. main_test.go covers these.

import (
	"errors"
	"net/url"
	"sort"
	"strings"

	"maunium.net/go/mautrix/event"
	"maunium.net/go/mautrix/id"
)

// homeserverInput is what the person typed in the sign-in screen's one field: a homeserver ("matrix.org",
// "https://matrix.example.com") or their user id ("@me:matrix.org").
type homeserverInput struct {
	// Server is the server name to look up .well-known on; empty when Base was given outright.
	Server string
	// Base is the client API's address when the person gave one with its scheme.
	Base string
	// User is the user id, when the field held one.
	User string
}

// parseHomeserver reads the sign-in field. A user id names its server after the colon; an address with a scheme is
// used as it is; anything else is a server name, which .well-known may point elsewhere.
func parseHomeserver(in string) (homeserverInput, error) {
	in = strings.TrimSpace(in)
	if in == "" {
		in = "matrix.org"
	}
	if strings.HasPrefix(in, "@") {
		_, server, err := id.UserID(in).Parse()
		if err != nil || server == "" {
			return homeserverInput{}, errors.New("that user id isn't one Matrix knows: it looks like @name:server")
		}
		return homeserverInput{Server: server, User: in}, nil
	}
	if strings.HasPrefix(in, "https://") || strings.HasPrefix(in, "http://") {
		u, err := url.Parse(in)
		if err != nil || u.Host == "" {
			return homeserverInput{}, errors.New("that address isn't one a homeserver can be at")
		}
		return homeserverInput{Base: strings.TrimRight(in, "/")}, nil
	}
	if strings.ContainsAny(in, " /@") {
		return homeserverInput{}, errors.New("that isn't a homeserver: try matrix.org, or your user id")
	}
	return homeserverInput{Server: strings.ToLower(in)}, nil
}

// ssoURL is the address that sends the person's browser to their homeserver's sign-in, which comes back to
// [redirect] with a loginToken (the compatibility route Matrix Authentication Service keeps on matrix.org).
func ssoURL(base, redirect string) string {
	return strings.TrimRight(base, "/") + "/_matrix/client/v3/login/sso/redirect?redirectUrl=" + url.QueryEscape(redirect)
}

// loginIdentifier is the user field as /login takes it: a full user id stays whole, a bare name is the localpart.
func loginIdentifier(user string) string {
	user = strings.TrimSpace(user)
	if strings.HasPrefix(user, "@") {
		return user
	}
	return strings.TrimPrefix(user, "@")
}

// roomTitle names a room as Element does: its name; its alias; the other person in a direct chat; the heroes the
// server named (people in it); else plainly what it is. [names] gives each user id's display name.
func roomTitle(name, alias string, others []id.UserID, names map[id.UserID]string, direct bool) string {
	if s := strings.TrimSpace(name); s != "" {
		return s
	}
	if alias != "" {
		return alias
	}
	who := make([]string, 0, len(others))
	for _, u := range others {
		n := strings.TrimSpace(names[u])
		if n == "" {
			n = u.Localpart()
			if n == "" {
				n = string(u)
			}
		}
		who = append(who, n)
	}
	switch len(who) {
	case 0:
		if direct {
			return "Matrix contact"
		}
		return "Empty room"
	case 1:
		return who[0]
	case 2:
		return who[0] + " and " + who[1]
	default:
		sort.Strings(who[2:])
		return who[0] + ", " + who[1] + " and " + itoa(len(who)-2) + " others"
	}
}

// itoa is a count that is never negative, in digits.
func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var b []byte
	for n > 0 {
		b = append([]byte{byte('0' + n%10)}, b...)
		n /= 10
	}
	return string(b)
}

// mediaOf is a picture, video, sound or file in a message as the app is told it: its mxc address, and, in an encrypted
// room, the key to decrypt it with (the "file" object the event carried, given back to download as it is).
func mediaOf(c *event.MessageEventContent) map[string]any {
	m := map[string]any{"mime": "", "name": c.FileName, "size": 0, "width": 0, "height": 0, "duration": 0}
	if c.FileName == "" {
		m["name"] = c.Body
	}
	if c.Info != nil {
		m["mime"] = c.Info.MimeType
		m["size"] = c.Info.Size
		m["width"] = c.Info.Width
		m["height"] = c.Info.Height
		m["duration"] = c.Info.Duration
	}
	if c.File != nil {
		m["mxc"] = string(c.File.URL)
		m["file"] = c.File
	} else {
		m["mxc"] = string(c.URL)
		m["file"] = nil
	}
	if m["mime"] == "" {
		switch c.MsgType {
		case event.MsgImage:
			m["mime"] = "image/jpeg"
		case event.MsgVideo:
			m["mime"] = "video/mp4"
		case event.MsgAudio:
			m["mime"] = "audio/ogg"
		default:
			m["mime"] = "application/octet-stream"
		}
	}
	return m
}

// messageOf is a timeline event, decrypted where it was encrypted, as the app's "message" event says it; nil for one
// that is not a message (state, reactions, redactions) or that was redacted.
func messageOf(evt *event.Event, me id.UserID, senderName string) map[string]any {
	if evt.Unsigned.RedactedBecause != nil {
		return nil
	}
	if evt.Type != event.EventMessage && evt.Type != event.EventSticker {
		return nil
	}
	_ = evt.Content.ParseRaw(evt.Type)
	c := evt.Content.AsMessage()
	if c == nil {
		return nil
	}
	m := map[string]any{
		"room": string(evt.RoomID),
		"id":   string(evt.ID),
		"from": string(evt.Sender),
		"name": senderName,
		"mine": evt.Sender == me,
		"ts":   evt.Timestamp,
		"text": "",
		"kind": string(c.MsgType),
	}
	if evt.Type == event.EventSticker {
		m["kind"] = "m.sticker"
	}
	// An edit: the app changes the message it replaces.
	if c.RelatesTo != nil && c.RelatesTo.GetReplaceID() != "" && c.NewContent != nil {
		m["replaces"] = string(c.RelatesTo.GetReplaceID())
		c = c.NewContent
	}
	c.RemoveReplyFallback()
	// A reply sent without HTML still quotes what it answers in its body ("> <@who> …"): the app shows the quote itself.
	if c.RelatesTo.GetReplyTo() != "" {
		c.Body = event.TrimReplyFallbackText(c.Body)
	}
	media := []any{}
	switch c.MsgType {
	case event.MsgImage, event.MsgVideo, event.MsgAudio, event.MsgFile:
		media = append(media, mediaOf(c))
		// A caption is a body that is not the file's name.
		if c.FileName != "" && c.Body != c.FileName {
			m["text"] = c.Body
		}
	default:
		if evt.Type == event.EventSticker {
			media = append(media, mediaOf(c))
		} else {
			m["text"] = c.Body
		}
	}
	if c.MsgType == event.MsgEmote {
		m["text"] = "* " + c.Body
	}
	m["media"] = media
	if c.RelatesTo != nil {
		if r := c.RelatesTo.GetNonFallbackReplyTo(); r != "" {
			m["reply_to"] = string(r)
		}
	}
	return m
}

// undecryptable is an encrypted message this device has no key for (yet), as the app is told it: no words, and a
// flag the app shows as "Waiting for this message's key".
func undecryptable(evt *event.Event, me id.UserID, senderName string) map[string]any {
	return map[string]any{
		"room": string(evt.RoomID), "id": string(evt.ID), "from": string(evt.Sender), "name": senderName,
		"mine": evt.Sender == me, "ts": evt.Timestamp, "text": "", "kind": "m.text", "media": []any{},
		"undecryptable": true,
	}
}

// reactionOf is an m.reaction as the app's "reaction" event says it; nil for anything else.
func reactionOf(evt *event.Event) map[string]any {
	if evt.Type != event.EventReaction || evt.Unsigned.RedactedBecause != nil {
		return nil
	}
	_ = evt.Content.ParseRaw(evt.Type)
	r := evt.Content.AsReaction()
	if r == nil || r.RelatesTo.GetAnnotationID() == "" {
		return nil
	}
	return map[string]any{
		"room": string(evt.RoomID), "id": string(evt.ID), "target": string(r.RelatesTo.GetAnnotationID()),
		"from": string(evt.Sender), "emoji": r.RelatesTo.GetAnnotationKey(), "ts": evt.Timestamp,
	}
}

// redactedOf is the event an m.room.redaction takes away (room v11 keeps it in the content, older rooms beside it).
func redactedOf(evt *event.Event) id.EventID {
	if evt.Redacts != "" {
		return evt.Redacts
	}
	_ = evt.Content.ParseRaw(evt.Type)
	if r := evt.Content.AsRedaction(); r != nil {
		return r.Redacts
	}
	return ""
}

// mediaKind is the msgtype a file of [mime] is sent as.
func mediaKind(mime string) event.MessageType {
	switch {
	case strings.HasPrefix(mime, "image/"):
		return event.MsgImage
	case strings.HasPrefix(mime, "video/"):
		return event.MsgVideo
	case strings.HasPrefix(mime, "audio/"):
		return event.MsgAudio
	default:
		return event.MsgFile
	}
}
