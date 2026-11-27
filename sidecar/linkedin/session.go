package main

// The cookies the person copied from their browser, and the session file they are kept in.

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"go.mau.fi/mautrix-linkedin/pkg/linkedingo"
)

// The two cookies LinkedIn's website cannot be spoken to without: li_at is the sign-in itself, JSESSIONID is sent
// back in a header with every request (its CSRF token). The rest of the browser's cookies are passed along as given.
const (
	cookieSignIn  = "li_at"
	cookieSession = linkedingo.LinkedInCookieJSESSIONID
)

// neededCookies are the ones a sign-in, and a saved session, is refused without.
var neededCookies = []string{cookieSignIn, cookieSession}

// cookieHeader checks that the cookies LinkedIn needs are there, saying in words which are not, and writes them as
// the Cookie header a browser would send: the form the library's cookie jar is made from.
func cookieHeader(cookies map[string]string) (string, error) {
	clean := map[string]string{}
	for name, value := range cookies {
		name, value = strings.TrimSpace(name), strings.TrimSpace(value)
		// Tools that export cookies differ in the case they write names in; LinkedIn does not.
		for _, needed := range neededCookies {
			if strings.EqualFold(name, needed) {
				name = needed
			}
		}
		if name == "" || value == "" || strings.ContainsAny(name+value, ";\r\n") {
			continue
		}
		clean[name] = value
	}
	var missing []string
	for _, needed := range neededCookies {
		if clean[needed] == "" {
			missing = append(missing, needed)
		}
	}
	const again = ": sign in to linkedin.com in the browser and copy the cookies again"
	switch len(missing) {
	case 0:
	case 1:
		return "", fmt.Errorf("the %s cookie is missing%s", missing[0], again)
	default:
		return "", fmt.Errorf("the %s cookies are missing%s", strings.Join(missing, " and "), again)
	}
	names := make([]string, 0, len(clean))
	for name := range clean {
		names = append(names, name)
	}
	sort.Strings(names)
	parts := make([]string, 0, len(names))
	for _, name := range names {
		parts = append(parts, name+"="+clean[name])
	}
	return strings.Join(parts, "; "), nil
}

// cookieJar is the jar the library signs its requests from, made as mautrix-linkedin's own cookie sign-in makes it.
func cookieJar(cookies map[string]string) (*linkedingo.StringCookieJar, error) {
	header, err := cookieHeader(cookies)
	if err != nil {
		return nil, err
	}
	jar, err := linkedingo.NewJarFromCookieHeader(header)
	if err != nil {
		return nil, errors.New("those cookies could not be read: copy them from the browser again")
	}
	// A value the jar would not take (a stray character in it) is gone by now: say so rather than sign in without it.
	for _, needed := range neededCookies {
		if jar.GetCookie(needed) == "" {
			return nil, fmt.Errorf("the %s cookie could not be read: copy the cookies from the browser again", needed)
		}
	}
	return jar, nil
}

// session is what session.json holds: who is signed in and their cookies. Nothing else is kept between runs.
type session struct {
	Me      string                      `json:"me"`
	Name    string                      `json:"name"`
	Handle  string                      `json:"handle"`
	Cookies *linkedingo.StringCookieJar `json:"cookies"`
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
	// WriteFile keeps the mode of a file already there; this one is the cookies.
	if err := os.Chmod(tmp, 0o600); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	return os.Rename(tmp, path)
}

// loadSession reads a saved session; nil where there is none, or one without the cookies to sign in with.
func loadSession(path string) *session {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	var s session
	if json.Unmarshal(data, &s) != nil || s.Me == "" || s.Cookies == nil {
		return nil
	}
	for _, needed := range neededCookies {
		if s.Cookies.GetCookie(needed) == "" {
			return nil
		}
	}
	return &s
}

// statusOf is the status LinkedIn answered with, 0 where the error is not an answer of LinkedIn's.
func statusOf(err error) int {
	var re *linkedingo.ResponseError
	if errors.As(err, &re) {
		return re.StatusCode
	}
	return 0
}

// LinkedIn answers 999 to a client it takes for a program.
const statusBlocked = 999

// rejected is whether LinkedIn turned the session itself away: signed out (401, or the li_at cookie taken back), or
// sent to its sign-in or "confirm it's you" pages (its API redirects nowhere else).
func rejected(err error) bool {
	status := statusOf(err)
	return errors.Is(err, linkedingo.ErrTokenInvalidated) || status == http.StatusUnauthorized || (status >= 300 && status < 400)
}

// What the app shows for the two things only the person can mend, each said in more than one place.
const (
	wordsSignedOut = "LinkedIn signed this session out. Sign in to linkedin.com in the browser and copy the cookies again."
	wordsCheck     = "LinkedIn is asking for a check that it is you. Finish it at linkedin.com in the browser, then copy the cookies again."
)

// endedWords is what the app shows when LinkedIn ends the session.
func endedWords(err error) string {
	if status := statusOf(err); status >= 300 && status < 400 || status == http.StatusForbidden || status == statusBlocked {
		return wordsCheck
	}
	return wordsSignedOut
}

// signInWords says why LinkedIn did not take the cookies, for a person to read.
func signInWords(err error) error {
	status := statusOf(err)
	switch {
	case errors.Is(err, linkedingo.ErrTokenInvalidated), status == http.StatusUnauthorized:
		return errors.New("LinkedIn did not take those cookies. Sign in to linkedin.com in the browser and copy them again.")
	case status == http.StatusForbidden, status == statusBlocked, status >= 300 && status < 400:
		return errors.New(wordsCheck)
	case status == http.StatusTooManyRequests:
		return errors.New("LinkedIn says there were too many tries. Wait a few minutes and try again.")
	case status >= 500:
		return errors.New("LinkedIn had a problem of its own. Try again in a little while.")
	case status != 0:
		return fmt.Errorf("LinkedIn did not take those cookies (it answered %d). Sign in to linkedin.com in the browser and copy them again.", status)
	}
	return plain(err)
}

// plain puts an error from LinkedIn into words for a person; other errors are already in words.
func plain(err error) error {
	status := statusOf(err)
	switch {
	case err == nil:
		return nil
	case errors.Is(err, linkedingo.ErrTokenInvalidated), status == http.StatusUnauthorized:
		return errors.New(wordsSignedOut)
	case status >= 300 && status < 400:
		return errors.New(wordsCheck)
	case status == http.StatusTooManyRequests:
		return errors.New("LinkedIn says there were too many requests. Wait a few minutes and try again.")
	case status == http.StatusForbidden:
		return errors.New("LinkedIn does not allow that here.")
	case status == statusBlocked:
		return errors.New("LinkedIn blocked the request as coming from a program. Open linkedin.com in the browser, finish any check it shows, and try again.")
	case status >= 500:
		return errors.New("LinkedIn had a problem of its own. Try again in a little while.")
	case status != 0:
		return fmt.Errorf("LinkedIn refused the request (it answered %d).", status)
	case errors.Is(err, context.DeadlineExceeded):
		return errors.New("LinkedIn did not answer in time.")
	case errors.Is(err, linkedingo.ErrMissingGraphQLData):
		return errors.New("LinkedIn answered with nothing. Try again.")
	case strings.Contains(err.Error(), "failed to send request"):
		return errors.New("LinkedIn could not be reached. Check the connection and try again.")
	}
	return err
}
