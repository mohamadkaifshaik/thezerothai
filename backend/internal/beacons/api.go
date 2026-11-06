// Package beacons is the Beacons ("Plans") module: a concrete, time-boxed invitation to do one activity together, scoped
// to one community or public, with request-to-join and organiser acceptance (docs/beacons-plan.md,
// proto/dzeroth/beacons/v1). It owns beacons/{beaconId}, its beaconParticipants subcollection and
// users/{uid}/beaconMemberships/{beaconId}, and dzeroth.beacons.v1.BeaconService. Other modules reach it through the
// interfaces in this file and model.go only; it reads communities through communities.Reader, the social graph through
// graph.Reader and profiles through identity.Directory, never another module's storage.
//
// What exists (PR 2): the flag gates (FEATURE_BEACONS, two classes), the model and validation (model.go, validate.go), the
// organiser write path CreateBeacon, UpdateBeacon and CancelBeacon and the reads GetBeacon and ListBeacons (service.go,
// service_read.go, repo_firestore.go, repo_read.go, server.go), and the lifecycle (purge.go, export.go, registered in
// apiserver/lifecycle_beacons.go). The guard (internal/apiserver/lifecycle_collections_guard_test.go) fails the build for
// a collection constant without an erasure row, which is why they ship in one PR. Participation (RequestToJoin and the
// rest, ListMyBeacons, ListParticipants) is PR 3; reports and the opsctl hide are PR 4; notifications are PR 5.
package beacons

import (
	"context"
	"errors"

	"github.com/dzeroth/dzeroth/backend/internal/communities"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// FlagName is the wire name of FEATURE_BEACONS, the `feature` metadata of FEATURE_DISABLED and the string in
// GetMe.enabled_features.
const FlagName = "beacons"

// FlagChecker is the seam to pkg/platform/flags.Registry (*flags.Registry satisfies it): Enabled answers "is the flag on
// for this caller", GloballyOff "is it the kill switch" (off for everyone; a rollout the caller is outside of is not).
type FlagChecker interface {
	Enabled(uid, name string) bool
	GloballyOff(name string) bool
}

// Guard is the write-class gate (CreateBeacon, UpdateBeacon, RequestToJoin, RespondToJoinRequest): the flag must be on
// for the caller, before any Firestore access. Disabled is FAILED_PRECONDITION + FEATURE_DISABLED with metadata
// feature=beacons. A nil checker is off for everyone.
func Guard(ctx context.Context, fc FlagChecker, uid string) error {
	return guard(ctx, func(uid, name string) bool { return fc != nil && fc.Enabled(uid, name) }, uid, FlagName)
}

// GuardNotOff is the read-class gate (GetBeacon, ListBeacons, ListMyBeacons, ListParticipants, CancelBeacon,
// WithdrawJoinRequest, LeaveBeacon, RemoveParticipant): the flag only needs to not be globally off, so a caller dropped
// from an allowlist can still read, leave and cancel. Same error shape as Guard. A nil checker is off for everyone.
func GuardNotOff(ctx context.Context, fc FlagChecker, uid string) error {
	return guard(ctx, func(_, name string) bool { return fc != nil && !fc.GloballyOff(name) }, uid, FlagName)
}

// GuardCommunities is the gate a community-audience beacon adds: FEATURE_COMMUNITIES on for the caller when mustBeOn
// (CreateBeacon), else only not globally off (the reads and CancelBeacon). Disabled names feature=communities.
func GuardCommunities(ctx context.Context, fc FlagChecker, uid string, mustBeOn bool) error {
	enabled := func(uid, name string) bool {
		if fc == nil {
			return false
		}
		if mustBeOn {
			return fc.Enabled(uid, name)
		}
		return !fc.GloballyOff(name)
	}
	return guard(ctx, enabled, uid, communities.FlagName)
}

// guard runs flags.Guard for name and stamps the request line and the error metadata with the feature.
func guard(ctx context.Context, enabled func(uid, name string) bool, uid, name string) error {
	err := flags.Guard(ctx, enabled, uid, name)
	if err == nil {
		return nil
	}
	logger.SetRequestField(ctx, "feature", name)
	var ae *apierr.Error
	if errors.As(err, &ae) {
		return ae.WithMeta("feature", name)
	}
	return err
}
