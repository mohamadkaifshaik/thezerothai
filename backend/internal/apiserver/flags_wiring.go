// flags_wiring.go builds the feature-flag registry Build hands to every module: one line per FEATURE_* spec config.Load
// parsed. A spec left out here is loaded, listed in the promotion ceiling and still off for everyone, which is why
// flags_wiring_test.go pins the newest entries.
package apiserver

import (
	"github.com/dzeroth/dzeroth/backend/internal/keys"
	"github.com/dzeroth/dzeroth/backend/internal/messaging"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// featureRegistry is the registry over every cfg.Feature* spec. It is a function of cfg alone so a test can check
// exactly what Build wires.
//
// The end-to-end-encryption coupling (E2EE Plan 6 §1.3): the effective e2ee_dm for a uid is e2ee_dm && messaging, and the
// effective e2ee_required is e2ee_required && the effective e2ee_dm. Enabled (every module's gate) and EnabledFeatures
// (GetMe.enabled_features) report the effective values; GloballyOff (the kill switch K1 and RemoveKeyDevice read) keeps
// reading each raw flag. Why: percent buckets are salted per flag name, so two percent ramps overlap only on a fraction
// of users; with the coupling E2EE_DM, E2EE_REQUIRED and DEVICE_SIGN_OUT can be on globally while MESSAGING alone ramps,
// and no client without messaging creates a vault, a device and its key packages.
func featureRegistry(cfg config.Config) *flags.Registry {
	return flags.NewRegistry(cfg.FeatureGraph, cfg.FeaturePosts, cfg.FeatureAccountLifecycle, cfg.FeatureReplies, cfg.FeatureProfileSnapshot, cfg.FeatureMedia, cfg.FeatureNotifications, cfg.FeatureReports, cfg.FeatureEngagement, cfg.FeatureQuotes, cfg.FeatureContentDisclosure, cfg.FeatureReplyAudience, cfg.FeatureScheduledPosts, cfg.FeatureBookmarks, cfg.FeatureMessaging, cfg.FeatureLists, cfg.FeatureCommunities, cfg.FeatureProfileExtras, cfg.FeatureProfileTabs, cfg.FeatureLikesList, cfg.FeatureFollowSuggestions, cfg.FeaturePrivateAccounts, cfg.FeatureUIShell, cfg.FeatureUITablet, cfg.FeatureShells, cfg.FeatureCrashReporting, cfg.FeatureAnalytics, cfg.FeatureRemovedIDs, cfg.FeatureSearch, cfg.FeatureTrends, cfg.FeaturePolls, cfg.FeatureDrafts, cfg.FeatureGif, cfg.FeatureBeacons, cfg.FeatureNotificationPrefs, cfg.FeatureDMPolicy, cfg.FeatureReadReceipts, cfg.FeatureChatSharedPlans, cfg.FeatureBeaconQuickJoin, cfg.FeaturePostBeaconEmbed, cfg.FeatureCommunityMemberSearch, cfg.FeatureDMPostShare, cfg.FeatureDMShareCheck, cfg.FeatureShareCount, cfg.FeatureHandleSuggestions, cfg.FeatureListFollows, cfg.FeatureListSuggestions, cfg.FeatureBookmarkHistory, cfg.FeatureArticleImages, cfg.FeatureExportZip, cfg.FeatureMessageSearch, cfg.FeatureSearchLists, cfg.FeatureSearchFilters, cfg.FeatureDMSuggestions, cfg.FeaturePostViews, cfg.FeatureCreatorInsights, cfg.FeatureLocation, cfg.FeatureTrendingMedia, cfg.FeatureTrendingPosts, cfg.FeaturePublicIDs, cfg.FeatureE2EEDM, cfg.FeatureDeviceSignOut, cfg.FeatureE2EERequired).
		Require(keys.FlagName, messaging.FlagName).
		Require(messaging.E2EERequiredFlag, keys.FlagName)
}
