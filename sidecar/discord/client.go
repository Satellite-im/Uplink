package main

// The part of Discord this helper speaks to, behind one interface: the real one is beeper's discordgo fork (as
// mautrix-discord uses it for a person's account), and the tests put a stand-in in its place.

import (
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"strings"
	"sync/atomic"
	"time"

	"github.com/bwmarrin/discordgo"
	"github.com/coder/websocket"
	"github.com/imroc/req/v3"
	utls "github.com/refraction-networking/utls"
)

// client is what the helper asks of Discord.
type client interface {
	// Open connects the live gateway and returns once Discord has said READY (which also reaches the event
	// handler). errBadToken where Discord refuses the token.
	Open() error
	Close()
	// What the gateway's READY and the events since have said: the person, their direct messages and groups,
	// a channel or a server by id (nil where unknown).
	Me() *discordgo.User
	PrivateChannels() []*discordgo.Channel
	Channel(id string) *discordgo.Channel
	Guild(id string) *discordgo.Guild
	// ReadState is how far each channel had been read when READY came.
	ReadState() *discordgo.ReadStateList

	Messages(ctx context.Context, c chatRef, limit int, before, around string) ([]*discordgo.Message, error)
	Send(ctx context.Context, c chatRef, m *discordgo.MessageSend) (*discordgo.Message, error)
	// Upload puts a file where a message can attach it, and gives the name Discord filed it under.
	Upload(ctx context.Context, c chatRef, name, mime string, size int64, r io.Reader) (string, error)
	React(ctx context.Context, c chatRef, message, emoji string, remove bool) error
	Delete(ctx context.Context, c chatRef, message string) error
	Ack(ctx context.Context, c chatRef, message string) error
	User(ctx context.Context, id string) (*discordgo.User, error)
	// Get fetches a file from Discord's servers into [w], no more than [limit] bytes.
	Get(ctx context.Context, url string, w io.Writer, limit int64) error
	// Heartbeat is the app's "heartbeat session", to keep between runs.
	Heartbeat() *discordgo.HeartbeatSession
}

// newClient makes the client for a token; the tests replace it. Nothing is asked of Discord yet.
var newClient = newDiscordClient

// discordClient is the real client: a discordgo session signed in as the person. uploadID counts this run's
// uploads: each file is named to Discord by the next number.
type discordClient struct {
	s *discordgo.Session
	// For uploads and downloads, which may outlast the API client's 20 seconds.
	files    *http.Client
	uploadID atomic.Int64
}

// newDiscordClient makes the session for a person's token: [hb] is the heartbeat session kept from the last run (nil
// for none), [handler] is called with every gateway event. A bot's token is refused.
func newDiscordClient(token string, hb *discordgo.HeartbeatSession, handler func(any)) (client, error) {
	s, err := discordgo.New(token)
	if err != nil {
		return nil, err
	}
	if !s.IsUser {
		return nil, errors.New("that is a bot's token, not a person's")
	}
	// Coming back as the same app, as mautrix-discord does, while Discord would still take it as one session.
	if hb != nil && !hb.IsExpired() {
		s.HeartbeatSession = *hb
	}
	s.HeartbeatSession.BumpLastUsed()
	// Speak to Discord as Chrome does: its TLS handshake and HTTP/2 for the API, HTTP/1.1 for the gateway.
	s.Client.Transport = compileTransport(false)
	// A client of its own: setting the default one's transport would change it for everything in the process.
	s.GatewayHTTPClient = &http.Client{Transport: compileTransport(true)}
	s.LogLevel = discordgo.LogInformational
	s.Logger = discordLogger
	s.State.MaxMessageCount = 0
	s.EventHandler = handler
	return &discordClient{s: s, files: &http.Client{Transport: s.Client.Transport}}, nil
}

// discordLogger passes the library's log on to the helper's. A line that would print a whole event (which may
// hold what a message says) is written without it.
func discordLogger(level, _ int, format string, a ...any) {
	if strings.Contains(format, "%#v") || strings.Contains(format, "%+v") {
		a = nil
	}
	msg := strings.TrimSpace(format)
	if len(a) > 0 {
		msg = strings.TrimSpace(fmt.Sprintf(format, a...))
	}
	switch level {
	case discordgo.LogError:
		log.Error().Str("component", "discordgo").Msg(msg)
	case discordgo.LogWarning:
		log.Warn().Str("component", "discordgo").Msg(msg)
	case discordgo.LogInformational:
		log.Info().Str("component", "discordgo").Msg(msg)
	default:
		log.Debug().Str("component", "discordgo").Msg(msg)
	}
}

// Open loads Discord's page and then connects the gateway. A connection Discord drops at once is tried three more
// times, five seconds apart; one closed with 4004 is errBadToken.
func (c *discordClient) Open() error {
	// As Discord's website does first: its page, which says the gateway's address and the app's build number.
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	if err := c.s.LoadMainPage(ctx); err != nil {
		log.Warn().Err(err).Msg("load Discord's main page; going on with the library's defaults")
	}
	cancel()
	for tries := 0; ; tries++ {
		err := c.s.Open()
		if errors.Is(err, discordgo.ErrImmediateDisconnect) && tries < 3 {
			time.Sleep(5 * time.Second)
			continue
		}
		if err != nil && websocket.CloseStatus(err) == 4004 {
			return errBadToken
		}
		return err
	}
}

func (c *discordClient) Close() { _ = c.s.Close() }

func (c *discordClient) Me() *discordgo.User {
	c.s.State.RLock()
	defer c.s.State.RUnlock()
	return c.s.State.User
}

// PrivateChannels is a copy of the list, for the caller to keep while the gateway goes on changing its own.
func (c *discordClient) PrivateChannels() []*discordgo.Channel {
	c.s.State.RLock()
	defer c.s.State.RUnlock()
	return append([]*discordgo.Channel(nil), c.s.State.PrivateChannels...)
}

func (c *discordClient) Channel(id string) *discordgo.Channel {
	ch, err := c.s.State.Channel(id)
	if err != nil {
		return nil
	}
	return ch
}

func (c *discordClient) Guild(id string) *discordgo.Guild {
	g, err := c.s.State.Guild(id)
	if err != nil {
		return nil
	}
	return g
}

func (c *discordClient) ReadState() *discordgo.ReadStateList {
	c.s.State.RLock()
	defer c.s.State.RUnlock()
	return c.s.State.ReadState
}

func (c *discordClient) Heartbeat() *discordgo.HeartbeatSession {
	hb := c.s.HeartbeatSession
	return &hb
}

// opts are what every request about a chat carries: the page it is asked from, as Discord's website sends it.
func opts(ctx context.Context, c chatRef, more ...discordgo.RequestOption) []discordgo.RequestOption {
	return append([]discordgo.RequestOption{discordgo.WithChannelReferer(c.Guild, c.Channel), discordgo.WithContext(ctx)}, more...)
}

func (c *discordClient) Messages(ctx context.Context, ch chatRef, limit int, before, around string) ([]*discordgo.Message, error) {
	return c.s.ChannelMessages(ch.Channel, limit, before, "", around, opts(ctx, ch)...)
}

func (c *discordClient) Send(ctx context.Context, ch chatRef, m *discordgo.MessageSend) (*discordgo.Message, error) {
	return c.s.ChannelMessageSendComplex(ch.Channel, m, opts(ctx, ch)...)
}

// Upload is the website's way of attaching a file: Discord is asked for a place, the file is put there, and the
// message names it.
func (c *discordClient) Upload(ctx context.Context, ch chatRef, name, mime string, size int64, r io.Reader) (string, error) {
	clip := false
	prep, err := c.s.ChannelAttachmentCreate(ch.Channel, &discordgo.ReqPrepareAttachments{Files: []*discordgo.FilePrepare{{
		Size:                int(size),
		Name:                name,
		ID:                  fmt.Sprint(c.uploadID.Add(2)),
		IsClip:              &clip,
		OriginalContentType: mime,
	}}}, opts(ctx, ch)...)
	if err != nil {
		return "", err
	}
	if prep == nil || len(prep.Attachments) == 0 || prep.Attachments[0].UploadURL == "" {
		return "", errors.New("Discord gave no place to put the file")
	}
	put, err := http.NewRequestWithContext(ctx, http.MethodPut, prep.Attachments[0].UploadURL, r)
	if err != nil {
		return "", err
	}
	put.ContentLength = size
	for k, v := range discordgo.DroidBaseHeaders {
		put.Header.Set(k, v)
	}
	put.Header.Set("Content-Type", "application/octet-stream")
	put.Header.Set("Referer", "https://discord.com/")
	put.Header.Set("Sec-Fetch-Dest", "empty")
	put.Header.Set("Sec-Fetch-Mode", "cors")
	put.Header.Set("Sec-Fetch-Site", "cross-site")
	resp, err := c.files.Do(put)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		return "", &statusError{Code: resp.StatusCode}
	}
	return prep.Attachments[0].UploadFilename, nil
}

// React adds the person's own reaction to a message, or takes it off.
func (c *discordClient) React(ctx context.Context, ch chatRef, message, emoji string, remove bool) error {
	if remove {
		return c.s.MessageReactionRemoveUser(ch.Guild, ch.Channel, message, emoji, "@me", discordgo.WithContext(ctx))
	}
	return c.s.MessageReactionAddUser(ch.Guild, ch.Channel, message, emoji, discordgo.WithContext(ctx))
}

func (c *discordClient) Delete(ctx context.Context, ch chatRef, message string) error {
	return c.s.ChannelMessageDelete(ch.Channel, message, opts(ctx, ch)...)
}

// Ack marks a channel read up to [message].
func (c *discordClient) Ack(ctx context.Context, ch chatRef, message string) error {
	_, err := c.s.ChannelMessageAckNoToken(ch.Channel, message, opts(ctx, ch)...)
	return err
}

func (c *discordClient) User(ctx context.Context, id string) (*discordgo.User, error) {
	return c.s.User(id, discordgo.WithContext(ctx))
}

// Get fetches a file with the headers Discord's app sends for one, and without the token. Any answer but 200 is a
// statusError; a file past [limit] is an error, once [limit]+1 bytes of it have been written.
func (c *discordClient) Get(ctx context.Context, url string, w io.Writer, limit int64) error {
	r, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return err
	}
	for k, v := range discordgo.DroidDownloadHeaders {
		r.Header.Set(k, v)
	}
	r.Header.Set("Referer", "https://discord.com/")
	resp, err := c.files.Do(r)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return &statusError{Code: resp.StatusCode}
	}
	n, err := io.Copy(w, io.LimitReader(resp.Body, limit+1))
	if err == nil && n > limit {
		err = errors.New("the file is larger than expected")
	}
	return err
}

// --- speaking as Chrome ---------------------------------------------------------------------------------------------

// compileTransport is mautrix-discord's (http.go, AGPL-3.0, Tulir Asokan): Chrome's TLS fingerprint through beeper's
// req fork, and for the gateway the same handshake offering only HTTP/1.1, as Chrome's websocket does.
func compileTransport(onlyHTTP1 bool) http.RoundTripper {
	c := req.C().ImpersonateChrome()
	c.SetProxy(http.ProxyFromEnvironment)
	if onlyHTTP1 {
		forceHTTP1ChromeFingerprint(c)
		c.EnableForceHTTP1()
	}
	return c.Transport
}

// forceHTTP1ChromeFingerprint makes [c] shake hands as Chrome 120 does but for two things: it offers HTTP/1.1 alone,
// and leaves out the application settings extension, which belongs to HTTP/2.
func forceHTTP1ChromeFingerprint(c *req.Client) {
	c.SetTLSHandshake(func(ctx context.Context, addr string, plainConn net.Conn) (net.Conn, *tls.ConnectionState, error) {
		hostname := addr
		if i := strings.LastIndex(addr, ":"); i != -1 {
			hostname = addr[:i]
		}
		// It must be the hello req's ImpersonateChrome uses.
		spec, err := utls.UTLSIdToSpec(utls.HelloChrome_120)
		if err != nil {
			return nil, nil, fmt.Errorf("failed to build Chrome uTLS spec: %w", err)
		}
		exts := spec.Extensions[:0]
		for _, ext := range spec.Extensions {
			switch e := ext.(type) {
			case *utls.ApplicationSettingsExtension:
				continue
			case *utls.ALPNExtension:
				e.AlpnProtocols = []string{"http/1.1"}
			}
			exts = append(exts, ext)
		}
		spec.Extensions = exts
		conf := c.GetTLSClientConfig()
		uconn := utls.UClient(plainConn, &utls.Config{
			ServerName:         hostname,
			NextProtos:         []string{"http/1.1"},
			RootCAs:            conf.RootCAs,
			InsecureSkipVerify: conf.InsecureSkipVerify,
		}, utls.HelloCustom)
		if err := uconn.ApplyPreset(&spec); err != nil {
			return nil, nil, fmt.Errorf("failed to apply Chrome uTLS spec: %w", err)
		}
		if err := uconn.HandshakeContext(ctx); err != nil {
			return nil, nil, err
		}
		cs := uconn.ConnectionState()
		return uconn, &tls.ConnectionState{
			Version:            cs.Version,
			HandshakeComplete:  cs.HandshakeComplete,
			DidResume:          cs.DidResume,
			CipherSuite:        cs.CipherSuite,
			NegotiatedProtocol: cs.NegotiatedProtocol,
			ServerName:         cs.ServerName,
			PeerCertificates:   cs.PeerCertificates,
			VerifiedChains:     cs.VerifiedChains,
		}, nil
	})
}
