// Package budgettest is a reusable Firestore read/write/delete budget assertion for integration tests
// (testing-strategy skill: "assert an RPC stays within its documented budget. A budget regression fails
// CI."). It depends on the "testing" package, so — like net/http/httptest — it must only ever be
// imported from _test.go files, never from production code (backend/internal/*, backend/pkg/platform/*
// outside tests). Not wired into any non-test build.
package budgettest

import (
	"testing"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
)

// Budget is an RPC's documented worst-case Firestore cost for one call, taken from the proto doc comment
// and/or docs/reviews/cost-model.md. Every field is a ceiling (<=), not an exact match — pass the exact
// worst case from the documentation so a regression that reads/writes more than documented fails the
// build, per CLAUDE.md rule 6 ("every RPC documents its worst-case Firestore reads/writes").
type Budget struct {
	Reads   int64
	Writes  int64
	Deletes int64
}

// Assert fails t (without stopping the goroutine — use t.Fatal in the caller if that's needed) when c's
// totals exceed the documented budget b. name identifies the RPC/call in the failure message. Call this
// right after the call under test, using the *budget.Counter returned by budget.WithCounter for that
// call — one counter per call, never shared/reused, so counts aren't attributed to the wrong RPC.
func Assert(t testing.TB, name string, c *budget.Counter, b Budget) {
	t.Helper()
	if got := c.Reads(); got > b.Reads {
		t.Errorf("%s: Reads() = %d, want <= %d (documented budget)", name, got, b.Reads)
	}
	if got := c.Writes(); got > b.Writes {
		t.Errorf("%s: Writes() = %d, want <= %d (documented budget)", name, got, b.Writes)
	}
	if got := c.Deletes(); got > b.Deletes {
		t.Errorf("%s: Deletes() = %d, want <= %d (documented budget)", name, got, b.Deletes)
	}
}
