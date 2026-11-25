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

// reasonRequiredFailsClosed is the startup warning for e2ee_required not off while e2ee_dm is off or narrower: the users
// in that gap can exchange no DM at all (plaintext is refused, mls_init needs e2ee_dm). It is the intended fail-closed
// state, and operators must see it.
const reasonRequiredFailsClosed = "required_without_e2ee_dm"

// featureRegistry is the registry over every cfg.Feature* spec, coupled by coupleE2EE. It is a function of cfg alone so
// a test can check exactly what Build wires.
func featureRegistry(cfg config.Config) *flags.Registry {
	return coupleE2EE(flags.NewRegistry(cfg.FeatureGraph, cfg.FeaturePosts, cfg.FeatureAccountLifecycle, cfg.FeatureReplies, cfg.FeatureProfileSnapshot, cfg.FeatureMedia, cfg.FeatureNotifications, cfg.FeatureReports, cfg.FeatureEngagement, cfg.FeatureQuotes, cfg.FeatureContentDisclosure, cfg.FeatureReplyAudience, cfg.FeatureScheduledPosts, cfg.FeatureBookmarks, cfg.FeatureMessaging, cfg.FeatureLists, cfg.FeatureCommunities, cfg.FeatureProfileExtras, cfg.FeatureProfileTabs, cfg.FeatureLikesList, cfg.FeatureFollowSuggestions, cfg.FeaturePrivateAccounts, cfg.FeatureUIShell, cfg.FeatureUITablet, cfg.FeatureShells, cfg.FeatureCrashReporting, cfg.FeatureAnalytics, cfg.FeatureRemovedIDs, cfg.FeatureSearch, cfg.FeatureTrends, cfg.FeaturePolls, cfg.FeatureDrafts, cfg.FeatureGif, cfg.FeatureBeacons, cfg.FeatureNotificationPrefs, cfg.FeatureDMPolicy, cfg.FeatureReadReceipts, cfg.FeatureChatSharedPlans, cfg.FeatureBeaconQuickJoin, cfg.FeaturePostBeaconEmbed, cfg.FeatureCommunityMemberSearch, cfg.FeatureDMPostShare, cfg.FeatureDMShareCheck, cfg.FeatureShareCount, cfg.FeatureHandleSuggestions, cfg.FeatureListFollows, cfg.FeatureListSuggestions, cfg.FeatureBookmarkHistory, cfg.FeatureArticleImages, cfg.FeatureExportZip, cfg.FeatureMessageSearch, cfg.FeatureSearchLists, cfg.FeatureSearchFilters, cfg.FeatureDMSuggestions, cfg.FeaturePostViews, cfg.FeatureCreatorInsights, cfg.FeatureLocation, cfg.FeatureTrendingMedia, cfg.FeatureTrendingPosts, cfg.FeaturePublicIDs, cfg.FeatureE2EEDM, cfg.FeatureDeviceSignOut, cfg.FeatureE2EERequired))
}

// coupleE2EE is the end-to-end-encryption coupling (E2EE Plan 6 §1.3, as ruled in the 6-1 security review):
//   - effective e2ee_dm = e2ee_dm && messaging. Percent buckets are salted per flag name, so two percent ramps overlap
//     only on a fraction of users; with the coupling E2EE_DM can be on globally while MESSAGING alone ramps, and no
//     client without messaging creates a vault, a device and its key packages.
//   - effective e2ee_required = e2ee_required && messaging, and deliberately NOT && e2ee_dm. The product promise is that
//     no readable DM is stored for a required user. Killing or narrowing e2ee_dm must not reopen plaintext for them: they
//     then can exchange nothing (plaintext refused, mls_init refused by e2ee_dm), visibly, and the startup warning says
//     so. The one lever that reopens plaintext is E2EE_REQUIRED itself.
//
// Enabled (every module's gate) and EnabledFeatures (GetMe.enabled_features) report the effective values; GloballyOff
// (the kill switch K1 and RemoveKeyDevice read) keeps reading each raw flag.
func coupleE2EE(reg *flags.Registry) *flags.Registry {
	return reg.Require(keys.FlagName, messaging.FlagName).Require(messaging.E2EERequiredFlag, messaging.FlagName)
}

// featureCouplingWarnings is what Build logs as WARN lines at startup (modes only, never uids): every coupled flag that
// is not off while its parent is off or obviously narrower, every rejected requirement cycle, and e2ee_required not off
// while e2ee_dm is off or narrower (reasonRequiredFailsClosed).
func featureCouplingWarnings(reg *flags.Registry) []flags.CouplingWarning {
	out := reg.CouplingWarnings()
	if w, ok := reg.Narrower(messaging.E2EERequiredFlag, keys.FlagName); ok {
		w.Reason = reasonRequiredFailsClosed
		out = append(out, w)
	}
	return out
}
