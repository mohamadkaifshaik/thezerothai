// Package apiserver is the dzeroth monolith's composition root (ADR-0002): it wires every registered
// module's Connect handler, /health (+ /healthz alias) and /internal/* onto one *http.ServeMux with the full interceptor
// chain (ADR-0006 §2). cmd/api/main.go calls Build at startup; backend/e2e also calls it directly to boot
// the exact same handler inside an httptest.Server against the Firebase Emulator Suite.
//
// This package exists only because Go cannot import a `package main` from another package ("is a
// program, not an importable package") — extracting the wiring here is the seam that lets backend/e2e
// exercise the real handler without a second copy of it. cmd/api/main.go is left as a thin
// config-load-and-serve wrapper around Build.
package apiserver

import (
	"context"
	"fmt"
	"log/slog"
	"net/http"
	"time"

	"cloud.google.com/go/firestore"
	"connectrpc.com/connect"
	firebase "firebase.google.com/go/v4"

	engagementv1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/engagement/v1/engagementv1connect"
	graphv1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1/graphv1connect"
	identityv1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1/identityv1connect"
	mediav1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/media/v1/mediav1connect"
	moderationv1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/moderation/v1/moderationv1connect"
	notificationsv1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/notifications/v1/notificationsv1connect"
	postsv1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1/postsv1connect"
	timelinev1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/timeline/v1/timelinev1connect"
	"github.com/dzeroth/dzeroth/backend/internal/engagement"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/internal/media"
	"github.com/dzeroth/dzeroth/backend/internal/moderation"
	"github.com/dzeroth/dzeroth/backend/internal/notifications"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/internal/timeline"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/degraded"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/fsclient"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/health"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/httpcors"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/limits"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/mw"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/objstore"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/pubsubpublish"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/pubsubpush"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/quota"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ratelimit"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/snowflake"
)

// healthPaths is exempt from PreAuthIPMiddleware (M1): Cloud Run's startup/liveness probe hits /health
// (and its legacy /healthz alias) constantly and must never be throttled. Checked against the path *after*
// any Firebase Hosting `/api/**` StripPrefix (see the wrapping order below), so both routes exempt with
// just these two bare entries.
var healthPaths = map[string]struct{}{"/health": {}, "/healthz": {}}

// Build wires every module's Connect handler plus /health and /internal/* into one handler (ADR-0002: one
// process, one mux, one cold start). The caller owns closing the returned *firestore.Client (e.g. defer).
//
// The return type is http.Handler, not *http.ServeMux: Firebase Hosting forwards `/api/**` to Cloud Run
// unchanged (firebase.json), so every route below is also mounted under an `/api` prefix (B1) by wrapping
// the base mux a second time with http.StripPrefix. That doubly-mounted mux is then wrapped, outermost
// first: CORS (M10) -> PreAuthIPMiddleware (M1) -> http.MaxBytesHandler (hardening). All of these return
// http.Handler, and cmd/api/main.go / backend/e2e only ever need an http.Handler (net/http's native h2c
// support / httptest.NewServer), so nothing downstream needs ServeMux itself.
//
// Full per-request pipeline, outermost to innermost (document any change here in the PR body — it's the
// ADR-0006 §2 order plus the plain-net/http layers M1/hardening added in front of it):
//
//	CORS -> PreAuthIPMiddleware (M1: coarse per-IP flood backstop, pre-auth) -> MaxBytesHandler (hardening)
//	  -> [mux dispatch: /health | /internal/* | a module's Connect handler, each connect.WithReadMaxBytes'd]
//	    -> logging -> recover -> App Check -> ID token -> rate limit (fine-grained, per-uid/IP, post-auth)
//	       -> degraded mode -> account status -> errorMapping -> handler
//
// M1 (docs/reviews/security-audit-v0.1.0.md — distinct from ADR-0006 §2's own "Phase 0 review M1"
// amendment, coincidentally the same finding ID and date): the ADR-0006 §2 rate-limit interceptor still
// sits *after* App Check/ID token verification, so on its own it can't stop an unauthenticated flood from
// paying JWT-verify CPU. PreAuthIPMiddleware is a second, independent Limiter (never the same
// bucket/instance as the one ratelimit.Interceptor uses below) that rejects by IP before any of that
// verification work runs at all.
func Build(ctx context.Context, cfg config.Config, log *slog.Logger) (http.Handler, *firestore.Client, error) {
	return build(ctx, cfg, log, nil)
}

// build is Build with an optional ID-token verifier override. Only integration tests pass one (the Auth emulator's
// verifier checks revoked/disabled users on every call, which production does not); Build always passes nil.
func build(ctx context.Context, cfg config.Config, log *slog.Logger, idVerifierOverride authn.IDTokenVerifier) (http.Handler, *firestore.Client, error) {
	fsClient, err := fsclient.New(ctx, cfg.ProjectID)
	if err != nil {
		return nil, nil, fmt.Errorf("firestore client: %w", err)
	}

	idVerifier := idVerifierOverride
	if idVerifier == nil {
		idVerifier, err = authn.NewIDTokenVerifier(ctx, cfg.ProjectID)
		if err != nil {
			return nil, nil, fmt.Errorf("id token verifier: %w", err)
		}
	}
	appCheckVerifier, err := authn.NewAppCheckVerifier(ctx, cfg.ProjectID)
	if err != nil {
		return nil, nil, fmt.Errorf("app check verifier: %w", err)
	}

	// --- feature flags (ADR-0008 D6) ---
	featureFlags := flags.NewRegistry(cfg.FeatureGraph, cfg.FeaturePosts, cfg.FeatureAccountLifecycle, cfg.FeatureReplies, cfg.FeatureProfileSnapshot, cfg.FeatureMedia, cfg.FeatureNotifications, cfg.FeatureReports, cfg.FeatureEngagement, cfg.FeatureQuotes, cfg.FeatureContentDisclosure, cfg.FeatureReplyAudience, cfg.FeatureScheduledPosts, cfg.FeatureBookmarks, cfg.FeatureProfileExtras, cfg.FeatureProfileTabs, cfg.FeatureLikesList, cfg.FeatureFollowSuggestions, cfg.FeaturePrivateAccounts, cfg.FeatureUIShell, cfg.FeatureShells, cfg.FeatureRemovedIDs)
	log.Info("feature_flags", "flags", featureFlags.StartupLogValues())
	// ADR-0025 (W3-25b): the private-accounts limits, so an operator can see what the revision enforces. Numbers only.
	log.Info("privacy_limits", "toggles_per_day", cfg.Quota.PrivacyTogglesPerDay, "protected_authors_max", cfg.Privacy.ProtectedAuthorsMax,
		"protected_set_max_stale", cfg.Privacy.ProtectedSetMaxStale.String(), "respond_per_min", cfg.RateLimit.FollowRequestsRespondPerUserPerMinute)

	// --- modules ---
	// graph.FirestoreRepo backs both identity.GraphInitializer (creating the empty graph/{uid} doc inside
	// CreateProfile's transaction, unchanged since the Phase 0 bootstrap) and the full GraphService
	// (ADR-0008). graph depends on identity.Directory/Counters directly; identity depends on graph only
	// through the consumer-side identity.BlockChecker interface it declares itself (identity/api.go) — no
	// import cycle. graph.Service needs identity.Directory (implemented by identitySvc) and identitySvc
	// needs graph.Service as its BlockChecker: SetDirectory breaks that construction-order cycle (see
	// graph.service's doc comment) — safe because it runs once, synchronously, before ListenAndServe.
	graphRepo := graph.NewFirestoreRepo(fsClient)
	identityRepo := identity.NewFirestoreRepo(fsClient, graphRepo)
	// identityRepo implements identity.Counters (AddFollowersCount/AddFollowingCount); the increments must
	// land in the same transaction/batch as the edge change (ADR-0008 D3), hence a repo-level setter rather
	// than service.go opening its own separate write.
	graphRepo.SetCounters(identityRepo)
	graphRepo.SetProfiles(identityRepo)
	graphRepo.SetTxProfiles(identityRepo)
	identityCache := identity.NewCache(cfg.CacheTTL)
	graphCache := graph.NewCache(cfg.CacheTTL)

	// P6 (ADR-0017 D2): graph reports created follow edges through this slot; Build binds the notifications emitter
	// into it below, once identity (the fan-out's Directory) exists.
	notifSlot := &emitterSlot{}
	graphSvc := graph.New(graph.Deps{
		Events:                  followNotifier{slot: notifSlot},
		Repo:                    graphRepo,
		Cache:                   graphCache,
		Flags:                   featureFlags,
		CursorKey:               cfg.CursorHMACKey,
		ReadOnly:                cfg.Degraded == config.DegradedReadonly,
		FollowsPerDay:           int64(cfg.Quota.FollowsPerDay),
		NewAccountFollowsPerDay: int64(cfg.Quota.NewAccountFollowsPerDay),
		BlocksPerDay:            int64(cfg.Quota.BlocksPerDay),
		NewAccountBlocksPerDay:  int64(cfg.Quota.NewAccountBlocksPerDay),
		NewAccountWindow:        cfg.Quota.NewAccountWindow,
		// ADR-0024 D8, D10: the ListSuggestedUsers limits and the curated SUGGESTED_USER_IDS list (W3-12 reads them).
		Suggestions: graph.SuggestionLimits{
			SampleFollowees: cfg.Suggestions.SampleFollowees, EdgeLimit: cfg.Suggestions.EdgeLimit,
			HydrateMax: cfg.Suggestions.HydrateMax, MaxResults: cfg.Suggestions.MaxResults,
			CacheTTL: cfg.Suggestions.CacheTTL, CuratedUIDs: cfg.Suggestions.UserIDs,
		},
	})
	// The Firebase Auth admin client is built once, here, and handed only to identity (IAM control C2): the account
	// lifecycle and the M2 sign-up check (CreateProfile refuses a token whose Auth user was deleted or disabled).
	fbApp, err := firebase.NewApp(ctx, &firebase.Config{ProjectID: cfg.ProjectID})
	if err != nil {
		return nil, nil, fmt.Errorf("firebase app: %w", err)
	}
	authAdminClient, err := fbApp.Auth(ctx)
	if err != nil {
		return nil, nil, fmt.Errorf("firebase auth admin client: %w", err)
	}
	// P2: the shared jobs publisher is also the profile-snapshot-refresh trigger (lazy: no I/O until first use).
	// --- media (ADR-0005, P4): built before identity and posts, which consume its library (avatar resolution, post
	// attachment) and job publisher. The jobs publisher is lazy (no I/O before ListenAndServe) and is also the
	// account lifecycle's. The identity directory media needs is bound after identity is built.
	postsRepo := posts.NewFirestoreRepo(fsClient)
	snowflakeNode, err := snowflake.NewNode()
	if err != nil {
		return nil, nil, fmt.Errorf("snowflake node: %w", err)
	}
	jobsPublisher, err := pubsubpublish.New(cfg.ProjectID, cfg.JobsTopic)
	if err != nil {
		return nil, nil, fmt.Errorf("jobs publisher: %w", err)
	}
	lateDirectory := &lateAccountDirectory{}
	mediaMod, err := wireMedia(cfg, log, fsClient, featureFlags, lateDirectory, postsRepo, snowflakeNode, jobsPublisher, identityRepo)
	if err != nil {
		return nil, nil, err
	}
	// ADR-0024 (W3-6): the pinned-post check is posts' (bound once posts exists, below); the banner resolver is media's; the
	// profile_extras flag gates setting the new fields and omits the pin from responses while globally off.
	pinChecker := &latePinChecker{}
	// ADR-0025 (W3-26a): the one protected-set loader of this instance (lazy, singleflight, 60 s, detached reads). The
	// consumers (posts.Audience, timeline, notifications) take protectedAuthors in their own tickets; identity's toggle
	// feeds it the committing instance's own change.
	protectedAuthors := identity.NewProtectedSetLoader(identityRepo, cfg.CacheTTL, cfg.Privacy.ProtectedSetMaxStale, nil, log)
	identitySvc := identity.New(identityRepo, identityCache, cfg.HandleChangeCooldown,
		identity.WithFeatureFlags(featureFlags),
		identity.WithBlockChecker(graphSvc),
		identity.WithSignupAuth(authAdminClient, log),
		identity.WithAvatarResolver(avatarResolver{lib: mediaMod.library, flags: featureFlags}),
		identity.WithBannerResolver(bannerResolver{lib: mediaMod.library, flags: featureFlags}),
		// ADR-0024 Amendment 1 A4: a replaced or removed avatar or banner goes to media's retire step (PROFILE_MEDIA_RETIRE).
		identity.WithMediaRetirer(profileMediaRetirer{jobs: mediaMod.jobs}, log),
		identity.WithPinChecker(pinChecker),
		identity.WithExtrasFlags(featureFlags),
		identity.WithPrivacy(identity.PrivacyDeps{
			Repo: identityRepo, Set: protectedAuthors,
			Limits: identity.PrivacyLimits{TogglesPerDay: int64(cfg.Quota.PrivacyTogglesPerDay), SetMax: cfg.Privacy.ProtectedAuthorsMax},
		}),
		identity.WithProfileSnapshots(identity.ProfileSnapshotDeps{
			Publisher: jobsPublisher, Flags: featureFlags, Quota: identity.NewSnapshotQuota(fsClient),
			PerDay: int64(cfg.Quota.SnapshotEditsPerDay), Log: log,
		}),
	)
	// identitySvc's concrete type also implements identity.Directory (GetProfiles/Forget); asserted here
	// since identity.Service itself only exposes the Connect-handler-facing RPC methods.
	graphSvc.SetDirectory(identitySvc.(identity.Directory))
	lateDirectory.d = identitySvc.(identity.Directory)

	// --- notifications (P6, ADR-0017): rows + FCM push, fed by graph and posts through the emitter slot. The Firebase
	// Messaging client and the Pub/Sub publisher are created lazily on first use (no I/O before ListenAndServe).
	notifRepo := notifications.NewFirestoreRepo(fsClient).WithDirectory(identitySvc.(identity.Directory))
	var pushSender notifications.PushSender = notifications.LogSender{Log: log}
	var tokenValidator notifications.TokenValidator = notifications.NopValidator{}
	if cfg.NotificationsDelivery == "pubsub" {
		fcm := notifications.NewFCMSender(fbApp)
		pushSender, tokenValidator = fcm, fcm // one lazily created messaging client for sends and dry runs
	}
	// N-1: the per-actor recipient cap. "New account" is decided with 0 reads from actorAges, which the account-status
	// adapter fills on every authenticated request (graph Follow and post create evict the actor's cached profile just
	// before they emit, so a cache peek at emit time would always miss), falling back to a profile cache peek. An
	// unknown actor counts as established: the stricter tier is best effort, never a read.
	actorAges := newAccountAges(cfg.Quota.NewAccountWindow)
	isNewActor := func(uid string) bool {
		if isNew, known := actorAges.IsNew(uid); known {
			return isNew
		}
		p, ok := identityCache.GetProfile(uid)
		return ok && !p.CreatedAt.IsZero() && time.Since(p.CreatedAt) < cfg.Quota.NewAccountWindow
	}
	recipientCap := notifications.NewRecipientCap(cfg.RateLimit.NotificationRecipientsPerActorPerDay, cfg.RateLimit.NotificationRecipientsPerNewActorPerDay, isNewActor)
	notifFanout := notifications.NewFanout(notifications.FanoutDeps{
		Repo: notifRepo, Directory: identitySvc.(identity.Directory), Social: graphSvc, Sender: pushSender,
		Flags: featureFlags, Log: log, ProjectID: cfg.ProjectID, ReadOnly: cfg.Degraded == config.DegradedReadonly,
		Audience:  protectedAudience(protectedAuthors),
		PushLimit: notifications.NewPushLimiter(int(cfg.RateLimit.NotificationPushesPerRecipientPerHour)),
	})
	switch cfg.NotificationsDelivery {
	case "inline":
		notifSlot.em = notifications.NewInlineEmitter(notifFanout, featureFlags, log).WithRecipientCap(recipientCap)
	default:
		notifPublisher, perr := pubsubpublish.New(cfg.ProjectID, cfg.NotificationsTopic)
		if perr != nil {
			return nil, nil, fmt.Errorf("notifications publisher: %w", perr)
		}
		notifSlot.em = notifications.NewPubSubEmitter(notifPublisher, featureFlags, log).WithRecipientCap(recipientCap)
	}
	notifService := notifications.NewService(notifications.Deps{
		Repo: notifRepo, Directory: identitySvc.(identity.Directory), Social: graphSvc, Seen: identityRepo, Validator: tokenValidator, CursorKey: cfg.CursorHMACKey,
	})
	notifServer := notifications.NewServer(notifService, featureFlags)

	// posts and timeline (ADR-0010, T5): both services are registered behind FEATURE_POSTS. Their RPC bodies land
	// in T8/T9/T12/T13; until then every RPC is Unimplemented once the flag is on. timeline gets only the
	// posts.Reader and graph.Reader seams (ADR-0004 handoff: it never queries `posts` or `graph` itself).
	postsCache := posts.NewCache(cfg.CacheTTL, cfg.CachePostsEntries, cfg.CacheAuthorRecentEntries)
	postsRepo.SetWriters(posts.WriteDeps{
		Idempotency: idempotency.New(fsClient),
		Quotas:      quota.New(fsClient),
		Counters:    identityRepo,
		IDs:         snowflakeNode,
		Media:       postsMediaAttacher{lib: mediaMod.library},
		// The publish sweep reads the author's users/{uid} inside its transaction (ADR-0021 L-7): never cached.
		Profiles: identityRepo,
	})
	postsSvc := posts.New(posts.Deps{
		Repo: postsRepo, Cache: postsCache, Events: postNotifier{slot: notifSlot},
		Jobs:                  mediaMod.jobs,
		Directory:             identitySvc.(identity.Directory),
		Graph:                 graphSvc,
		PostsPerDay:           int64(cfg.Quota.PostsPerDay),
		NewAccountPostsPerDay: int64(cfg.Quota.NewAccountPostsPerDay),
		NewAccountWindow:      cfg.Quota.NewAccountWindow,
		CursorKey:             cfg.CursorHMACKey,
		// Scheduled posts (ADR-0021 D4): the repository and the limits come from config; the RPCs stay behind
		// FEATURE_SCHEDULED_POSTS (server.go), so wiring them costs nothing while the flag is off.
		Scheduled: postsRepo,
		Schedule: posts.ScheduleLimits{
			MaxPending: cfg.Scheduled.MaxPending, WindowCap: cfg.Scheduled.PerAuthorPerRun,
			MinLead: cfg.Scheduled.MinLead, Horizon: cfg.Scheduled.Horizon, TerminalTTL: cfg.Scheduled.TerminalTTL,
			SchedulesPerDay: int64(cfg.Quota.SchedulesPerDay), NewAccountSchedulesPerDay: int64(cfg.Quota.NewAccountSchedulesPerDay),
		},
		// The publish sweep (ADR-0021 CMP-D4) behind /internal/cron/publish-scheduled. Flags is the registry's kill-switch
		// view (GloballyOff), so an allowlist or percent rollout still publishes every due item.
		Sweep: posts.SweepDeps{
			Repo: postsRepo, Flags: featureFlags, ReadOnly: cfg.Degraded == config.DegradedReadonly, Log: log,
			// A sweep-published post has no authenticated request behind it, so the recipient cap would not know the author is
			// new (and the profile cache entry is evicted right after the publish): hand it the createdAt the publish read.
			RecordAuthorAge: actorAges.Record,
			Limits: posts.SweepLimits{
				PerAuthorPerRun: cfg.Scheduled.PerAuthorPerRun, AuthorReadsWarn: cfg.Scheduled.AuthorReadsWarn,
				Limit: cfg.Scheduled.SweepLimit, MaxPages: cfg.Scheduled.SweepMaxPages, Concurrency: cfg.Scheduled.SweepConcurrency,
				MaxLateness: cfg.Scheduled.MaxLateness, MaxAttempts: cfg.Scheduled.MaxAttempts, TerminalTTL: cfg.Scheduled.TerminalTTL,
			},
		},
	}, posts.WithAllowAnonymous(cfg.AuthEmulator), posts.WithProtectedAuthors(protectedAuthors))
	// ADR-0024 D3: identity's UpdateProfile asks posts whether a post is the caller's own visible pin candidate. Bound here, once,
	// before ListenAndServe (posts needs identity.Directory, so identity was built first).
	pinChecker.c = posts.NewPinChecker(postsSvc)

	// engagement (P5, ADR-0018): likes and reposts behind FEATURE_ENGAGEMENT. posts and engagement need each
	// other (engagement drives posts' counters and clean-up, DeletePost releases through engagement's reposts
	// links), so the links are bound here, once, synchronously, before ListenAndServe.
	engagementRepo := engagement.NewFirestoreRepo(fsClient, engagement.WriteDeps{
		Quotas: quota.New(fsClient), Writer: postsRepo, Counters: identityRepo, IDs: snowflakeNode,
		Idempotency: idempotency.New(fsClient), // AddBookmark / RemoveBookmark idempotency docs (ADR-0023 D4)
	})
	engagementMod, err := engagement.New(engagement.Deps{
		Repo: engagementRepo, Posts: postsSvc.(posts.Engagement), Reader: postsSvc, Directory: identitySvc.(identity.Directory),
		Events:      engagementNotifier{slot: notifSlot},
		LikesPerDay: int64(cfg.Quota.LikesPerDay), NewAccountLikesPerDay: int64(cfg.Quota.NewAccountLikesPerDay),
		PostsPerDay: int64(cfg.Quota.PostsPerDay), NewAccountPostsPerDay: int64(cfg.Quota.NewAccountPostsPerDay),
		NewAccountWindow: cfg.Quota.NewAccountWindow, CacheTTL: cfg.CacheTTL, AllowAnonymous: cfg.AuthEmulator,
		// Bookmarks (ADR-0023 D4): the repo is the engagement repo, the quota and the cap are config, not literals.
		BookmarkRepo: engagementRepo, BookmarksPerDay: int64(cfg.Quota.BookmarksPerDay),
		NewAccountBookmarksPerDay: int64(cfg.Quota.NewAccountBookmarksPerDay), BookmarksMaxPerUser: cfg.Quota.BookmarksMaxPerUser,
		// ListBookmarks (ADR-0023 D2, D6): the graph snapshot filters blocked and muted authors, the flags decide viewer-state
		// hydration, the cursor key seals the page tokens, and readonly mode skips the lazy prune.
		Graph: graphSvc, Flags: featureFlags, CursorKey: cfg.CursorHMACKey, ReadOnly: cfg.Degraded == config.DegradedReadonly,
		// W3-29b: both lists decide protected authors' rows through the one posts.Audience (ADR-0025 D4).
		Audience: rowAudience(posts.AudienceOf(postsSvc)),
	})
	if err != nil {
		return nil, nil, fmt.Errorf("engagement: %w", err)
	}
	postsRepo.SetRepostLinks(engagementMod)
	postsSvc.(interface{ SetRepostLinks(posts.RepostLinks) }).SetRepostLinks(engagementMod)
	engagementServer := engagement.NewServer(engagementMod, featureFlags, engagement.WithBookmarks(engagementMod))
	postsServer := posts.NewServer(postsSvc, featureFlags, posts.WithViewerFlags(engagementMod), posts.WithScheduler(postsSvc.(posts.Scheduler)))
	// The removal log is built only when FEATURE_REMOVED_IDS is not off: off means no instance cache, no reads and
	// no reset of cached client feeds (timeline treats a nil Removals as "no removed_ids"). Allowlist and percent
	// modes are enforced per caller in timeline.removedIDs.
	var removals posts.Removals
	if cfg.FeatureRemovedIDs.Mode != flags.Off {
		removals = posts.NewRemovalLog(postsRepo, cfg.CacheTTL, nil)
	}
	timelineServer := timeline.NewServer(timeline.Deps{
		Flags: featureFlags, Posts: postsSvc, Graph: graphSvc, Directory: identitySvc.(identity.Directory), Viewer: engagementMod,
		Removals:  removals,
		CursorKey: cfg.CursorHMACKey, TokenTTL: cfg.TimelineTokenTTL, SettleWindow: cfg.TimelineSettleWindow,
	}, timeline.WithProtectedAuthors(protectedAuthors)) // ADR-0025 D4 (W3-30)

	// --- account lifecycle (ADR-0011, P8): DeleteAccount / RequestAccountExport / GetAccountExport and the job
	// handlers. The Firebase Auth admin client (built above) is handed only to identity (IAM control C2); the
	// publisher and the exports bucket client are lazy, so nothing here does I/O before ListenAndServe.
	exportStore, err := objstore.New(cfg.ExportBucket)
	if err != nil {
		return nil, nil, fmt.Errorf("export store: %w", err)
	}
	lifecycle, err := identity.NewLifecycle(identity.LifecycleDeps{
		Repo: identityRepo, Cache: identityCache, Publisher: jobsPublisher, Auth: authAdminClient, Objects: exportStore,
		Log: log, ProjectID: cfg.ProjectID, ExportsPerDay: int64(cfg.Quota.ExportsPerDay),
		ExportRetention: cfg.ExportRetention, ExportURLTTL: cfg.ExportURLTTL,
		Snapshots: profileSnapshotWriter{postsRepo}, Flags: featureFlags,
	})
	if err != nil {
		return nil, nil, fmt.Errorf("account lifecycle: %w", err)
	}
	if err := registerLifecycleModules(lifecycle, postsRepo, graphRepo, mediaMod.purger, notifRepo); err != nil {
		return nil, nil, fmt.Errorf("account lifecycle registry: %w", err)
	}
	if err := registerEngagementLifecycle(lifecycle, engagementRepo); err != nil {
		return nil, nil, fmt.Errorf("engagement lifecycle registry: %w", err)
	}
	// moderation (ADR-0016, P7): ReportContent behind FEATURE_REPORTS. It reuses posts.GetForViewer and
	// identity.GetProfile for target visibility and writes only reports/* and the reports quota.
	moderationRepo := moderation.NewFirestoreRepo(fsClient, quota.New(fsClient))
	if err := registerModerationLifecycle(lifecycle, moderationRepo); err != nil {
		return nil, nil, fmt.Errorf("moderation lifecycle registry: %w", err)
	}
	// scheduled posts (ADR-0021 D4): the erase step and export section are registered whether or not
	// FEATURE_SCHEDULED_POSTS is on, because documents outlive the flag; the step runs after reports, before identity.
	if err := registerScheduledLifecycle(lifecycle, postsRepo); err != nil {
		return nil, nil, fmt.Errorf("scheduled lifecycle registry: %w", err)
	}
	// bookmarks (ADR-0023 D6, D8): the erase step and export section are registered whether or not FEATURE_BOOKMARKS is
	// on; the step runs after scheduled, before identity.
	if err := registerBookmarkLifecycle(lifecycle, engagementRepo); err != nil {
		return nil, nil, fmt.Errorf("bookmarks lifecycle registry: %w", err)
	}
	// follow_requests (ADR-0025 D11): the erase step and export section are registered whether or not
	// FEATURE_PRIVATE_ACCOUNTS is on; the step runs after bookmarks, before identity.
	if err := registerFollowRequestsLifecycle(lifecycle, graphRepo); err != nil {
		return nil, nil, fmt.Errorf("follow_requests lifecycle registry: %w", err)
	}
	moderationSvc := moderation.New(moderation.Deps{
		Repo: moderationRepo, Posts: postsSvc, Accounts: identitySvc, Directory: lateDirectory.d,
		ReportsPerDay:           int64(cfg.Quota.ReportsPerDay),
		NewAccountReportsPerDay: int64(cfg.Quota.NewAccountReportsPerDay),
		NewAccountWindow:        cfg.Quota.NewAccountWindow,
		AllowAnonymous:          cfg.AuthEmulator,
	})
	moderationServer := moderation.NewServer(moderationSvc, featureFlags)
	// post_delete (P4 media, P5 engagement; ADR-0018 D10): one message, one composite handler.
	postDeleteJob := postDeleteChain{
		media: mediaMod.jobs,
		eng:   engagement.NewJobs(engagementRepo, postsRepo, postGone{postsRepo}, jobsPublisher),
		pins:  identity.NewPinJobs(identityRepo, postGone{postsRepo}, identitySvc.(identity.Directory).Forget),
	}
	if err := lifecycle.RegisterJobHandler(media.JobKindPostDelete, postDeleteJob); err != nil {
		return nil, nil, fmt.Errorf("post_delete job handler: %w", err)
	}
	// profile_media_retired (ADR-0024 Amendment 1 A4): the media step that schedules a replaced or removed avatar or
	// banner for deletion. Registered whatever PROFILE_MEDIA_RETIRE says: with the switch off the handler acks without
	// action, so a message published by a revision that had it on is never left in a retry loop.
	if err := lifecycle.RegisterJobHandler(media.JobKindProfileMediaRetired, mediaMod.jobs.RetireHandler()); err != nil {
		return nil, nil, fmt.Errorf("profile_media_retired job handler: %w", err)
	}
	identityServer := identity.NewServer(identitySvc,
		identity.WithAllowAnonymous(cfg.AuthEmulator), identity.WithFlagChecker(featureFlags),
		identity.WithLifecycle(lifecycle), identity.WithReauthMaxAge(cfg.AccountDeleteReauthMaxAge))
	graphServer := graph.NewServer(graphSvc)

	// search and admin are not implemented yet; their Connect servers are not registered.

	// --- interceptors (ADR-0006 §2 order) ---
	accountStatusProvider := accountStatusAdapter{svc: identitySvc, peek: identityCache.GetProfile, ages: actorAges}
	profileExempt := profileExemptProcedures()

	// M1: rate limit (and degraded mode, also a free in-memory check) now run *before* account status.
	// Previously account status ran first, so a caller who never completes sign-up (no users/{uid}) could
	// call any non-exempt RPC as many times as it wanted — each rejected with PROFILE_REQUIRED — without
	// ever tripping the per-uid/per-IP limiter, because AccountStatusInterceptor returned before
	// ratelimit.Interceptor got a chance to run at all. Moving the free checks first means every call is
	// rate-limited regardless of how it's ultimately rejected, and identity.Cache's ~10s negative "no
	// profile" cache (service.go getProfileCached) keeps the *cost* of the calls that do get through low.
	// N5: logging now runs *before* (outside) recover, not after, so a panicking request still gets its one
	// log line and trace field instead of the panic unwinding past Logging's post-call code entirely.
	// See pkg/platform/mw's package doc comment for the exact final order and the M3 fallback-reporting
	// rationale.
	interceptors := connect.WithInterceptors(
		mw.Logging(log, cfg.ProjectID),
		mw.Recover(log),
		authn.AppCheckInterceptor(appCheckVerifier, authn.Mode(cfg.AppCheck)),
		authn.IDTokenInterceptor(idVerifier),
		// ADR-0010 D5 A2/A10: 0-read verified-identity gate (sign-in provider allowlist). Callers outside it never
		// reach the rate limiter, so a minted uid creates no limiter key and no Firestore read. Anonymous passes
		// only against the Auth emulator.
		authn.VerifiedIdentityInterceptor(profileExempt, cfg.AuthEmulator),
		ratelimit.Interceptor(RateLimitConfig(cfg)),
		degraded.Interceptor(cfg.Degraded, mediaProcedures()),
		authn.AccountStatusInterceptor(accountStatusProvider, profileExempt, authn.AllowRestricted(RestrictedAllowedProcedures()...)),
		mw.ErrorMapping(log),
	)

	// M8: outside ENV=local, config.Load already refuses to start unless both InternalOIDCAudience and
	// InternalOIDCAllowedEmails are set (fail closed), so /internal/* is only ever unauthenticated here
	// when cfg.Env == "local" — where no real Pub/Sub push subscription exists yet to forge a call from.
	protectInternal := func(h http.Handler) http.Handler { return h }
	if cfg.InternalOIDCAudience != "" {
		protectInternal = pubsubpush.NewVerifier(cfg.InternalOIDCAudience, cfg.InternalOIDCAllowedEmails...).Middleware
	}

	// Every route goes through the route table (routes.go): Connect services always get the interceptor chain above,
	// /internal/* always gets protectInternal, and only the patterns in publicRoutes are served without auth.
	routes := newRouteTable(interceptors, protectInternal)
	// /health is the canonical path: Cloud Run's Google front end reserves URL paths ending in "z" on
	// *.run.app, so external requests to /healthz never reach the container. /healthz stays as an alias.
	routes.public("/health", http.HandlerFunc(health.Handler()))
	routes.public("/healthz", http.HandlerFunc(health.Handler()))

	// Hardening (2026-09-27 security audit, informational finding): connect.WithReadMaxBytes caps the
	// *decompressed* body size at the Connect codec layer (a gzip-bomb guard — see limits.MaxRequestBytes's
	// doc comment); http.MaxBytesHandler below caps the raw bytes read off the socket before that.
	routes.connect(func(o ...connect.HandlerOption) (string, http.Handler) {
		return identityv1connect.NewIdentityServiceHandler(identityServer, o...)
	})

	routes.connect(func(o ...connect.HandlerOption) (string, http.Handler) {
		return graphv1connect.NewGraphServiceHandler(graphServer, o...)
	})

	routes.connect(func(o ...connect.HandlerOption) (string, http.Handler) {
		return postsv1connect.NewPostServiceHandler(postsServer, o...)
	})

	routes.connect(func(o ...connect.HandlerOption) (string, http.Handler) {
		return timelinev1connect.NewTimelineServiceHandler(timelineServer, o...)
	})

	routes.connect(func(o ...connect.HandlerOption) (string, http.Handler) {
		return engagementv1connect.NewEngagementServiceHandler(engagementServer, o...)
	})

	routes.connect(func(o ...connect.HandlerOption) (string, http.Handler) {
		return moderationv1connect.NewModerationServiceHandler(moderationServer, o...)
	})
	routes.connect(func(o ...connect.HandlerOption) (string, http.Handler) {
		return notificationsv1connect.NewNotificationServiceHandler(notifServer, o...)
	})
	routes.connect(func(o ...connect.HandlerOption) (string, http.Handler) {
		return mediav1connect.NewMediaServiceHandler(mediaMod.server, o...)
	})

	routes.internal("/internal/", pubsubpush.PlaceholderHandler())
	// ADR-0011: the shared jobs topic's push endpoint and the daily-maintenance backstop. Never behind the
	// account_lifecycle flag or DEGRADED_MODE (Q8, Q9): an accepted deletion must finish.
	routes.internal("/internal/pubsub/jobs", lifecycle.JobsHandler())
	routes.internal("/internal/cron/daily-maintenance", lifecycle.CronHandler())
	// ADR-0021 D1: the scheduled-post publish sweep (Cloud Scheduler every 5 min, prod). POST only, 25 s deadline, its own
	// budget counter and panic recovery. The kill switch (FEATURE_SCHEDULED_POSTS / FEATURE_POSTS globally off) and
	// DEGRADED_MODE=readonly are checked inside the sweep, which then answers 204 with 0 reads.
	routes.internal("/internal/cron/publish-scheduled", posts.NewSweepHandler(postsSvc.(posts.Sweeper), log, cfg.ProjectID))
	// ADR-0017 D3: the notifications-fanout push endpoint. Behind the OIDC verifier like every /internal/* route; the
	// FEATURE_NOTIFICATIONS flag and DEGRADED_MODE=readonly are checked per event inside the handler, which then
	// acknowledges and drops (never a 5xx, so a switched-off feature cannot fill the DLQ).
	routes.internal("/internal/pubsub/notifications-fanout", notifFanout.Handler())

	// M1 (docs/reviews/security-audit-v0.1.0.md): a coarse, pre-auth per-IP token bucket wraps the whole mux — /health,
	// /internal/* and every module's Connect handler — as plain net/http middleware, so an unauthenticated
	// flood is rejected before it costs any App Check / ID token JWT-verify CPU (that verification happens
	// only once a request reaches a Connect handler's own interceptor chain inside mux, below this layer).
	// This is a *different* Limiter instance from the one ratelimit.Interceptor uses above (rlIP): a
	// request is never double-charged against the same bucket for the two layers.
	//
	// Hardening: http.MaxBytesHandler caps the raw request-body bytes read off the socket (before any
	// decompression) for every route on mux, using the same limits.MaxRequestBytes as
	// connect.WithReadMaxBytes above.
	//
	// Both wrap mux itself, *before* it is mounted twice below — so exemptPaths (healthPaths) and every
	// route see the same normalized path regardless of whether the request arrived at "/health" directly or
	// "/api/health" via Firebase Hosting's rewrite (http.StripPrefix runs first on that path, then this
	// same wrapped handler runs against the already-stripped "/health").
	preAuthIPLimiter := ratelimit.NewLimiter(cfg.RateLimit.PreAuthIPPerMinute, idleBucketTTL)
	protectedMux := ratelimit.PreAuthIPMiddleware(preAuthIPLimiter, cfg.TrustedProxyHops, healthPaths)(
		http.MaxBytesHandler(routes.mux, limits.MaxRequestBytes),
	)

	// B1: Firebase Hosting's `/api/**` rewrite (firebase.json) forwards the path unchanged, so every route
	// above must also answer under that prefix: apiRoot (routes.go) mounts the same protected mux at "/" and,
	// through http.StripPrefix, at "/api/", so this stays correct as new modules are added.
	// M10: CORS is off unless cfg.CORSAllowedOrigins is non-empty (local dev by default, or an explicit
	// CORS_ALLOWED_ORIGINS elsewhere) — see pkg/platform/httpcors's doc comment.
	return httpcors.Wrap(cfg.CORSAllowedOrigins, apiRoot(protectedMux)), fsClient, nil
}

// accountStatusAdapter adapts identity.Service to authn.AccountStatusProvider without either package
// importing the other's concrete types (ADR-0002: modules/platform depend on interfaces only).
type accountStatusAdapter struct {
	svc identity.Service
	// peek and ages (both optional) record the caller's createdAt after the status lookup has cached the profile:
	// a 0-read cache peek that lets the notifications recipient cap tell a new account at emit time.
	peek func(uid string) (identity.Profile, bool)
	ages *accountAges
}

func (a accountStatusAdapter) AccountStatus(ctx context.Context, uid string) (bool, authn.AccountStatus, error) {
	exists, status, err := a.svc.AccountStatus(ctx, uid)
	if err != nil {
		return false, authn.AccountStatusUnknown, err
	}
	if exists && a.ages != nil && a.peek != nil {
		if p, ok := a.peek(uid); ok {
			a.ages.Record(uid, p.CreatedAt)
		}
	}
	switch status {
	case identity.AccountStatusActive:
		return exists, authn.AccountStatusActive, nil
	case identity.AccountStatusSuspended:
		return exists, authn.AccountStatusSuspended, nil
	case identity.AccountStatusDeleting:
		return exists, authn.AccountStatusDeleting, nil
	default:
		return exists, authn.AccountStatusUnknown, nil
	}
}

// rowAudience adapts the posts Audience to engagement.Deps.Audience. A nil Audience (a posts service that is not the
// concrete one) must stay a nil interface, not a typed nil, so the lists skip the protected decision.
func rowAudience(a *posts.Audience) engagement.RowAudience {
	if a == nil {
		return nil
	}
	return a
}
