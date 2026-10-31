package search

import (
	"strings"

	"golang.org/x/text/unicode/norm"
)

// maxTrendKeyPoints is the longest key an operator may hide: a stored hashtag body has at most 50 code points
// (text.MaxHashtagLen), so a longer key can never match a tag.
const maxTrendKeyPoints = 50

// TrendKey is the one matching function for trends: the denylist (TRENDS_DENYLIST), the hide list (trends/hidden) and the
// stored tags are all compared by this key (ADR-0028 note 2026-10-31 part 1, review M-1). Steps, in order: trim, drop one
// leading '#', NFKC (fullwidth and mathematical letters are valid D8 letters), lower-case, drop U+200C, U+200D and '_',
// NFKC again. The '#' is dropped again after the first NFKC so a fullwidth '＃' behaves like '#'. An empty key never
// matches anything. Stored tags are not rewritten and counting is unchanged. Cross-script homoglyphs (UTS #39) stay a
// residual: each variant costs one hide.
func TrendKey(s string) string {
	s = strings.TrimPrefix(strings.TrimSpace(s), "#")
	s = norm.NFKC.String(s)
	s = strings.TrimPrefix(s, "#")
	s = strings.Map(func(r rune) rune {
		if r == '\u200c' || r == '\u200d' || r == '_' {
			return -1
		}
		return r
	}, strings.ToLower(s))
	return norm.NFKC.String(s)
}

// trendKeySet is the set of non-empty keys of the given tag bodies.
func trendKeySet(tags []string) map[string]struct{} {
	m := make(map[string]struct{}, len(tags))
	for _, t := range tags {
		if k := TrendKey(t); k != "" {
			m[k] = struct{}{}
		}
	}
	return m
}
