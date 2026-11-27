package main

// Opening the person's X Chat keys with their passcode. X keeps the keys of its encrypted chats in Juicebox, guarded
// by the 4-digit passcode the person chose on x.com; the website asks for it in Messages. This follows
// mautrix-twitter's connector (login.go, keybackup.go: Copyright (C) 2025 Tulir Asokan, AGPL-3.0), whose bridge
// layer this helper does not use.

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"slices"
	"strings"

	"github.com/rs/zerolog"

	"go.mau.fi/mautrix-twitter/pkg/juiceboxgo"
	"go.mau.fi/mautrix-twitter/pkg/twittermeow"
	"go.mau.fi/mautrix-twitter/pkg/twittermeow/crypto"
	"go.mau.fi/mautrix-twitter/pkg/twittermeow/data/response"
	"go.mau.fi/mautrix-twitter/pkg/twittermeow/methods"
)

// passcodeOK is whether [p] looks like an X Chat passcode: four digits.
func passcodeOK(p string) bool {
	if len(p) != 4 {
		return false
	}
	for _, c := range p {
		if c < '0' || c > '9' {
			return false
		}
	}
	return true
}

// juiceboxConfig is the ready-made Juicebox configuration X gives with a public key, and the token of each realm.
func juiceboxConfig(m response.KeyStoreTokenMap) (string, map[string]juiceboxgo.AuthToken) {
	tokens := map[string]juiceboxgo.AuthToken{}
	for _, e := range m.TokenMap {
		realm, token := strings.ToLower(strings.TrimSpace(e.Key)), strings.TrimSpace(e.Value.Token)
		if realm != "" && token != "" {
			tokens[realm] = juiceboxgo.AuthToken(token)
		}
	}
	return strings.TrimSpace(m.KeyStoreTokenMapJSON), tokens
}

// passcodeKeys is the person's public keys that a passcode guards, newest first.
func passcodeKeys(resp *response.GetPublicKeysResponse) []response.PublicKeyWithTokenMap {
	if resp == nil || len(resp.Data.UserResultsByRestIDs) == 0 {
		return nil
	}
	var out []response.PublicKeyWithTokenMap
	for _, k := range resp.Data.UserResultsByRestIDs[0].Result.GetPublicKeys.PublicKeysWithTokenMap {
		if cfg, tokens := juiceboxConfig(k.TokenMap); cfg != "" && len(tokens) > 0 {
			out = append(out, k)
		}
	}
	slices.SortStableFunc(out, func(a, b response.PublicKeyWithTokenMap) int {
		return methods.CompareSnowflake(b.PublicKeyWithMetadata.Version, a.PublicKeyWithMetadata.Version)
	})
	return out
}

// juiceboxClient makes a Juicebox client from the configuration and tokens X gives with a public key.
func juiceboxClient(m response.KeyStoreTokenMap, log zerolog.Logger) (*juiceboxgo.Client, error) {
	cfgJSON, tokens := juiceboxConfig(m)
	cfg, err := juiceboxgo.ConfigurationFromJSON(cfgJSON)
	if err != nil {
		return nil, fmt.Errorf("X's passcode service gave a configuration that could not be read: %w", err)
	}
	return juiceboxgo.NewClient(cfg, tokens, nil, log)
}

// splitSecret reads what Juicebox gives back: the two keys as JSON, or as raw bytes (decrypt key then signing key).
func splitSecret(secret []byte) (ownKeys, error) {
	if len(secret) > 0 && secret[0] == '{' {
		var data struct {
			SigningKey string `json:"signing_key"`
			SecretKey  string `json:"secret_key"`
		}
		if err := json.Unmarshal(secret, &data); err != nil {
			return ownKeys{}, err
		}
		return ownKeys{SecretKey: data.SecretKey, SigningKey: data.SigningKey}, nil
	}
	var priv, sign []byte
	switch {
	case len(secret) >= 64 && len(secret)%2 == 0:
		priv, sign = secret[:len(secret)/2], secret[len(secret)/2:]
	case len(secret) > 32:
		priv, sign = secret[:32], secret[32:]
	default:
		priv = secret
	}
	k := ownKeys{SecretKey: base64.StdEncoding.EncodeToString(priv)}
	if len(sign) > 0 {
		k.SigningKey = base64.StdEncoding.EncodeToString(sign)
	}
	return k, nil
}

// checkKeys makes sure both recovered keys are P-256 scalars, as X's are.
func checkKeys(k ownKeys) error {
	if k.SecretKey == "" || k.SigningKey == "" {
		return errors.New("X's passcode service gave back only part of the X Chat keys")
	}
	for _, s := range []string{k.SecretKey, k.SigningKey} {
		if _, err := crypto.ParsePrivateKeyScalar(s); err != nil {
			return errors.New("X's passcode service gave back keys that could not be read")
		}
	}
	return nil
}

// recoverKeys opens the person's X Chat keys with [passcode]. Every call that reaches Juicebox with a wrong passcode
// spends one of the few tries X allows, so it is called once per sign-in and never retried.
func recoverKeys(ctx context.Context, cli *twittermeow.Client, me, passcode string, log zerolog.Logger) (ownKeys, error) {
	resp, err := cli.GetPublicKeys(ctx, []string{me})
	if err != nil {
		return ownKeys{}, err
	}
	candidates := passcodeKeys(resp)
	if len(candidates) == 0 {
		return ownKeys{}, errors.New(wordsNoPasscode)
	}
	// The newest key that Juicebox holds a secret for: asking whether it is registered costs no try.
	var chosen *response.PublicKeyWithTokenMap
	for i := range candidates {
		jb, err := juiceboxClient(candidates[i].TokenMap, log)
		if err != nil {
			return ownKeys{}, err
		}
		err = jb.CheckRegistration(ctx)
		jb.Close()
		if err == nil {
			chosen = &candidates[i]
			break
		}
		if !errors.Is(err, juiceboxgo.ErrNotRegistered) {
			return ownKeys{}, passcodeWords(err)
		}
	}
	if chosen == nil {
		return ownKeys{}, errors.New(wordsNoPasscode)
	}
	jb, err := juiceboxClient(chosen.TokenMap, log)
	if err != nil {
		return ownKeys{}, err
	}
	defer jb.Close()
	secret, err := jb.Recover(ctx, []byte(passcode), nil)
	if err != nil {
		return ownKeys{}, passcodeWords(err)
	}
	keys, err := splitSecret(secret)
	if err != nil {
		return ownKeys{}, errors.New("X's passcode service gave back keys that could not be read")
	}
	keys.Version = chosen.PublicKeyWithMetadata.Version
	if err := checkKeys(keys); err != nil {
		return ownKeys{}, err
	}
	return keys, nil
}
