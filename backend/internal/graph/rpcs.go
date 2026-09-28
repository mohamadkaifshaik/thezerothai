package graph

import (
	"context"
	"errors"

	"connectrpc.com/connect"
)

// errNotBuiltYet's message is deliberately generic (mirrors identity/server.go's errUnimplementedPhase1
// rationale): sent verbatim to the client, so it must never leak which ticket hasn't landed yet.
var errNotBuiltYet = errors.New("not implemented yet")

// unimplemented is the placeholder every GraphService RPC returns once past the flag guard, until its own
// ticket (T7-T10) replaces it. Never reached when FEATURE_GRAPH is off for the caller (checked first, 0
// reads either way).
func unimplemented() error {
	return connect.NewError(connect.CodeUnimplemented, errNotBuiltYet)
}

func (s *service) checkFlag(callerUID string) error {
	if !s.flags.Enabled(callerUID, graphFlagName) {
		return featureDisabledErr()
	}
	return nil
}

func (s *service) Follow(ctx context.Context, callerUID, idempotencyKey, targetUID string) (Relationship, error) {
	if err := s.checkFlag(callerUID); err != nil {
		return Relationship{}, err
	}
	return Relationship{}, unimplemented()
}

func (s *service) Unfollow(ctx context.Context, callerUID, idempotencyKey, targetUID string) (Relationship, error) {
	if err := s.checkFlag(callerUID); err != nil {
		return Relationship{}, err
	}
	return Relationship{}, unimplemented()
}

func (s *service) Block(ctx context.Context, callerUID, idempotencyKey, targetUID string) (Relationship, error) {
	if err := s.checkFlag(callerUID); err != nil {
		return Relationship{}, err
	}
	return Relationship{}, unimplemented()
}

func (s *service) Unblock(ctx context.Context, callerUID, idempotencyKey, targetUID string) (Relationship, error) {
	if err := s.checkFlag(callerUID); err != nil {
		return Relationship{}, err
	}
	return Relationship{}, unimplemented()
}

func (s *service) Mute(ctx context.Context, callerUID, idempotencyKey, targetUID string) (Relationship, error) {
	if err := s.checkFlag(callerUID); err != nil {
		return Relationship{}, err
	}
	return Relationship{}, unimplemented()
}

func (s *service) Unmute(ctx context.Context, callerUID, idempotencyKey, targetUID string) (Relationship, error) {
	if err := s.checkFlag(callerUID); err != nil {
		return Relationship{}, err
	}
	return Relationship{}, unimplemented()
}

func (s *service) GetRelationships(ctx context.Context, callerUID string, targetUIDs []string) ([]Relationship, error) {
	if err := s.checkFlag(callerUID); err != nil {
		return nil, err
	}
	return nil, unimplemented()
}

func (s *service) ListFollowers(ctx context.Context, callerUID, targetUID string, pageSize int32, pageToken string) (Page, error) {
	if err := s.checkFlag(callerUID); err != nil {
		return Page{}, err
	}
	return Page{}, unimplemented()
}

func (s *service) ListFollowing(ctx context.Context, callerUID, targetUID string, pageSize int32, pageToken string) (Page, error) {
	if err := s.checkFlag(callerUID); err != nil {
		return Page{}, err
	}
	return Page{}, unimplemented()
}

func (s *service) ListBlockedUsers(ctx context.Context, callerUID string, pageSize int32, pageToken string) (Page, error) {
	if err := s.checkFlag(callerUID); err != nil {
		return Page{}, err
	}
	return Page{}, unimplemented()
}

func (s *service) ListMutedUsers(ctx context.Context, callerUID string, pageSize int32, pageToken string) (Page, error) {
	if err := s.checkFlag(callerUID); err != nil {
		return Page{}, err
	}
	return Page{}, unimplemented()
}
