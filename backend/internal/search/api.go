// Package search is the search and trends module (plan W4): people by handle prefix, posts by one exact
// hashtag, and the daily trending-hashtags list. It owns the trends collection: trends/current (tags and counts only, no uid) and trends/hidden (the operator hide list, folded tag keys, no uid).
// People come from identity (Directory.SearchHandles) and posts from posts.Reader.ByHashtag; search never queries
// another module's collection directly, and other modules reach it through the interfaces in this file only.
//
// The skeleton: the two flag gates (FEATURE_SEARCH and FEATURE_TRENDS) and the three Connect
// handlers; service.go implements People, Posts and Trends, and trends_refresh.go
// the refresher.
package search

import (
	"context"

	searchv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/search/v1"
)

const (
	// FlagSearch is the wire name of FEATURE_SEARCH: the `feature` metadata of FEATURE_DISABLED and the string
	// in GetMe.enabled_features. It gates SearchPeople and SearchPosts per caller.
	FlagSearch = "search"
	// FlagTrends is the wire name of FEATURE_TRENDS. It gates GetTrends per caller; the refresh step honours
	// only GloballyOff.
	FlagTrends = "trends"
)

// FlagChecker is the seam to pkg/platform/flags.Registry (*flags.Registry satisfies it): Enabled answers "is the flag on
// for this caller", GloballyOff "is it the kill switch" (off for everyone; a rollout the caller is outside of is not).
type FlagChecker interface {
	Enabled(uid, name string) bool
	GloballyOff(name string) bool
}

// Service is the Connect handler's dependency. Each method takes the caller's uid from the token (never
// from the request), checks its flag before any Firestore access (FEATURE_DISABLED with metadata feature=search or
// trends) and then applies the rules. The RPC rules are in the doc
// comments of proto/dzeroth/search/v1 and on the implementing methods.
type Service interface {
	// People answers SearchPeople (flag "search"): handle-prefix matches, at most limit rows, no pagination.
	People(ctx context.Context, uid, query string, limit int32) (*searchv1.SearchPeopleResponse, error)
	// Posts answers SearchPosts (flag "search"): posts carrying one hashtag, ordered by tab, paged by a sealed token.
	Posts(ctx context.Context, uid, query string, tab searchv1.SearchTab, pageSize int32, pageToken string) (*searchv1.SearchPostsResponse, error)
	// Trends answers GetTrends (flag "trends"): the cached trending-hashtags list, optionally filtered by prefix.
	Trends(ctx context.Context, uid string, limit int32, prefix string) (*searchv1.GetTrendsResponse, error)
}

// TrendsRefresher recomputes trends/current from the posts created since the last run. A scheduled step
// calls it; the cron host is wiring only.
type TrendsRefresher interface {
	Refresh(ctx context.Context) error
}
