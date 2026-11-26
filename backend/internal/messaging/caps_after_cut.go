package messaging

import (
	"context"
	"strings"
	"time"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/quota"
)

// Commit caps after a session cut (removal-server design Q8, Plan 6 lane D PR 5). The three per-uid commit caps (the
// interceptor's "messages_commits_daily", and the service's "messages_commits_per_conversation_daily" and
// "messages_resets_daily") are keyed by the caller's current session cut as well, so a session that signed in after a
// REMOTE device removal gets fresh counters: a thief's drain from before the cut cannot block the removal commits that
// follow. A cut is only written with FEATURE_DEVICE_SIGN_OUT on for the remover (keys), so that is the gating.
//
// The tag is the cut's IST calendar day, not its time (fix round 1, security M1): the daily caps reset at the IST day
// boundary anyway, so a day tag gives the honest remover one fresh set of counters on the day of the cut, and any number
// of further cuts that day (each needs a real sign-in and a REMOTE removal) renew nothing. Renewal is bounded to twice
// the caps per IST day with no new limit.
//
// No cut keeps today's key byte for byte, so a deploy resets nobody's counters. A key is never logged.

// SessionCutReader answers the caller's session cut (identity.SessionCuts.SessionsValidAfter, from the cached profile):
// zero for none or for a uid without a profile.
type SessionCutReader interface {
	SessionsValidAfter(ctx context.Context, uid string) (time.Time, error)
}

// fieldCapCutUnknown is the request-line field set when the cut lookup of a cap key failed (the old key is used). A bool,
// never a time or a uid.
const fieldCapCutUnknown = "cap_cut_unknown"

// CapKeyAfterCut is key for no cut, and key + "|c" + the cut's IST calendar day (YYYYMMDD, the day boundary every
// DailyCap rolls over at) for a cut. Two cuts on one IST day give the same key. The tag is part of an in-memory map key
// only (never logged).
func CapKeyAfterCut(key string, cut time.Time) string {
	if cut.IsZero() {
		return key
	}
	return key + "|c" + strings.ReplaceAll(quota.TodayAt(cut), "-", "")
}

// CommitCapKeyFor is base tagged with cut (CapKeyAfterCut) only for a caller whose session signed in at or after the cut
// (claims.AuthTime >= cut, the session cut interceptor's own pass rule). Any other caller keeps base: no claims, a zero
// auth_time, or a session from before the cut. Such a session reaches the caps only while device_sign_out is globally off
// (the interceptor then checks nothing, the emergency lever) or inside the other instances' 60 s stale-cache window; it
// must not get the fresh counters the cut gives the remover, so it stays on the counter it drained.
func CommitCapKeyFor(ctx context.Context, base string, cut time.Time) string {
	if cut.IsZero() {
		return base
	}
	claims, ok := authn.ClaimsFromContext(ctx)
	if !ok || claims.AuthTime.IsZero() || claims.AuthTime.Before(cut) {
		return base
	}
	return CapKeyAfterCut(base, cut)
}

// CommitCapKey reads uid's cut through cuts and returns CommitCapKeyFor. A nil reader, or a failed lookup, keeps base (the
// stricter, pre-cut counter; the lookup failure is noted on the request line as cap_cut_unknown=true and the request goes
// on, account status reports the read failure itself).
func CommitCapKey(ctx context.Context, cuts SessionCutReader, uid, base string) string {
	if cuts == nil {
		return base
	}
	cut, err := cuts.SessionsValidAfter(ctx, uid)
	if err != nil {
		logger.SetRequestField(ctx, fieldCapCutUnknown, true)
		return base
	}
	return CommitCapKeyFor(ctx, base, cut)
}
