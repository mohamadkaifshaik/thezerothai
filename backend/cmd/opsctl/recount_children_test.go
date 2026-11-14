package main

import (
	"bytes"
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/posts"
)

// fakeChildCounts is posts' ChildRecounter: a stored counter and a counted value per post, recording writes.
type fakeChildCounts struct {
	stored, counted int64
	missing         bool
	err             error
	calls           []posts.ChildCount
	writes          int
}

func (f *fakeChildCounts) RecountChildren(_ context.Context, _ string, which posts.ChildCount, write bool) (posts.ChildRecount, error) {
	f.calls = append(f.calls, which)
	switch {
	case f.missing:
		return posts.ChildRecount{}, posts.ErrNotFound
	case f.err != nil:
		return posts.ChildRecount{}, f.err
	}
	out := posts.ChildRecount{Stored: f.stored, Counted: f.counted}
	if write && f.stored != f.counted {
		out.Written = true
		f.writes++
	}
	return out, nil
}

func TestRecountChildren(t *testing.T) {
	const pid = "0000000000000000001"
	tests := []struct {
		name       string
		cmd        string
		f          *fakeChildCounts
		args       []string
		code       int
		wantWhich  posts.ChildCount
		wantWrites int
		wantOut    string
		wantErr    string
		noOpener   bool
	}{
		{name: "replies dry run by default", cmd: "recount-replies", f: &fakeChildCounts{stored: 9, counted: 4}, args: []string{"--post", pid},
			wantWhich: posts.ChildReplies, wantOut: "dry-run: would set reply_count to 4"},
		{name: "replies write repairs", cmd: "recount-replies", f: &fakeChildCounts{stored: 9, counted: 4}, args: []string{"--post", pid, "--write"},
			wantWhich: posts.ChildReplies, wantWrites: 1, wantOut: "set reply_count to 4"},
		{name: "quotes write repairs", cmd: "recount-quotes", f: &fakeChildCounts{stored: 3, counted: 1}, args: []string{"--post", pid, "--write"},
			wantWhich: posts.ChildQuotes, wantWrites: 1, wantOut: "set quote_count to 1"},
		{name: "in step writes nothing", cmd: "recount-quotes", f: &fakeChildCounts{stored: 2, counted: 2}, args: []string{"--post", pid, "--write"},
			wantWhich: posts.ChildQuotes, wantOut: "in step"},
		{name: "missing post", cmd: "recount-replies", f: &fakeChildCounts{missing: true}, args: []string{"--post", pid}, code: 1, wantErr: "not found"},
		{name: "recount fails", cmd: "recount-replies", f: &fakeChildCounts{err: errors.New("boom")}, args: []string{"--post", pid, "--write"}, code: 1, wantErr: "boom"},
		{name: "bad post id", cmd: "recount-quotes", f: &fakeChildCounts{}, args: []string{"--post", "12"}, code: 2, wantErr: "19-digit"},
		{name: "--dry-run is refused (the default already is one)", cmd: "recount-replies", f: &fakeChildCounts{}, args: []string{"--post", pid, "--dry-run"}, code: 2, noOpener: true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var out, errOut bytes.Buffer
			opened := 0
			open := func(context.Context, string) (*backends, error) {
				opened++
				return &backends{childCounts: tt.f, close: func() {}}, nil
			}
			args := append([]string{tt.cmd, "--project", "demo-dev"}, tt.args...)
			code := run(context.Background(), args, strings.NewReader(""), &out, &errOut, open, func() time.Time { return time.Unix(0, 0) })
			if code != tt.code {
				t.Fatalf("code = %d, want %d (out %q, err %q)", code, tt.code, out.String(), errOut.String())
			}
			if tt.wantOut != "" && !strings.Contains(out.String(), tt.wantOut) {
				t.Fatalf("out = %q, want %q", out.String(), tt.wantOut)
			}
			if tt.wantErr != "" && !strings.Contains(errOut.String(), tt.wantErr) {
				t.Fatalf("err = %q, want %q", errOut.String(), tt.wantErr)
			}
			if tt.code == 0 && (len(tt.f.calls) != 1 || tt.f.calls[0] != tt.wantWhich) {
				t.Fatalf("calls = %v, want one for %v", tt.f.calls, tt.wantWhich)
			}
			if tt.f.writes != tt.wantWrites {
				t.Fatalf("writes = %d, want %d", tt.f.writes, tt.wantWrites)
			}
			if tt.noOpener && opened != 0 {
				t.Fatal("a usage error opened the backends")
			}
		})
	}
	// The help names both commands and the moderation decision.
	var out, errOut bytes.Buffer
	run(context.Background(), nil, strings.NewReader(""), &out, &errOut, nil, time.Now)
	for _, w := range []string{"recount-replies", "recount-quotes", "whatever its moderation"} {
		if !strings.Contains(errOut.String(), w) {
			t.Errorf("usage lacks %q", w)
		}
	}
}
