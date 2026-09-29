//go:build integration

package graph_test

import (
	"testing"

	"cloud.google.com/go/firestore"
)

// TEMP: replaced by T16a's invariants_integration_test.go at merge.
func assertGraphInvariants(t *testing.T, client *firestore.Client) {
	t.Helper()
	_ = client
}
