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

// maxDraftsPerAuthor caps an author's unpublished drafts (pending publications included). Only creating a new
// draft id is refused at the cap; editing, publishing and deleting an existing draft always stay allowed, so an
// author already over it (drafts made before the cap) is never locked out. draftLimitName is the
// LIMIT_REACHED metadata["limit"] value the client matches.
const (
	maxDraftsPerAuthor = 50
	draftLimitName     = "article_drafts"
)

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
	Caption string    `json:"caption,omitempty"`
}

// maxArticleImages caps the inline image blocks of one article body. The alt text limit matches a post's (CreatePost:
// at most 1,000 characters); a caption is one line of at most 280 characters.
const (
	maxArticleImages     = 20
	maxImageAltRunes     = 1000
	maxImageCaptionRunes = 280
)

var controls = regexp.MustCompile(`[\x00-\x08\x0b\x0c\x0e-\x1f\x7f\x{202a}-\x{202e}\x{2066}-\x{2069}]`)
var validID = regexp.MustCompile(`^[A-Za-z0-9_-]{16,64}$`)

// contentInfo is what a valid body yields: its excerpt and the media ids of its inline image blocks, in body order.
type contentInfo struct {
	Excerpt  string
	ImageIDs []string
}

func validateContent(title, body string, publishing bool) (string, error) {
	info, err := inspectContent(title, body, publishing)
	return info.Excerpt, err
}

func inspectContent(title, body string, publishing bool) (contentInfo, error) {
	if !utf8.ValidString(title) || utf8.RuneCountInString(title) > 100 || strings.ContainsAny(title, "\r\n") || controls.MatchString(title) || (publishing && strings.TrimSpace(title) == "") {
		return contentInfo{}, apierr.Validation("title", "title must be a single line of at most 100 characters")
	}
	if len(body) > maxBodyBytes || !utf8.ValidString(body) {
		return contentInfo{}, apierr.Validation("body", "article body is too large")
	}
	var blocks []block
	dec := json.NewDecoder(strings.NewReader(body))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&blocks); err != nil || blocks == nil || len(blocks) > 1000 {
		return contentInfo{}, apierr.Validation("body", "invalid structured article body")
	}
	if dec.Decode(new(any)) != io.EOF {
		return contentInfo{}, apierr.Validation("body", "invalid trailing article content")
	}
	var text strings.Builder
	var imageIDs []string
	seen := make(map[string]bool)
	for _, b := range blocks {
		switch b.Kind {
		case "paragraph", "heading1", "heading2", "quote", "bulletedListItem", "numberedListItem", "code":
			if b.MediaID != "" || b.AltText != "" || b.Caption != "" {
				return contentInfo{}, apierr.Validation("body", "media fields on a text block")
			}
		case "image":
			// An image block names one media id the author owns and that is not yet attached (checked by the service
			// and again inside the publication transaction). Only the reference and its alt text and caption are stored.
			if len(b.Runs) != 0 || !validID.MatchString(b.MediaID) {
				return contentInfo{}, apierr.Validation("body", "invalid image block")
			}
			if !utf8.ValidString(b.AltText) || utf8.RuneCountInString(b.AltText) > maxImageAltRunes || controls.MatchString(b.AltText) {
				return contentInfo{}, apierr.Validation("body", "image alt text is too long or has invalid characters")
			}
			if !utf8.ValidString(b.Caption) || utf8.RuneCountInString(b.Caption) > maxImageCaptionRunes || controls.MatchString(b.Caption) {
				return contentInfo{}, apierr.Validation("body", "image caption is too long or has invalid characters")
			}
			if seen[b.MediaID] {
				return contentInfo{}, apierr.Validation("body", "an image appears more than once")
			}
			seen[b.MediaID] = true
			imageIDs = append(imageIDs, b.MediaID)
			if len(imageIDs) > maxArticleImages {
				return contentInfo{}, apierr.Validation("body", "an article has at most 20 images")
			}
		case "divider":
			if len(b.Runs) != 0 || b.MediaID != "" || b.AltText != "" || b.Caption != "" {
				return contentInfo{}, apierr.Validation("body", "invalid divider")
			}
		default:
			return contentInfo{}, apierr.Validation("body", "unknown article block")
		}
		for _, r := range b.Runs {
			if controls.MatchString(r.Text) {
				return contentInfo{}, apierr.Validation("body", "article contains invalid control characters")
			}
			for _, mark := range r.Marks {
				switch mark {
				case "bold", "italic", "underline", "strikethrough", "code":
				default:
					return contentInfo{}, apierr.Validation("body", "unknown article mark")
				}
			}
			if r.Link != "" {
				u, e := url.Parse(r.Link)
				if e != nil || (u.Scheme != "https" && u.Scheme != "http") || u.Hostname() == "" || u.User != nil {
					return contentInfo{}, apierr.Validation("body", "article links must be HTTP(S)")
				}
			}
			text.WriteString(r.Text)
		}
		text.WriteByte('\n')
	}
	plain := strings.TrimSpace(text.String())
	// An article of images alone may publish: its caption or title is the post text.
	if utf8.RuneCountInString(plain) > 100000 || (publishing && plain == "" && len(imageIDs) == 0) {
		return contentInfo{}, apierr.Validation("body", "article needs a body of at most 100000 characters")
	}
	excerpt := []rune(strings.Join(strings.Fields(plain), " "))
	if len(excerpt) > maxPreviewExcerptRunes {
		excerpt = excerpt[:maxPreviewExcerptRunes]
	}
	return contentInfo{Excerpt: string(excerpt), ImageIDs: imageIDs}, nil
}

// imageIDsOf is the lenient reading of a stored body's image block ids, in body order (a row written under older rules
// still reads; a body that does not decode has none).
func imageIDsOf(body string) []string {
	var blocks []block
	if err := json.Unmarshal([]byte(body), &blocks); err != nil {
		return nil
	}
	var ids []string
	for _, b := range blocks {
		if b.Kind == "image" && b.MediaID != "" {
			ids = append(ids, b.MediaID)
		}
	}
	return ids
}

// Two excerpt lengths on purpose: maxPreviewExcerptRunes bounds the excerpt frozen into the root post's
// ArticlePreview at publication (timeline cards); maxExcerptRunes bounds Article.excerpt, computed on read for the
// author's library (proto contract: at most 280 code points).
const (
	maxPreviewExcerptRunes = 160
	maxExcerptRunes        = 280
)

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
