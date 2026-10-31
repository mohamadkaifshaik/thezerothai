// poll.go is the one place that knows the poll creation rules (ADR-0029 D1, D2, plan W6-5): the limits, the validation of
// a CreatePost poll, the idempotency suffix and the stored shape. The Flutter client mirrors the same rules from the
// shared fixture testdata/poll_rules.json (the Go test poll_rules_test.go and the Dart test run the same rows).
// Nothing here reads or writes Firestore.
package posts

import (
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"golang.org/x/text/cases"
	"golang.org/x/text/unicode/norm"

	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"

	"github.com/dzeroth/dzeroth/backend/internal/posts/text"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
)

// pollField is the VALIDATION field every poll rule reports (ADR-0029 D1).
const pollField = "poll"

// MaxPollChoices is the structural ceiling of a poll: the wire contract indexes choices 0..3 (VotePoll.choice_index,
// viewer_poll_choice 1..4) and the vote increments the counter keys "0".."3". PollLimits.MaxChoices can only lower it.
const MaxPollChoices = 4

// PollLimits are the creation limits, filled by the wiring from config.Composer (rule 11: limits are config; posts does not
// import config). The zero value rejects every poll (fail closed), so a missing wiring never opens an unbounded poll.
type PollLimits struct {
	// MaxChoices is the most choices a poll may have, 2..MaxPollChoices (POLL_MAX_CHOICES).
	MaxChoices int
	// ChoiceMaxCodepoints is the longest label in code points after normalisation (POLL_CHOICE_MAX_CODEPOINTS).
	ChoiceMaxCodepoints int
	// MinDuration and MaxDuration bound the duration (POLL_MIN_DURATION, POLL_MAX_DURATION); whole minutes are compared.
	MinDuration time.Duration
	MaxDuration time.Duration
}

// usable reports whether the limits can accept any poll at all.
func (l PollLimits) usable() bool {
	return l.MaxChoices >= 2 && l.MaxChoices <= MaxPollChoices && l.ChoiceMaxCodepoints >= 1 &&
		l.MinDuration >= time.Minute && l.MaxDuration >= l.MinDuration
}

// PollInput is CreatePostRequest.poll as the handler passes it (nil = no poll).
type PollInput struct {
	Choices         []string
	DurationMinutes int32
}

// Poll is the stored poll of a root post (ADR-0029 D1). Counts has one entry per option (index = choice index), Total is the
// sum of the votes (kept as its own counter so redaction can show it without the counts). The instance cache and every reader
// treat a Poll as read-only; a writer builds a new one.
type Poll struct {
	Options     []string
	DurationMin int
	// ClosesAt is created_at + DurationMin, computed from the Snowflake createdAt of the committing attempt (never the client).
	ClosesAt time.Time
	Counts   []int64
	Total    int64
}

// EmbeddedPoll is the frozen definition a QUOTE or REPOST copies (ADR-0029 D5): labels and closing time, never counts.
type EmbeddedPoll struct {
	Options  []string
	ClosesAt time.Time
}

// PollDraft is a validated poll waiting for its createdAt: normalised labels and the duration in minutes.
type PollDraft struct {
	Options     []string
	DurationMin int
}

// Closed reports now >= ClosesAt (by the server clock the caller passes).
func (p *Poll) Closed(now time.Time) bool { return !now.Before(p.ClosesAt) }

// newPoll builds the stored poll for a draft at createdAt: zero counts, closesAt = createdAt + duration. A fresh value per
// call, so a retried transaction attempt never mutates or shares the previous one.
func (d PollDraft) newPoll(createdAt time.Time) *Poll {
	return &Poll{
		Options:     append([]string(nil), d.Options...),
		DurationMin: d.DurationMin,
		ClosesAt:    createdAt.Add(time.Duration(d.DurationMin) * time.Minute),
		Counts:      make([]int64, len(d.Options)),
	}
}

// frozen is the embed form of p (labels copied, no counts).
func (p *Poll) frozen() *EmbeddedPoll {
	if p == nil {
		return nil
	}
	return &EmbeddedPoll{Options: append([]string(nil), p.Options...), ClosesAt: p.ClosesAt}
}

// validatePoll checks a CreatePost poll against the limits and returns the normalised draft. Every failure is VALIDATION
// field=poll. Order: shape, then each label (NFC, no control or bidi characters, code-point count), then distinctness after
// NFC + case folding, then the duration in whole minutes (bounded as an integer before any conversion, so a huge value
// cannot wrap a time.Duration into the allowed range).
func validatePoll(l PollLimits, in *PollInput) (PollDraft, error) {
	if !l.usable() {
		return PollDraft{}, apierr.Validation(pollField, "polls are not available")
	}
	if in == nil || len(in.Choices) < 2 || len(in.Choices) > l.MaxChoices {
		return PollDraft{}, apierr.Validation(pollField, "a poll needs between 2 and "+strconv.Itoa(l.MaxChoices)+" choices")
	}
	labels := make([]string, len(in.Choices))
	seen := make(map[string]struct{}, len(in.Choices))
	for i, raw := range in.Choices {
		s, err := text.NormalizeLabel(raw)
		if err != nil {
			return PollDraft{}, apierr.Validation(pollField, "a choice "+err.Error())
		}
		if utf8.RuneCountInString(s) > l.ChoiceMaxCodepoints {
			return PollDraft{}, apierr.Validation(pollField, "a choice must be at most "+strconv.Itoa(l.ChoiceMaxCodepoints)+" characters")
		}
		key := foldKey(s)
		if _, dup := seen[key]; dup {
			return PollDraft{}, apierr.Validation(pollField, "choices must be different from each other")
		}
		seen[key] = struct{}{}
		labels[i] = s
	}
	lo, hi := int64(l.MinDuration/time.Minute), int64(l.MaxDuration/time.Minute)
	if d := int64(in.DurationMinutes); d < lo || d > hi {
		return PollDraft{}, apierr.Validation(pollField, "the poll must last between "+strconv.Itoa(int(lo))+" and "+strconv.Itoa(int(hi))+" minutes")
	}
	return PollDraft{Options: labels, DurationMin: int(in.DurationMinutes)}, nil
}

// foldKey is the comparison key of the distinctness rule: NFC of the case-folded NFC label. A fresh Caser per call, because a
// cases.Caser is not safe for concurrent use.
func foldKey(s string) string { return norm.NFC.String(cases.Fold().String(norm.NFC.String(s))) }

// pollHashSuffix is the ADR-0029 D2 suffix appended to the request hash base after `|ai=1`, only when a poll is present:
// `|poll=<n>:<hex SHA-256 of the normalised labels joined by U+001F>|dur=<minutes>`. Empty for no poll, so a CreatePost
// without a poll hashes byte for byte as before.
func pollHashSuffix(d *PollDraft) string {
	if d == nil {
		return ""
	}
	return "|poll=" + strconv.Itoa(len(d.Options)) + ":" + idempotency.HashRequest(strings.Join(d.Options, "\x1f")) + "|dur=" + strconv.Itoa(d.DurationMin)
}

// checkPoll validates the request's poll before any read (ADR-0029 D1): the refused combinations first (media or alt texts,
// a reply, a quote, empty text), then the poll's own rules. Every failure is VALIDATION field=poll, so no combination is
// told apart by its error. It returns nil, nil for a request without a poll.
func (s *service) checkPoll(in CreateInput) (*PollDraft, error) {
	if in.Poll == nil {
		return nil, nil
	}
	if len(in.MediaIDs) > 0 || len(in.MediaAltTexts) > 0 {
		return nil, apierr.Validation(pollField, "a poll cannot be combined with images")
	}
	if in.ReplyToPostID != "" || in.QuoteOfPostID != "" {
		return nil, apierr.Validation(pollField, "a poll can only be on a new post, not a reply or a quote")
	}
	// The question is the post text: blank text is refused as a poll error, not the generic text error.
	if parsed, err := text.ParseOptional(in.Text); err == nil && parsed.Text == "" {
		return nil, apierr.Validation(pollField, "a poll needs a question in the post text")
	}
	d, err := validatePoll(s.poll, in.Poll)
	if err != nil {
		return nil, err
	}
	return &d, nil
}

// requestHashWithPoll is requestHash plus the ADR-0029 D2 poll suffix (absent for no poll, so the hash is today's).
func requestHashWithPoll(normalisedText, replyTo, quoteOf string, mediaIDs, alts []string, policy ReplyPolicy, paidPartnership, madeWithAI bool, poll *PollDraft) string {
	return idempotency.HashRequest(requestHashBase(normalisedText, replyTo, quoteOf, mediaIDs, alts, policy, paidPartnership, madeWithAI) + pollHashSuffix(poll))
}

// pollInputOf maps CreatePostRequest.poll to the service input (nil for no poll).
func pollInputOf(m *postsv1.PollDraft) *PollInput {
	if m == nil {
		return nil
	}
	return &PollInput{Choices: m.GetChoices(), DurationMinutes: m.GetDurationMinutes()}
}

// Voted returns a copy of p whose poll counts one more vote for choice (ADR-0029 D6 step 8): a NEW Post and a NEW Poll with
// fresh Counts, never an in-place change, because the cached *Post and its *Poll are shared by every reader (Cache.AdjustCounts
// copies Post shallowly). It is p itself when p has no poll or choice is out of range.
func (p *Post) Voted(choice int) *Post {
	if p == nil || p.Poll == nil || choice < 0 || choice >= len(p.Poll.Options) {
		return p
	}
	np := *p.Poll
	np.Counts = make([]int64, len(p.Poll.Options))
	copy(np.Counts, p.Poll.Counts)
	np.Counts[choice]++
	np.Total++
	cp := *p
	cp.Poll = &np
	return &cp
}
