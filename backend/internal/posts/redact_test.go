package posts

import (
	"context"
	"fmt"
	"strings"
	"testing"

	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// TestServiceErrorsNeverCarryRawUids: graph's repo wraps Firestore errors as "graph: get <uid>: ...", and
// mw.ErrorMapping logs the whole cause chain, so every service wrap that can see such an error must redact the
// uids involved (security review L4). The author uid in GetPost is not the caller's.
func TestServiceErrorsNeverCarryRawUids(t *testing.T) {
	leak := func(uid string) error { return fmt.Errorf("graph: get %s: rpc error: unavailable", uid) }
	tests := []struct {
		name string
		run  func(e *createEnv) error
	}{
		{"create: load author", func(e *createEnv) error {
			e.dir.profileErr = leak(testUID)
			_, _, err := e.create(CreateInput{IdempotencyKey: key1, Text: "hi"})
			return err
		}},
		{"create: resolve mentions", func(e *createEnv) error {
			e.dir.resolveErr = leak(testUID)
			_, _, err := e.create(CreateInput{IdempotencyKey: key1, Text: "hi @bob"})
			return err
		}},
		{"get: load author", func(e *createEnv) error {
			e.dir.profileErr = leak(otherUID)
			_, err := e.svc.GetForViewer(googleCtx(context.Background(), testUID), testUID, pidOther)
			return err
		}},
		{"get: load caller graph", func(e *createEnv) error {
			e.graph.errs = map[string]error{testUID: leak(testUID)}
			_, err := e.svc.GetForViewer(googleCtx(context.Background(), testUID), testUID, pidOther)
			return err
		}},
		{"get: load author graph", func(e *createEnv) error {
			e.graph.snaps = map[string]graph.Snapshot{testUID: {BlockedByOverflow: true}}
			e.graph.errs = map[string]error{otherUID: leak(otherUID)}
			_, err := e.svc.GetForViewer(googleCtx(context.Background(), testUID), testUID, pidOther)
			return err
		}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := tt.run(newDeleteEnv())
			if err == nil {
				t.Fatal("want an error")
			}
			for _, msg := range []string{err.Error(), logger.CauseChain(err)} {
				if strings.Contains(msg, testUID) || strings.Contains(msg, otherUID) {
					t.Fatalf("raw uid in %q", msg)
				}
			}
		})
	}
}
