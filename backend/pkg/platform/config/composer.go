package config

import (
	"fmt"
	"time"
)

// Hard bounds of the composer-extras config (ADR-0029). A value outside them fails startup naming the key: the wire
// contract (PollChoice indexes 0..3, viewer_poll_choice 1..4, the poll.counts.<i> keys) caps the choices at 4, and the
// rest keep an operator typo from disabling a guard or opening an abuse path.
const (
	// pollChoicesCeiling is the most choices a poll can ever have (VotePoll choice_index 0..3).
	pollChoicesCeiling = 4
	// pollCodepointsCeiling bounds POLL_CHOICE_MAX_CODEPOINTS (the default is 25; the doc stores them all).
	pollCodepointsCeiling = 100
	// pollMaxDurationCeiling bounds POLL_MAX_DURATION: the vote TTL and the client copy are written for at most 30 days.
	pollMaxDurationCeiling = 30 * 24 * time.Hour
	// pollVoteTTLCeiling bounds POLL_VOTE_TTL_AFTER_CLOSE: a vote doc is data kept past the poll, so it is not open-ended.
	pollVoteTTLCeiling = 90 * 24 * time.Hour
	// pollViewerVotesCeiling bounds POLL_VIEWER_VOTES_KEPT: the userLikes.pollVotes array stays far below the 40,000
	// index-entry and 1 MiB document limits (it is also index-exempt).
	pollViewerVotesCeiling = 1000
	// gifFramesCeiling, gifEdgeCeiling and gifFrameAreaCeiling bound the decode guards (ADR-0029 D11): a raised value is
	// a memory and CPU decision, so it needs an ADR, not an env var.
	gifFramesCeiling    = 1000
	gifEdgeCeiling      = 4096
	gifFrameAreaCeiling = 200_000_000
	// mediaScreenAttemptsCeiling bounds MEDIA_MAX_SCREEN_ATTEMPTS: every attempt can bill up to 2 Vision units (W6-27, H-3).
	mediaScreenAttemptsCeiling = 10
	// mediaScreenRetriesCeiling bounds MEDIA_MAX_SCREEN_RETRIES (W6-40, ADR-0029 Amendment 1 A5.4): with the attempts it sets the claims
	// ceiling, and every claim can bill up to 2 Vision units (8 claims x 2 = 16 per document at the defaults).
	mediaScreenRetriesCeiling = 10
	// mediaVisionUnitsDayCeiling and mediaVisionUnitsDayNewAccountCeiling bound the per-uid daily Vision-units caps (A5.5).
	mediaVisionUnitsDayCeiling           = 200
	mediaVisionUnitsDayNewAccountCeiling = 60
)

// ComposerConfig holds the poll and GIF limits of the composer extras (ADR-0029 D1, D6, D8, D11). The VotePoll bucket and
// the poll_votes_daily cap live in RateLimitConfig (PollVotePerUserPerMinute, PollVotesPerDay, PollVotesPerDayNewAccount).
// Every value is validated at startup (rule 11: limits are config, never literals in code).
type ComposerConfig struct {
	// PollMaxChoices is the most choices a poll may have, 2..4 (POLL_MAX_CHOICES, default 4). The minimum is always 2.
	PollMaxChoices int
	// PollChoiceMaxCodepoints is the longest choice label in Unicode code points after normalisation, 1..100
	// (POLL_CHOICE_MAX_CODEPOINTS, default 25).
	PollChoiceMaxCodepoints int
	// PollMinDuration and PollMaxDuration bound a poll's duration (POLL_MIN_DURATION default 5m, POLL_MAX_DURATION default
	// 168h = 7 days); 1m <= min <= max <= 30 days.
	PollMinDuration time.Duration
	PollMaxDuration time.Duration
	// PollVoteTTLAfterClose is how long a pollVotes doc outlives its poll's closesAt before the TTL deletes it
	// (POLL_VOTE_TTL_AFTER_CLOSE, default 720h = 30 days); 24h..90 days.
	PollVoteTTLAfterClose time.Duration
	// PollViewerVotesKept is how many entries userLikes.pollVotes keeps after a lazy trim (POLL_VIEWER_VOTES_KEPT,
	// default 500), 1..1000.
	PollViewerVotesKept int
	// GifMaxFrames, GifMaxEdge and GifMaxFrameAreaSum are the pre-scan limits of a GIF before any decode (GIF_MAX_FRAMES
	// default 300, GIF_MAX_EDGE default 1,280 pixels per side, GIF_MAX_FRAME_AREA_SUM default 50,000,000 pixels).
	GifMaxFrames       int
	GifMaxEdge         int
	GifMaxFrameAreaSum int
	// MediaMaxScreenAttempts is MEDIA_MAX_SCREEN_ATTEMPTS (default 3, 1..10): the most screening attempts (FinalizeUpload
	// claims) one media document gets; after that it is REJECTED with no further Vision call (W6-27, security H-3).
	// MediaMaxScreenAttempts, revised by W6-40 (ADR-0029 Amendment 1 A5.4): the attempts that produced a valid assessment without ending
	// the document (screenAssessed). A document with that many is REJECTED with no Vision call.
	MediaMaxScreenAttempts int
	// MediaMaxScreenRetries is MEDIA_MAX_SCREEN_RETRIES (default 5, 0..10): the claimed attempts that produced no valid assessment (an
	// outage, a timeout, a billed-but-invalid answer). With MediaMaxScreenAttempts it sets the crash-safe claims ceiling on screenAttempts (3 + 5 = 8).
	MediaMaxScreenRetries int
	// MediaVisionUnitsPerDay and MediaVisionUnitsPerDayNewAccount are MEDIA_VISION_UNITS_PER_DAY (default 60, 2..200) and
	// MEDIA_VISION_UNITS_PER_DAY_NEW_ACCOUNT (default 12, 2..60): the per-uid Vision units one instance lets a uid spend per IST day
	// (media_vision_units_daily; 180 and 36 effective at 3 instances). Charged before the claim.
	MediaVisionUnitsPerDay           int
	MediaVisionUnitsPerDayNewAccount int
}

// loadComposer reads and validates the poll and GIF keys; the error names the key.
func loadComposer() (ComposerConfig, error) {
	var c ComposerConfig
	for _, f := range []struct {
		dst           *int
		key           string
		def, min, max int
	}{
		{&c.PollMaxChoices, "POLL_MAX_CHOICES", 4, 1, pollChoicesCeiling},
		{&c.PollChoiceMaxCodepoints, "POLL_CHOICE_MAX_CODEPOINTS", 25, 1, pollCodepointsCeiling},
		{&c.PollViewerVotesKept, "POLL_VIEWER_VOTES_KEPT", 500, 1, pollViewerVotesCeiling},
		{&c.GifMaxFrames, "GIF_MAX_FRAMES", 300, 1, gifFramesCeiling},
		{&c.GifMaxEdge, "GIF_MAX_EDGE", 1280, 1, gifEdgeCeiling},
		{&c.GifMaxFrameAreaSum, "GIF_MAX_FRAME_AREA_SUM", 50_000_000, 1, gifFrameAreaCeiling},
		{&c.MediaMaxScreenAttempts, "MEDIA_MAX_SCREEN_ATTEMPTS", 3, 1, mediaScreenAttemptsCeiling},
		{&c.MediaMaxScreenRetries, "MEDIA_MAX_SCREEN_RETRIES", 5, 0, mediaScreenRetriesCeiling},
		{&c.MediaVisionUnitsPerDay, "MEDIA_VISION_UNITS_PER_DAY", 60, 2, mediaVisionUnitsDayCeiling},
		{&c.MediaVisionUnitsPerDayNewAccount, "MEDIA_VISION_UNITS_PER_DAY_NEW_ACCOUNT", 12, 2, mediaVisionUnitsDayNewAccountCeiling},
	} {
		v, err := getInt(f.key, f.def)
		if err != nil {
			return ComposerConfig{}, err
		}
		if v < f.min || v > f.max {
			return ComposerConfig{}, fmt.Errorf("config: %s must be %d..%d (got %d)", f.key, f.min, f.max, v)
		}
		*f.dst = v
	}
	if c.PollMaxChoices < 2 {
		return ComposerConfig{}, fmt.Errorf("config: POLL_MAX_CHOICES must be 2..%d (got %d)", pollChoicesCeiling, c.PollMaxChoices)
	}
	for _, f := range []struct {
		dst      *time.Duration
		key      string
		def      time.Duration
		min, max time.Duration
	}{
		{&c.PollMinDuration, "POLL_MIN_DURATION", 5 * time.Minute, time.Minute, pollMaxDurationCeiling},
		{&c.PollMaxDuration, "POLL_MAX_DURATION", 168 * time.Hour, time.Minute, pollMaxDurationCeiling},
		{&c.PollVoteTTLAfterClose, "POLL_VOTE_TTL_AFTER_CLOSE", 720 * time.Hour, 24 * time.Hour, pollVoteTTLCeiling},
	} {
		d, err := getDuration(f.key, f.def)
		if err != nil {
			return ComposerConfig{}, err
		}
		if d < f.min || d > f.max {
			return ComposerConfig{}, fmt.Errorf("config: %s must be between %v and %v (got %v)", f.key, f.min, f.max, d)
		}
		*f.dst = d
	}
	if c.PollMinDuration > c.PollMaxDuration {
		return ComposerConfig{}, fmt.Errorf("config: POLL_MIN_DURATION (%v) must not exceed POLL_MAX_DURATION (%v)", c.PollMinDuration, c.PollMaxDuration)
	}
	return c, nil
}
