//go:build integration

package identity_test

import (
	"context"
	"fmt"
	"slices"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
)

// TestSuggestHandles_Integration (on the real repo, one batched handles GetAll): a reserved input answers nothing, a
// taken candidate (claimed by another instance, so this one's cache is cold) is never offered, the free ones come
// back in candidate order, capped at 5, and nothing is written.
func TestSuggestHandles_Integration(t *testing.T) {
	client := newTestClient(t)
	graphRepo := graph.NewFirestoreRepo(client)
	repo := identity.NewFirestoreRepo(client, graphRepo)
	graphRepo.SetCounters(repo)
	ctx := context.Background()

	base := fmt.Sprintf("sg%x", time.Now().UnixNano()&0xffffffff) // unique per run, at most 10 chars
	taken := base + "2"
	owner := identity.New(repo, identity.NewCache(time.Minute), 7*24*time.Hour)
	if _, err := owner.CreateProfile(ctx, "uid-"+base, "0123456789abcdef", taken, "Taken "+base); err != nil {
		t.Fatalf("CreateProfile(%s): %v", taken, err)
	}

	svc := identity.New(repo, identity.NewCache(time.Minute), 7*24*time.Hour) // fresh cache: the read decides
	tests := []struct {
		name  string
		input string
		want  []string
	}{
		{"reserved input", "admin", []string{}},
		{"invalid input", "no way!", []string{}},
		{"taken candidate skipped, free ones in order", base, []string{base + "_2", base + "3", base + "_3", base + "4", base + "_4"}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := svc.SuggestHandles(ctx, tt.input)
			if err != nil {
				t.Fatalf("SuggestHandles(%q): %v", tt.input, err)
			}
			if !slices.Equal(got, tt.want) {
				t.Errorf("SuggestHandles(%q) = %v, want %v", tt.input, got, tt.want)
			}
			if slices.Contains(got, taken) {
				t.Errorf("taken handle %q offered", taken)
			}
		})
	}

	// Read-only: none of the offered handles gained a document.
	for _, h := range []string{base + "_2", base + "3", base + "_3", base + "4", base + "_4"} {
		snap, err := client.Collection("handles").Doc(h).Get(ctx)
		if err == nil && snap.Exists() {
			t.Errorf("handles/%s exists after SuggestHandles", h)
		}
	}
}
