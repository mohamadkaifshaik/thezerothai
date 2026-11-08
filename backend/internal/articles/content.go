// Package articles owns structured article drafts and separately authorized bodies.
package articles

import (
	"encoding/json"
	"io"
	"net/url"
	"regexp"
	"strings"
	"unicode/utf8"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
)

// These are project limits, not claims about X's server implementation.
const maxBodyBytes = 180000

type textRun struct {
	Text  string   `json:"text"`
	Marks []string `json:"marks"`
	Link  string   `json:"link,omitempty"`
}
type block struct {
	Kind    string    `json:"kind"`
	Runs    []textRun `json:"runs"`
	MediaID string    `json:"mediaId,omitempty"`
	AltText string    `json:"altText,omitempty"`
}

var controls = regexp.MustCompile(`[\x00-\x08\x0b\x0c\x0e-\x1f\x7f\x{202a}-\x{202e}\x{2066}-\x{2069}]`)
var validID = regexp.MustCompile(`^[A-Za-z0-9_-]{16,64}$`)

func validateContent(title, body string, publishing bool) (string, error) {
	if !utf8.ValidString(title) || utf8.RuneCountInString(title) > 100 || strings.ContainsAny(title, "\r\n") || controls.MatchString(title) || (publishing && strings.TrimSpace(title) == "") {
		return "", apierr.Validation("title", "title must be a single line of at most 100 characters")
	}
	if len(body) > maxBodyBytes || !utf8.ValidString(body) {
		return "", apierr.Validation("body", "article body is too large")
	}
	var blocks []block
	dec := json.NewDecoder(strings.NewReader(body))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&blocks); err != nil || blocks == nil || len(blocks) > 1000 {
		return "", apierr.Validation("body", "invalid structured article body")
	}
	if dec.Decode(new(any)) != io.EOF {
		return "", apierr.Validation("body", "invalid trailing article content")
	}
	var text strings.Builder
	for _, b := range blocks {
		switch b.Kind {
		case "paragraph", "heading1", "heading2", "quote", "bulletedListItem", "numberedListItem", "code":
			if b.MediaID != "" || b.AltText != "" {
				return "", apierr.Validation("body", "media fields on a text block")
			}
		case "image":
			// Inline media needs a multi-image reservation lifecycle; reject it rather
			// than persisting an unowned or unclaimed media reference.
			return "", apierr.Validation("body", "inline images are not available yet; use a cover image")
		case "divider":
			if len(b.Runs) != 0 || b.MediaID != "" || b.AltText != "" {
				return "", apierr.Validation("body", "invalid divider")
			}
		default:
			return "", apierr.Validation("body", "unknown article block")
		}
		for _, r := range b.Runs {
			if controls.MatchString(r.Text) {
				return "", apierr.Validation("body", "article contains invalid control characters")
			}
			for _, mark := range r.Marks {
				switch mark {
				case "bold", "italic", "underline", "strikethrough", "code":
				default:
					return "", apierr.Validation("body", "unknown article mark")
				}
			}
			if r.Link != "" {
				u, e := url.Parse(r.Link)
				if e != nil || (u.Scheme != "https" && u.Scheme != "http") || u.Hostname() == "" || u.User != nil {
					return "", apierr.Validation("body", "article links must be HTTP(S)")
				}
			}
			text.WriteString(r.Text)
		}
		text.WriteByte('\n')
	}
	plain := strings.TrimSpace(text.String())
	if utf8.RuneCountInString(plain) > 100000 || (publishing && plain == "") {
		return "", apierr.Validation("body", "article needs a body of at most 100000 characters")
	}
	excerpt := []rune(strings.Join(strings.Fields(plain), " "))
	if len(excerpt) > 160 {
		excerpt = excerpt[:160]
	}
	return string(excerpt), nil
}

// maxExcerptRunes bounds Article.excerpt (proto contract: at most 280 code points).
const maxExcerptRunes = 280

// plainText is the lenient reading of a stored body for derived text (list excerpts, report evidence): the runs of
// every block, one line per block. It never validates (a row written under older rules still reads) and answers ""
// for a body that does not decode.
func plainText(body string) string {
	var blocks []block
	if err := json.Unmarshal([]byte(body), &blocks); err != nil {
		return ""
	}
	var text strings.Builder
	for _, b := range blocks {
		for _, r := range b.Runs {
			text.WriteString(r.Text)
		}
		text.WriteByte('\n')
	}
	return strings.TrimSpace(text.String())
}

// excerptOf is the whitespace-collapsed plain text of body, cut at maxExcerptRunes code points.
func excerptOf(body string) string {
	return truncateRunes(strings.Join(strings.Fields(plainText(body)), " "), maxExcerptRunes)
}

// truncateRunes cuts s to at most n code points, never inside one.
func truncateRunes(s string, n int) string {
	if utf8.RuneCountInString(s) <= n {
		return s
	}
	return string([]rune(s)[:n])
}

// truncateBytes cuts s to at most n bytes of UTF-8, never inside a code point.
func truncateBytes(s string, n int) string {
	if len(s) <= n {
		return s
	}
	for n > 0 && !utf8.RuneStart(s[n]) {
		n--
	}
	return s[:n]
}
