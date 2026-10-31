//go:build integration

package main

import (
	"bytes"
	"context"
	"strings"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/lists"
)

// End-to-end emulator test of `opsctl lists hide|restore` (plan W5-44): the real run() flag handling and output over the real
// lists.FirestoreRepo. The cost line is the budget assertion: 1 read and, when the flag changes, 1 write.
func TestLists_Integration_CLI(t *testing.T) {
	client, project := backfillTestClient(t)
	ctx := context.Background()
	const id = "0000000000000004242"
	if _, err := client.Collection("lists").Doc(id).Set(ctx, map[string]any{
		"ownerId": "u-owner", "name": "Cricket", "description": "ODI", "isPrivate": false, "memberIds": []string{"u1"},
		"createdAt": time.Now().UTC(), "updatedAt": time.Now().UTC().Add(-time.Hour),
	}); err != nil {
		t.Fatal(err)
	}
	runCLI := func(args ...string) (code int, stdout, stderr string) {
		open := func(context.Context, string) (*backends, error) {
			return &backends{lists: lists.NewFirestoreRepo(client, nil, nil), close: func() {}}, nil
		}
		var out, errOut bytes.Buffer
		code = run(ctx, args, strings.NewReader(""), &out, &errOut, open, func() time.Time { return time.Date(2026, 10, 31, 12, 0, 0, 0, time.UTC) })
		return code, out.String(), errOut.String()
	}
	steps := []struct {
		name       string
		args       []string
		code       int
		want       []string
		wantHidden any // value of the stored field after the step (nil = absent)
	}{
		{"hide", []string{"lists", "hide", id}, 0, []string{"hidden: list_hash=", "wrote=true", "cost: reads=1 writes=1"}, true},
		{"hide again", []string{"lists", "hide", id}, 0, []string{"already hidden", "wrote=false", "cost: reads=1 writes=0"}, true},
		{"dry-run restore", []string{"lists", "restore", id, "--dry-run"}, 0, []string{"currently hidden=true", "cost: reads=1 writes=0"}, true},
		{"restore", []string{"lists", "restore", id}, 0, []string{"restored: list_hash=", "wrote=true", "cost: reads=1 writes=1"}, nil},
		{"restore again", []string{"lists", "restore", id}, 0, []string{"not hidden", "wrote=false", "cost: reads=1 writes=0"}, nil},
	}
	for _, s := range steps {
		code, out, errOut := runCLI(append(s.args, "--project", project)...)
		if code != s.code {
			t.Fatalf("%s: code %d stderr %q", s.name, code, errOut)
		}
		for _, w := range s.want {
			if !strings.Contains(out, w) {
				t.Errorf("%s: output lacks %q:\n%s", s.name, w, out)
			}
		}
		snap, err := client.Collection("lists").Doc(id).Get(ctx)
		if err != nil {
			t.Fatal(err)
		}
		got, _ := snap.DataAt("hidden")
		if s.wantHidden == nil {
			if _, err := snap.DataAt("hidden"); err == nil {
				t.Errorf("%s: hidden = %v, want the field absent", s.name, got)
			}
		} else if got != s.wantHidden {
			t.Errorf("%s: hidden = %v, want %v", s.name, got, s.wantHidden)
		}
		if n, _ := snap.DataAt("name"); n != "Cricket" {
			t.Errorf("%s: name = %v", s.name, n)
		}
	}

	// A missing list is refused with exit 1, writes nothing and creates nothing.
	code, out, errOut := runCLI("lists", "hide", "0000000000000009999", "--project", project)
	if code != 1 || !strings.Contains(errOut, "no such list") || !strings.Contains(out, "cost: reads=1 writes=0") {
		t.Errorf("missing: code=%d stdout=%q stderr=%q", code, out, errOut)
	}
	if _, err := client.Collection("lists").Doc("0000000000000009999").Get(ctx); err == nil {
		t.Error("the hide created a list document")
	}
}
