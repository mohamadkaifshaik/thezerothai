// Package fsclient constructs the single, process-wide Firestore client (ADR-0002: "one Firestore
// client ... for the whole process, shared, created at startup"). It honors FIRESTORE_EMULATOR_HOST
// automatically via the underlying SDK; no branching needed for local dev vs. dev/prod.
package fsclient

import (
	"context"
	"fmt"
	"time"

	"cloud.google.com/go/firestore"
)

// connectTimeout bounds the one-time startup connection so a misconfigured environment fails fast
// instead of hanging the cold start (ADR-0002 cold-start budget).
const connectTimeout = 10 * time.Second

// New builds a Firestore client for projectID. Cheap: the SDK lazily dials on first use, so this mostly
// validates configuration (credentials, emulator host format).
func New(ctx context.Context, projectID string) (*firestore.Client, error) {
	ctx, cancel := context.WithTimeout(ctx, connectTimeout)
	defer cancel()
	client, err := firestore.NewClient(ctx, projectID)
	if err != nil {
		return nil, fmt.Errorf("fsclient: new client for project %q: %w", projectID, err)
	}
	return client, nil
}
