// poll_retention.go is the retention of the per-account copy of a poll vote, userLikes/{uid}.pollVotes (ADR-0029 D3, D8; security
// L-2, ticket W6-29). The vote document pollVotes/{postId}_{uid} expires by TTL at closesAt + POLL_VOTE_TTL_AFTER_CLOSE; the copy
// goes on the same schedule:
//
//   - Each entry is "<postId>:<choice>:<closesAtUnix>". closesAt is immutable per post, so the entry string can always be rebuilt
//     from the post (ArrayRemove needs the exact string, and one entry per post is replaced when a vote may change, A2), and the
//     entry expires at closesAt + the TTL in force (the TTL is at least 24 hours, so the poll is closed by then). An older
//     two-part entry "<postId>:<choice>" (written before W6-29, dev only) expires at its post's creation time + 30 days (the
//     POLL_MAX_DURATION ceiling) + the TTL, a bound that is never early.
//   - An expired entry is never shown (the viewer set is built from live entries only) and is removed on the next read or write of
//     the document by this module (service.state, one field-level write, once).
//   - userLikes.pollVotesDueDays holds the UTC day number (unix seconds / 86400) of every entry's expiry, written by the same Set as
//     the entry (ArrayUnion, so concurrent votes never lose a day). The daily sweep (SweepPollVotes, run by the daily-maintenance
//     cron) finds documents with a due day in the last 30 days and removes what has expired: an account that never returns is
//     cleaned by the sweep, not only by its own activity.
package engagement

import (
	"context"
	"fmt"
	"strconv"
	"strings"
	"time"

	"cloud.google.com/go/firestore"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/snowflake"
)

const (
	// legacyPollMaxDuration is the POLL_MAX_DURATION ceiling (30 days): the longest a poll can last, whatever the config.
	legacyPollMaxDuration = 30 * 24 * time.Hour
	secondsPerDay         = 24 * 60 * 60
	// sweepWindowDays is how many past due days one sweep looks at (array-contains-any takes at most 30 values), so a cron outage
	// of up to 30 days is caught up.
	sweepWindowDays = 30
	// PollSweepLimit is the most documents one sweep run reads (the rest wait for the next run).
	PollSweepLimit = 50
)

// pollEntry is the userLikes.pollVotes entry of a vote: "<postId>:<index>:<closesAtUnix>" (ADR-0029 D3, W6-29). A zero closesAt
// gives the two-part form.
func pollEntry(postID string, choice int, closesAt time.Time) string {
	e := postID + ":" + strconv.Itoa(choice)
	if closesAt.IsZero() {
		return e
	}
	return e + ":" + strconv.FormatInt(closesAt.Unix(), 10)
}

// pollEntryExpiry reports when the entry must be gone: closesAt + ttl, or for a two-part entry the post's creation time + 30 days
// + ttl. ok is false for an entry it cannot read (kept, never deleted by guesswork).
func pollEntryExpiry(entry string, ttl time.Duration) (time.Time, bool) {
	postID, rest, found := strings.Cut(entry, ":")
	if !found {
		return time.Time{}, false
	}
	_, closes, hasClose := strings.Cut(rest, ":")
	if hasClose {
		n, err := strconv.ParseInt(closes, 10, 64)
		if err != nil {
			return time.Time{}, false
		}
		return time.Unix(n, 0).UTC().Add(ttl), true
	}
	created, err := snowflake.Time(postID)
	if err != nil {
		return time.Time{}, false
	}
	return created.UTC().Add(legacyPollMaxDuration + ttl), true
}

// splitPollVotes separates entries into those still live at now and those expired. ttl <= 0 (polls not configured) keeps all.
func splitPollVotes(entries []string, ttl time.Duration, now time.Time) (live, expired []string) {
	if ttl <= 0 {
		return entries, nil
	}
	for _, e := range entries {
		if exp, ok := pollEntryExpiry(e, ttl); ok && !exp.After(now) {
			expired = append(expired, e)
			continue
		}
		live = append(live, e)
	}
	return live, expired
}

// pollDueDay is the UTC day number of an expiry time.
func pollDueDay(t time.Time) int64 { return t.UTC().Unix() / secondsPerDay }

// PollSweepResult is what one SweepPollVotes run did.
type PollSweepResult struct {
	// Docs is how many userLikes documents the query returned (reads), Pruned how many were updated (writes), Entries how many
	// entries were removed, Skipped how many lost a race and wait for the next run. More is true when the query was full.
	Docs, Pruned, Entries, Skipped int
	More                           bool
}

// PollVoteSweeper removes expired userLikes.pollVotes entries from accounts that have not come back.
type PollVoteSweeper interface {
	// SweepPollVotes runs one bounded pass. Reads: documents returned (min 1, at most PollSweepLimit); writes: one per document
	// changed. 0 when nothing is due beyond the 1 read of the empty query.
	SweepPollVotes(ctx context.Context, now time.Time, ttl time.Duration) (PollSweepResult, error)
}

var _ PollVoteSweeper = (*FirestoreRepo)(nil)

// SweepPollVotes implements PollVoteSweeper. The query is `pollVotesDueDays array-contains-any [today-29..today] LIMIT 50` on the
// automatic single-field index. Each document is rewritten with an Update that carries a LastUpdateTime precondition (never a Set:
// a document the eraser deleted is not recreated, and a vote that landed after the query is not lost; a failed precondition is
// skipped for the next run): expired entries are ArrayRemoved and pollVotesDueDays is replaced with the days of what remains.
func (r *FirestoreRepo) SweepPollVotes(ctx context.Context, now time.Time, ttl time.Duration) (PollSweepResult, error) {
	var res PollSweepResult
	if ttl <= 0 {
		return res, nil
	}
	today := pollDueDay(now)
	days := make([]any, 0, sweepWindowDays)
	for d := today - sweepWindowDays + 1; d <= today; d++ {
		days = append(days, d)
	}
	docs, err := r.client.Collection(userLikesCollection).Where("pollVotesDueDays", "array-contains-any", days).Limit(PollSweepLimit).Documents(ctx).GetAll()
	n := max(len(docs), 1)
	budget.FromContext(ctx).AddReads(int64(n))
	if err != nil {
		return res, fmt.Errorf("engagement: poll vote sweep query: %w", err)
	}
	res.Docs, res.More = len(docs), len(docs) == PollSweepLimit
	for _, snap := range docs {
		var d userLikesDoc
		if err := snap.DataTo(&d); err != nil {
			return res, fmt.Errorf("engagement: poll vote sweep decode: %w", err)
		}
		live, expired := splitPollVotes(d.PollVotes, ttl, now)
		due := dueDaysOf(live, ttl)
		if len(expired) == 0 && sameDays(snap, due) {
			continue // due later today: nothing to change, no write
		}
		updates := []firestore.Update{{Path: "pollVotesDueDays", Value: due}}
		if len(due) == 0 {
			updates[0].Value = firestore.Delete
		}
		if len(expired) > 0 {
			updates = append(updates,
				firestore.Update{Path: "pollVotes", Value: firestore.ArrayRemove(toAny(expired)...)},
				firestore.Update{Path: "updatedAt", Value: now.UTC()})
		}
		_, err := snap.Ref.Update(ctx, updates, firestore.LastUpdateTime(snap.UpdateTime))
		switch status.Code(err) {
		case codes.OK:
			budget.FromContext(ctx).AddWrites(1)
			res.Pruned++
			res.Entries += len(expired)
		case codes.FailedPrecondition, codes.NotFound, codes.Aborted:
			res.Skipped++ // changed or erased since the query: the next run sees the new state
		default:
			return res, fmt.Errorf("engagement: poll vote sweep update: %w", err)
		}
	}
	return res, nil
}

// dueDaysOf lists the distinct expiry days of entries, as stored in pollVotesDueDays.
func dueDaysOf(entries []string, ttl time.Duration) []int64 {
	seen := map[int64]struct{}{}
	out := []int64{}
	for _, e := range entries {
		exp, ok := pollEntryExpiry(e, ttl)
		if !ok {
			continue
		}
		d := pollDueDay(exp)
		if _, dup := seen[d]; !dup {
			seen[d] = struct{}{}
			out = append(out, d)
		}
	}
	return out
}

// sameDays reports whether the document's stored pollVotesDueDays equals due as a set.
func sameDays(snap *firestore.DocumentSnapshot, due []int64) bool {
	raw, err := snap.DataAt("pollVotesDueDays")
	if err != nil {
		return len(due) == 0
	}
	list, _ := raw.([]any)
	if len(list) != len(due) {
		return false
	}
	have := make(map[int64]struct{}, len(list))
	for _, v := range list {
		n, ok := v.(int64)
		if !ok {
			return false
		}
		have[n] = struct{}{}
	}
	for _, d := range due {
		if _, ok := have[d]; !ok {
			return false
		}
	}
	return true
}
