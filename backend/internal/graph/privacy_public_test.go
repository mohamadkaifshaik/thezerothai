package graph

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"strings"
	"sync"
	"testing"
	"time"
)

// W3-28b (ADR-0025 D8): the privacy_public job's handler and listener over a fake page source.

type fakePager struct {
	mu    sync.Mutex
	pages []PendingPageResult
	err   error
	calls []PendingPageArgs
}

func (f *fakePager) AcceptPendingPage(_ context.Context, a PendingPageArgs) (PendingPageResult, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls = append(f.calls, a)
	if f.err != nil {
		return PendingPageResult{}, f.err
	}
	i := len(f.calls) - 1
	if i >= len(f.pages) {
		return PendingPageResult{}, nil
	}
	return f.pages[i], nil
}

type acceptEvents struct {
	mu  sync.Mutex
	got [][2]string
}

func (a *acceptEvents) Followed(context.Context, string, string, time.Time)        {}
func (a *acceptEvents) FollowRequested(context.Context, string, string, time.Time) {}
func (a *acceptEvents) FollowRequestAccepted(_ context.Context, target, requester string, _ time.Time) {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.got = append(a.got, [2]string{target, requester})
}

func fullPage(prefix string, n int) PendingPageResult {
	r := PendingPageResult{Scanned: n, Last: &PendingCursor{ID: fmt.Sprintf("%s-last", prefix)}}
	for i := 0; i < n; i++ {
		r.Accepted = append(r.Accepted, fmt.Sprintf("%s%03d", prefix, i))
	}
	return r
}

func newJob(p PendingAccepter, ev FollowEvents) *PrivacyPublicJob {
	repo, dir := requestsFixture(0)
	svc := requestsSvc(repo, dir, ev)
	return svc.PrivacyPublicJob(p, nil)
}

func TestPrivacyPublicJob_Run(t *testing.T) {
	boom := errors.New("boom")
	tests := []struct {
		name        string
		pages       []PendingPageResult
		err         error
		wantOutcome string
		wantErr     error
		wantCalls   int
		wantEvents  int
	}{
		{"no requests", []PendingPageResult{{}}, nil, "done", nil, 1, 0},
		{"one short page", []PendingPageResult{{Scanned: 1, Accepted: []string{"a"}}}, nil, "done", nil, 1, 1},
		{"two pages then done", []PendingPageResult{fullPage("a", 100), {Scanned: 50, Accepted: []string{"x"}}}, nil, "done", nil, 2, 101},
		{"exact multiple ends on an empty page", []PendingPageResult{fullPage("a", 100), {}}, nil, "done", nil, 2, 100},
		{"re-protected stops", []PendingPageResult{{Stop: "protected"}}, nil, "stopped:protected", nil, 1, 0},
		{"re-protected between pages stops", []PendingPageResult{fullPage("a", 100), {Stop: "protected"}}, nil, "stopped:protected", nil, 2, 100},
		{"target gone", []PendingPageResult{{Stop: "target_gone"}}, nil, "stopped:target_gone", nil, 1, 0},
		{"error nacks", nil, boom, "", boom, 1, 0},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			p := &fakePager{pages: tc.pages, err: tc.err}
			ev := &acceptEvents{}
			job := newJob(p, ev)
			got, err := job.Run(context.Background(), "uid-p")
			if !errors.Is(err, tc.wantErr) || got != tc.wantOutcome {
				t.Fatalf("Run = %q, %v; want %q, %v", got, err, tc.wantOutcome, tc.wantErr)
			}
			if len(p.calls) != tc.wantCalls || len(ev.got) != tc.wantEvents {
				t.Errorf("calls = %d, events = %d; want %d, %d", len(p.calls), len(ev.got), tc.wantCalls, tc.wantEvents)
			}
			for i, c := range p.calls {
				if c.Limit != 100 || c.TargetUID != "uid-p" || c.Active == nil {
					t.Errorf("call %d args = %+v", i, c)
				}
				if (i == 0) != (c.After == nil) {
					t.Errorf("call %d cursor = %v, want nil only on the first page", i, c.After)
				}
			}
			for _, e := range ev.got {
				if e[0] != "uid-p" {
					t.Errorf("event target = %q, want uid-p", e[0])
				}
			}
		})
	}
}

func TestPrivacyPublicJob_BoundedPerDelivery(t *testing.T) {
	// A delivery that accepted something and still has more is nacked, so the next delivery continues.
	var pages []PendingPageResult
	for i := 0; i < privacyPublicMaxPages+1; i++ {
		pages = append(pages, PendingPageResult{Scanned: 100, Accepted: []string{"a"}, Last: &PendingCursor{ID: "x"}})
	}
	p := &fakePager{pages: pages}
	_, err := newJob(p, nil).Run(context.Background(), "uid-p")
	if !errors.Is(err, ErrPrivacyPublicMore) || len(p.calls) != privacyPublicMaxPages {
		t.Fatalf("err = %v after %d pages, want ErrPrivacyPublicMore after %d", err, len(p.calls), privacyPublicMaxPages)
	}
}

// TestPrivacyPublicJob_StuckAcks is W3-40b O-1: a delivery whose every page was skipped acks as "stuck" with a counts-only
// log line instead of nacking; one inactive request dropped, or one accepted, is progress and still nacks.
func TestPrivacyPublicJob_StuckAcks(t *testing.T) {
	full := func(mut func(*PendingPageResult)) []PendingPageResult {
		var pages []PendingPageResult
		for i := 0; i < privacyPublicMaxPages+1; i++ {
			r := PendingPageResult{Scanned: 100, SkippedCap: 100, Last: &PendingCursor{ID: "x"}}
			if i == privacyPublicMaxPages-1 && mut != nil {
				mut(&r)
			}
			pages = append(pages, r)
		}
		return pages
	}
	tests := []struct {
		name        string
		pages       []PendingPageResult
		wantStuck   bool
		wantScanned int
	}{
		{"every page skipped at the cap", full(nil), true, 100 * privacyPublicMaxPages},
		{"last page accepted one", full(func(r *PendingPageResult) { r.Accepted = []string{"a"}; r.SkippedCap = 99 }), false, 0},
		{"last page dropped one inactive", full(func(r *PendingPageResult) { r.SkippedInactive = 1; r.SkippedCap = 99 }), false, 0},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var buf bytes.Buffer
			p := &fakePager{pages: tt.pages}
			job := newJob(p, nil)
			job.log = slog.New(slog.NewJSONHandler(&buf, nil))
			out, err := job.Run(context.Background(), "uid-p")
			if len(p.calls) != privacyPublicMaxPages {
				t.Fatalf("pages = %d, want %d", len(p.calls), privacyPublicMaxPages)
			}
			if !tt.wantStuck {
				if !errors.Is(err, ErrPrivacyPublicMore) {
					t.Fatalf("out=%q err=%v, want ErrPrivacyPublicMore", out, err)
				}
				return
			}
			if err != nil || out != "stuck" {
				t.Fatalf("out=%q err=%v, want an ack with outcome stuck", out, err)
			}
			var last map[string]any
			for _, line := range strings.Split(strings.TrimSpace(buf.String()), "\n") {
				var m map[string]any
				if json.Unmarshal([]byte(line), &m) == nil && m["outcome"] == "stuck" {
					last = m
				}
			}
			if last == nil || last["level"] != "WARN" || int(last["scanned"].(float64)) != tt.wantScanned ||
				int(last["skipped_cap"].(float64)) != tt.wantScanned || int(last["pages"].(float64)) != privacyPublicMaxPages {
				t.Fatalf("stuck log = %v", last)
			}
			if strings.Contains(buf.String(), "uid-p") {
				t.Fatalf("the log line holds a raw uid: %s", buf.String())
			}
		})
	}
}

func TestPrivacyPublicJob_Handle(t *testing.T) {
	good, _ := json.Marshal(PrivacyPublicMessage{Kind: JobKindPrivacyPublic, UID: "uid-p", At: time.Now()})
	wrongKind, _ := json.Marshal(PrivacyPublicMessage{Kind: "other", UID: "uid-p"})
	badUID, _ := json.Marshal(PrivacyPublicMessage{Kind: JobKindPrivacyPublic, UID: "a_b"})
	noUID, _ := json.Marshal(PrivacyPublicMessage{Kind: JobKindPrivacyPublic})
	tests := []struct {
		name      string
		data      []byte
		want      string
		wantCalls int
	}{
		{"good", good, "done", 1},
		{"malformed", []byte("{nope"), "dropped:malformed_message", 0},
		{"wrong kind", wrongKind, "dropped:invalid_message", 0},
		{"reserved separator in uid", badUID, "dropped:invalid_message", 0},
		{"no uid", noUID, "dropped:invalid_message", 0},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			p := &fakePager{}
			got, err := newJob(p, nil).Handle(context.Background(), tc.data)
			if err != nil || got != tc.want || len(p.calls) != tc.wantCalls {
				t.Fatalf("Handle = %q, %v after %d calls; want %q after %d", got, err, len(p.calls), tc.want, tc.wantCalls)
			}
		})
	}
}

type fakeJobPub struct {
	data []byte
	err  error
}

func (f *fakeJobPub) Publish(_ context.Context, data []byte) error {
	f.data = data
	return f.err
}

func TestPrivacyListener_BecamePublic(t *testing.T) {
	pub := &fakeJobPub{}
	at := time.Date(2026, 10, 28, 1, 2, 3, 0, time.UTC)
	if err := NewPrivacyListener(pub).BecamePublic(context.Background(), "uid-p", at); err != nil {
		t.Fatal(err)
	}
	var m PrivacyPublicMessage
	if err := json.Unmarshal(pub.data, &m); err != nil || m.Kind != JobKindPrivacyPublic || m.UID != "uid-p" || !m.At.Equal(at) {
		t.Fatalf("message = %s (%v)", pub.data, err)
	}
	if err := NewPrivacyListener(&fakeJobPub{err: errors.New("down")}).BecamePublic(context.Background(), "uid-p", at); err == nil {
		t.Error("a publish failure must be returned (identity logs it)")
	}
	if err := NewPrivacyListener(nil).BecamePublic(context.Background(), "uid-p", at); err == nil {
		t.Error("no publisher must be an error, not a panic")
	}
}
