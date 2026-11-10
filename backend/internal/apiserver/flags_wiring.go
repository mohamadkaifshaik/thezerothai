// flags_wiring.go builds the feature-flag registry Build hands to every module: one line per FEATURE_* spec config.Load
// parsed. A spec left out here is loaded, listed in the promotion ceiling and still off for everyone, which is why
// flags_wiring_test.go pins the newest entries.
package apiserver

import (
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// featureRegistry is the registry over every cfg.Feature* spec. It is a function of cfg alone so a test can check
// exactly what Build wires.
func featureRegistry(cfg config.Config) *flags.Registry {
	return flags.NewRegistry(cfg.FeatureGraph, cfg.FeaturePosts, cfg.FeatureAccountLifecycle, cfg.FeatureReplies, cfg.FeatureProfileSnapshot, cfg.FeatureMedia, cfg.FeatureNotifications, cfg.FeatureReports, cfg.FeatureEngagement, cfg.FeatureQuotes, cfg.FeatureContentDisclosure, cfg.FeatureReplyAudience, cfg.FeatureScheduledPosts, cfg.FeatureBookmarks, cfg.FeatureMessaging, cfg.FeatureLists, cfg.FeatureCommunities, cfg.FeatureProfileExtras, cfg.FeatureProfileTabs, cfg.FeatureLikesList, cfg.FeatureFollowSuggestions, cfg.FeaturePrivateAccounts, cfg.FeatureUIShell, cfg.FeatureShells, cfg.FeatureCrashReporting, cfg.FeatureAnalytics, cfg.FeatureRemovedIDs, cfg.FeatureSearch, cfg.FeatureTrends, cfg.FeaturePolls, cfg.FeatureDrafts, cfg.FeatureGif, cfg.FeatureBeacons, cfg.FeatureNotificationPrefs, cfg.FeatureDMPolicy, cfg.FeatureReadReceipts)
}
