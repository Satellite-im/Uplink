// Fetching files: the pictures of people and chats, kept under <dir>/avatars, and a message's media for `download`.
// Instagram's file addresses are signed links on its content servers: they need no cookies, so none are sent, and the
// requests are made as a browser makes them for a picture or a video on a page (the bridge's msgconv/mediadl).
package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"go.mau.fi/mautrix-meta/pkg/instameow"
	"go.mau.fi/mautrix-meta/pkg/messagix/useragent"
)

// The most that is fetched for a picture of a person or chat (5 MB) and for a message's file (1 GB), and how a long
// video is fetched: a megabyte at a time.
const (
	maxAvatar   = 5 << 20
	maxDownload = 1 << 30
	// Instagram hands long videos over from this host only a piece at a time.
	chunkedHost = "video.xx.fbcdn.net"
	chunkSize   = 1 << 20
)

// mediaHTTP fetches files, with no cookies. A redirect to the host that serves long videos is not followed: fetch
// sees it and reads the video in pieces instead.
var mediaHTTP = &http.Client{
	Timeout: 10 * time.Minute,
	CheckRedirect: func(req *http.Request, via []*http.Request) error {
		if req.URL.Hostname() == chunkedHost {
			return http.ErrUseLastResponse
		}
		if len(via) >= 10 {
			return errors.New("too many redirects")
		}
		return nil
	},
}

// mediaRequest asks for a file with the headers a browser sends for a picture, video or sound on a page, by [mime];
// [byteRange] is a Range header's value, "" for the whole file.
func mediaRequest(ctx context.Context, method, address, mime, byteRange string) (*http.Response, error) {
	req, err := http.NewRequestWithContext(ctx, method, address, nil)
	if err != nil {
		return nil, err
	}
	h := req.Header
	h.Set("Accept", "*/*")
	switch strings.Split(mime, "/")[0] {
	case "image":
		h.Set("Accept", "image/avif,image/webp,*/*")
		h.Set("Sec-Fetch-Dest", "image")
	case "video":
		h.Set("Sec-Fetch-Dest", "video")
	case "audio":
		h.Set("Sec-Fetch-Dest", "audio")
	default:
		h.Set("Sec-Fetch-Dest", "empty")
	}
	h.Set("Sec-Fetch-Mode", "no-cors")
	h.Set("Sec-Fetch-Site", "cross-site")
	h.Set("User-Agent", useragent.UserAgent)
	h.Set("sec-ch-ua", useragent.SecCHUserAgent)
	h.Set("sec-ch-ua-platform", useragent.SecCHPlatform)
	if byteRange != "" {
		h.Set("Range", byteRange)
	}
	return mediaHTTP.Do(req)
}

// statusWords puts a file server's refusal in words: a link that has run out is the usual one.
func statusWords(code int) error {
	switch code {
	case http.StatusForbidden, http.StatusUnauthorized, http.StatusNotFound, http.StatusGone:
		return errors.New("Instagram no longer gives this file: its link has run out. Open the chat again for a fresh one")
	case http.StatusTooManyRequests:
		return errors.New(wordsSlowDown)
	}
	return fmt.Errorf("Instagram answered %d for the file", code)
}

// fetch writes the file at [address] to [w], at most [limit] bytes of it.
func fetch(ctx context.Context, address, mime string, limit int64, w io.Writer) error {
	resp, err := mediaRequest(ctx, http.MethodGet, address, mime, "")
	if err != nil {
		return fmt.Errorf("the file could not be fetched: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusFound {
		if loc, _ := resp.Location(); loc != nil && loc.Hostname() == chunkedHost {
			return fetchChunked(ctx, loc.String(), mime, limit, w)
		}
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return statusWords(resp.StatusCode)
	}
	return copyLimited(w, resp.Body, limit)
}

// copyLimited copies [r] to [w], failing where there is more than [limit] bytes of it.
func copyLimited(w io.Writer, r io.Reader, limit int64) error {
	n, err := io.Copy(w, io.LimitReader(r, limit+1))
	if err != nil {
		return fmt.Errorf("the file could not be fetched: %v", err)
	}
	if n > limit {
		return errors.New("the file is too large to fetch here")
	}
	return nil
}

// fetchChunked fetches a long video a megabyte at a time, as the bridge's downloadChunkedVideo does.
func fetchChunked(ctx context.Context, address, mime string, limit int64, w io.Writer) error {
	head, err := mediaRequest(ctx, http.MethodHead, address, mime, "")
	if err != nil {
		return fmt.Errorf("the file could not be fetched: %v", err)
	}
	_ = head.Body.Close()
	whole := head.StatusCode == http.StatusForbidden || (head.StatusCode == http.StatusOK && head.Header.Get("Accept-Ranges") != "bytes")
	if whole {
		resp, err := mediaRequest(ctx, http.MethodGet, address, mime, "")
		if err != nil {
			return fmt.Errorf("the file could not be fetched: %v", err)
		}
		defer resp.Body.Close()
		if resp.StatusCode < 200 || resp.StatusCode >= 300 {
			return statusWords(resp.StatusCode)
		}
		return copyLimited(w, resp.Body, limit)
	}
	if head.StatusCode != http.StatusOK {
		return statusWords(head.StatusCode)
	}
	size := head.ContentLength
	if size <= 0 {
		return errors.New("Instagram did not say how large the file is")
	}
	if size > limit {
		return errors.New("the file is too large to fetch here")
	}
	for offset := int64(0); offset < size; offset += chunkSize {
		end := min(offset+chunkSize, size) - 1
		resp, err := mediaRequest(ctx, http.MethodGet, address, mime, fmt.Sprintf("bytes=%d-%d", offset, end))
		if err != nil {
			return fmt.Errorf("the file could not be fetched: %v", err)
		}
		if resp.StatusCode < 200 || resp.StatusCode >= 300 {
			_ = resp.Body.Close()
			return statusWords(resp.StatusCode)
		}
		_, err = io.Copy(w, io.LimitReader(resp.Body, end-offset+1))
		_ = resp.Body.Close()
		if err != nil {
			return fmt.Errorf("the file could not be fetched: %v", err)
		}
	}
	return nil
}

// fetchTo fetches into [dest] by way of a file beside it, so a fetch that fails leaves nothing half-written there.
func fetchTo(ctx context.Context, address, mime string, limit int64, dest string) error {
	tmp, err := os.CreateTemp(filepath.Dir(dest), ".fetch-*")
	if err != nil {
		return fmt.Errorf("the file could not be written: %v", err)
	}
	err = fetch(ctx, address, mime, limit, tmp)
	if closeErr := tmp.Close(); err == nil && closeErr != nil {
		err = fmt.Errorf("the file could not be written: %v", closeErr)
	}
	if err == nil {
		if err = os.Rename(tmp.Name(), dest); err != nil {
			err = fmt.Errorf("the file could not be written: %v", err)
		}
	}
	if err != nil {
		_ = os.Remove(tmp.Name())
	}
	return err
}

// pointer is what `download` is handed back for a message's file: its address, and the kind of file it is.
type pointer struct {
	URL  string `json:"url"`
	Mime string `json:"mime"`
}

// parsePointer reads a media pointer as a message's `media` gave it. Only a secure web address is taken: the pointer
// comes back from the app, and nothing but a file on the web is ever to be fetched for it.
func parsePointer(raw json.RawMessage) (pointer, error) {
	var p pointer
	if len(raw) == 0 || json.Unmarshal(raw, &p) != nil || p.URL == "" {
		return p, errors.New("the file's pointer is not one this helper gave")
	}
	u, err := url.Parse(p.URL)
	if err != nil || u.Scheme != "https" || u.Hostname() == "" {
		return p, errors.New("the file's pointer is not one this helper gave")
	}
	return p, nil
}

// download writes a message's file to [dest]. It needs no session: the pointer's address is enough while it lasts.
func download(ctx context.Context, raw json.RawMessage, dest string) error {
	p, err := parsePointer(raw)
	if err != nil {
		return err
	}
	if dest == "" {
		return errors.New("no place to write the file was named")
	}
	return fetchTo(ctx, p.URL, p.Mime, maxDownload, dest)
}

// avatarPath is where the picture at [address] is kept. Instagram signs a picture's address anew each time it lists
// it; the file's own name inside the address stays, so that names the kept copy (as the bridge names avatars).
func avatarPath(address string) string {
	if address == "" {
		return ""
	}
	key := address
	if u, err := url.Parse(address); err == nil {
		if base := path.Base(u.Path); base != "" && base != "." && base != "/" {
			key = base
		}
	}
	sum := sha256.Sum256([]byte(key))
	return filepath.Join(avatarDir(), hex.EncodeToString(sum[:12]))
}

// avatarCached is the kept picture for [address]; "" where there is none yet.
func avatarCached(address string) string {
	p := avatarPath(address)
	if p == "" {
		return ""
	}
	if st, err := os.Stat(p); err != nil || st.Size() == 0 {
		return ""
	}
	return p
}

// fetchAvatar fetches and keeps the picture at [address]; "" where it can't be had.
func fetchAvatar(ctx context.Context, address string) string {
	if p := avatarCached(address); p != "" {
		return p
	}
	p := avatarPath(address)
	if p == "" {
		return ""
	}
	_ = os.MkdirAll(avatarDir(), 0o700)
	if err := fetchTo(ctx, address, "image/*", maxAvatar, p); err != nil {
		log.Debug().Err(err).Msg("a picture could not be fetched")
		return ""
	}
	return p
}

// avatarJob is one picture waiting to be fetched for the session of [c], and what to do with the file.
type avatarJob struct {
	c       *instameow.Client
	address string
	then    func(file string)
}

// The pictures waiting, and the one goroutine that fetches them, started at the first.
var (
	avatarJobs = make(chan avatarJob, 1024)
	avatarOnce sync.Once
)

// later fetches a picture after the event that named it has been said, one picture at a time, and calls [then] with
// the kept file. A full queue drops the job: the picture is fetched when `who` or a later listing asks again.
func later(c *instameow.Client, address string, then func(file string)) {
	avatarOnce.Do(func() {
		go func() {
			for job := range avatarJobs {
				// A session since ended has no use for the picture, and its folder is gone.
				if !isCurrent(job.c) {
					continue
				}
				ctx, cancel := context.WithTimeout(bg(), time.Minute)
				file := fetchAvatar(ctx, job.address)
				cancel()
				if file != "" && isCurrent(job.c) {
					job.then(file)
				}
			}
		}()
	})
	select {
	case avatarJobs <- avatarJob{c: c, address: address, then: then}:
	default:
	}
}
