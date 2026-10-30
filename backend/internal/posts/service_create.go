package posts

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/internal/posts/text"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ids"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// Create implements Service (ADR-0010 D2, D7, D13, D18; plan T8).
//
// Firestore, worst case (CreatePost proto comment; keep the integration budget assertion in sync):
//
//	reads : author profile (the account-status interceptor's cached read) 1, handles/* <= 10 in one GetAll (only
//	        when the text has mention candidates outside URLs), idempotency 1, quotas 1 (the last two fresh inside
//	        the transaction)  => 13 cold / 2 warm, planning 2.5. The documented ceiling stays 14: the author graph
//	        is no longer read (M2, D7 amendment), so the proto, ADR and plan numbers are conservative upper bounds.
//	writes: idempotency doc, post, users.postsCount, quotas = 4, plus 1 eventual TTL delete
//	with media (P4, FEATURE_MEDIA): + len(media_ids) reads (one GetAll of media/*, inside the transaction, so
//	        up to 4 more: 17 cold / 6 warm ceiling, planning 2.5 + n) and + len(media_ids) writes (media/{id}.postId,
//	        so up to 8); a replay re-reads no media
//	replay: the idempotency doc, then the post (cache first): 13 cold / 1 warm reads, 0 writes
//
// Poll (ADR-0029 D1, FEATURE_POLLS): a root post with a poll costs exactly a root post, +0 reads and +0 writes (the poll is a field of
// the same post doc, written in the same commit; replay unchanged). A refused poll (flag, shape, combination) reads and writes
// nothing.
//
// Reply policy (ADR-0021 D2): setting one on a root post or quote costs +0 reads and +0 writes. A reply in a
// FOLLOWING / MENTIONED_ONLY conversation adds, cold (0 warm, caches 60 s): parent = root MENTIONED_ONLY +0,
// FOLLOWING +1; deeper MENTIONED_ONLY +3, FOLLOWING +4 (see enforceReplyPolicy); a refusal reads the same and
// writes nothing. An EVERYONE / absent conversation adds nothing and never loads the root.
func (s *service) Create(ctx context.Context, uid string, in CreateInput) (_ *Post, err error) {
	logger.SetRequestField(ctx, fieldOp, "create")
	defer func() {
		if err != nil {
			noteRejected(ctx, err)
		}
	}()

	// 1. Sub-features first, before any other validation or read (D2). Order: replies, quotes, media.
	if in.ReplyToPostID != "" && !in.RepliesEnabled {
		return nil, featureDisabled("replies")
	}
	if in.QuoteOfPostID != "" && !in.QuotesEnabled {
		return nil, featureDisabled("quotes")
	}
	if in.QuoteOfPostID != "" && in.ReplyToPostID != "" {
		return nil, apierr.Validation("quote_of_post_id", "a post cannot both reply to and quote another post")
	}
	hasMedia := len(in.MediaIDs) > 0 || len(in.MediaAltTexts) > 0
	if hasMedia && !in.MediaEnabled {
		return nil, featureDisabled("media")
	}
	// reply_audience (ADR-0021 D2) gates only SETTING a policy: any reply_policy other than UNSPECIFIED (EVERYONE, the
	// not-yet-available values and unknown numbers included) is FEATURE_DISABLED while the flag is off, 0 reads.
	// Enforcing a stored policy (enforceReplyPolicy) never consults the flag. Disclosure comes after it.
	if in.ReplyPolicy != int32(postsv1.ReplyPolicy_REPLY_POLICY_UNSPECIFIED) && !in.ReplyAudienceEnabled {
		return nil, featureDisabled("reply_audience")
	}
	if (in.PaidPartnership || in.MadeWithAI) && !in.DisclosureEnabled {
		return nil, featureDisabled("content_disclosure")
	}
	// polls (ADR-0029 D2) comes after content_disclosure: a poll with FEATURE_POLLS off for the caller is FEATURE_DISABLED, 0 reads.
	if in.Poll != nil && !in.PollsEnabled {
		return nil, featureDisabled("polls")
	}
	if !idempotency.KeyFormatValid(in.IdempotencyKey) {
		return nil, apierr.Validation("idempotency_key", "idempotency_key must be 16-64 characters of [A-Za-z0-9_-]")
	}
	// A poll's own and combination rules come first, so a poll with images or a reply is always field=poll (ADR-0029 D1).
	pollDraft, err := s.checkPoll(in)
	if err != nil {
		return nil, err
	}
	logger.SetRequestField(ctx, fieldHasPoll, pollDraft != nil)
	policy, err := validateReplyPolicy(in)
	if err != nil {
		return nil, err
	}
	if err := validateMedia(in.MediaIDs, in.MediaAltTexts); err != nil {
		return nil, err
	}
	// An image-only post is allowed: empty text is valid exactly when at least one image is attached.
	parse := text.Parse
	if len(in.MediaIDs) > 0 {
		parse = text.ParseOptional
	}
	parsed, err := parse(in.Text)
	if err != nil {
		return nil, err
	}
	if err := authn.RequireVerifiedEmail(ctx, s.allowAnonymous, "posting"); err != nil {
		return nil, err
	}
	logger.SetRequestField(ctx, fieldTextLen, len([]rune(parsed.Text)))
	logger.SetRequestField(ctx, fieldHashtagsCount, len(parsed.Hashtags))
	logger.SetRequestField(ctx, fieldMentionsInURL, parsed.MentionsInURL)

	// 2. Author profile (cache-first; the interceptor has just warmed it) and mentions.
	profiles, err := s.directory.GetProfiles(ctx, []string{uid})
	if err != nil {
		return nil, logger.RedactErr(fmt.Errorf("posts: load author: %w", err), uid)
	}
	author, ok := profiles[uid]
	if !ok {
		return nil, apierr.New(connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_PROFILE_REQUIRED, "create a profile first")
	}
	var parent *Post
	if in.ReplyToPostID != "" {
		if parent, err = s.replyParent(ctx, uid, in.ReplyToPostID); err != nil {
			return nil, err
		}
		// ADR-0021 D2: after the visibility check (NOT_FOUND first), before mentions and the transaction.
		if err = s.enforceReplyPolicy(ctx, uid, parent); err != nil {
			return nil, err
		}
	}
	var quoted *Post
	if in.QuoteOfPostID != "" {
		if quoted, err = s.quoteTarget(ctx, uid, in.QuoteOfPostID); err != nil {
			return nil, err
		}
	}
	mentions, err := s.resolveMentions(ctx, uid, parsed.Mentions)
	if err != nil {
		return nil, err
	}
	logger.SetRequestField(ctx, fieldMentionsResolved, len(mentions))
	logger.SetRequestField(ctx, fieldMentionsDropped, len(parsed.Mentions)-len(mentions))

	// 3. The transaction.
	limit := s.postsPerDay
	if s.isNewAccount(author, s.now()) {
		limit = s.newAccountPostsPerDay
	}
	hashtags := parsed.Hashtags
	if hashtags == nil {
		hashtags = []string{}
	}
	snapshot, snapshotVersion := authorSnapshotOf(uid, author)
	params := CreateParams{
		AuthorID:    uid,
		IdemKey:     idempotency.Key(uid, createRPC, in.IdempotencyKey),
		RequestHash: requestHashWithPoll(parsed.Text, in.ReplyToPostID, in.QuoteOfPostID, in.MediaIDs, in.MediaAltTexts, policy, in.PaidPartnership, in.MadeWithAI, pollDraft),
		Poll:        pollDraft,
		QuotaLimit:  limit,
		MediaIDs:    in.MediaIDs,
		MediaAlts:   in.MediaAltTexts,
		Draft: Post{
			AuthorID: uid,
			Author:   snapshot,
			Kind:     KindPost, Text: parsed.Text,
			Hashtags: hashtags, Mentions: mentions,
			Visibility: VisibilityPublic, SnapshotVersion: snapshotVersion,
			PaidPartnership: in.PaidPartnership, MadeWithAI: in.MadeWithAI,
			ReplyPolicy: policy, // a reply's is replaced by the parent's in applyReply
		},
	}
	if parent != nil {
		applyReply(&params, parent)
	}
	if quoted != nil {
		applyQuote(&params, quoted)
	}
	res, err := s.repo.Create(ctx, params)
	noteTxnAttempts(ctx, res.Attempts)
	if err != nil {
		if errors.Is(err, ErrMediaNotReady) {
			return nil, apierr.New(connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_MEDIA_NOT_READY,
				"one of the images is not ready; upload it again")
		}
		if errors.Is(err, ErrParentGone) {
			logger.SetRequestField(ctx, fieldOutcome, outcomeNotFound)
			return nil, postNotFound()
		}
		if errors.Is(err, ErrIdempotencyKeyReused) {
			return nil, apierr.New(connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_IDEMPOTENCY_KEY_REUSED,
				"this idempotency_key was already used for a different request")
		}
		var ae *apierr.Error
		if errors.As(err, &ae) {
			return nil, err // quota exceeded and other already-shaped errors
		}
		return nil, logger.RedactErr(fmt.Errorf("posts: create: %w", err), uid)
	}

	// Replay: the first call's post, cache-first (0 reads warm, 1 cold). No post-commit effects.
	if res.Post == nil {
		logger.SetRequestField(ctx, fieldOutcome, outcomeReplay)
		p, err := s.Get(ctx, res.ReplayID)
		if errors.Is(err, ErrNotFound) {
			return nil, apierr.New(connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "the post created by this request no longer exists")
		}
		return p, err
	}

	// 4. After commit: instance caches from the written data, then the (no-op) hook. Never inside the txn.
	post := res.Post
	s.cache.SetPost(post)
	if post.Kind == KindQuote {
		s.cache.AdjustCounts(post.QuoteOfID, 0, 0, 1) // the quoted post's quoteCount moved in the same commit
	}
	if post.IsReply {
		// Replies are not root posts: they stay out of the author-recent entry (the Posts tab and Home feed
		// cache). The parent's cached copy has a stale replyCount.
		s.cache.DeletePost(post.ReplyToID)
	} else {
		s.cache.PrependOwn(post)
	}
	s.directory.Forget(uid) // users.postsCount changed by a blind increment (ADR-0008 B2)
	s.events.Created(ctx, post)
	logger.SetRequestField(ctx, fieldOutcome, outcomeCreated)
	return post, nil
}

// resolveMentions turns the parser's candidates (lower-case, valid, at most MaxMentions after the cap) into stored
// mentions (D7, amended 2026-10-05, M2): nothing without candidates (so no handle read); unknown handles dropped.
// Mentions never depend on the block graph: dropping a user who blocked the author would let the author learn
// "X blocked me" from the response (a block oracle). A blocker is suppressed where it matters instead: the author
// cannot open the blocker's profile (NOT_FOUND, ADR-0008 D9) and notifications (P6) must filter by the graph.
func (s *service) resolveMentions(ctx context.Context, uid string, candidates []string) ([]Mention, error) {
	if len(candidates) == 0 {
		return nil, nil
	}
	if len(candidates) > text.MaxMentions {
		candidates = candidates[:text.MaxMentions]
	}
	uids, err := s.directory.ResolveHandles(ctx, candidates)
	if err != nil {
		return nil, logger.RedactErr(fmt.Errorf("posts: resolve mentions: %w", err), uid)
	}
	var out []Mention
	seen := make(map[string]struct{}, len(candidates))
	for _, h := range candidates {
		mu, ok := uids[h]
		if !ok {
			continue
		}
		if _, dup := seen[mu]; dup {
			continue
		}
		seen[mu] = struct{}{}
		out = append(out, Mention{UserID: mu, Handle: h})
	}
	return out, nil
}

// isNewAccount reports whether p was created within the new-account window (ADR-0003 quotas).
func (s *service) isNewAccount(p identity.Profile, now time.Time) bool {
	return !p.CreatedAt.IsZero() && now.Sub(p.CreatedAt) < s.newAccountWindow
}

// requestHash is the canonical hash of the request body for IDEMPOTENCY_KEY_REUSED: the normalised text, the
// reply target, media ids and alt texts in request order and the quote target, in a fixed order (D18). A
// text-only root post hashes exactly as it did before P3 and P4. The ADR-0021 disclosure labels are appended
// (`|pp=1`, `|ai=1`) ONLY when true, so a request without them hashes byte-for-byte as before the deploy and a
// retry across it still replays instead of IDEMPOTENCY_KEY_REUSED. The reply policy (`|policy=FOLLOWING`, the enum
// name) is appended before `|pp=`, only when restricted; EVERYONE and UNSPECIFIED are both absent, and a reply's
// inherited policy is never hashed (a reply's request carries none).
func requestHash(normalisedText, replyTo, quoteOf string, mediaIDs, alts []string, policy ReplyPolicy, paidPartnership, madeWithAI bool) string {
	return idempotency.HashRequest(requestHashBase(normalisedText, replyTo, quoteOf, mediaIDs, alts, policy, paidPartnership, madeWithAI))
}

// requestHashBase is the canonical string requestHash digests; SchedulePost appends its publish time to it.
func requestHashBase(normalisedText, replyTo, quoteOf string, mediaIDs, alts []string, policy ReplyPolicy, paidPartnership, madeWithAI bool) string {
	base := fmt.Sprintf("v1|text=%q|media=%q|alts=%q|reply=%q|quote=%q",
		normalisedText, strings.Join(mediaIDs, ","), strings.Join(alts, "\x1f"), replyTo, quoteOf)
	if policy != ReplyPolicyEveryone {
		base += "|policy=" + string(policy)
	}
	if paidPartnership {
		base += "|pp=1"
	}
	if madeWithAI {
		base += "|ai=1"
	}
	return base
}

// validateReplyPolicy checks the request's reply_policy before any read (ADR-0021 D2) and returns the value to
// store: UNSPECIFIED and EVERYONE are stored as absent. FOLLOWING_OF_FOLLOWING and VERIFIED are declared but not
// available; unknown numbers are invalid; any non-UNSPECIFIED value on a reply is refused, because a reply
// inherits its conversation's policy and never sets its own.
func validateReplyPolicy(in CreateInput) (ReplyPolicy, error) {
	p := postsv1.ReplyPolicy(in.ReplyPolicy)
	switch p {
	case postsv1.ReplyPolicy_REPLY_POLICY_UNSPECIFIED:
		return ReplyPolicyEveryone, nil
	case postsv1.ReplyPolicy_REPLY_POLICY_FOLLOWING_OF_FOLLOWING, postsv1.ReplyPolicy_REPLY_POLICY_VERIFIED:
		return "", apierr.Validation("reply_policy", "this reply setting is not available yet")
	case postsv1.ReplyPolicy_REPLY_POLICY_EVERYONE, postsv1.ReplyPolicy_REPLY_POLICY_FOLLOWING, postsv1.ReplyPolicy_REPLY_POLICY_MENTIONED_ONLY:
		if in.ReplyToPostID != "" {
			return "", apierr.Validation("reply_policy", "set who can reply on the first post of a conversation")
		}
		switch p {
		case postsv1.ReplyPolicy_REPLY_POLICY_FOLLOWING:
			return ReplyPolicyFollowing, nil
		case postsv1.ReplyPolicy_REPLY_POLICY_MENTIONED_ONLY:
			return ReplyPolicyMentionedOnly, nil
		default:
			return ReplyPolicyEveryone, nil
		}
	default:
		return "", apierr.Validation("reply_policy", "reply_policy is not a valid value")
	}
}

// maxAltTextRunes bounds one alt text (CreatePost proto: <= 1,000 chars).
const maxAltTextRunes = 1000

// validateMedia checks the shape of media_ids and media_alt_texts before any read: at most 4 distinct 19-digit
// ids and alt texts that are empty or parallel to the ids, valid UTF-8, no control characters, <= 1,000 code points.
func validateMedia(mediaIDs, alts []string) error {
	if len(mediaIDs) > MaxMedia {
		return apierr.Validation("media_ids", "at most 4 images per post")
	}
	if len(alts) > 0 && len(alts) != len(mediaIDs) {
		return apierr.Validation("media_alt_texts", "media_alt_texts must be empty or parallel to media_ids")
	}
	seen := make(map[string]struct{}, len(mediaIDs))
	for _, id := range mediaIDs {
		if !ids.ValidPostID(id) {
			return apierr.Validation("media_ids", "media_ids must be 19-digit media ids")
		}
		if _, dup := seen[id]; dup {
			return apierr.Validation("media_ids", "media_ids must not repeat")
		}
		seen[id] = struct{}{}
	}
	for _, a := range alts {
		if !utf8.ValidString(a) || utf8.RuneCountInString(a) > maxAltTextRunes {
			return apierr.Validation("media_alt_texts", "each alt text must be at most 1,000 characters")
		}
		for _, r := range a {
			if unicode.IsControl(r) {
				return apierr.Validation("media_alt_texts", "alt text must not contain control characters")
			}
		}
	}
	return nil
}

// featureDisabled is FEATURE_DISABLED with metadata["feature"] (ADR-0010 D2).
func featureDisabled(feature string) error {
	return flags.DisabledError().WithMeta("feature", feature)
}

// authorSnapshotOf is the denormalised author block a new post stores (handle, display name, thumbnail, verified) and the
// profile snapshotVersion it was taken at (ADR-0003: the profile-snapshot job refreshes older versions). It is the one
// place a post's author block is built from an identity.Profile: CreatePost (from the cached directory profile) and the
// scheduled-post publish transaction (from the in-transaction profile) both use it, so the two can never disagree.
func authorSnapshotOf(uid string, p identity.Profile) (AuthorSnapshot, int64) {
	return AuthorSnapshot{
		UserID: uid, Handle: p.Handle, DisplayName: p.DisplayName, AvatarURL: p.AvatarThumbURL, Verified: p.Verified,
	}, p.SnapshotVersion
}
