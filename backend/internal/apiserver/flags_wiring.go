// flags_wiring.go builds the feature-flag registry Build hands to every module: one line per FEATURE_* spec config.Load
// parsed. A spec left out here is loaded, listed in the promotion ceiling and still off for everyone, which is why
// flags_wiring_test.go pins the newest entries.
package apiserver

import (
	"log/slog"

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

// reasonMessagingWithoutRequired is the startup warning for messaging reaching users e2ee_required does not cover: their
// DMs can be stored readable, which breaks the promise the required cohort is built for.
const reasonMessagingWithoutRequired = "messaging_without_required"

// featureCouplingWarnings is what Build logs at startup as feature_flag_coupling lines (flag names, modes, a reason and
// an uncovered count; never a uid), in this order: every coupled flag whose parent does not cover it, every rejected
// requirement cycle and unknown parent (flags.Registry.CouplingWarnings); e2ee_required reaching users e2ee_dm does not
// (reasonRequiredFailsClosed); messaging reaching users e2ee_required does not (reasonMessagingWithoutRequired). Each
// uses flags.Registry.Narrower: by mode, and by the count of allowlist entries the other flag's own spec does not
// enable. couplingLevel picks the level.
func featureCouplingWarnings(reg *flags.Registry) []flags.CouplingWarning {
	out := reg.CouplingWarnings()
	for _, pair := range []struct{ flag, by, reason string }{
		{messaging.E2EERequiredFlag, keys.FlagName, reasonRequiredFailsClosed},
		{messaging.FlagName, messaging.E2EERequiredFlag, reasonMessagingWithoutRequired},
	} {
		if w, ok := reg.Narrower(pair.flag, pair.by); ok {
			w.Reason = pair.reason
			out = append(out, w)
		}
	}
	return out
}

// couplingLevel is a feature_flag_coupling line's level: INFO for a parent_narrower finding under messaging with nothing
// uncovered (e2ee_dm or e2ee_required on while MESSAGING alone ramps: the planned rollout, which must not WARN on every
// start); WARN for everything else (required_without_e2ee_dm, messaging_without_required, a cycle, an unknown parent, a
// parent other than messaging, and any uncovered count above 0). One event name, so an alert keys on level and reason.
func couplingLevel(w flags.CouplingWarning) slog.Level {
	if w.Reason == flags.ReasonParentNarrower && w.Parent == messaging.FlagName && w.Uncovered == 0 {
		return slog.LevelInfo
	}
	return slog.LevelWarn
}
