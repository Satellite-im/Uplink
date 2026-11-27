package main

// The browser session the person copied (its token and cookies), and the session file it is kept in.

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/slack-go/slack"
)

// Slack's website signs every request with two things: the `d` cookie (the browser's sign-in, "xoxd-…") and the
// token its page holds for the workspace ("xoxc-…"), which no cookie carries. The app hands the token over as a
// pseudo-cookie named `token`. The rest of the browser's slack.com cookies (`d-s`, `b`…) are passed along as given.
const (
	cookieD     = "d"
	cookieToken = "token"
)

// copyAgain ends the sign-in errors that copying the browser's session afresh would mend.
const copyAgain = ": open the workspace in the browser, signed in, and copy the cookies and token again"

// credentials checks what sign_in was given, saying in words what is missing, and gives the token and the cookies to
// send (the `d` cookie as Slack set it, not escaped for a header).
func credentials(given map[string]string) (string, map[string]string, error) {
	cookies := map[string]string{}
	token := ""
	for name, value := range given {
		name, value = strings.TrimSpace(name), strings.TrimSpace(value)
		if name == "" || value == "" || strings.ContainsAny(name+value, ";\r\n") {
			continue
		}
		switch {
		case strings.EqualFold(name, cookieToken):
			token = strings.Trim(value, `"`)
		case strings.EqualFold(name, cookieD):
			// Copied from the browser the cookie is escaped ("xoxd-…%2F…"); the library escapes it again. A "+" is
			// part of the value, not an escaped space.
			if strings.Contains(value, "%") {
				if plain, err := url.PathUnescape(value); err == nil {
					value = plain
				}
			}
			cookies[cookieD] = value
		default:
			cookies[name] = value
		}
	}
	var missing []string
	if cookies[cookieD] == "" {
		missing = append(missing, "the d cookie is missing")
	}
	if token == "" {
		missing = append(missing, "the token (xoxc-…) is missing")
	}
	if len(missing) > 0 {
		return "", nil, errors.New(strings.Join(missing, " and ") + copyAgain)
	}
	if !strings.HasPrefix(token, "xoxc-") {
		return "", nil, errors.New("that token is not a browser session's (it starts xoxc-)" + copyAgain)
	}
	if !strings.HasPrefix(cookies[cookieD], "xoxd-") {
		return "", nil, errors.New("that d cookie is not Slack's sign-in (it starts xoxd-)" + copyAgain)
	}
	return token, cookies, nil
}

// clientOptions are the library's options for a session: its cookies, sent as the browser sends them.
func clientOptions(cookies map[string]string) []slack.Option {
	opts := []slack.Option{slack.OptionHTTPClient(httpClient), slack.OptionLog(slackLog{})}
	names := make([]string, 0, len(cookies))
	for name := range cookies {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		if name == cookieD {
			opts = append(opts, slack.OptionCookie(cookieD, cookies[cookieD]))
			continue
		}
		opts = append(opts, slack.OptionCookieRAW(&http.Cookie{Name: name, Value: cookies[name], Path: "/", Domain: ".slack.com", Secure: true}))
	}
	// Only a 429 is tried again (after the wait Slack asks for); the retries come after the client they wrap.
	return append(opts, slack.OptionRetry(3))
}

// session is what session.json holds: the workspace, who is signed in to it, and the browser session. Nothing else is
// kept between runs.
type session struct {
	Team       string            `json:"team"`
	TeamName   string            `json:"team_name"`
	TeamDomain string            `json:"team_domain"`
	Me         string            `json:"me"`
	Name       string            `json:"name"`
	Handle     string            `json:"handle"`
	Token      string            `json:"token"`
	Cookies    map[string]string `json:"cookies"`
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
	// WriteFile keeps the mode of a file already there; this one is the session.
	if err := os.Chmod(tmp, 0o600); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	return os.Rename(tmp, path)
}

// loadSession reads a saved session; nil where there is none, or one without what signing in needs.
func loadSession(path string) *session {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	var s session
	if json.Unmarshal(data, &s) != nil || s.Team == "" || s.Me == "" || !strings.HasPrefix(s.Token, "xoxc-") || s.Cookies[cookieD] == "" {
		return nil
	}
	return &s
}

// --- what Slack said, in words --------------------------------------------------------------------------------------

// errCode is the error Slack answered with ("invalid_auth"…), "" where the error is not an answer of Slack's.
func errCode(err error) string {
	var se slack.SlackErrorResponse
	if errors.As(err, &se) {
		return se.Err
	}
	var pse *slack.SlackErrorResponse
	if errors.As(err, &pse) && pse != nil {
		return pse.Err
	}
	return ""
}

// statusOf is the HTTP status Slack answered with where it gave no error of its own (a 500, say); 0 otherwise.
func statusOf(err error) int {
	var sc slack.StatusCodeError
	if errors.As(err, &sc) {
		return sc.Code
	}
	return 0
}

// rejected is whether Slack turned the session itself away: signed out, the account deactivated or removed from the
// workspace, or the workspace gone.
func rejected(err error) bool {
	switch errCode(err) {
	case "invalid_auth", "not_authed", "token_revoked", "token_expired", "account_inactive", "user_removed_from_team", "team_disabled":
		return true
	}
	return false
}

// wordsSignedOut is what the app shows for a session Slack ended without saying more.
const wordsSignedOut = "Slack signed this session out. Open the workspace in the browser, signed in, and copy the cookies and token again."

// endedWords is what the app shows when Slack ends the session.
func endedWords(err error) string {
	switch errCode(err) {
	case "account_inactive":
		return "Slack says this account is deactivated in the workspace."
	case "user_removed_from_team":
		return "Slack says this account was removed from the workspace."
	case "team_disabled":
		return "Slack says the workspace is no longer available."
	}
	return wordsSignedOut
}

// signInWords says why Slack did not take the session, for a person to read.
func signInWords(err error) error {
	switch errCode(err) {
	case "invalid_auth", "not_authed":
		return errors.New("Slack did not take that token and cookie. Open the workspace in the browser, signed in, and copy them again.")
	case "token_revoked", "token_expired":
		return errors.New("that browser session is signed out of Slack. Sign in again in the browser and copy the cookies and token again.")
	case "account_inactive", "user_removed_from_team", "team_disabled":
		return errors.New(endedWords(err))
	}
	return plain(err)
}

// plain puts an error from Slack into words for a person; other errors are already in words.
func plain(err error) error {
	var rl *slack.RateLimitedError
	code := errCode(err)
	switch {
	case err == nil:
		return nil
	case rejected(err):
		return errors.New(endedWords(err))
	case errors.As(err, &rl), code == "ratelimited", code == "rate_limited":
		return errors.New("Slack says there were too many requests. Wait a minute and try again.")
	case code == "channel_not_found", code == "not_in_channel":
		return errors.New("that chat is not one this account can see in Slack.")
	case code == "is_archived", code == "channel_is_archived":
		return errors.New("that Slack channel is archived.")
	case code == "message_not_found", code == "thread_not_found":
		return errors.New("Slack has no such message (it may have been deleted).")
	case code == "cant_delete_message", code == "cant_update_message":
		return errors.New("Slack does not let this account delete that message.")
	case code == "edit_window_closed":
		return errors.New("Slack's time for changing that message has passed.")
	case code == "msg_too_long":
		return errors.New("that message is too long for Slack.")
	case code == "invalid_name":
		return errors.New("Slack has no emoji of that name.")
	case code == "too_many_reactions", code == "too_many_emoji":
		return errors.New("Slack takes no more reactions on that message.")
	case code == "file_not_found", code == "file_deleted":
		return errors.New("Slack no longer has that file.")
	case code == "hidden_by_limit":
		return errors.New("that file is hidden by the workspace's plan.")
	case code == "restricted_action", code == "restricted_action_read_only_channel", code == "restricted_action_thread_only_channel",
		code == "no_permission", code == "not_allowed_token_type", code == "access_denied", code == "ekm_access_denied", code == "missing_scope":
		return errors.New("Slack does not allow that here.")
	case code == "fatal_error", code == "internal_error", code == "service_unavailable", statusOf(err) >= 500:
		return errors.New("Slack had a problem of its own. Try again in a little while.")
	case code != "":
		return fmt.Errorf("Slack refused the request (%s).", code)
	case statusOf(err) != 0:
		return fmt.Errorf("Slack refused the request (it answered %d).", statusOf(err))
	case errors.Is(err, context.DeadlineExceeded):
		return errors.New("Slack did not answer in time.")
	case strings.Contains(err.Error(), "dial tcp"), strings.Contains(err.Error(), "no such host"), strings.Contains(err.Error(), "connection refused"):
		return errors.New("Slack could not be reached. Check the connection and try again.")
	}
	return err
}
