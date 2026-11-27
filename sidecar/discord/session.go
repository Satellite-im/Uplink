package main

// The token the person copied from their browser, the session file it is kept in, and Discord's errors in words.

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strings"

	"github.com/bwmarrin/discordgo"
)

// tokenField is the entry of `sign_in`'s cookies that carries the token. Discord's website keeps the sign-in in
// its own storage, not in a cookie, so the app sends it under this name beside any cookies; those are taken and
// not used.
const tokenField = "token"

// tokenOf finds the token among what `sign_in` was given and checks it looks like a person's.
func tokenOf(cookies map[string]string) (string, error) {
	var token string
	for name, value := range cookies {
		if strings.EqualFold(strings.TrimSpace(name), tokenField) {
			token = value
		}
	}
	token = strings.TrimSpace(token)
	// The browser's storage shows it in quotes.
	token = strings.TrimSpace(strings.Trim(token, `"'`))
	const how = ": copy it from discord.com in a browser signed in to your account"
	switch {
	case token == "":
		return "", errors.New("the Discord token is missing" + how)
	case strings.HasPrefix(token, "Bot ") || strings.HasPrefix(token, "Bearer "):
		return "", errors.New("that is a bot's or an app's token, not a person's" + how)
	case strings.ContainsAny(token, " \t\r\n;") || len(token) < 20:
		return "", errors.New("that does not look like a Discord token" + how)
	}
	return token, nil
}

// session is what session.json holds: who is signed in, their token, and the "heartbeat session" Discord's app keeps
// between runs (kept so this helper looks like the same app coming back, as mautrix-discord does).
type session struct {
	Me        string                      `json:"me"`
	Name      string                      `json:"name"`
	Handle    string                      `json:"handle"`
	Token     string                      `json:"token"`
	Heartbeat *discordgo.HeartbeatSession `json:"heartbeat,omitempty"`
}

// sessionPath is where the session is kept: session.json in the helper's folder.
func sessionPath() string { return filepath.Join(dir, "session.json") }

// saveSession writes the session for the person alone to read (0600), whole or not at all.
func saveSession(path string, s session) error {
	data, err := json.Marshal(s)
	if err != nil {
		return err
	}
	tmp := path + ".new"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return err
	}
	// WriteFile keeps the mode of a file already there; this one is the token.
	if err := os.Chmod(tmp, 0o600); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	return os.Rename(tmp, path)
}

// loadSession reads a saved session; nil where there is none, or one without the token to sign in with.
func loadSession(path string) *session {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	var s session
	if json.Unmarshal(data, &s) != nil || s.Me == "" || s.Token == "" {
		return nil
	}
	return &s
}

// --- Discord's errors, in words -------------------------------------------------------------------------------------

// errBadToken is the gateway refusing the token (it closes with 4004), or an InvalidAuth event.
var errBadToken = errors.New("discord: authentication failed")

// statusError is a file fetch Discord answered with something other than the file.
type statusError struct{ Code int }

func (e *statusError) Error() string { return fmt.Sprintf("HTTP %d", e.Code) }

// statusOf is the status Discord answered with, 0 where the error is not an answer of Discord's.
func statusOf(err error) int {
	var re *discordgo.RESTError
	if errors.As(err, &re) && re.Response != nil {
		return re.Response.StatusCode
	}
	var se *statusError
	if errors.As(err, &se) {
		return se.Code
	}
	var rl *discordgo.RateLimitError
	if errors.As(err, &rl) {
		return http.StatusTooManyRequests
	}
	return 0
}

// codeOf is Discord's own error code (its JSON "code"), 0 where there is none.
func codeOf(err error) int {
	var re *discordgo.RESTError
	if errors.As(err, &re) && re.Message != nil {
		return re.Message.Code
	}
	return 0
}

// bodyOf is what Discord's answer said, as it came; "" where the error is not an answer of Discord's.
func bodyOf(err error) string {
	var re *discordgo.RESTError
	if errors.As(err, &re) {
		return string(re.ResponseBody)
	}
	return ""
}

// Discord's own error codes this helper says something particular for.
const (
	codeUnknownChannel   = 10003
	codeUnknownMessage   = 10008
	codeNoAccess         = 50001
	codeCannotDM         = 50007
	codeNotYours         = 50005
	codeNoPermission     = 50013
	codeNeedsVerifying   = 40002
	codeTooManyReactions = 30010
)

// rejected is whether Discord turned the session itself away: the token no longer works.
func rejected(err error) bool {
	return errors.Is(err, errBadToken) || errors.Is(err, discordgo.ErrUnauthorized) || statusOf(err) == http.StatusUnauthorized
}

// What the app shows for the three things only the person can mend.
const (
	wordsSignedOut = "Discord signed this session out: the token no longer works. Copy a new one from discord.com in the browser and sign in again."
	wordsVerify    = "Discord wants this account verified before it does that. Open Discord in a browser or its app, finish what it asks, and try again."
	wordsCaptcha   = "Discord asked for a captcha. Do the same thing once in Discord's own app, then try again here."
)

// endedWords is what the app shows when Discord ends the session.
func endedWords(error) string { return wordsSignedOut }

// signInWords says why Discord did not take the token, for a person to read.
func signInWords(err error) error {
	switch {
	case rejected(err):
		return errors.New("Discord did not take that token. Copy it again from discord.com in a browser signed in to your account.")
	case codeOf(err) == codeNeedsVerifying:
		return errors.New(wordsVerify)
	}
	return plain(err)
}

// plain puts an error from Discord into words for a person; other errors are already in words.
func plain(err error) error {
	if err == nil {
		return nil
	}
	status, code := statusOf(err), codeOf(err)
	switch {
	case rejected(err):
		return errors.New(wordsSignedOut)
	case strings.Contains(bodyOf(err), "captcha_key"):
		return errors.New(wordsCaptcha)
	case code == codeNeedsVerifying:
		return errors.New(wordsVerify)
	case code == codeCannotDM:
		return errors.New("Discord won't deliver this: the person takes direct messages only from friends or people in a server with them.")
	case code == codeUnknownMessage:
		return errors.New("Discord no longer has that message.")
	case code == codeUnknownChannel:
		return errors.New("Discord no longer has that chat, or this account is not in it.")
	case code == codeNotYours:
		return errors.New("That is someone else's message.")
	case code == codeTooManyReactions:
		return errors.New("That message has as many reactions as Discord allows.")
	case code == codeNoAccess, code == codeNoPermission, status == http.StatusForbidden:
		return errors.New("Discord does not let this account do that here.")
	case status == http.StatusTooManyRequests:
		return errors.New("Discord says there were too many requests. Wait a minute and try again.")
	case status >= 500:
		return errors.New("Discord had a problem of its own. Try again in a little while.")
	case status == http.StatusNotFound:
		return errors.New("Discord has nothing there.")
	case status != 0:
		return fmt.Errorf("Discord refused the request (it answered %d).", status)
	case errors.Is(err, context.DeadlineExceeded):
		return errors.New("Discord did not answer in time.")
	case strings.Contains(err.Error(), "dial tcp"), strings.Contains(err.Error(), "no such host"):
		return errors.New("Discord could not be reached. Check the connection and try again.")
	}
	return err
}
