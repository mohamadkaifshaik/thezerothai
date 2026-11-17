package apiserver

// The uid scan's finder (public id PR 7): given a wire response, find every needle (a seeded uid, a seeded public id,
// the tombstone) in it. Untagged so its own tests run in `make test`: a finder that misses a uid hidden in a base64
// error detail, a map key or a header would make the whole scan vacuous.

import (
	"encoding/base64"
	"encoding/json"
	"net/http"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"testing"
)

// uidScanNeedle is a value that must not appear, named by the role of its owner (the raw value is never printed).
type uidScanNeedle struct{ Label, Value string }

// uidScanHit is one occurrence. Path is the JSON path of the enclosing key ("targets[0].full.url", a "(base64)"
// suffix for a decoded string, "key ..." for a map key, "header X" for a header, "$raw" when only the raw bytes hold
// it). Value is the string that holds the needle (never printed).
type uidScanHit struct {
	Label, Path, Value string
}

var uidScanIndex = regexp.MustCompile(`\[\d+\]`)

// norm is the path with array indexes folded, the form uidScanKnownLeaks and the upload exception match.
func (h uidScanHit) norm() string { return uidScanIndex.ReplaceAllString(h.Path, "[]") }

// uidScanFind scans body (a Connect JSON body, success or error) and the response headers for every needle.
func uidScanFind(body []byte, header http.Header, needles []uidScanNeedle) []uidScanHit {
	var hits []uidScanHit
	// A path never carries a raw needle (a map key can): each is replaced by {label}.
	mask := func(path string) string {
		for _, n := range needles {
			if n.Value != "" {
				path = strings.ReplaceAll(path, n.Value, "{"+n.Label+"}")
			}
		}
		return path
	}
	scanString := func(path, s string) {
		path = mask(path)
		for _, n := range needles {
			if n.Value != "" && strings.Contains(s, n.Value) {
				hits = append(hits, uidScanHit{Label: n.Label, Path: path, Value: s})
			}
		}
		// A string that is base64 of bytes holding a needle: Connect JSON carries every error detail (a protobuf) as
		// base64, and a uid inside it is invisible to a substring check on the text.
		if len(s) >= 8 {
			for _, enc := range []*base64.Encoding{base64.StdEncoding, base64.RawStdEncoding, base64.URLEncoding, base64.RawURLEncoding} {
				if dec, err := enc.DecodeString(s); err == nil {
					for _, n := range needles {
						if n.Value != "" && strings.Contains(string(dec), n.Value) {
							hits = append(hits, uidScanHit{Label: n.Label, Path: path + "(base64)", Value: string(dec)})
						}
					}
					break
				}
			}
		}
	}
	var walk func(path string, v any)
	walk = func(path string, v any) {
		switch x := v.(type) {
		case map[string]any:
			keys := make([]string, 0, len(x))
			for k := range x {
				keys = append(keys, k)
			}
			sort.Strings(keys)
			for _, k := range keys {
				child := k
				if path != "" {
					child = path + "." + k
				}
				scanString("key "+child, k)
				walk(child, x[k])
			}
		case []any:
			for i, e := range x {
				walk(path+"["+strconv.Itoa(i)+"]", e)
			}
		case string:
			scanString(path, x)
		}
	}
	var doc any
	if err := json.Unmarshal(body, &doc); err == nil {
		walk("", doc)
	} else {
		scanString("$body", string(body))
	}
	names := make([]string, 0, len(header))
	for k := range header {
		names = append(names, k)
	}
	sort.Strings(names)
	for _, k := range names {
		scanString("header "+k, k)
		for _, v := range header[k] {
			scanString("header "+k, v)
		}
	}
	// Backstop: the raw bytes (escapes the walk may not have decoded the way the needle is spelled).
	for _, n := range needles {
		if n.Value == "" || !strings.Contains(string(body), n.Value) {
			continue
		}
		found := false
		for _, h := range hits {
			found = found || h.Label == n.Label
		}
		if !found {
			hits = append(hits, uidScanHit{Label: n.Label, Path: "$raw", Value: string(body)})
		}
	}
	return hits
}

// uidScanKnownLeak is a documented leak the scan found and a follow-up must fix. The scan subtracts it (so CI stays
// green) and TestUIDScan's "known leaks are still leaking" subtest fails once an entry stops leaking, so an entry cannot
// outlive its fix. An empty table is the goal; every entry is reported in the PR.
type uidScanKnownLeak struct {
	// Proc is the procedure; Path the normalized JSON path ("posts[].author.userId"); Label the role label of the uid.
	Proc, Path, Label string
	Reason, FixIn     string
}

// uidScanKnownLeaks: nothing is known to leak.
var uidScanKnownLeaks = []uidScanKnownLeak{}

func (k uidScanKnownLeak) matches(proc string, h uidScanHit) bool {
	return k.Proc == proc && k.Path == h.norm() && (k.Label == "" || strings.HasPrefix(h.Label, k.Label))
}

func TestUIDScan_FinderSeesEveryHidingPlace(t *testing.T) {
	uid := uidScanNeedle{Label: "B", Value: "AbCdEfGhIjKlMnOpQrStUvWxYz12"}
	other := uidScanNeedle{Label: "A", Value: "ZyXwVuTsRqPoNmLkJiHgFeDcBa98"}
	detail := base64.RawStdEncoding.EncodeToString([]byte("\x0a\x05field\x12" + uid.Value))
	tests := []struct {
		name   string
		body   string
		header http.Header
		want   []string // "label path"
	}{
		{"clean", `{"posts":[{"author":{"userId":"u0123456789abcdefghjkmnpqrs"}}]}`, nil, nil},
		{"value", `{"posts":[{"author":{"userId":"` + uid.Value + `"}}]}`, nil, []string{"B posts[0].author.userId"}},
		{"embedded in an id", `{"notifications":[{"id":"follow_` + uid.Value + `"}]}`, nil, []string{"B notifications[0].id"}},
		{"map key", `{"headers":{"` + uid.Value + `":"x"}}`, nil, []string{"B key headers.{B}"}},
		{"base64 error detail", `{"code":"invalid_argument","message":"x","details":[{"type":"t","value":"` + detail + `"}]}`, nil, []string{"B details[0].value(base64)"}},
		{"error message", `{"code":"not_found","message":"no ` + uid.Value + `"}`, nil, []string{"B message"}},
		{"header", `{}`, http.Header{"X-Thing": {uid.Value}}, []string{"B header X-Thing"}},
		{"trailer", `{}`, http.Header{"Trailer-X": {"a " + other.Value}}, []string{"A header Trailer-X"}},
		{"not json", `plain ` + uid.Value, nil, []string{"B $body"}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var got []string
			for _, h := range uidScanFind([]byte(tt.body), tt.header, []uidScanNeedle{uid, other}) {
				got = append(got, h.Label+" "+h.Path)
			}
			if strings.Join(got, "|") != strings.Join(tt.want, "|") {
				t.Errorf("hits = %v, want %v", got, tt.want)
			}
		})
	}
}

func TestUIDScan_KnownLeakMatching(t *testing.T) {
	h := uidScanHit{Label: "A (mutual follow)", Path: "posts[3].author.userId"}
	if h.norm() != "posts[].author.userId" {
		t.Fatalf("norm = %q", h.norm())
	}
	k := uidScanKnownLeak{Proc: "/p/M", Path: "posts[].author.userId", Label: "A"}
	if !k.matches("/p/M", h) || k.matches("/p/Other", h) || (uidScanKnownLeak{Proc: "/p/M", Path: "posts[].id"}).matches("/p/M", h) {
		t.Error("known-leak matching is wrong")
	}
}

// TestUIDScan_KnownLeaksAreWellFormed: every entry names a registered procedure and carries its reason and the follow-up
// that fixes it (the table is empty today; this keeps an entry from being a silent mute).
func TestUIDScan_KnownLeaksAreWellFormed(t *testing.T) {
	_, methods := uidScanProcedures()
	for i, k := range uidScanKnownLeaks {
		if _, ok := methods[k.Proc]; !ok || k.Path == "" || k.Reason == "" || k.FixIn == "" {
			t.Errorf("uidScanKnownLeaks[%d] = %+v: needs a registered procedure, a path, a reason and the follow-up (FixIn)", i, k)
		}
	}
}
