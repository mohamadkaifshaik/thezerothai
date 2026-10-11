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
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/internal/posts/text"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
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
func (s *service) Create(ctx context.Context, uid string, in CreateInput) (_ *Post, err error) {
	logger.SetRequestField(ctx, fieldOp, "create")
	defer func() {
		if err != nil {
			noteRejected(ctx, err)
		}
	}()

	// 1. Sub-features first, before any other validation or read (D2). Order: replies, quotes, media.
	if in.ReplyToPostID != "" {
		return nil, featureDisabled("replies")
	}
	if in.QuoteOfPostID != "" {
		return nil, featureDisabled("quotes")
	}
	hasMedia := len(in.MediaIDs) > 0 || len(in.MediaAltTexts) > 0
	if hasMedia && !in.MediaEnabled {
		return nil, featureDisabled("media")
	}
	if !idempotency.KeyFormatValid(in.IdempotencyKey) {
		return nil, apierr.Validation("idempotency_key", "idempotency_key must be 16-64 characters of [A-Za-z0-9_-]")
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
	res, err := s.repo.Create(ctx, CreateParams{
		AuthorID:    uid,
		IdemKey:     idempotency.Key(uid, createRPC, in.IdempotencyKey),
		RequestHash: requestHash(parsed.Text, in.MediaIDs, in.MediaAltTexts),
		QuotaLimit:  limit,
		MediaIDs:    in.MediaIDs,
		MediaAlts:   in.MediaAltTexts,
		Draft: Post{
			AuthorID: uid,
			Author: AuthorSnapshot{
				UserID: uid, Handle: author.Handle, DisplayName: author.DisplayName,
				AvatarURL: author.AvatarThumbURL, Verified: author.Verified,
			},
			Kind: KindPost, Text: parsed.Text,
			Hashtags: hashtags, Mentions: mentions,
			Visibility: VisibilityPublic, SnapshotVersion: author.SnapshotVersion,
		},
	})
	noteTxnAttempts(ctx, res.Attempts)
	if err != nil {
		if errors.Is(err, ErrMediaNotReady) {
			return nil, apierr.New(connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_MEDIA_NOT_READY,
				"one of the images is not ready; upload it again")
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
	s.cache.PrependOwn(post)
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
// media ids and alt texts in request order and the two slice-2+ fields (always empty while they are rejected), in
// a fixed order (D18). A text-only request hashes exactly as it did before P4.
func requestHash(normalisedText string, mediaIDs, alts []string) string {
	return idempotency.HashRequest(fmt.Sprintf("v1|text=%q|media=%q|alts=%q|reply=%q|quote=%q",
		normalisedText, strings.Join(mediaIDs, ","), strings.Join(alts, "\x1f"), "", ""))
}

// maxAltTextRunes bounds one alt text (CreatePost proto: <= 1,000 chars).
const maxAltTextRunes = 1000

// validateMedia checks the shape of media_ids and media_alt_texts before any read: at most 4 distinct 19-digit
// ids and alt texts that are empty or parallel to the ids, valid UTF-8, no control characters, <= 1,000 code points.
func validateMedia(ids, alts []string) error {
	if len(ids) > MaxMedia {
		return apierr.Validation("media_ids", "at most 4 images per post")
	}
	if len(alts) > 0 && len(alts) != len(ids) {
		return apierr.Validation("media_alt_texts", "media_alt_texts must be empty or parallel to media_ids")
	}
	seen := make(map[string]struct{}, len(ids))
	for _, id := range ids {
		if !postIDPattern.MatchString(id) {
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
