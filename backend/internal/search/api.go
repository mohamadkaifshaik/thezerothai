// Package search is the search and trends module (ADR-0028, plan W4): people by handle prefix, posts by one exact
// hashtag, and the daily trending-hashtags list. It owns one collection, trends/current (tags and counts only, no uid).
// People come from identity (Directory.SearchHandles) and posts from posts.Reader.ByHashtag; search never queries
// another module's collection directly, and other modules reach it through the interfaces in this file only.
//
// W4-3 ships the skeleton: the two flag gates (FEATURE_SEARCH and FEATURE_TRENDS, ADR-0028 D8) and the three Connect
// handlers. A caller the flag lets through gets Unimplemented until W4-5 (People), W4-7 (Posts) and W4-9 (Trends and
// the refresher) fill the methods in.
package search

import (
	"context"

	searchv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/search/v1"
)

const (
	// FlagSearch is the wire name of FEATURE_SEARCH (ADR-0028 D8): the `feature` metadata of FEATURE_DISABLED and the string
	// in GetMe.enabled_features. It gates SearchPeople and SearchPosts per caller.
	FlagSearch = "search"
	// FlagTrends is the wire name of FEATURE_TRENDS (ADR-0028 D8). It gates GetTrends per caller; the refresh step honours
	// only GloballyOff.
	FlagTrends = "trends"
)

// FlagChecker is the seam to pkg/platform/flags.Registry (*flags.Registry satisfies it): Enabled answers "is the flag on
// for this caller", GloballyOff "is it the kill switch" (off for everyone; a rollout the caller is outside of is not).
type FlagChecker interface {
	Enabled(uid, name string) bool
	GloballyOff(name string) bool
}

// Service is the Connect handler's dependency (ADR-0028 D11). Each method takes the caller's uid from the token (never
// from the request), checks its flag before any Firestore access (FEATURE_DISABLED with metadata feature=search or
// trends, 0 reads) and then applies the rules. Worst-case Firestore reads and writes per method are in the RPC doc
// comments of proto/dzeroth/search/v1 and on the implementing methods.
type Service interface {
	// People answers SearchPeople (flag "search"): handle-prefix matches, at most limit rows, no pagination.
	People(ctx context.Context, uid, query string, limit int32) (*searchv1.SearchPeopleResponse, error)
	// Posts answers SearchPosts (flag "search"): posts carrying one hashtag, ordered by tab, paged by a sealed token.
	Posts(ctx context.Context, uid, query string, tab searchv1.SearchTab, pageSize int32, pageToken string) (*searchv1.SearchPostsResponse, error)
	// Trends answers GetTrends (flag "trends"): the cached trending-hashtags list, optionally filtered by prefix.
	Trends(ctx context.Context, uid string, limit int32, prefix string) (*searchv1.GetTrendsResponse, error)
}

// TrendsRefresher recomputes trends/current from the posts created since the last run (ADR-0028 D6). A scheduled step
// calls it; the cron host is wiring only. W4-9 implements it; the skeleton only names the seam.
type TrendsRefresher interface {
	Refresh(ctx context.Context) error
}
