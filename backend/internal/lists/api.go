// Package lists is the Lists module (ADR-0030): curated sets of up to LIST_MAX_MEMBERS accounts that a user can read as a
// timeline and pin as a custom Home tab. It owns the lists/{listId} collection and dzeroth.lists.v1.ListService. Other modules
// reach it through the interfaces only (ADR-0030 D1): Service for the handlers, Pins for the owner's pinned-tab clean-up (W5-9
// implements it in identity), and lists.Reader for the timeline (W5-7).
//
// What exists: the flag gate (W5-3, FEATURE_LISTS, D9); the write path CreateList, UpdateList and DeleteList (W5-4: model.go, service.go,
// repo_firestore.go, cache.go); and the lifecycle (W5-5: purge.go, the `lists` eraser step and export section, registered in
// apiserver/lifecycle_lists.go). The T11 guard (internal/apiserver/lifecycle_collections_guard_test.go) fails the build for a
// collection constant without an erasure row, which is why W5-4 and W5-5 ship in one PR. Still to come: members (W5-6), reads and
// lists.Reader (W5-7); GetListTimeline lives in the timeline module (W5-8) and SetHomeTabs in identity and timeline (W5-9).
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
