// Package lists is the Lists module (ADR-0030): curated sets of up to LIST_MAX_MEMBERS accounts that a user can read as a
// timeline and pin as a custom Home tab. It will own the lists/{listId} collection and dzeroth.lists.v1.ListService. Other
// modules reach it through the interfaces in this file only (ADR-0030 D1): lists.Reader for reads, lists.Pins for the
// pinned-tab clean-up, both added by the tickets that need them.
//
// W5-3 ships the skeleton only: the flag name and its gate (FEATURE_LISTS, D9). It names no collection constant on purpose:
// the T11 guard (internal/apiserver/lifecycle_collections_guard_test.go) fails the build for a collection constant without
// an erasure row, so the constant, the eraser step and the guard row arrive together in W5-4 + W5-5. Later tickets add the
// write path (W5-4), the lifecycle (W5-5), members (W5-6), reads and lists.Reader (W5-7); GetListTimeline lives in the
// timeline module (W5-8) and SetHomeTabs in identity and timeline (W5-9).
package lists

import (
	"context"
	"errors"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// FlagName is the wire name of FEATURE_LISTS (ADR-0030 D9), the `feature` metadata of FEATURE_DISABLED and the string in
// GetMe.enabled_features. timeline.GetListTimeline and SetHomeTabs gate on the same name.
const FlagName = "lists"

// FlagChecker is the seam to pkg/platform/flags.Registry (*flags.Registry satisfies it): Enabled answers "is the flag on
// for this caller", GloballyOff "is it the kill switch" (off for everyone; a rollout the caller is outside of is not).
type FlagChecker interface {
	Enabled(uid, name string) bool
	GloballyOff(name string) bool
}

// Guard is the flag gate every ListService method (and timeline's GetListTimeline and SetHomeTabs) runs before any
// Firestore access (ADR-0030 D9: one class, the flag must be on for the caller). Disabled is FAILED_PRECONDITION +
// FEATURE_DISABLED with metadata feature=lists and 0 reads. A nil checker is off for everyone.
func Guard(ctx context.Context, fc FlagChecker, uid string) error {
	err := flags.Guard(ctx, func(uid, name string) bool { return fc != nil && fc.Enabled(uid, name) }, uid, FlagName)
	if err == nil {
		return nil
	}
	logger.SetRequestField(ctx, "feature", FlagName)
	var ae *apierr.Error
	if errors.As(err, &ae) {
		return ae.WithMeta("feature", FlagName)
	}
	return err
}
