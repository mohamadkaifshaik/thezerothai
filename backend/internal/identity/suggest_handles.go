package identity

import (
	"context"
	"fmt"
	"strconv"
	"strings"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/handle"
)

const (
	// MaxHandleSuggestions is the most handles SuggestHandles returns.
	MaxHandleSuggestions = 5
	// suggestionFirstSuffix and suggestionLastSuffix bound the numeric suffix n of a candidate (base+n, base_n).
	suggestionFirstSuffix = 2
	suggestionLastSuffix  = 7
	// suggestionBaseMaxLen keeps the longest candidate (base + "_7") within handle.MaxLen.
	suggestionBaseMaxLen = handle.MaxLen - 2
)

// handleCandidates derives the suggestion candidates from input, in order: base2, base_2, base3, base_3, ... base7,
// base_7 (at most 12). base is input trimmed, lower-cased and truncated so the longest candidate fits handle.MaxLen.
// Input that fails issue (malformed, or reserved: suggesting "support2" for "support" would invite impersonation)
// yields nothing. A candidate that fails issue or equals the input is dropped. issue is handleFormatIssue in
// production; tests inject a stricter one to prove the per-candidate check.
func handleCandidates(input string, issue func(string) string) []string {
	in := strings.ToLower(strings.TrimSpace(input))
	if issue(in) != "" {
		return nil
	}
	base := in
	if len(base) > suggestionBaseMaxLen { // ValidRun proved it ASCII, so byte slicing is safe
		base = base[:suggestionBaseMaxLen]
	}
	out := make([]string, 0, 2*(suggestionLastSuffix-suggestionFirstSuffix+1))
	for n := suggestionFirstSuffix; n <= suggestionLastSuffix; n++ {
		suffix := strconv.Itoa(n)
		for _, c := range []string{base + suffix, base + "_" + suffix} {
			if c == in || issue(c) != "" {
				continue
			}
			out = append(out, c)
		}
	}
	return out
}

// SuggestHandles implements Service: up to MaxHandleSuggestions free handles in candidate order (0 is a valid
// answer). Candidates in the positive handle cache are skipped without a read; the rest are checked with ONE batched
// GetAll on handles/{candidate} (at most 12 docs). The 10 s negative "free" cache is deliberately not consulted (a
// handle freed or claimed elsewhere must be read fresh), and not filled either. Invalid input reads nothing. It never
// writes Firestore; the only side effect is warming the in-memory positive handle cache from the read.
func (s *service) SuggestHandles(ctx context.Context, input string) ([]string, error) {
	return s.suggestHandles(ctx, input, handleFormatIssue)
}

func (s *service) suggestHandles(ctx context.Context, input string, issue func(string) string) ([]string, error) {
	candidates := handleCandidates(input, issue)
	unknown := make([]string, 0, len(candidates))
	for _, c := range candidates {
		if _, taken := s.cache.GetHandleUID(c); !taken {
			unknown = append(unknown, c)
		}
	}
	if len(unknown) == 0 {
		return []string{}, nil
	}
	owners, err := s.repo.ResolveHandles(ctx, unknown)
	if err != nil {
		return nil, fmt.Errorf("identity: suggest handles: %w", err)
	}
	out := make([]string, 0, MaxHandleSuggestions)
	for _, c := range unknown {
		if uid, taken := owners[c]; taken {
			s.cache.SetHandleUID(c, uid)
			continue
		}
		if len(out) < MaxHandleSuggestions {
			out = append(out, c)
		}
	}
	return out, nil
}
