// service_sweep_item.go is the per-item rule set of the publish sweep (ADR-0021 "Sweep" steps 3 to 5), cheapest and
// most decisive check first (review L-4):
//
//  1. expiry: now - publishAt > SCHEDULED_MAX_LATENESS -> FAILED EXPIRED (0 reads)
//  2. schemaVersion above ours -> FAILED UNSUPPORTED; no draft, an unreadable policy or media shape, or text that no
//     longer parses -> FAILED INVALID_CONTENT (CPU only, 0 reads)
//  3. the publish transaction (repo_publish_scheduled.go): status, quota, media, mentions, then the post
//
// Every write outside the transaction (expiry, UNSUPPORTED, INVALID_CONTENT, attempts++, FAILED after the attempts
// limit or a panic) is an Update with firestore.LastUpdateTime(the query snapshot's UpdateTime), 0 reads, 1 write. A
// failed precondition means someone else moved the item on and is a quiet no-op, never "fixed" with an unconditional
// write, and nothing here ever uses Set or merge: a write after the eraser cannot recreate a purged doc (review L-7).
package posts

import (
	"context"
	"errors"
	"fmt"

	"github.com/dzeroth/dzeroth/backend/internal/posts/text"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// sweepItem processes one due item. The panic recovery is the caller's (sweepItemSafe).
func (s *service) sweepItem(ctx context.Context, run runRef, it *ScheduledPost, tally *sweepTally) {
	lim := s.sweep.Limits
	// The only trace an unrecoverable crash (a fatal runtime error, an OOM kill) leaves: written before the transaction.
	// uid_hash is one-way and the scheduled id is itself a SHA-256 prefix. Never the draft text. INFO, not DEBUG: the
	// process logger drops DEBUG, and the crash-isolation runbook step reads this line.
	s.sweep.Log.InfoContext(ctx, "scheduled_item_start", append([]any{"uid_hash", logger.HashUID(it.UID), "scheduled_id", it.ID}, logger.TraceAttrs(ctx)...)...)

	// 1. Expiry: the catch-up bound. After an outage stale posts are not dumped onto feeds hours late.
	if run.now.Sub(it.PublishAt) > lim.MaxLateness {
		s.endItem(ctx, it, ScheduledTransition{To: ScheduledFailed, Failure: FailureExpired}, tally)
		return
	}

	// 2. Content checks, CPU only.
	if it.SchemaVersion > ScheduledSchemaVersion {
		s.endItem(ctx, it, ScheduledTransition{To: ScheduledFailed, Failure: FailureUnsupported}, tally)
		return
	}
	params, ok := s.publishParams(it)
	if !ok {
		s.endItem(ctx, it, ScheduledTransition{To: ScheduledFailed, Failure: FailureInvalidContent}, tally)
		return
	}

	// 3. The publish transaction.
	res, err := s.sweep.Repo.PublishScheduled(ctx, params)
	switch {
	case errors.Is(err, errPublishPanic):
		// A panic inside the callback was rolled back by the wrapper. Retire the item in this run: never the attempts++ branch.
		s.reportErr(ctx, logger.ScrubErr(fmt.Errorf("posts: scheduled publish: %w", err), it.UID))
		s.endItem(ctx, it, ScheduledTransition{To: ScheduledFailed, Failure: FailureInternal}, tally)
	case err != nil:
		s.transient(ctx, it, err, tally)
	default:
		s.settle(ctx, it, res, tally)
	}
}

// publishParams parses the draft into the transaction's parameters. ok=false is INVALID_CONTENT: no draft, a policy or
// media shape this revision does not accept, or text that no longer parses (the rules may have tightened since it was
// scheduled). No error text leaves this function: the draft is never logged.
func (s *service) publishParams(it *ScheduledPost) (PublishParams, bool) {
	d := it.Draft
	if d == nil {
		return PublishParams{}, false
	}
	switch d.ReplyPolicy {
	case ReplyPolicyEveryone, ReplyPolicyFollowing, ReplyPolicyMentionedOnly:
	default:
		return PublishParams{}, false
	}
	mediaIDs := make([]string, len(d.Media))
	alts := make([]string, len(d.Media))
	for i, m := range d.Media {
		mediaIDs[i], alts[i] = m.ID, m.AltText
	}
	if validateMedia(mediaIDs, alts) != nil {
		return PublishParams{}, false
	}
	parse := text.Parse
	if len(mediaIDs) > 0 {
		parse = text.ParseOptional // an image-only post is valid, exactly as SchedulePost accepted it
	}
	parsed, err := parse(d.Text)
	if err != nil {
		return PublishParams{}, false
	}
	hashtags := parsed.Hashtags
	if hashtags == nil {
		hashtags = []string{}
	}
	p := PublishParams{
		UID: it.UID, ID: it.ID,
		Draft: Post{
			Kind: KindPost, Text: parsed.Text, Hashtags: hashtags, Visibility: VisibilityPublic,
			PaidPartnership: d.PaidPartnership, MadeWithAI: d.MadeWithAI, ReplyPolicy: d.ReplyPolicy,
		},
		MediaIDs: mediaIDs, MediaAlts: alts,
		PostsLimit: s.postsPerDay, NewAccountPostsLimit: s.newAccountPostsPerDay, NewAccountWindow: s.newAccountWindow,
		Now: s.now(), TerminalTTL: s.sweep.Limits.TerminalTTL,
	}
	if len(mediaIDs) == 0 {
		p.MediaIDs, p.MediaAlts = nil, nil
	}
	if candidates := parsed.Mentions; len(candidates) > 0 {
		// Mentions resolve at publish, inside each attempt, last (handles may have changed). Cache-first: 0 to 10 reads.
		p.ResolveMentions = func(ctx context.Context) ([]Mention, error) { return s.resolveMentions(ctx, it.UID, candidates) }
	}
	return p, true
}

// settle records the outcome of a committed publish transaction.
func (s *service) settle(ctx context.Context, it *ScheduledPost, res PublishResult, tally *sweepTally) {
	switch res.Outcome {
	case PublishPublished:
		tally.add(func(r *SweepResult) { r.Published++ })
		// Exactly what CreatePost does after its commit, from the written data (no re-read): the instance caches, the
		// author's cached profile (postsCount moved by a blind increment) and the mention/notification hook.
		post := res.Post
		s.cache.SetPost(post)
		s.cache.PrependOwn(post)
		s.directory.Forget(it.UID)
		if s.sweep.RecordAuthorAge != nil {
			s.sweep.RecordAuthorAge(it.UID, res.AuthorCreatedAt) // before the emitter consults the new-account tier
		}
		s.events.Created(ctx, post)
	case PublishCancelled:
		tally.add(func(r *SweepResult) { r.Cancelled++ })
	case PublishFailed:
		tally.failed(res.Failure)
	default: // PublishNoop: another run, a Cancel or the eraser won the race
		tally.add(func(r *SweepResult) { r.Noop++ })
	}
}

// transient handles an error the transaction rolled back on (a deadline, UNAVAILABLE, ABORTED exhausted, a media load
// that is not ErrMediaNotReady). It counts one attempt; the last allowed attempt retires the item FAILED INTERNAL and
// reports it. The error text may name documents and uids of any user, so it is scrubbed before it is logged or reported
// (review L-8); our own messages never include a uid or a scheduled id.
func (s *service) transient(ctx context.Context, it *ScheduledPost, err error, tally *sweepTally) {
	scrubbed := logger.ScrubErr(fmt.Errorf("posts: scheduled publish: %w", err), it.UID)
	tally.add(func(r *SweepResult) { r.Transient++ })
	if it.Attempts+1 >= max(s.sweep.Limits.MaxAttempts, 1) {
		s.reportErr(ctx, scrubbed)
		s.endItem(ctx, it, ScheduledTransition{To: ScheduledFailed, Failure: FailureInternal}, tally)
		return
	}
	s.sweep.Log.WarnContext(ctx, "scheduled_item_transient", append([]any{
		"uid_hash", logger.HashUID(it.UID), "attempt", it.Attempts + 1, "error", scrubbed.Error(),
	}, logger.TraceAttrs(ctx)...)...)
	bctx, cancel := bookkeepingCtx(ctx)
	defer cancel()
	_, applied, berr := s.sweep.Repo.BumpScheduledAttempts(bctx, it.Ref(), s.now())
	switch {
	case berr != nil:
		s.bookkeepingFailed(ctx, it, berr, tally)
	case !applied:
		tally.add(func(r *SweepResult) { r.Noop++ })
	}
}

// endItem moves the item to a terminal state with the query snapshot's UpdateTime as the precondition (0 reads, 1
// write). applied=false (changed, or gone) is a quiet no-op.
func (s *service) endItem(ctx context.Context, it *ScheduledPost, tr ScheduledTransition, tally *sweepTally) {
	bctx, cancel := bookkeepingCtx(ctx)
	defer cancel()
	_, applied, err := s.sweep.Repo.TransitionScheduled(bctx, it.Ref(), tr, s.now(), s.sweep.Limits.TerminalTTL)
	switch {
	case err != nil:
		s.bookkeepingFailed(ctx, it, err, tally)
	case !applied:
		tally.add(func(r *SweepResult) { r.Noop++ })
	case tr.To == ScheduledCancelled:
		tally.add(func(r *SweepResult) { r.Cancelled++ })
	default:
		tally.failed(tr.Failure)
	}
}

// bookkeepingFailed logs a failed state write. The item stays as it was and is re-read next run.
func (s *service) bookkeepingFailed(ctx context.Context, it *ScheduledPost, err error, tally *sweepTally) {
	tally.add(func(r *SweepResult) { r.WriteFailed++ })
	scrubbed := logger.ScrubErr(fmt.Errorf("posts: scheduled state write: %w", err), it.UID)
	s.sweep.Log.WarnContext(ctx, "scheduled_item_bookkeeping_failed", append([]any{
		"uid_hash", logger.HashUID(it.UID), "error", scrubbed.Error(),
	}, logger.TraceAttrs(ctx)...)...)
}

// bookkeepingCtx is a short context detached from the item's cancellation: an item that hit the run deadline can still
// be counted. WithoutCancel keeps the budget counter and the trace values (review M-2).
func bookkeepingCtx(ctx context.Context) (context.Context, context.CancelFunc) {
	return context.WithTimeout(context.WithoutCancel(ctx), sweepBookkeepingTimeout)
}
