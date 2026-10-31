package engagement

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"testing"
	"time"
)

type fakePollPurger struct {
	pages []int // deleted count per call
	calls int
	err   error
}

func (f *fakePollPurger) PurgePollVotesPage(context.Context, string) (int, error) {
	f.calls++
	if f.err != nil {
		return 0, f.err
	}
	if f.calls > len(f.pages) {
		return 0, nil
	}
	return f.pages[f.calls-1], nil
}

// The step deletes a page per call and finishes on the first short page, including the empty page of an account that never voted
// and the re-run of a finished one.
func TestPollVoteEraser_PurgeUser(t *testing.T) {
	tests := []struct {
		name        string
		pages       []int
		wantDone    []bool
		wantDeleted int
	}{
		{"never voted", nil, []bool{true}, 0},
		{"120 votes", []int{120}, []bool{true}, 120},
		{"exactly one full page needs the empty page after it", []int{500}, []bool{false, true}, 500},
		{"a full page then a short one", []int{500, 3}, []bool{false, true}, 503},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			f := &fakePollPurger{pages: tt.pages}
			e := NewPollVoteEraser(f)
			cp := PollVoteCheckpoint{}
			for i, want := range tt.wantDone {
				var done bool
				var err error
				if cp, done, err = e.PurgeUser(context.Background(), "u1", cp); err != nil {
					t.Fatal(err)
				}
				if done != want {
					t.Fatalf("call %d: done = %v, want %v", i, done, want)
				}
			}
			if cp.Deleted != tt.wantDeleted || f.calls != len(tt.wantDone) {
				t.Errorf("deleted %d calls %d, want %d/%d", cp.Deleted, f.calls, tt.wantDeleted, len(tt.wantDone))
			}
		})
	}
	t.Run("an error keeps the checkpoint and does not finish", func(t *testing.T) {
		boom := errors.New("boom")
		cp := PollVoteCheckpoint{Deleted: 5}
		next, done, err := NewPollVoteEraser(&fakePollPurger{err: boom}).PurgeUser(context.Background(), "u1", cp)
		if !errors.Is(err, boom) || done || next != cp {
			t.Errorf("next %+v done %v err %v", next, done, err)
		}
	})
}

type fakePollVoteSource struct {
	rows   []ExportedPollVote
	afters []string
}

func (f *fakePollVoteSource) ExportPollVotesPage(_ context.Context, _, afterID string, limit int) ([]ExportedPollVote, error) {
	f.afters = append(f.afters, afterID)
	start := 0
	if afterID != "" {
		for i, r := range f.rows {
			if r.id == afterID {
				start = i + 1
			}
		}
	}
	return f.rows[start:min(start+limit, len(f.rows))], nil
}

// The export streams valid JSON in pages of 500, each row exactly post id, choice and time (the user's own vote, nothing else).
func TestPollVoteExporter_ExportUser(t *testing.T) {
	for _, n := range []int{0, 1, 120, 500, 501, 1000} {
		t.Run(fmt.Sprint(n, " votes"), func(t *testing.T) {
			src := &fakePollVoteSource{}
			base := time.Date(2026, 10, 1, 0, 0, 0, 0, time.UTC)
			for i := range n {
				post := fmt.Sprintf("%019d", 1000+i)
				src.rows = append(src.rows, ExportedPollVote{PostID: post, Choice: i % 4, CreatedAt: base.Add(time.Duration(i) * time.Minute), id: post + "_u1"})
			}
			var buf bytes.Buffer
			if err := NewPollVoteExporter(src).ExportUser(context.Background(), "u1", &buf); err != nil {
				t.Fatal(err)
			}
			var doc struct {
				Votes []map[string]any `json:"poll_votes"`
			}
			if err := json.Unmarshal(buf.Bytes(), &doc); err != nil {
				t.Fatalf("export is not valid JSON: %v\n%.200s", err, buf.String())
			}
			if len(doc.Votes) != n {
				t.Fatalf("rows = %d, want %d", len(doc.Votes), n)
			}
			for _, r := range doc.Votes {
				if len(r) != 3 || r["postId"] == nil || r["choice"] == nil || r["createdAt"] == nil {
					t.Fatalf("row = %v, want exactly postId, choice and createdAt", r)
				}
			}
			if wantPages := n/pollVotePage + 1; len(src.afters) != wantPages || src.afters[0] != "" {
				t.Errorf("pages = %d (first cursor %q), want %d from the start", len(src.afters), src.afters[0], wantPages)
			}
		})
	}
}
