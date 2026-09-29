package graph

import (
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
)

// idempotencyKeyIssue mirrors the common.proto convention (16-64 chars, [A-Za-z0-9_-]), delegating to the
// shared validator (reuse-first: identity/validate.go uses the same one).
func idempotencyKeyIssue(key string) bool {
	return !idempotency.KeyFormatValid(key)
}

// targetUserIDIssue reuses identity.ValidUserID (graph already depends on the identity package for
// Directory/Counters) instead of duplicating its Firebase-UID regex.
func targetUserIDIssue(id string) bool {
	return id == "" || !identity.ValidUserID(id)
}

// relationshipIDsIssue validates GetRelationshipsRequest.user_ids (ADR-0008: "1-50 ids").
func relationshipIDsIssue(ids []string) (field, reason string) {
	if len(ids) == 0 {
		return "user_ids", "at least one user_id is required"
	}
	if len(ids) > 50 {
		return "user_ids", "at most 50 user_ids are allowed"
	}
	for _, id := range ids {
		if targetUserIDIssue(id) {
			return "user_ids", "every user_id must be 1-128 characters of [A-Za-z0-9_-] and not of the form __x__"
		}
	}
	return "", ""
}
