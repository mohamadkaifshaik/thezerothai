// Package apiserver is the dzeroth monolith's composition root: it wires every registered
// module's Connect handler, /health (+ /healthz alias) and /internal/* onto one *http.ServeMux with the full interceptor
// chain. cmd/api/main.go calls Build at startup; backend/e2e also calls it directly to boot
// the exact same handler inside an httptest.Server against the Firebase Emulator Suite.
//
// This package exists only because Go cannot import a `package main` from another package ("is a
// program, not an importable package") — extracting the wiring here is the seam that lets backend/e2e
// exercise the real handler without a second copy of it. cmd/api/main.go is left as a thin
// config-load-and-serve wrapper around Build.
package apiserver

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"time"

	"cloud.google.com/go/firestore"
	"connectrpc.com/connect"
	firebase "firebase.google.com/go/v4"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/articles/v1/articlesv1connect"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/billing/v1/billingv1connect"
	"github.com/dzeroth/dzeroth/backend/internal/articles"
	"github.com/dzeroth/dzeroth/backend/internal/beacons"
	"github.com/dzeroth/dzeroth/backend/internal/billing"

	beaconsv1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/beacons/v1/beaconsv1connect"
	communitiesv1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/communities/v1/communitiesv1connect"
	engagementv1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/engagement/v1/engagementv1connect"
	graphv1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1/graphv1connect"
	identityv1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1/identityv1connect"
	listsv1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/lists/v1/listsv1connect"
	mediav1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/media/v1/mediav1connect"
	messagingv1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1/messagingv1connect"
	moderationv1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/moderation/v1/moderationv1connect"
	notificationsv1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/notifications/v1/notificationsv1connect"
	postsv1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1/postsv1connect"
	searchv1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/search/v1/searchv1connect"
	timelinev1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/timeline/v1/timelinev1connect"
	"github.com/dzeroth/dzeroth/backend/internal/communities"
	"github.com/dzeroth/dzeroth/backend/internal/engagement"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/internal/lists"
	"github.com/dzeroth/dzeroth/backend/internal/media"
	"github.com/dzeroth/dzeroth/backend/internal/messaging"
	"github.com/dzeroth/dzeroth/backend/internal/moderation"
	"github.com/dzeroth/dzeroth/backend/internal/notifications"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/internal/search"
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
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
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

// Build wires every module's Connect handler plus /health and /internal/* into one handler (one process, one mux, one cold start).
// The caller owns closing the returned *firestore.Client (e.g. defer).
//
// The return type is http.Handler, not *http.ServeMux: Firebase Hosting forwards `/api/**` to Cloud Run
// unchanged (firebase.json), so every route below is also mounted under an `/api` prefix (B1) by wrapping
// the base mux a second time with http.StripPrefix. That doubly-mounted mux is then wrapped, outermost
// first: CORS (M10) -> PreAuthIPMiddleware (M1) -> http.MaxBytesHandler (hardening). All of these return
// http.Handler, and cmd/api/main.go / backend/e2e only ever need an http.Handler (net/http's native h2c
// support / httptest.NewServer), so nothing downstream needs ServeMux itself.
//
// Full per-request pipeline, outermost to innermost (document any change here in the PR body — it's the
// order plus the plain-net/http layers M1/hardening added in front of it):
//
//	CORS -> PreAuthIPMiddleware (M1: coarse per-IP flood backstop, pre-auth) -> MaxBytesHandler (hardening)
//	  -> [mux dispatch: /health | /internal/* | a module's Connect handler, each connect.WithReadMaxBytes'd]
//	    -> logging -> recover -> App Check -> ID token -> rate limit (fine-grained, per-uid/IP, post-auth)
//	       -> degraded mode -> account status -> errorMapping -> handler
//
// M1 of the v0.1.0 security audit — distinct from the earlier "Phase 0 review M1"
// amendment, coincidentally the same finding ID and date): the rate-limit interceptor still
// sits *after* App Check/ID token verification, so on its own it can't stop an unauthenticated flood from
// paying JWT-verify CPU. PreAuthIPMiddleware is a second, independent Limiter (never the same
// bucket/instance as the one ratelimit.Interceptor uses below) that rejects by IP before any of that
// verification work runs at all.
func Build(ctx context.Context, cfg config.Config, log *slog.Logger) (http.Handler, *firestore.Client, error) {
	return build(ctx, cfg, log, nil)
}

// build is Build with an optional ID-token verifier override. Only integration tests pass one (the Auth emulator's
// verifier checks revoked/disabled users on every call, which production does not); Build always passes nil.
func build(ctx context.Context, cfg config.Config, log *slog.Logger, idVerifierOverride authn.IDTokenVerifier, opts ...buildOption) (http.Handler, *firestore.Client, error) {
	var bo buildOpts
	for _, o := range opts {
		o(&bo)
	}
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

	// --- feature flags ---
	featureFlags := featureRegistry(cfg)
	log.Info("feature_flags", "flags", featureFlags.StartupLogValues())
	// The private-accounts limits, so an operator can see what the revision enforces. Numbers only.
	log.Info("privacy_limits", "protected_authors_max", cfg.Privacy.ProtectedAuthorsMax,
		"protected_set_max_stale", cfg.Privacy.ProtectedSetMaxStale.String(), "respond_per_min", cfg.RateLimit.FollowRequestsRespondPerUserPerMinute)
	// The community limits, so an operator can see what the revision enforces. Numbers only: the creators are a count,
	// never the uids.
	log.Info("community_limits", "creators", len(cfg.Communities.Creators), "max_owned", cfg.Communities.MaxOwned, "max_joined", cfg.Communities.MaxJoined,
		"max_moderators", cfg.Communities.MaxModerators)

	// --- modules ---
	// graph.FirestoreRepo backs both identity.GraphInitializer (creating the empty graph/{uid} doc inside
	// CreateProfile's transaction, unchanged since the Phase 0 bootstrap) and the full GraphService.
	// Graph depends on identity.Directory/Counters directly; identity depends on graph only
	// through the consumer-side identity.BlockChecker interface it declares itself (identity/api.go) — no
	// import cycle. graph.Service needs identity.Directory (implemented by identitySvc) and identitySvc
	// needs graph.Service as its BlockChecker: SetDirectory breaks that construction-order cycle (see
	// graph.service's doc comment) — safe because it runs once, synchronously, before ListenAndServe.
	graphRepo := graph.NewFirestoreRepo(fsClient)
	identityRepo := identity.NewFirestoreRepo(fsClient, graphRepo)
	// identityRepo implements identity.Counters (AddFollowersCount/AddFollowingCount); the increments must
	// land in the same transaction/batch as the edge change, hence a repo-level setter rather
	// than service.go opening its own separate write.
	graphRepo.SetCounters(identityRepo)
	graphRepo.SetProfiles(identityRepo)
	graphRepo.SetTxProfiles(identityRepo)
	// The one protected-set loader of this instance (lazy, singleflight, 60 s, detached reads). It is built
	// before graph so ListFollowers and ListFollowing decide PROTECTED_ACCOUNT through it; posts, timeline and
	// notifications take it below, and identity's toggle feeds it the committing instance's own change.
	protectedAuthors := identity.NewProtectedSetLoader(identityRepo, cfg.CacheTTL, cfg.Privacy.ProtectedSetMaxStale, nil, log)
	identityCache := identity.NewCache(cfg.CacheTTL)
	graphCache := graph.NewCache(cfg.CacheTTL)

	// Graph reports created follow edges through this slot; Build binds the notifications emitter
	// into it below, once identity (the fan-out's Directory) exists.
	notifSlot := &emitterSlot{}
	graphSvc := graph.New(graph.Deps{
		Events:    followNotifier{slot: notifSlot},
		Repo:      graphRepo,
		Cache:     graphCache,
		Flags:     featureFlags,
		CursorKey: cfg.CursorHMACKey,
		Protected: protectedAuthors,
		ReadOnly:  cfg.Degraded == config.DegradedReadonly,
		// The ListSuggestedUsers limits and the curated SUGGESTED_USER_IDS list (reads them).
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
	// The shared jobs publisher is also the profile-snapshot-refresh trigger (lazy: no I/O until first use).
	// --- media: built before identity and posts, which consume its library (avatar resolution, post
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
	// The pinned-post check is posts' (bound once posts exists, below); the
	// profile_extras flag gates setting the new fields and omits the pin from responses while globally off.
	pinChecker := &latePinChecker{}
	// Messaging counts the unread conversations (identity never imports messaging); its repo is built here
	// because identity needs the counter at construction and the messaging service needs identity.Directory.
	messagingRepo := messaging.NewFirestoreRepo(fsClient, quota.New(fsClient))
	// Notifications counts GetMe's unread badge the same way (identity never imports notifications): the repo is built
	// here, before identity, and gets its Directory once identity exists (below).
	notifRepo := notifications.NewFirestoreRepo(fsClient).WithLogger(log)
	identitySvc := identity.New(identityRepo, identityCache, cfg.HandleChangeCooldown,
		identity.WithFeatureFlags(featureFlags),
		identity.WithBlockChecker(graphSvc),
		identity.WithProtectedAuthors(protectedAuthors, log), identity.WithFollowRequestCounter(graphSvc, log), // The pin rule and the GetMe badge
		identity.WithSignupAuth(authAdminClient, log),
		// Warn-only sign-in identity audit in GetMe (AUTH_IDENTITY_AUDIT, default off).
		identity.WithAuthIdentityAudit(cfg.AuthIdentityAudit, log),
		identity.WithAvatarResolver(avatarResolver{lib: mediaMod.library, flags: featureFlags}),
		// A replaced or removed avatar goes to media's retire step (PROFILE_MEDIA_RETIRE).
		identity.WithMediaRetirer(profileMediaRetirer{jobs: mediaMod.jobs}, log),
		identity.WithPinChecker(pinChecker),
		identity.WithMessageBadge(messaging.NewUnreadBadge(messagingRepo), log), // GetMe.unread_conversation_count
		// GetMe.unread_notification_count: the unseen rows the caller would see (block, mute, blocked-by and the F-04
		// overflow lookup applied), not the raw count().
		identity.WithNotificationBadge(notifications.NewUnreadBadge(notifRepo, graphSvc, graphSvc), log),
		identity.WithExtrasFlags(featureFlags),
		// An unprotect publishes the privacy_public job (graph accepts the pending requests).
		identity.WithPrivacyListener(graph.NewPrivacyListener(jobsPublisher), log),
		identity.WithPrivacy(identity.PrivacyDeps{
			Repo: identityRepo, Set: protectedAuthors,
			Limits: identity.PrivacyLimits{SetMax: cfg.Privacy.ProtectedAuthorsMax},
		}),
		identity.WithProfileSnapshots(identity.ProfileSnapshotDeps{
			Publisher: jobsPublisher, Flags: featureFlags, Log: log,
		}),
	)
	// identitySvc's concrete type also implements identity.Directory (GetProfiles/Forget); asserted here
	// since identity.Service itself only exposes the Connect-handler-facing RPC methods.
	graphSvc.SetDirectory(identitySvc.(identity.Directory))
	lateDirectory.d = identitySvc.(identity.Directory)

	// --- notifications: rows + FCM push, fed by graph and posts through the emitter slot. The Firebase
	// Messaging client and the Pub/Sub publisher are created lazily on first use (no I/O before ListenAndServe).
	notifRepo.WithDirectory(identitySvc.(identity.Directory))
	var pushSender notifications.PushSender = notifications.LogSender{Log: log}
	var tokenValidator notifications.TokenValidator = notifications.NopValidator{}
	if cfg.NotificationsDelivery == "pubsub" {
		fcm := notifications.NewFCMSender(fbApp)
		pushSender, tokenValidator = fcm, fcm // one lazily created messaging client for sends and dry runs
	}
	// N-1: the per-actor recipient cap. "New account" is decided from actorAges without a read, which the account-status
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
	notifAudience := protectedAudience(protectedAuthors)
	// F6: push preferences (users/{uid}/settings/notifications), read by the fan-out through a 60 s instance cache and by
	// Get/UpdateNotificationPrefs. Inert until FEATURE_NOTIFICATION_PREFS is on for a caller.
	notifPrefs := notifications.NewPrefsStore(notifRepo, identitySvc.(identity.Directory))
	notifFanout := notifications.NewFanout(notifications.FanoutDeps{
		Repo: notifRepo, Directory: identitySvc.(identity.Directory), Social: graphSvc, Sender: pushSender,
		Flags: featureFlags, Log: log, ProjectID: cfg.ProjectID, ReadOnly: cfg.Degraded == config.DegradedReadonly,
		Audience:  notifAudience,
		Prefs:     notifPrefs,
		PushLimit: notifications.NewPushLimiter(int(cfg.RateLimit.NotificationPushesPerRecipientPerHour)),
		// The push-only message type has its own bucket (MESSAGES_PUSHES_PER_RECIPIENT_PER_HOUR, 20).
		MessagePushLimit: notifications.NewPushLimiter(cfg.Messaging.PushesPerRecipientPerHour),
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
		Blocks: graphSvc, // F-04: read-time blocked-by check for a caller whose blockedBy overflowed
	})
	notifServer := notifications.NewServer(notifService, featureFlags, notifications.WithPrefs(notifPrefs))

	// posts and timeline: both services are registered behind FEATURE_POSTS. Their RPC bodies land later;
	// until then every RPC is Unimplemented once the flag is on. timeline gets only the
	// posts.Reader and graph.Reader seams (it never queries `posts` or `graph` itself).
	postsCache := posts.NewCache(cfg.CacheTTL, cfg.CachePostsEntries, cfg.CacheAuthorRecentEntries)
	postsRepo.SetWriters(posts.WriteDeps{
		Idempotency: idempotency.New(fsClient),
		Quotas:      quota.New(fsClient),
		Counters:    identityRepo,
		IDs:         snowflakeNode,
		Media:       postsMediaAttacher{lib: mediaMod.library},
		// The publish sweep reads the author's users/{uid} inside its transaction: never cached.
		Profiles: identityRepo,
	})
	// Beacons: the repo is built here because the outbox's beacon_cancelled handler (below) and the account-lifecycle
	// registration need it (the eraser step and export section are registered whether or not FEATURE_BEACONS is on);
	// the service and routes are wired below.
	beaconsRepo := beacons.NewFirestoreRepo(fsClient, quota.New(fsClient), idempotency.New(fsClient))
	// The durable outbox: DeletePost stages its post_delete item in the delete batch, CancelBeacon its beacon_cancelled
	// item in the cancel transaction; the sweep re-runs leftovers (the cancel notices through the real notifier, never
	// the test seam inlineBeaconEvents).
	beaconCancelHandler := beacons.NewCancelOutboxHandler(beaconsRepo, beaconNotifier{slot: notifSlot}, cfg.Beacons.MaxOpenSpots)
	ob, err := newOutbox(fsClient, mediaMod.jobs, beaconCancelHandler, log, bo.outboxNow)
	if err != nil {
		return nil, nil, err
	}
	var inlinePostDeleteJobs posts.PostDeleteJobs = mediaMod.jobs
	if bo.inlinePostDeleteJobs != nil {
		inlinePostDeleteJobs = bo.inlinePostDeleteJobs(inlinePostDeleteJobs)
	}
	var subscriptionPostLimit func(context.Context, string) (int, error)
	postsSvc := posts.New(posts.Deps{
		PostTextLimit: func(ctx context.Context, uid string) (int, error) {
			if subscriptionPostLimit == nil {
				return 280, nil
			}
			return subscriptionPostLimit(ctx, uid)
		},
		Repo: postsRepo, Cache: postsCache, Events: postNotifier{slot: notifSlot},
		Jobs:      inlinePostDeleteJobs,
		Outbox:    ob,
		Directory: identitySvc.(identity.Directory),
		Graph:     graphSvc,
		CursorKey: cfg.CursorHMACKey,
		// Poll creation limits (config.Composer). The zero value would reject every poll.
		Poll: posts.PollLimits{
			MaxChoices: cfg.Composer.PollMaxChoices, ChoiceMaxCodepoints: cfg.Composer.PollChoiceMaxCodepoints,
			MinDuration: cfg.Composer.PollMinDuration, MaxDuration: cfg.Composer.PollMaxDuration,
		},
		// Scheduled posts: the repository and the limits come from config; the RPCs stay behind
		// FEATURE_SCHEDULED_POSTS (server.go), so wiring them costs nothing while the flag is off.
		Scheduled: postsRepo,
		Schedule: posts.ScheduleLimits{
			MaxPending: cfg.Scheduled.MaxPending, WindowCap: cfg.Scheduled.PerAuthorPerRun,
			MinLead: cfg.Scheduled.MinLead, Horizon: cfg.Scheduled.Horizon, TerminalTTL: cfg.Scheduled.TerminalTTL,
		},
		// The publish sweep behind /internal/cron/publish-scheduled. Flags is the registry's kill-switch
		// view (GloballyOff), so an allowlist or percent rollout still publishes every due item.
		Sweep: posts.SweepDeps{
			Repo: postsRepo, Flags: featureFlags, ReadOnly: cfg.Degraded == config.DegradedReadonly, Log: log,
			// A sweep-published post has no authenticated request behind it, so the recipient cap would not know the author is
			// new (and the profile cache entry is evicted right after the publish): hand it the createdAt the publish read.
			RecordAuthorAge: actorAges.Record,
			Limits: posts.SweepLimits{
				PerAuthorPerRun: cfg.Scheduled.PerAuthorPerRun,
				Limit:           cfg.Scheduled.SweepLimit, MaxPages: cfg.Scheduled.SweepMaxPages, Concurrency: cfg.Scheduled.SweepConcurrency,
				MaxLateness: cfg.Scheduled.MaxLateness, MaxAttempts: cfg.Scheduled.MaxAttempts, TerminalTTL: cfg.Scheduled.TerminalTTL,
			},
		},
	}, posts.WithAllowAnonymous(cfg.AuthEmulator), posts.WithProtectedAuthors(protectedAuthors))
	// Identity's UpdateProfile asks posts whether a post is the caller's own visible pin candidate. Bound here, once,
	// before ListenAndServe (posts needs identity.Directory, so identity was built first).
	pinChecker.c = posts.NewPinChecker(postsSvc)

	// engagement: likes and reposts behind FEATURE_ENGAGEMENT. posts and engagement need each
	// other (engagement drives posts' counters and clean-up, DeletePost releases through engagement's reposts
	// links), so the links are bound here, once, synchronously, before ListenAndServe.
	engagementRepo := engagement.NewFirestoreRepo(fsClient, engagement.WriteDeps{
		Writer: postsRepo, Counters: identityRepo, IDs: snowflakeNode,
		Idempotency: idempotency.New(fsClient), // AddBookmark / RemoveBookmark idempotency docs
	})
	audienceSvc := postsSvc
	if bo.audienceSource != nil {
		audienceSvc = bo.audienceSource(postsSvc)
	}
	engAudience := rowAudience(posts.AudienceOf(audienceSvc))
	rlCfg := RateLimitConfig(cfg)
	// F-03: ListBookmarks and ListLikedPosts drop rows whose author is not ACTIVE through identity's Directory (the page
	// fails closed without it), so a wiring regression refuses to start instead.
	engagementDir := identitySvc.(identity.Directory)
	if err := requireAuthorStatusSeams([]protectedSeam{{"engagement.Deps.Directory (identity.Directory)", engagementDir}}); err != nil {
		return nil, nil, err
	}
	engagementMod, err := engagement.New(engagement.Deps{
		Repo: engagementRepo, Posts: postsSvc.(posts.Engagement), Reader: postsSvc, Directory: engagementDir,
		Events:   engagementNotifier{slot: notifSlot},
		CacheTTL: cfg.CacheTTL, AllowAnonymous: cfg.AuthEmulator,
		// Bookmarks: the repo is the engagement repo, the cap is config, not a literal.
		BookmarkRepo: engagementRepo, BookmarksMaxPerUser: cfg.Quota.BookmarksMaxPerUser,
		// ListBookmarks: the graph snapshot filters blocked and muted authors, the flags decide viewer-state
		// hydration, the cursor key seals the page tokens, and readonly mode skips the lazy prune.
		Graph: graphSvc, Flags: featureFlags, CursorKey: cfg.CursorHMACKey, ReadOnly: cfg.Degraded == config.DegradedReadonly,
		// Both lists decide protected authors' rows through the one posts.Audience.
		Audience: engAudience,
		// VotePoll: the vote batch, the vote doc TTL and the lazy userLikes trim are config.
		PollRepo: engagementRepo, PollVoteTTLAfterClose: cfg.Composer.PollVoteTTLAfterClose, PollViewerVotesKept: cfg.Composer.PollViewerVotesKept, PollVoteChangesMax: cfg.Composer.PollVoteChangesMax,
	})
	if err != nil {
		return nil, nil, fmt.Errorf("engagement: %w", err)
	}
	postsRepo.SetRepostLinks(engagementMod)
	postsSvc.(interface{ SetRepostLinks(posts.RepostLinks) }).SetRepostLinks(engagementMod)
	engagementServer := engagement.NewServer(engagementMod, featureFlags, engagement.WithBookmarks(engagementMod))
	postsServer := posts.NewServer(postsSvc, featureFlags, posts.WithViewerFlags(engagementMod), posts.WithScheduler(postsSvc.(posts.Scheduler)), posts.WithScheduledEditor(postsSvc.(posts.ScheduledEditor)))
	// The removal log is built only when FEATURE_REMOVED_IDS is not off: off means no instance cache, no reads and
	// no reset of cached client feeds (timeline treats a nil Removals as "no removed_ids"). Allowlist and percent
	// modes are enforced per caller in timeline.removedIDs.
	var removals posts.Removals
	if cfg.FeatureRemovedIDs.Mode != flags.Off {
		removals = posts.NewRemovalLog(postsRepo, cfg.CacheTTL, nil)
	}
	// Lists: the repo, the service and the one identity adapter over users/{uid}.homeTabs are built before the timeline
	// because the timeline's SetHomeTabs reads lists through lists.Reader (the service) and writes tabs through the adapter
	// (timeline.HomeTabsStore); the same adapter is lists.Pins, so DeleteList unpins and UpdateList retitles. Routes are mounted below.
	listsRepo := lists.NewFirestoreRepo(fsClient, quota.New(fsClient), idempotency.New(fsClient))
	listsRepo.SetTxProfiles(identityRepo) // W5-45 / L-4: the target's status is read fresh inside the AddListMember transaction
	homeTabs := identity.NewHomeTabs(identityRepo, idempotency.New(fsClient), identityCache)
	listsSvc := lists.New(lists.Deps{
		Repo: listsRepo, Directory: identitySvc.(identity.Directory), IDs: snowflakeNode, Graph: graphSvc, CursorKey: cfg.CursorHMACKey,
		Pins: homeTabs,
		Limits: lists.Limits{
			MaxPerUser: cfg.Lists.MaxPerUser, CacheEntries: cfg.Lists.CacheEntries, MaxMembers: cfg.Lists.MaxMembers,
		},
	})
	listsReader := listsSvc.(lists.Reader)
	// Communities: the repo is built here because the account-lifecycle registration below needs it (the eraser step
	// and export section are registered whether or not FEATURE_COMMUNITIES is on); the service and routes are wired with the lists routes.
	communitiesRepo := communities.NewFirestoreRepo(fsClient, idempotency.New(fsClient)).
		WithPostModerator(posts.NewCommunityModerator(fsClient)) // the Hide / Restore post write (A12)
	// F-03: every feed drops rows whose author is not ACTIVE through identity's Directory (the page fails closed without it),
	// so a wiring regression refuses to start instead.
	timelineDir := identitySvc.(identity.Directory)
	if err := requireAuthorStatusSeams([]protectedSeam{{"timeline.Deps.Directory (identity.Directory)", timelineDir}}); err != nil {
		return nil, nil, err
	}
	timelineServer := timeline.NewServer(timeline.Deps{
		Flags: featureFlags, Posts: postsSvc, Graph: graphSvc, Directory: timelineDir, Viewer: engagementMod,
		Removals: removals, Lists: listsReader,
		CursorKey: cfg.CursorHMACKey, TokenTTL: cfg.TimelineTokenTTL, SettleWindow: cfg.TimelineSettleWindow,
	}, timeline.WithProtectedAuthors(protectedAuthors),
		timeline.WithHomeTabs(timeline.HomeTabsDeps{Store: homeTabs, Lists: listsReader, Flags: featureFlags, Max: cfg.Lists.HomeTabsMaxPinned}))

	// SearchPosts decides every row through a snapshot-based posts.Audience over the same loader (the
	// block test is the held graph snapshot, no read), exactly as the timelines do.
	searchAudience := posts.NewSnapshotAudience(protectedAuthors)

	// L-5: every module reads a nil loader or audience as "nobody is protected", so a refactor that drops one seam
	// would fail open. All eight are passed above from these values; refuse to start if any is nil.
	if err := requireProtectedSeams([]protectedSeam{
		{"identity.ProtectedAuthors loader", protectedAuthors},
		{"graph.Deps.Protected", protectedAuthors},
		{"identity.WithProtectedAuthors", protectedAuthors},
		{"notifications.FanoutDeps.Audience", notifAudience},
		{"posts.WithProtectedAuthors", protectedAuthors},
		{"engagement.Deps.Audience (posts.AudienceOf)", engAudience},
		{"timeline.WithProtectedAuthors", protectedAuthors},
		{"search.PostsDeps.Audience (posts.NewSnapshotAudience)", protectedAuthors},
	}); err != nil {
		return nil, nil, err
	}

	// --- account lifecycle: DeleteAccount / RequestAccountExport / GetAccountExport and the job
	// handlers. The Firebase Auth admin client (built above) is handed only to identity (IAM control C2); the
	// publisher and the exports bucket client are lazy, so nothing here does I/O before ListenAndServe.
	exportStore, err := objstore.New(cfg.ExportBucket)
	if err != nil {
		return nil, nil, fmt.Errorf("export store: %w", err)
	}
	lifecycle, err := identity.NewLifecycle(identity.LifecycleDeps{
		Repo: identityRepo, Cache: identityCache, Publisher: jobsPublisher, Auth: authAdminClient, Objects: exportStore,
		Log: log, ProjectID: cfg.ProjectID,
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
	if err := registerArticleLifecycle(lifecycle, fsClient); err != nil {
		return nil, nil, fmt.Errorf("articles lifecycle registry: %w", err)
	}
	// moderation: ReportContent behind FEATURE_REPORTS. It reuses posts.GetForViewer and
	// identity.GetProfile for target visibility and writes only reports/* and the reports quota.
	moderationRepo := moderation.NewFirestoreRepo(fsClient, quota.New(fsClient))
	if err := registerModerationLifecycle(lifecycle, moderationRepo); err != nil {
		return nil, nil, fmt.Errorf("moderation lifecycle registry: %w", err)
	}
	// scheduled posts: the erase step and export section are registered whether or not
	// FEATURE_SCHEDULED_POSTS is on, because documents outlive the flag; the step runs after reports, before identity.
	if err := registerScheduledLifecycle(lifecycle, postsRepo); err != nil {
		return nil, nil, fmt.Errorf("scheduled lifecycle registry: %w", err)
	}
	// bookmarks: the erase step and export section are registered whether or not FEATURE_BOOKMARKS is
	// on; the step runs after scheduled, before identity.
	if err := registerBookmarkLifecycle(lifecycle, engagementRepo); err != nil {
		return nil, nil, fmt.Errorf("bookmarks lifecycle registry: %w", err)
	}
	// follow_requests: the erase step and export section are registered whether or not
	// FEATURE_PRIVATE_ACCOUNTS is on; the step runs after bookmarks, before identity.
	if err := registerFollowRequestsLifecycle(lifecycle, graphRepo); err != nil {
		return nil, nil, fmt.Errorf("follow_requests lifecycle registry: %w", err)
	}
	// messaging: the erase step and export section are registered whether or not FEATURE_MESSAGING is on; the
	// step runs after follow_requests, before identity. The repo is also the send path's storage (wired with the routes).
	if err := registerMessagingLifecycle(lifecycle, messagingRepo, identitySvc.(identity.Directory), graphSvc, log); err != nil {
		return nil, nil, fmt.Errorf("messaging lifecycle registry: %w", err)
	}
	// lists: the erase step and export section are registered whether or not FEATURE_LISTS is on; the step runs
	// after messaging, before identity. The repo is also the write path's storage (wired with the routes).
	if err := registerListsLifecycle(lifecycle, listsRepo, identitySvc.(identity.Directory), graphSvc); err != nil {
		return nil, nil, fmt.Errorf("lists lifecycle registry: %w", err)
	}
	// poll_votes: the erase step and export section are registered whether or not FEATURE_POLLS is on; the step runs after
	// messaging and lists, before identity (appended, never inserted: step names are persisted).
	if err := registerPollVoteLifecycle(lifecycle, engagementRepo, cfg.Composer.PollVoteTTLAfterClose); err != nil {
		return nil, nil, fmt.Errorf("poll_votes lifecycle registry: %w", err)
	}
	// communities: the erase step and export section are registered whether or not FEATURE_COMMUNITIES is on; the
	// step runs after poll_votes, before identity (appended, never inserted: step names are persisted).
	if err := registerCommunitiesLifecycle(lifecycle, communitiesRepo, identitySvc.(identity.Directory)); err != nil {
		return nil, nil, fmt.Errorf("communities lifecycle registry: %w", err)
	}
	// beacons: the erase step and export section are registered whether or not FEATURE_BEACONS is on; the step runs
	// after communities, before identity (appended, never inserted: step names are persisted).
	if err := registerBeaconsLifecycle(lifecycle, beaconsRepo); err != nil {
		return nil, nil, fmt.Errorf("beacons lifecycle registry: %w", err)
	}
	// outbox: the user's pending work items (outbox/{kind}:{key}, uid ==); appended after beacons, before identity.
	if err := registerOutboxLifecycle(lifecycle, ob); err != nil {
		return nil, nil, fmt.Errorf("outbox lifecycle registry: %w", err)
	}
	// A MESSAGE report reaches the message only through messaging; bound once the messaging service exists.
	lateMessages := &lateMessageLookup{}
	// A COMMUNITY report reaches the community only through communities.CommunityReporter; bound once the communities service exists.
	lateCommunities := &lateCommunityLookup{}
	// A BEACON report reaches the beacon only through beacons.BeaconReporter; bound once the beacons service exists.
	lateBeacons := &lateBeaconLookup{}
	// Plan: a LIST report reaches the list only through lists.ListReporter (the lists service, built above).
	listReporter, ok := listsSvc.(lists.ListReporter)
	if !ok {
		return nil, nil, errors.New("lists service does not implement ListReporter")
	}
	moderationSvc := moderation.New(moderation.Deps{
		Repo: moderationRepo, Posts: postsSvc, Accounts: identitySvc, Directory: lateDirectory.d, Messages: lateMessages, Lists: listReportLookup{r: listReporter}, Communities: lateCommunities, Beacons: lateBeacons, Articles: articleReportLookup{r: articles.NewEvidenceReader(fsClient)},
		ReportsPerDay:           int64(cfg.Quota.ReportsPerDay),
		NewAccountReportsPerDay: int64(cfg.Quota.NewAccountReportsPerDay),
		NewAccountWindow:        cfg.Quota.NewAccountWindow,
		AllowAnonymous:          cfg.AuthEmulator,
	})
	moderationServer := moderation.NewServer(moderationSvc, featureFlags)
	// post_delete (media, engagement): one message, one composite handler.
	postDeleteJob := postDeleteChain{
		media: mediaMod.jobs,
		eng:   engagement.NewJobs(engagementRepo, postsRepo, postGone{postsRepo}, jobsPublisher),
		pins:  identity.NewPinJobs(identityRepo, postGone{postsRepo}, identitySvc.(identity.Directory).Forget),
		// The article rooted at a post deleted through posts.Delete goes with it (no orphan library entry).
		articles: articles.NewPostDeleteJobs(fsClient, postGone{postsRepo}),
	}
	if err := lifecycle.RegisterJobHandler(media.JobKindPostDelete, postDeleteJob); err != nil {
		return nil, nil, fmt.Errorf("post_delete job handler: %w", err)
	}
	// profile_media_retired: the media step that schedules a replaced or removed avatar
	// for deletion. Registered whatever PROFILE_MEDIA_RETIRE says: with the switch off the handler acks without
	// action, so a message published by a revision that had it on is never left in a retry loop.
	if err := lifecycle.RegisterJobHandler(media.JobKindProfileMediaRetired, mediaMod.jobs.RetireHandler()); err != nil {
		return nil, nil, fmt.Errorf("profile_media_retired job handler: %w", err)
	}
	// privacy_public: graph accepts the pending follow requests of an account that went public.
	// Never gated: a message published before a flag change is still honoured.
	if err := lifecycle.RegisterJobHandler(graph.JobKindPrivacyPublic, graphSvc.PrivacyPublicJob(graphRepo, log)); err != nil {
		return nil, nil, fmt.Errorf("privacy_public job handler: %w", err)
	}
	identityServer := identity.NewServer(identitySvc,
		identity.WithAllowAnonymous(cfg.AuthEmulator), identity.WithFlagChecker(featureFlags),
		identity.WithLifecycle(lifecycle), identity.WithReauthMaxAge(cfg.AccountDeleteReauthMaxAge))
	graphServer := graph.NewServer(graphSvc)

	// search and admin are not implemented yet; their Connect servers are not registered.

	// --- interceptors ---
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
		// 0-read verified-identity gate (sign-in provider allowlist). Callers outside it never
		// reach the rate limiter, so a minted uid creates no limiter key and no Firestore read. Anonymous passes
		// only against the Auth emulator.
		authn.VerifiedIdentityInterceptor(profileExempt, cfg.AuthEmulator),
		ratelimit.Interceptor(rlCfg),
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
	billingBindings := billing.NewFirestoreBindings(fsClient)
	if e := registerBillingLifecycle(lifecycle, billingBindings); e != nil {
		return nil, nil, e
	}
	var billingWebhookRecovery trendsStep
	if cfg.BillingWebhook.Enabled {
		if (cfg.Env != "dev" && cfg.Env != "prod") || cfg.AuthEmulator || cfg.BillingSandbox.Enabled {
			return nil, nil, fmt.Errorf("production billing webhooks require dev/prod without emulators or sandbox checkout")
		}
		products := map[string]billing.Product{}
		for id, product := range cfg.BillingWebhook.Products {
			products[id] = billing.Product{Store: product.Store, Entitlement: product.Entitlement}
		}
		provider, e := billing.NewRevenueCatProvider(cfg.BillingWebhook.SecretAPIKey, products, nil)
		if e != nil {
			return nil, nil, fmt.Errorf("billing webhook provider configuration invalid")
		}
		reconciler, e := billing.NewReconciler(billingBindings, provider, nil)
		if e != nil {
			return nil, nil, fmt.Errorf("billing webhook reconciliation configuration invalid")
		}
		processor, e := billing.NewWebhookProcessor(billingBindings, reconciler)
		if e != nil {
			return nil, nil, e
		}
		processor.ReadOnly = cfg.Degraded == config.DegradedReadonly
		if e = routes.revenuecat(processor, cfg.BillingWebhook.Authorization, cfg.BillingWebhook.SigningSecret, cfg.BillingWebhook.AppIDs); e != nil {
			return nil, nil, fmt.Errorf("billing webhook authentication configuration invalid")
		}
		billingWebhookRecovery = processor
		routes.internal("/internal/cron/billing-webhooks", billingRecoveryHandler(processor, log, cfg.ProjectID))
	}
	billingServer := billing.NewServer(nil, nil, nil)
	// A missing checker intentionally denies all new article publication in
	// every environment; disabling sales must not bypass paid authorization.
	var articlePublishingAccess func(context.Context, string) error
	if cfg.BillingSandbox.Enabled {
		if cfg.Env != "local" || cfg.ProjectID != "demo-dzeroth-local" || !cfg.AuthEmulator {
			return nil, nil, fmt.Errorf("billing sandbox requires local demo project and Auth emulator")
		}
		bindings := billingBindings
		provider, e := billing.NewRevenueCatProvider(cfg.BillingSandbox.SecretAPIKey,
			map[string]billing.Product{"monthly": {Store: "test_store", Entitlement: billing.ProEntitlement}}, nil)
		if e != nil {
			return nil, nil, fmt.Errorf("billing provider configuration invalid")
		}
		identities, e := billing.NewIdentityService(bindings, billing.Sandbox, nil)
		if e != nil {
			return nil, nil, fmt.Errorf("billing identity configuration invalid")
		}
		reconciler, e := billing.NewReconciler(bindings, provider, nil)
		if e != nil {
			return nil, nil, fmt.Errorf("billing reconciliation configuration invalid")
		}
		server := billing.NewServer(identities, bindings, reconciler)
		subscriptionPostLimit = func(ctx context.Context, uid string) (int, error) {
			b, err := bindings.LookupBinding(ctx, uid)
			if errors.Is(err, billing.ErrNotFound) {
				return 280, nil
			}
			if err != nil {
				return 0, connect.NewError(connect.CodeUnavailable, errors.New("subscription verification unavailable"))
			}
			snapshot, err := reconciler.Refresh(ctx, uid)
			if err != nil {
				return 0, connect.NewError(connect.CodeUnavailable, errors.New("subscription verification unavailable"))
			}
			tier, err := billing.EffectiveTier(b, snapshot, time.Now())
			if err != nil {
				return 0, connect.NewError(connect.CodeUnavailable, errors.New("subscription verification unavailable"))
			}
			return billing.CapabilitiesFor(tier, billing.FeatureAvailability{LongPosts: true}).MaxPostRunes, nil
		}
		articlePublishingAccess = func(ctx context.Context, uid string) error {
			b, err := bindings.LookupBinding(ctx, uid)
			if errors.Is(err, billing.ErrNotFound) {
				return connect.NewError(connect.CodePermissionDenied, errors.New("Premium subscription required"))
			}
			if err != nil {
				return connect.NewError(connect.CodeUnavailable, errors.New("subscription verification unavailable"))
			}
			snapshot, err := reconciler.Refresh(ctx, uid)
			if err != nil {
				return connect.NewError(connect.CodeUnavailable, errors.New("subscription verification unavailable"))
			}
			tier, err := billing.EffectiveTier(b, snapshot, time.Now())
			if err != nil {
				return connect.NewError(connect.CodeUnavailable, errors.New("subscription verification unavailable"))
			}
			if tier != billing.TierPremium {
				return connect.NewError(connect.CodePermissionDenied, errors.New("Premium subscription required"))
			}
			return nil
		}
		server.EnableSandboxPurchases()
		billingServer = server
	}
	routes.connect(func(o ...connect.HandlerOption) (string, http.Handler) {
		return billingv1connect.NewBillingServiceHandler(billingServer, o...)
	})
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
		return articlesv1connect.NewArticleServiceHandler(articles.NewServer(fsClient, postsSvc, featureFlags, func(ctx context.Context, uid, id string) (string, error) {
			ref, err := mediaMod.library.ResolvePostCover(ctx, uid, id)
			return ref.URL, err
		}).WithPublishingAccess(articlePublishingAccess), o...)
	})

	routes.connect(func(o ...connect.HandlerOption) (string, http.Handler) {
		return timelinev1connect.NewTimelineServiceHandler(timelineServer, o...)
	})

	routes.connect(func(o ...connect.HandlerOption) (string, http.Handler) {
		return engagementv1connect.NewEngagementServiceHandler(engagementServer, o...)
	})

	// L-7: conversation_hash in logs and error lines is an HMAC keyed by an HKDF derivation of CURSOR_HMAC_KEY (no new
	// secret), so a log holder cannot confirm a guessed uid pair against the plain hash. `opsctl messages loghash` reproduces it.
	if len(cfg.CursorHMACKey) == 0 {
		log.Warn("cursor key empty: conversation_hash uses a per-process random key")
	} else if err := logger.SetConversationKey(cfg.CursorHMACKey); err != nil {
		return nil, nil, fmt.Errorf("apiserver: conversation hash key: %w", err)
	}
	// Messaging: SendMessage behind FEATURE_MESSAGING, per caller and per recipient; ListConversations
	// is not globally off; the other three RPCs check the flag and answer Unimplemented until it ships. Badge evicts identity's cached
	// unread_conversation_count; the push event is adapted to notifications.Emitter (a no-op until it ships adds the type).
	messagingSvc := messaging.New(featureFlags, messaging.Deps{
		Repo: messagingRepo, Social: graphSvc, Profiles: identitySvc.(identity.Directory), Events: messageNotifier{slot: notifSlot},
		TxSocial: graphRepo, TxProfiles: identityRepo, AllowAnonymous: cfg.AuthEmulator, // Recipient graph and users doc in the send transaction
		Badge: identity.NewMessageBadgeCache(identityCache),
		Limits: messaging.Limits{
			RequestMaxUnanswered: int64(cfg.Messaging.RequestMaxUnanswered),
			DMNewPerDay:          int64(cfg.Quota.DMNewConversationsPerDay), NewAccountDMNewPerDay: int64(cfg.Quota.NewAccountDMNewConversationsPerDay),
			NewAccountSendsPerDay: int64(cfg.Messaging.NewAccountSendsPerDay), NewAccountWindow: cfg.Quota.NewAccountWindow,
			ConversationCacheEntries: cfg.Messaging.ConversationCacheEntries,
		},
		CursorKey: cfg.CursorHMACKey,
		Log:       log,
	})
	reporter, ok := messagingSvc.(messaging.MessageReporter)
	if !ok {
		return nil, nil, errors.New("messaging service does not implement MessageReporter")
	}
	lateMessages.r = reporter
	messagingServer := messaging.NewServer(messagingSvc)
	routes.connect(func(o ...connect.HandlerOption) (string, http.Handler) {
		return messagingv1connect.NewMessagingServiceHandler(messagingServer, o...)
	})

	// Lists: all seven routes are mounted so the interceptor chain covers them.
	// Lists: the write path (CreateList, UpdateList, DeleteList; AddListMember, RemoveListMember) and the reads (GetList, ListUserLists, ListListMembers) behind
	// FEATURE_LISTS. listsSvc (built above, before the timeline) also implements lists.Reader. Pins is the identity home-tabs adapter: a
	// DeleteList removes the owner's own pin; another user's pin of it dangles and the client shows it unavailable (GetMe adds no read).
	listsServer := lists.NewServer(featureFlags, listsSvc)
	routes.connect(func(o ...connect.HandlerOption) (string, http.Handler) {
		return listsv1connect.NewListServiceHandler(listsServer, o...)
	})

	// Communities: all thirteen CommunityService routes are mounted behind FEATURE_COMMUNITIES (FEATURE_DISABLED
	// feature=communities) so the interceptor chain covers them. CreateCommunity, UpdateCommunity and GetCommunity and JoinCommunity,
	// LeaveCommunity and ListMyCommunities run the service; replace the other six methods. CreateCommunity also needs the caller in COMMUNITY_CREATORS.
	// The one shared 60 s handle-prefix cache over identity.SearchHandles (CACHE_SEARCH_PREFIX_ENTRIES): SearchPeople and
	// SearchCommunityMembers (F36) read through the same entries, so a member search after a people search is a cache hit.
	handlePrefixes := search.NewPrefixCache(identitySvc.(identity.Directory), cfg.Search.PrefixCacheEntries)
	communitiesSvc := communities.New(communities.Deps{
		// A committed restore drops this instance's shared feed entry (timeline is built above; communities never imports it).
		OnPostRestored: timelineServer.ForgetCommunityFeed,
		Repo:           communitiesRepo, Directory: identitySvc.(identity.Directory), Graph: graphSvc, IDs: snowflakeNode,
		Creators: cfg.Communities.Creators, CursorKey: cfg.CursorHMACKey,
		// FEATURE_COMMUNITY_MEMBER_SEARCH and the candidate reader of SearchCommunityMembers.
		Flags: featureFlags, Handles: handlePrefixes,
		Limits: communities.Limits{
			MaxOwned: cfg.Communities.MaxOwned, MaxJoined: cfg.Communities.MaxJoined, MaxRules: cfg.Communities.MaxRules,
			ModlogMax: cfg.Communities.ModlogMax, MaxModerators: cfg.Communities.MaxModerators, RecentRemovalsMax: cfg.Communities.RecentRemovalsMax, CacheEntries: cfg.Communities.CacheEntries, MembersCacheEntries: cfg.Communities.MembersCacheEntries,
		},
	})
	// The posting gate: posts declares posts.CommunityGate and never imports communities; communities implements it over
	// its cached Reader, a fresh in-transaction member read and the per (uid, community) daily cap (COMMUNITY_POSTS_PER_COMMUNITY_PER_DAY,
	// per instance). Set before ListenAndServe, like SetRepostLinks; without it a set community_id stays FEATURE_DISABLED.
	communityReporter, ok := communitiesSvc.(communities.CommunityReporter)
	if !ok {
		return nil, nil, errors.New("communities service does not implement CommunityReporter")
	}
	lateCommunities.r = communityReporter
	postsSvc.(interface{ SetCommunityGate(posts.CommunityGate) }).SetCommunityGate(communities.NewPostGate(
		communitiesSvc.(communities.Reader), communitiesRepo, ratelimit.NewDailyCap(cfg.RateLimit.CommunityPostsPerCommunityPerDay)))
	// GetCommunityTimeline and the COMMUNITY kind of SetHomeTabs read communities through the same Reader; set before
	// ListenAndServe because communities is built after the timeline.
	timelineServer.SetCommunities(communitiesSvc.(communities.Reader), cfg.Communities.FeedCacheEntries)
	communitiesServer := communities.NewServer(featureFlags, communitiesSvc)
	routes.connect(func(o ...connect.HandlerOption) (string, http.Handler) {
		return communitiesv1connect.NewCommunityServiceHandler(communitiesServer, o...)
	})

	// Beacons: all twelve BeaconService routes are mounted behind FEATURE_BEACONS (FEATURE_DISABLED feature=beacons) so the
	// interceptor chain covers them. CreateBeacon, UpdateBeacon, CancelBeacon, GetBeacon and ListBeacons reach the service;
	// the participation RPCs answer Unimplemented until PR 3. Community-audience beacons read membership through
	// communities.Reader and gate on FEATURE_COMMUNITIES with the same registry.
	var beaconEvents beacons.Events = beaconNotifier{slot: notifSlot} // request, accept and cancel → notifications (PR 5)
	if bo.inlineBeaconEvents != nil {
		beaconEvents = bo.inlineBeaconEvents(beaconEvents)
	}
	beaconsSvc := beacons.New(beacons.Deps{
		Repo: beaconsRepo, Directory: identitySvc.(identity.Directory), Graph: graphSvc, Communities: communitiesSvc.(communities.Reader),
		CommunityFlags: featureFlags, IDs: snowflakeNode, CursorKey: cfg.CursorHMACKey,
		Events: beaconEvents,
		Outbox: ob, // the cancellation notices: staged in the cancel transaction, re-run by the outbox sweep (B07)
		Limits: beacons.Limits{MaxOpenPerUser: cfg.Beacons.MaxOpenPerUser, MaxPendingRequests: cfg.Beacons.MaxPendingRequests, MaxOpenSpots: cfg.Beacons.MaxOpenSpots},
	})
	beaconReporter, ok := beaconsSvc.(beacons.BeaconReporter)
	if !ok {
		return nil, nil, errors.New("beacons service does not implement BeaconReporter")
	}
	lateBeacons.r = beaconReporter // bound before ListenAndServe: a BEACON report can now reach the beacon
	// Post.beacon: CreatePost's beacon_id and the card hydration of every post producer.
	wirePostPlans(beaconsSvc, postsSvc, postsServer, timelineServer)
	beaconsServer := beacons.NewServer(featureFlags, beaconsSvc)
	routes.connect(func(o ...connect.HandlerOption) (string, http.Handler) {
		return beaconsv1connect.NewBeaconServiceHandler(beaconsServer, o...)
	})

	// Search and trends: FEATURE_SEARCH gates SearchPeople and SearchPosts, FEATURE_TRENDS gates GetTrends,
	// each FEATURE_DISABLED without any Firestore read. SearchPeople reads identity.Directory.SearchHandles through a
	// shared prefix cache and filters with the caller's graph snapshot. SearchPosts reads
	// posts.Reader.ByHashtag and decides every row through a snapshot-based posts.Audience over the one protected-set
	// loader. GetTrends reads trends/current through a 10 min instance copy; the refresher is the
	// daily step (and the standalone route). Both go through search.TrendsStore, the only code that touches the collection.
	trendsStore := search.NewTrendsRepo(fsClient)
	// F-03: SearchPosts drops every row whose author is not ACTIVE through identity's Directory, the rule GetPost and
	// GetUserTimeline apply (a REPOST of such an author's post is dropped, a QUOTE of one is tombstoned). WithPosts stays
	// Unimplemented without it, so refuse to start instead.
	var searchAuthors search.AuthorDirectory = identitySvc.(identity.Directory)
	if err := requireAuthorStatusSeams([]protectedSeam{{"search.PostsDeps.Authors (identity.Directory)", searchAuthors}}); err != nil {
		return nil, nil, err
	}
	searchServer := search.NewServer(search.New(featureFlags,
		search.WithPeople(search.PeopleDeps{Directory: identitySvc.(identity.Directory), Graph: graphSvc, PrefixEntries: cfg.Search.PrefixCacheEntries, Prefixes: handlePrefixes}),
		search.WithPosts(search.PostsDeps{
			Posts: postsSvc, Graph: graphSvc, Viewer: engagementMod, Audience: searchAudience, Authors: searchAuthors,
			CursorKey: cfg.CursorHMACKey, TagEntries: cfg.Search.TagCacheEntries,
		}),
		search.WithTrends(trendsStore, nil),
		// The denylist also applies at serve time, so a deploy takes effect within the 10 min copy.
		search.WithTrendsDenylist(cfg.Search.TrendsDenylist)))
	trendsRefresher := search.NewRefresher(trendsStore, postsSvc, protectedAuthors, identitySvc.(identity.Directory), featureFlags, search.RefresherConfig{
		MinAuthors: cfg.Search.TrendsMinAuthors, MaxPosts: cfg.Search.TrendsMaxPostsPerRun, MinInterval: cfg.Search.TrendsMinInterval,
		MinAccountAge: cfg.Search.TrendsMinAccountAge, MaxAuthorChecks: cfg.Search.TrendsMaxAuthorChecks,
		Denylist: cfg.Search.TrendsDenylist, ReadOnly: cfg.Degraded == config.DegradedReadonly, Log: log,
	})
	routes.connect(func(o ...connect.HandlerOption) (string, http.Handler) {
		return searchv1connect.NewSearchServiceHandler(searchServer, o...)
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
	// The shared jobs topic's push endpoint and the daily-maintenance backstop. Never behind the
	// account_lifecycle flag or DEGRADED_MODE (Q8, Q9): an accepted deletion must finish.
	routes.internal("/internal/pubsub/jobs", lifecycle.JobsHandler())
	// The same route also runs the trends refresh after the backstop, but its status is the
	// backstop's alone. The poll vote sweep runs first, the media orphan sweep last (it takes only what trends left). The
	// standalone route is for dev (no Scheduler jobs there) and a later hourly job.
	routes.internal("/internal/cron/daily-maintenance", dailyMaintenanceHandler(lifecycle.CronHandler(), stepChain{
		pollVoteSweepStep{sweeper: engagementRepo, ttl: cfg.Composer.PollVoteTTLAfterClose, readOnly: cfg.Degraded == config.DegradedReadonly, log: log, now: time.Now},
		trendsRefresher,
		mediaOrphanSweepStep{sweeper: mediaMod.orphans, mode: cfg.MediaOrphanSweep, limit: media.OrphanSweepPage, readOnly: cfg.Degraded == config.DegradedReadonly, log: log, now: time.Now},
	}, log, cfg.ProjectID, time.Now))
	routes.internal("/internal/cron/trends-refresh", search.NewRefreshHandler(trendsRefresher, log, cfg.ProjectID))
	// The scheduled-post publish sweep (Cloud Scheduler every 5 min, prod). POST only, 25 s deadline and panic
	// recovery. The kill switch (FEATURE_SCHEDULED_POSTS / FEATURE_POSTS globally off) and
	// DEGRADED_MODE=readonly are checked inside the sweep, which then answers 204.
	// The outbox sweep rides the same tick, after the publish sweep and never changing its status (outbox_wiring.go);
	// /internal/cron/outbox-sweep runs it alone (dev has no Scheduler jobs).
	outboxStep := outboxSweepStep{sweeper: ob, readOnly: cfg.Degraded == config.DegradedReadonly, log: log}
	routes.internal("/internal/cron/publish-scheduled", withBillingRecovery(withOutboxSweep(posts.NewSweepHandler(postsSvc.(posts.Sweeper), log, cfg.ProjectID), outboxStep, cfg.ProjectID, time.Now), billingWebhookRecovery, log))
	routes.internal("/internal/cron/outbox-sweep", outboxSweepHandler(outboxStep, log, cfg.ProjectID))
	// The notifications-fanout push endpoint. Behind the OIDC verifier like every /internal/* route; the
	// FEATURE_NOTIFICATIONS flag and DEGRADED_MODE=readonly are checked per event inside the handler, which then
	// acknowledges and drops (never a 5xx, so a switched-off feature cannot fill the DLQ).
	routes.internal("/internal/pubsub/notifications-fanout", notifFanout.Handler())

	// M1: a coarse, pre-auth per-IP token bucket wraps the whole mux — /health,
	// /internal/* and every module's Connect handler — as plain net/http middleware, so an unauthenticated
	// flood is rejected before it costs any App Check / ID token JWT-verify CPU (that verification happens
	// only once a request reaches a Connect handler's own interceptor chain inside mux, below this layer).
	// This is a *different* Limiter instance from the one ratelimit.Interceptor uses above (rlIP): a
	// request is never counted twice against the same bucket for the two layers.
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
// importing the other's concrete types (modules/platform depend on interfaces only).
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
