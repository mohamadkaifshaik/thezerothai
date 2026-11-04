//go:build integration

package messaging

import (
	"bytes"
	"strings"
	"testing"

	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
)

// export part on the emulator (security review M-2): carol blocked alice and then renamed; alice's export shows the
// handle frozen on her entry ("h-uid-carol"), never the live "carol-renamed", while bob (not blocked) shows the live handle.
// Budget: 2 conversations + 1 message each + 1 caller graph read + 1 entry read for the one blocked conversation = 6; 0 writes.
func TestExport_BlockedPeerFrozenHandleOnEmulator(t *testing.T) {
	e := newIT(t, func(e *itEnv) {
		e.addUser("uid-carol", "carol-renamed", false)
	})
	e.addUser(bob, "bob-live", false)
	e.seedConversation(alice, "uid-carol", stateAccepted, base, [2]string{"uid-carol", "hello"})
	e.seedConversation(alice, bob, stateAccepted, base.Add(1), [2]string{alice, "hi"})
	e.social.mu.Lock()
	e.social.snaps = map[string]graph.Snapshot{alice: {BlockedBy: map[string]bool{"uid-carol": true}}}
	e.social.mu.Unlock()

	var buf bytes.Buffer
	ctx, _ := budget.WithCounter(t.Context())
	if err := NewExporter(e.repo, e.profs, chargedSocial{e.social}).ExportUser(ctx, alice, &buf); err != nil {
		t.Fatal(err)
	}
	got := buf.String()
	if !strings.Contains(got, `"peerHandle":"h-uid-carol"`) || strings.Contains(got, "carol-renamed") {
		t.Errorf("blocked peer must show the frozen handle only: %s", got)
	}
	if !strings.Contains(got, `"peerHandle":"bob-live"`) {
		t.Errorf("an unblocked peer keeps the live handle: %s", got)
	}
}
