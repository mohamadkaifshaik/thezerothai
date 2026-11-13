package main

import (
	"bytes"
	"context"
	"errors"
	"strings"
	"testing"
	"time"
)

// fakeShareCounts is both halves of recount-shares: the stored counter and the marker count.
type fakeShareCounts struct {
	stored, markers int64
	missing         bool
	setErr          error
	set             []int64
}

func (f *fakeShareCounts) StoredShareCount(context.Context, string) (int64, bool, error) {
	return f.stored, !f.missing, nil
}
func (f *fakeShareCounts) SetShareCount(_ context.Context, _ string, n int64) error {
	if f.setErr != nil {
		return f.setErr
	}
	f.set = append(f.set, n)
	return nil
}
func (f *fakeShareCounts) CountShares(context.Context, string) (int64, error) { return f.markers, nil }

func TestRecountShares(t *testing.T) {
	const pid = "0000000000000000001"
	tests := []struct {
		name     string
		f        *fakeShareCounts
		args     []string
		code     int
		wantSet  []int64
		wantOut  string
		wantErr  string
		noOpener bool
	}{
		{name: "dry run by default", f: &fakeShareCounts{stored: 5, markers: 3}, args: []string{"--post", pid},
			wantOut: "dry-run: would set share_count to 3"},
		{name: "write repairs", f: &fakeShareCounts{stored: 5, markers: 3}, args: []string{"--post", pid, "--write"},
			wantSet: []int64{3}, wantOut: "set share_count to 3"},
		{name: "in step writes nothing", f: &fakeShareCounts{stored: 2, markers: 2}, args: []string{"--post", pid, "--write"},
			wantOut: "in step"},
		{name: "missing post", f: &fakeShareCounts{missing: true}, args: []string{"--post", pid}, code: 1, wantErr: "not found"},
		{name: "write fails", f: &fakeShareCounts{stored: 1, setErr: errors.New("boom")}, args: []string{"--post", pid, "--write"}, code: 1, wantErr: "boom"},
		{name: "bad post id", f: &fakeShareCounts{}, args: []string{"--post", "12"}, code: 2, wantErr: "19-digit"},
		{name: "--dry-run is refused (the default already is one)", f: &fakeShareCounts{}, args: []string{"--post", pid, "--dry-run"}, code: 2, noOpener: true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var out, errOut bytes.Buffer
			opened := 0
			open := func(context.Context, string) (*backends, error) {
				opened++
				return &backends{shareMarkers: tt.f, shareCounts: tt.f, close: func() {}}, nil
			}
			args := append([]string{"recount-shares", "--project", "demo-dev"}, tt.args...)
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
			if len(tt.f.set) != len(tt.wantSet) || (len(tt.wantSet) == 1 && tt.f.set[0] != tt.wantSet[0]) {
				t.Fatalf("set = %v, want %v", tt.f.set, tt.wantSet)
			}
			if tt.noOpener && opened != 0 {
				t.Fatal("a usage error opened the backends")
			}
		})
	}
	// --write is refused by any other command.
	var out, errOut bytes.Buffer
	code := run(context.Background(), []string{"restore-post", "--project", "demo-dev", "--post", pid, "--write"}, strings.NewReader(""), &out, &errOut,
		func(context.Context, string) (*backends, error) { t.Fatal("opened"); return nil, nil }, time.Now)
	if code != 2 || !strings.Contains(errOut.String(), "--write is not supported") {
		t.Fatalf("code=%d err=%q", code, errOut.String())
	}
}
