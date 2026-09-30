package graph

import (
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ids"
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
func relationshipIDsIssue(userIDs []string) (field, reason string) {
	if len(userIDs) == 0 {
		return "user_ids", "at least one user_id is required"
	}
	if len(userIDs) > 50 {
		return "user_ids", "at most 50 user_ids are allowed"
	}
	for _, id := range userIDs {
		if targetUserIDIssue(id) {
			return "user_ids", "every " + ids.UIDMessage
		}
	}
	return "", ""
}
