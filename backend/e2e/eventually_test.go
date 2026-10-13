//go:build integration

package e2e

import (
	"testing"
	"time"
)

// eventually polls cond every poll until it returns true or timeout passes, then fails the test with the last
// message. It is the one polling helper of the e2e suite (testing-strategy: no sleeps for sync). cond re-queries
// the server, so the poll is a bounded retry, not a fixed wait.
func eventually(t *testing.T, what string, timeout, poll time.Duration, cond func() (bool, string)) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	var last string
	for {
		ok, msg := cond()
		if ok {
			return
		}
		last = msg
		if time.Now().After(deadline) {
			t.Fatalf("%s: not satisfied within %v: %s", what, timeout, last)
		}
		time.Sleep(poll)
	}
}
