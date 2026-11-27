package main

// The cookies the person copied from their browser, the session file they are kept in with the X Chat keys, and
// X's errors put into words.

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"go.mau.fi/mautrix-twitter/pkg/juiceboxgo"
	"go.mau.fi/mautrix-twitter/pkg/twittermeow"
	"go.mau.fi/mautrix-twitter/pkg/twittermeow/crypto"
	"go.mau.fi/mautrix-twitter/pkg/twittermeow/methods"
)

// The two cookies X's website cannot be spoken to without: auth_token is the sign-in itself, ct0 is sent back in a
// header with every request (its CSRF token). twid names the account; X sets it again when the messages page loads,
// so it is wanted but not needed. The rest of the browser's cookies are passed along as given.
const (
	cookieSignIn = "auth_token"
	cookieCSRF   = "ct0"
	cookieTwid   = "twid"
)

var neededCookies = []string{cookieSignIn, cookieCSRF}

// cleanCookies checks that the cookies X needs are there, saying in words which are not, and gives the cookies to
// keep: names trimmed (the needed ones in X's own case), values without the quotes some tools write round them.
func cleanCookies(cookies map[string]string) (map[string]string, error) {
	clean := map[string]string{}
	for name, value := range cookies {
		name, value = strings.TrimSpace(name), strings.TrimSpace(value)
		for _, known := range []string{cookieSignIn, cookieCSRF, cookieTwid} {
			if strings.EqualFold(name, known) {
				name = known
			}
		}
		if len(value) >= 2 && value[0] == '"' && value[len(value)-1] == '"' {
			value = value[1 : len(value)-1]
		}
		if name == "" || value == "" || strings.ContainsAny(name+value, ";\r\n") || strings.ContainsAny(name, "= \t") {
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
	const again = ": sign in to x.com in the browser and copy the cookies again"
	switch len(missing) {
	case 0:
		return clean, nil
	case 1:
		return nil, fmt.Errorf("the %s cookie is missing%s", missing[0], again)
	default:
		return nil, fmt.Errorf("the %s cookies are missing%s", strings.Join(missing, " and "), again)
	}
}

// cookieMap reads the library's cookie string ("a=b; c=d") back into names and values.
func cookieMap(header string) map[string]string {
	out := map[string]string{}
	for _, part := range strings.Split(header, ";") {
		name, value, ok := strings.Cut(strings.TrimSpace(part), "=")
		if ok && name != "" && value != "" {
			out[name] = value
		}
	}
	return out
}

// sameCookies is whether two sets of cookies have the same names and values.
func sameCookies(a, b map[string]string) bool {
	if len(a) != len(b) {
		return false
	}
	for k, v := range a {
		if b[k] != v {
			return false
		}
	}
	return true
}

// cookieNames is the names of [cookies], sorted: what may be logged of them.
func cookieNames(cookies map[string]string) []string {
	names := make([]string, 0, len(cookies))
	for name := range cookies {
		names = append(names, name)
	}
	sort.Strings(names)
	return names
}

// --- the session file -----------------------------------------------------------------------------------------------

// ownKeys are the person's own X Chat keys, recovered with their passcode: SecretKey opens the key of each chat,
// SigningKey signs what is sent. Both are base64 P-256 scalars, as X keeps them.
type ownKeys struct {
	SecretKey  string `json:"secret_key"`
	SigningKey string `json:"signing_key"`
	Version    string `json:"signing_key_version"`
}

// convKey is one version of a chat's key, as session.json keeps it.
type convKey struct {
	Key       []byte    `json:"key"`
	CreatedAt time.Time `json:"created_at"`
}

// session is what session.json holds: who is signed in, their cookies, their X Chat keys, the key and token of each
// chat met, and how far the live stream had got. The passcode itself is never kept.
type session struct {
	Me      string            `json:"me"`
	Name    string            `json:"name"`
	Handle  string            `json:"handle"`
	Cookies map[string]string `json:"cookies"`
	Keys    ownKeys           `json:"keys"`
	// The newest X Chat event this helper has passed on: what is asked for after a reconnect.
	MaxSeq   string                        `json:"max_sequence_id,omitempty"`
	ConvKeys map[string]map[string]convKey `json:"conversation_keys,omitempty"`
	Tokens   map[string]string             `json:"conversation_tokens,omitempty"`
}

// sessionPath is where the session is kept, in the helper's folder.
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
	// WriteFile keeps the mode of a file already there; this one is the cookies and the keys.
	if err := os.Chmod(tmp, 0o600); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	return os.Rename(tmp, path)
}

// loadSession reads a saved session; nil where there is none, or one without the cookies or keys to connect with.
func loadSession(path string) *session {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	var s session
	if json.Unmarshal(data, &s) != nil || s.Me == "" || s.Keys.SecretKey == "" || s.Keys.SigningKey == "" {
		return nil
	}
	for _, needed := range neededCookies {
		if s.Cookies[needed] == "" {
			return nil
		}
	}
	return &s
}

// --- the key store --------------------------------------------------------------------------------------------------

// keyStore is the library's crypto.KeyStore, kept in memory and written into session.json (through [changed]) when
// anything in it changes. Safe for use from several goroutines.
type keyStore struct {
	mu      sync.RWMutex
	me      string
	own     ownKeys
	convs   map[string]map[string]convKey
	tokens  map[string]string
	changed func()
}

var _ crypto.KeyStore = (*keyStore)(nil)

// newKeyStore makes a store holding copies of a session's keys and tokens.
func newKeyStore(s session) *keyStore {
	ks := &keyStore{me: s.Me, own: s.Keys, convs: map[string]map[string]convKey{}, tokens: map[string]string{}}
	for conv, keys := range s.ConvKeys {
		ks.convs[conv] = map[string]convKey{}
		for v, k := range keys {
			ks.convs[conv][v] = k
		}
	}
	for conv, t := range s.Tokens {
		ks.tokens[conv] = t
	}
	return ks
}

// fill copies what the store holds into [s].
func (ks *keyStore) fill(s *session) {
	ks.mu.RLock()
	defer ks.mu.RUnlock()
	s.Keys = ks.own
	s.ConvKeys = map[string]map[string]convKey{}
	for conv, keys := range ks.convs {
		s.ConvKeys[conv] = map[string]convKey{}
		for v, k := range keys {
			s.ConvKeys[conv][v] = k
		}
	}
	s.Tokens = map[string]string{}
	for conv, t := range ks.tokens {
		s.Tokens[conv] = t
	}
}

// notify tells the account that something in the store changed, so it is written to session.json. Called with the
// store's lock let go: the write reads the store back through fill.
func (ks *keyStore) notify() {
	if ks.changed != nil {
		ks.changed()
	}
}

// hasKeys is whether a chat has a key here: whether what is sent to it is encrypted.
func (ks *keyStore) hasKeys(conv string) bool {
	ks.mu.RLock()
	defer ks.mu.RUnlock()
	return len(ks.convs[conv]) > 0
}

// hasToken is whether X has given a token for a chat: with no key beside it, one of X Chat's unencrypted chats.
func (ks *keyStore) hasToken(conv string) bool {
	ks.mu.RLock()
	defer ks.mu.RUnlock()
	return ks.tokens[conv] != ""
}

// GetConversationKey is a chat's key at one version; crypto.ErrKeyNotFound where it is not held.
func (ks *keyStore) GetConversationKey(_ context.Context, conv, version string) (*crypto.ConversationKey, error) {
	ks.mu.RLock()
	defer ks.mu.RUnlock()
	k, ok := ks.convs[conv][version]
	if !ok || len(k.Key) == 0 {
		return nil, crypto.ErrKeyNotFound
	}
	return &crypto.ConversationKey{ConversationID: conv, KeyVersion: version, Key: k.Key, CreatedAt: k.CreatedAt}, nil
}

// PutConversationKey keeps a copy of a chat's key under its version.
func (ks *keyStore) PutConversationKey(_ context.Context, key *crypto.ConversationKey) error {
	if key == nil || key.ConversationID == "" || key.KeyVersion == "" || len(key.Key) == 0 {
		return errors.New("an empty conversation key")
	}
	ks.mu.Lock()
	if ks.convs[key.ConversationID] == nil {
		ks.convs[key.ConversationID] = map[string]convKey{}
	}
	ks.convs[key.ConversationID][key.KeyVersion] = convKey{Key: append([]byte(nil), key.Key...), CreatedAt: key.CreatedAt}
	ks.mu.Unlock()
	ks.notify()
	return nil
}

func (ks *keyStore) DeleteConversationKey(_ context.Context, conv, version string) error {
	ks.mu.Lock()
	delete(ks.convs[conv], version)
	ks.mu.Unlock()
	ks.notify()
	return nil
}

// GetLatestConversationKey is a chat's key at its newest version: versions are snowflakes, so the largest is newest.
func (ks *keyStore) GetLatestConversationKey(_ context.Context, conv string) (*crypto.ConversationKey, error) {
	ks.mu.RLock()
	defer ks.mu.RUnlock()
	var best string
	for v := range ks.convs[conv] {
		if best == "" || methods.CompareSnowflake(v, best) > 0 {
			best = v
		}
	}
	if best == "" {
		return nil, crypto.ErrKeyNotFound
	}
	k := ks.convs[conv][best]
	return &crypto.ConversationKey{ConversationID: conv, KeyVersion: best, Key: k.Key, CreatedAt: k.CreatedAt}, nil
}

// GetOwnSigningKey is the person's own keys, read from the base64 they are kept in.
func (ks *keyStore) GetOwnSigningKey(context.Context) (*crypto.SigningKeyPair, error) {
	ks.mu.RLock()
	own, me := ks.own, ks.me
	ks.mu.RUnlock()
	if own.SecretKey == "" && own.SigningKey == "" {
		return nil, crypto.ErrKeyNotFound
	}
	return crypto.LoadSigningKeyPair(me, own.Version, own.SigningKey, own.SecretKey)
}

func (ks *keyStore) PutOwnSigningKey(_ context.Context, key *crypto.SigningKeyPair) error {
	if key == nil {
		return errors.New("an empty signing key")
	}
	ks.mu.Lock()
	ks.own = ownKeys{SecretKey: key.DecryptKeyB64, SigningKey: key.SigningKeyB64, Version: key.KeyVersion}
	ks.mu.Unlock()
	ks.notify()
	return nil
}

// Others' public keys are given with each signed event; nothing is kept of them.
func (ks *keyStore) GetPublicKey(context.Context, string, string) (*crypto.PublicKeyInfo, error) {
	return nil, crypto.ErrKeyNotFound
}

func (ks *keyStore) PutPublicKey(context.Context, *crypto.PublicKeyInfo) error { return nil }

// GetConversationToken is the token X gave for a chat; crypto.ErrKeyNotFound where it gave none.
func (ks *keyStore) GetConversationToken(_ context.Context, conv string) (string, error) {
	ks.mu.RLock()
	defer ks.mu.RUnlock()
	if t := ks.tokens[conv]; t != "" {
		return t, nil
	}
	return "", crypto.ErrKeyNotFound
}

// PutConversationToken keeps a chat's token. The session is written again only when it differs from the one held.
func (ks *keyStore) PutConversationToken(_ context.Context, conv, token string) error {
	if conv == "" || token == "" {
		return nil
	}
	ks.mu.Lock()
	same := ks.tokens[conv] == token
	ks.tokens[conv] = token
	ks.mu.Unlock()
	if !same {
		ks.notify()
	}
	return nil
}

// --- X's errors in words --------------------------------------------------------------------------------------------

var statusPattern = regexp.MustCompile(`HTTP (\d{3})`)

// statusOf is the HTTP status X answered with, 0 where the error does not say one. The library writes it into the
// error's words ("HTTP 401: …") rather than a type.
func statusOf(err error) int {
	if err == nil {
		return 0
	}
	m := statusPattern.FindStringSubmatch(err.Error())
	if m == nil {
		return 0
	}
	n, _ := strconv.Atoi(m[1])
	return n
}

// rejected is whether X turned the session itself away: signed out, the cookies out of date, the account locked or
// suspended.
func rejected(err error) bool {
	return twittermeow.IsAuthError(err) || errors.Is(err, twittermeow.ErrCSRFMismatch) || statusOf(err) == http.StatusUnauthorized
}

// X turning the account away, in words, by the reason it gave: shown when a session ends and when a sign-in fails.
const (
	wordsSignedOut = "X signed this session out. Sign in to x.com in the browser and copy the cookies again."
	wordsLocked    = "X has locked this account for now. Open x.com in the browser, finish the checks it shows, then sign in again."
	wordsSuspended = "X says this account is suspended or no longer active."
)

// endedWords is what the app shows when X ends the session.
func endedWords(err error) string {
	switch {
	case errors.Is(err, twittermeow.ErrAccountTemporarilyLocked):
		return wordsLocked
	case errors.Is(err, twittermeow.ErrUserSuspended), errors.Is(err, twittermeow.ErrNotActive):
		return wordsSuspended
	}
	return wordsSignedOut
}

// signInWords says why X did not take the cookies, for a person to read.
func signInWords(err error) error {
	switch {
	case errors.Is(err, twittermeow.ErrAccountTemporarilyLocked):
		return errors.New(wordsLocked)
	case errors.Is(err, twittermeow.ErrUserSuspended), errors.Is(err, twittermeow.ErrNotActive):
		return errors.New(wordsSuspended)
	case rejected(err):
		return errors.New("X did not take those cookies. Sign in to x.com in the browser and copy them again.")
	case errors.Is(err, twittermeow.ErrRatelimitExceeded), statusOf(err) == http.StatusTooManyRequests:
		return errors.New("X says there were too many tries. Wait a few minutes and try again.")
	}
	return plain(err)
}

// plain puts an error from X into words for a person; other errors are already in words.
func plain(err error) error {
	status := statusOf(err)
	switch {
	case err == nil:
		return nil
	case errors.Is(err, twittermeow.ErrAccountTemporarilyLocked):
		return errors.New(wordsLocked)
	case errors.Is(err, twittermeow.ErrUserSuspended), errors.Is(err, twittermeow.ErrNotActive):
		return errors.New(wordsSuspended)
	case rejected(err):
		return errors.New(wordsSignedOut)
	case errors.Is(err, twittermeow.ErrRatelimitExceeded), status == http.StatusTooManyRequests:
		return errors.New("X says there were too many requests. Wait a few minutes and try again.")
	case errors.Is(err, twittermeow.ErrConversationDoesntExist):
		return errors.New("X says that chat does not exist.")
	case status == http.StatusForbidden:
		return errors.New("X does not allow that here.")
	case status >= 500:
		return errors.New("X had a problem of its own. Try again in a little while.")
	case status != 0:
		return fmt.Errorf("X refused the request (it answered %d).", status)
	case errors.Is(err, crypto.ErrKeyNotFound):
		return errors.New("This chat's X Chat key is not on this device yet. Try again in a little while.")
	case errors.Is(err, twittermeow.ErrXChatWebsocketNotConnected):
		return errors.New("Not connected to X Chat just now. Try again in a moment.")
	case errors.Is(err, context.DeadlineExceeded):
		return errors.New("X did not answer in time.")
	case errors.Is(err, twittermeow.ErrRequestFailed), errors.Is(err, twittermeow.ErrMaxRetriesReached):
		return errors.New("X could not be reached. Check the connection and try again.")
	}
	return err
}

// passcodeWords says why the X Chat passcode did not open the keys. X allows only a few wrong passcodes before it
// locks X Chat, so the words say how many are left, and the helper never tries one again by itself.
func passcodeWords(err error) error {
	var re *juiceboxgo.RecoverError
	switch {
	case errors.As(err, &re) && re.GuessesRemaining != nil && *re.GuessesRemaining == 0:
		return errors.New("Too many wrong passcodes: X has locked X Chat for this account. Reset the passcode on x.com, then sign in again.")
	case errors.As(err, &re) && re.GuessesRemaining != nil:
		left := *re.GuessesRemaining
		word := "tries"
		if left == 1 {
			word = "try"
		}
		return fmt.Errorf("That X Chat passcode is not right. %d %s left before X locks X Chat.", left, word)
	case errors.As(err, &re):
		return errors.New("That X Chat passcode is not right.")
	case errors.Is(err, juiceboxgo.ErrNotRegistered):
		return errors.New(wordsNoPasscode)
	case errors.Is(err, juiceboxgo.ErrRateLimitExceeded):
		return errors.New("X says there were too many passcode tries. Wait a while and try again.")
	case errors.Is(err, juiceboxgo.ErrInvalidAuth):
		return errors.New("X did not let this device check the passcode. Copy the cookies again and retry.")
	case errors.Is(err, juiceboxgo.ErrUpgradeRequired):
		return errors.New("X wants a newer version of this helper to check the passcode.")
	case errors.Is(err, juiceboxgo.ErrTransient):
		return errors.New("X's passcode service had a passing problem. Try again.")
	}
	return plain(err)
}

// What a sign-in answers when the passcode is the trouble: the account has none, or none was given.
const (
	wordsNoPasscode   = "This account has no X Chat passcode yet. Open x.com/messages in the browser, set one up, then sign in here again."
	wordsNeedPasscode = "X keeps its chats encrypted: give the 4-digit X Chat passcode (the one x.com asks for in Messages) with the cookies."
)
