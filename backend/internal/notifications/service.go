package notifications

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"regexp"
	"slices"
	"strings"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/cursor"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// ListInput is one ListNotifications call (already past the flag guard).
type ListInput struct {
	PageSize   int32
	PageToken  string
	SinceToken string
}

// ListResult is one ListNotifications response.
type ListResult struct {
	Notifications []Notification
	NextPageToken string
	SinceToken    string
	GapPageToken  string
	// SeenAt is the caller's notificationsSeenAt (zero when never marked seen).
	SeenAt time.Time
}

// DeviceInput is one RegisterDevice call.
type DeviceInput struct {
	IdempotencyKey string
	DeviceID       string
	Token          string
	Platform       Platform
}

// Service is the Connect handler's dependency.
type Service interface {
	List(ctx context.Context, uid string, in ListInput) (ListResult, error)
	MarkSeen(ctx context.Context, uid, idempotencyKey string) (time.Time, error)
	RegisterDevice(ctx context.Context, uid string, in DeviceInput) error
	UnregisterDevice(ctx context.Context, uid, idempotencyKey, deviceID string) error
}

// Deps are the Service's collaborators.
type Deps struct {
	Repo      Repo
	Directory Directory
	// Social is the caller's cached graph context: List hides rows whose actor the caller blocks or mutes, or who
	// blocks the caller, as of read time (a block after the fan-out check must take effect). Required.
	Social Social
	// Blocks answers "which of these actors blocked the caller" when the caller's blockedBy overflowed its cap (the
	// snapshot's BlockedBy is then incomplete). Never called otherwise. Nil with an overflowed caller fails the page.
	Blocks BlockLookup
	Seen   SeenStore
	// Validator checks a FCM token with a dry-run send before RegisterDevice stores it (N-5). Nil accepts every token.
	Validator TokenValidator
	CursorKey []byte
	// TokenTTL is the lifetime of a persisted since/gap token (RefreshTokenTTL when zero).
	TokenTTL time.Duration
	Now      func() time.Time
}

type service struct {
	d Deps
}

// NewService builds the Service.
func NewService(d Deps) Service {
	if d.Now == nil {
		d.Now = time.Now
	}
	if d.TokenTTL <= 0 {
		d.TokenTTL = RefreshTokenTTL
	}
	return &service{d: d}
}

var deviceIDPattern = regexp.MustCompile(`^[A-Za-z0-9_-]{16,64}$`)

func sinceBinding(uid string) string { return "notifications|since|" + uid }
func pageBinding(uid string) string  { return "notifications|page|" + uid }

func clampPageSize(n int32) int {
	switch {
	case n <= 0:
		return DefaultPageSize
	case n > MaxPageSize:
		return MaxPageSize
	}
	return int(n)
}

// List: reads the page of rows (20 at the default page, 50 at the maximum) and the caller's graph snapshot
// (cached 60 s). Only when the caller's blockedBy overflowed its cap does it also ask graph.BlockLookup about the
// page's actors: one call of at most graph.MaxBlockLookup users, each answered from the graph cache or by batched
// GetAlls of up to 25 docs (see overflowBlockers). Then one cache-first Directory lookup (two only on a page of more
// than 49 distinct displayed actors) gives the actors' account status, seen_at and the faces (see activeActors); the
// caller's seen_at profile is the account-status interceptor's cached entry. It writes nothing.
//
// Filtering runs after the page query, so a page may come back shorter than page_size, or empty, while more rows
// exist: the tokens are computed from the raw rows (what was scanned), never the filtered ones, and the client
// keeps paging while next_page_token is set. There is deliberately no refill loop: reads stay bounded.
func (s *service) List(ctx context.Context, uid string, in ListInput) (ListResult, error) {
	if in.PageToken != "" && in.SinceToken != "" {
		return ListResult{}, apierr.Validation("page_token", "send either page_token or since_token, not both")
	}
	limit := clampPageSize(in.PageSize)
	now := s.d.Now()

	var q ListQuery
	q.Limit = limit
	var since *cursor.Cursor
	var gapLower *cursor.Cursor
	switch {
	case in.SinceToken != "":
		c, err := cursor.DecodeAtTTL(s.d.CursorKey, sinceBinding(uid), in.SinceToken, now, s.d.TokenTTL)
		if err != nil {
			return ListResult{}, apierr.Validation("since_token", "invalid or expired since_token")
		}
		since = &c
		q.After = &c
	case in.PageToken != "":
		w, err := cursor.DecodeWindowAt(s.d.CursorKey, pageBinding(uid), in.PageToken, now, s.d.TokenTTL)
		if err != nil || w.IsZero() {
			return ListResult{}, apierr.Validation("page_token", "invalid or expired page_token")
		}
		up := w.Upper
		q.Before = &up
		q.After = w.Lower
		gapLower = w.Lower
	}

	rows, err := s.d.Repo.List(ctx, uid, q)
	if err != nil {
		return ListResult{}, logger.RedactErr(err, uid)
	}
	// rows is the raw page: full, oldest and the since token below come from it, not from the filtered slice.
	var shown []Notification
	if len(rows) > 0 {
		snap, err := s.d.Social.Snapshot(ctx, uid)
		if err != nil {
			return ListResult{}, logger.RedactErr(fmt.Errorf("notifications: caller graph: %w", err), uid)
		}
		var ov *overflowBlocks
		if snap.BlockedByOverflow {
			ov, err = s.overflowBlockers(ctx, uid, rows, snap)
			if err != nil {
				return ListResult{}, err
			}
		}
		shown = make([]Notification, 0, len(rows))
		for _, n := range rows {
			if v, ok := visible(n, snap, ov); ok {
				shown = append(shown, v)
			}
		}
	}
	res := ListResult{Notifications: shown}
	if shown == nil {
		res.Notifications = []Notification{}
	}
	full := len(rows) == limit
	oldest := cursor.Cursor{}
	if len(rows) > 0 {
		last := rows[len(rows)-1]
		oldest = cursor.Cursor{CreatedAt: last.CreatedAt, DocID: last.ID}
	}

	switch {
	case since != nil: // refresh
		if full {
			res.GapPageToken = cursor.EncodeWindowAt(s.d.CursorKey, pageBinding(uid), cursor.Window{Upper: oldest, Lower: since}, now)
		}
		res.SinceToken = s.sinceToken(uid, rows, since, now)
	case in.PageToken != "": // scroll or gap fill
		if full {
			res.NextPageToken = cursor.EncodeWindowAt(s.d.CursorKey, pageBinding(uid), cursor.Window{Upper: oldest, Lower: gapLower}, now)
		}
	default: // cold open
		if full {
			res.NextPageToken = cursor.EncodeWindowAt(s.d.CursorKey, pageBinding(uid), cursor.Window{Upper: oldest}, now)
		}
		res.SinceToken = s.sinceToken(uid, rows, nil, now)
	}

	shown, err = s.activeActors(ctx, uid, &res)
	if err != nil {
		return ListResult{}, err
	}
	res.Notifications = shown
	return res, nil
}

// activeActors is the account-status half of List's read-time rule (F-03, as the feeds apply it to authors): a row
// whose displayed actor is not ACTIVE (SUSPENDED, DELETING, or no users doc) is hidden, the same way visible() hides
// a blocked one; a folded actor this call proved not ACTIVE is pruned from ActorIDs and subtracted from the count. It
// also sets res.SeenAt and hydrates the avatar stack (Notification.Actors) from the same lookup.
//
// Reads: one cache-first Directory lookup for the caller (seen_at), every shown row's displayed actor and the newest
// visible faces, at most MaxPageProfileLookup ids per call. Faces fill only what the caller and the displayed actors
// leave of the first call's budget, so a page needs a second call only when the caller plus its distinct displayed
// actors exceed MaxPageProfileLookup (a page_size 50 page of 50 different actors). A folded actor that is not a face is
// not looked up and keeps counting: a viral like row can name 50 ids, and treating an unchecked one as inactive would
// collapse every such count. The tokens are already cut from the raw rows, so a page this rule empties still advances.
//
// A failed lookup fails the page when there are rows to judge: a row whose actor status is unknown is never shown
// (the F-03 rule, "never an assumed status"). With no row left it only loses seen_at, which degrades as before.
func (s *service) activeActors(ctx context.Context, uid string, res *ListResult) ([]Notification, error) {
	rows := res.Notifications
	seed := []string{uid}
	seeded := map[string]bool{uid: true}
	for _, n := range rows {
		if id := n.Actor.UserID; id != "" && !seeded[id] {
			seeded[id] = true
			seed = append(seed, id)
		}
	}
	picks, ids := pickShownActorsFrom(rows, seed, MaxPageProfileLookup)
	profiles := make(map[string]identity.Profile, len(ids))
	for batch := range slices.Chunk(ids, MaxPageProfileLookup) {
		got, err := s.d.Directory.GetProfiles(ctx, batch)
		if err != nil {
			err = logger.RedactErr(fmt.Errorf("notifications: actor status: %w", err), ids...)
			if len(rows) == 0 {
				// seen_at is a nicety (unread styling); an empty page is still good. Log so a failing directory is visible.
				slog.WarnContext(ctx, "notifications_list_seen_at_unavailable", "uid_hash", logger.HashUID(uid), "err", err)
				return rows, nil
			}
			return nil, err
		}
		for id, p := range got {
			if p.Status == identity.AccountStatusActive {
				profiles[id] = p
			}
		}
	}
	res.SeenAt = profiles[uid].NotificationsSeenAt
	checked := make(map[string]bool, len(ids))
	for _, id := range ids {
		checked[id] = true
	}
	inactive := func(id string) bool { return id != "" && id != uid && checked[id] && !profilesHas(profiles, id) }
	out := make([]Notification, 0, len(rows))
	outPicks := make([][]string, 0, len(rows))
	for i, n := range rows {
		v, ok := pruneActors(n, inactive)
		if !ok {
			continue
		}
		out = append(out, v)
		outPicks = append(outPicks, picks[i])
	}
	logger.SetRequestField(ctx, fieldDroppedInactive, len(rows)-len(out))
	hydrateActors(out, outPicks, profiles)
	return out, nil
}

// fieldDroppedInactive counts the rows a List page hid because their displayed actor is not ACTIVE (the timelines log
// the same field for authors).
const fieldDroppedInactive = "dropped_inactive"

func profilesHas(profiles map[string]identity.Profile, id string) bool {
	_, ok := profiles[id]
	return ok
}

// pickShownActors chooses, for each shown row, up to MaxShownActors distinct actors newest first. The rows are
// already pruned by visible(), so a hidden actor is never picked. foldActor appends the newest actor at the end of
// ActorIDs, so the picks come from the tail. The page's distinct ids are capped at budget (the batched lookup's
// size); picking goes round by round (every row's newest actor first, then the second newest, ...), so when the cap
// bites a row loses its older faces before another row loses its newest. picks[i] is row i's ids in display order;
// ids is the deduplicated union to look up.
func pickShownActors(rows []Notification, budget int) (picks [][]string, ids []string) {
	return pickShownActorsFrom(rows, nil, budget)
}

// pickShownActorsFrom is pickShownActors with ids already chosen: seed (distinct, in order) starts ids and counts
// toward budget, and picking a seeded id costs nothing. List seeds the caller and the displayed actors, which it must
// look up anyway for their account status.
func pickShownActorsFrom(rows []Notification, seed []string, budget int) (picks [][]string, ids []string) {
	picks = make([][]string, len(rows))
	seen := make(map[string]bool, len(seed))
	ids = append(ids, seed...)
	for _, id := range seed {
		seen[id] = true
	}
	for round := 0; round < MaxShownActors; round++ {
		for i, n := range rows {
			if len(picks[i]) != round {
				continue // this row ran out of actors in an earlier round
			}
			id := nthNewestActor(n.ActorIDs, picks[i])
			if id == "" {
				continue
			}
			if !seen[id] {
				if len(ids) >= budget {
					continue
				}
				seen[id] = true
				ids = append(ids, id)
			}
			picks[i] = append(picks[i], id)
		}
	}
	return picks, ids
}

// nthNewestActor is the newest id of actorIDs (scanning from the tail) not already in taken and not empty, or "".
func nthNewestActor(actorIDs, taken []string) string {
	for j := len(actorIDs) - 1; j >= 0; j-- {
		id := actorIDs[j]
		if id != "" && !slices.Contains(taken, id) {
			return id
		}
	}
	return ""
}

// hydrateActors fills each row's Actors from the picks, in order. An id the Directory did not return (gone,
// suspended or deleting) is left out; ActorCount is untouched (activeActors already pruned the inactive ids).
func hydrateActors(rows []Notification, picks [][]string, profiles map[string]identity.Profile) {
	for i := range rows {
		for _, id := range picks[i] {
			p, ok := profiles[id]
			if !ok {
				continue
			}
			rows[i].Actors = append(rows[i].Actors, liveActorFromProfile(p))
		}
	}
}

// liveActorFromProfile is the live row of one actor: the 96 px thumb as avatar_url (the full avatar when there is no
// thumb, as the stored actor snapshot does) and the is_private lock badge.
func liveActorFromProfile(p identity.Profile) LiveActor {
	a := actorFromProfile(p)
	return LiveActor{UserID: a.UserID, Handle: a.Handle, DisplayName: a.DisplayName, AvatarURL: a.AvatarURL, Verified: a.Verified, IsPrivate: p.IsPrivate}
}

// overflowBlocks is what List established about the page's actors when the caller's blockedBy overflowed (F-04):
// blockers are the actors the graph module says blocked the caller; checked are the actors it was asked about.
type overflowBlocks struct {
	blockers map[string]bool
	checked  map[string]bool
}

// overflowBlockers asks graph.BlockLookup, in one batched call, which of the page's actors blocked the caller. Only
// actors the snapshot does not already hide are asked: every distinct shown actor first (at most MaxPageSize, always
// inside graph.MaxBlockLookup), then the folded ActorIDs in page order until the cap. A folded actor past the cap is
// unchecked and visible() counts it as suppressed. A failed or unwired lookup fails the whole page, the same policy
// as a failed caller-graph read: no row whose visibility is unknown is returned, and no token moves past rows that
// were never shown.
func (s *service) overflowBlockers(ctx context.Context, uid string, rows []Notification, snap graph.Snapshot) (*overflowBlocks, error) {
	return lookupOverflowBlockers(ctx, s.d.Blocks, uid, rows, snap)
}

// lookupOverflowBlockers is overflowBlockers on an explicit lookup (List and the unread badge share it).
func lookupOverflowBlockers(ctx context.Context, lookup BlockLookup, uid string, rows []Notification, snap graph.Snapshot) (*overflowBlocks, error) {
	known := func(id string) bool { return id == "" || snapHides(snap, id) }
	ov := &overflowBlocks{checked: map[string]bool{}}
	candidates := make([]string, 0, graph.MaxBlockLookup)
	add := func(id string) {
		if len(candidates) < graph.MaxBlockLookup && !known(id) && !ov.checked[id] {
			ov.checked[id] = true
			candidates = append(candidates, id)
		}
	}
	for _, n := range rows {
		add(n.Actor.UserID)
	}
	for _, n := range rows {
		for _, id := range n.ActorIDs {
			add(id)
		}
	}
	if len(candidates) == 0 {
		return ov, nil
	}
	if lookup == nil {
		return nil, logger.RedactErr(errors.New("notifications: caller blockedBy overflowed and no block lookup is wired"), uid)
	}
	blockers, err := lookup.BlockersAmong(ctx, uid, candidates)
	if err != nil {
		// The cause chain can name other users' graph documents: redact every uid the lookup was asked about.
		return nil, logger.RedactErr(fmt.Errorf("notifications: overflow block lookup: %w", err), append([]string{uid}, candidates...)...)
	}
	ov.blockers = blockers
	return ov, nil
}

// snapHides is the snapshot-only rule: the caller blocks or mutes id, or id is in the caller's blockedBy.
func snapHides(snap graph.Snapshot, id string) bool {
	return snap.Blocked[id] || snap.Muted[id] || snap.BlockedBy[id]
}

// visible applies the caller's social context at read time. A row is hidden when its displayed (most recent)
// actor is blocked or muted by the caller, or blocks the caller: the same set the timelines and thread replies
// use. For a collapsed row the other actors that are suppressed are subtracted from the count, and they are pruned
// from the returned row's ActorIDs (a fresh slice; the input's backing array is never written).
//
// The pruning is what keeps the wire count right: ToProto sends max(ActorCount, len(ActorIDs)), and that max must
// stay, because a row written before actorCount existed and folded once afterwards stores actorCount=1
// (Increment on a missing field) with more ids than that. With the hidden ids pruned, both terms of the max exclude
// the hidden actors, so neither can bring them back.
//
// ov is nil unless the caller's blockedBy overflowed; the snapshot alone then decides, with no read. When it is
// set, an actor the graph lookup reports as a blocker is hidden by the same rule, and a folded actor the lookup did
// not cover (past its cap) is treated as suppressed for the count: fail closed. The shown actor is always covered.
func visible(n Notification, snap graph.Snapshot, ov *overflowBlocks) (Notification, bool) {
	return pruneActors(n, hiddenRule(snap, ov))
}

// pruneActors applies one per-actor hide rule to a row: false when the displayed actor is hidden, else the row with the
// hidden folded actors pruned from ActorIDs (a fresh slice) and subtracted from ActorCount, floor 1 (see visible).
func pruneActors(n Notification, hidden func(id string) bool) (Notification, bool) {
	if hidden(n.Actor.UserID) {
		return n, false
	}
	suppressed := 0
	for _, id := range n.ActorIDs {
		if hidden(id) {
			suppressed++
		}
	}
	if suppressed > 0 {
		n.ActorCount = max(max(n.ActorCount, len(n.ActorIDs))-suppressed, 1)
		kept := make([]string, 0, len(n.ActorIDs)-suppressed)
		for _, id := range n.ActorIDs {
			if !hidden(id) {
				kept = append(kept, id)
			}
		}
		n.ActorIDs = kept
	}
	return n, true
}

// hiddenRule is the per-actor hide rule of one read: the snapshot alone, or with the overflow lookup's answer (a
// reported blocker, or an actor the lookup did not cover, is hidden).
func hiddenRule(snap graph.Snapshot, ov *overflowBlocks) func(id string) bool {
	if ov == nil {
		return func(id string) bool { return snapHides(snap, id) }
	}
	return func(id string) bool {
		return snapHides(snap, id) || ov.blockers[id] || (id != "" && !ov.checked[id])
	}
}

// sinceToken returns the token for the next refresh: the newest returned row trailing by SettleWindow, the old
// position when nothing new arrived, or "now - settle" for an empty first page.
func (s *service) sinceToken(uid string, rows []Notification, prev *cursor.Cursor, now time.Time) string {
	var c cursor.Cursor
	switch {
	case len(rows) > 0:
		c = cursor.Cursor{CreatedAt: rows[0].CreatedAt.Add(-SettleWindow), DocID: rows[0].ID}
	case prev != nil:
		c = *prev
	default:
		c = cursor.Cursor{CreatedAt: now.Add(-SettleWindow), DocID: "-"}
	}
	return cursor.EncodeAt(s.d.CursorKey, sinceBinding(uid), c, now)
}

// MarkSeenMinInterval is how recent a cached notificationsSeenAt must be for MarkSeen to be a no-op: a client
// that marks seen on every tab focus must not turn each focus into a write.
const MarkSeenMinInterval = 10 * time.Second

// MarkSeen: the profile is the account-status interceptor's cached entry. It writes the seen_at, but nothing when the cached seen_at is younger than MarkSeenMinInterval (the cached value is returned and
// nothing is evicted).
func (s *service) MarkSeen(ctx context.Context, uid, idempotencyKey string) (time.Time, error) {
	if !idempotency.KeyFormatValid(idempotencyKey) {
		return time.Time{}, apierr.Validation("idempotency_key", "idempotency_key must be 16-64 characters of [A-Za-z0-9_-]")
	}
	now := s.d.Now().UTC()
	if profiles, err := s.d.Directory.GetProfiles(ctx, []string{uid}); err == nil {
		// A seenAt slightly in the future (another instance's clock) is fresh too: now.Sub is negative.
		if seen := profiles[uid].NotificationsSeenAt; !seen.IsZero() && now.Sub(seen) < MarkSeenMinInterval {
			return seen, nil
		}
	}
	at := now.Truncate(time.Microsecond)
	if err := s.d.Seen.MarkNotificationsSeen(ctx, uid, at); err != nil {
		if errors.Is(err, identity.ErrNotFound) {
			return time.Time{}, apierr.New(connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_PROFILE_REQUIRED, "profile required")
		}
		return time.Time{}, logger.RedactErr(fmt.Errorf("notifications: mark seen: %w", err), uid)
	}
	// The cached profile carries the old seen_at and the cached unread count the old badge: evict both here.
	s.d.Directory.Forget(uid)
	return at, nil
}

// validateToken checks the registration token's shape. It never echoes the token.
func validateToken(token string) error {
	if token == "" || len(token) > MaxFCMTokenBytes {
		return apierr.Validation("fcm_token", "fcm_token must be 1-4096 bytes")
	}
	if strings.IndexFunc(token, func(r rune) bool { return r <= ' ' || r == 0x7f }) >= 0 {
		return apierr.Validation("fcm_token", "fcm_token must not contain whitespace or control characters")
	}
	return nil
}

// validateTimeout bounds the FCM dry run inside RegisterDevice's 5 s RPC deadline, leaving the transaction time.
const validateTimeout = 2 * time.Second

// checkToken runs the FCM dry run (N-5). Only a definitive rejection fails; every other outcome (timeout, quota,
// permission before the fcmSend role is applied, FCM down) logs a WARN with the fixed code and lets the
// registration through.
func (s *service) checkToken(ctx context.Context, uid, token string) error {
	if s.d.Validator == nil {
		return nil
	}
	vctx, cancel := context.WithTimeout(ctx, validateTimeout)
	defer cancel()
	err := s.d.Validator.Validate(vctx, token)
	switch {
	case err == nil:
		return nil
	case errors.Is(err, ErrTokenInvalid):
		slog.WarnContext(ctx, "notification_device_token_rejected", "uid_hash", logger.HashUID(uid))
		return apierr.Validation("fcm_token", "fcm_token is not a valid registration token")
	}
	code := "UNKNOWN"
	var pe *PushError
	if errors.As(err, &pe) {
		code = pe.Code
	}
	slog.WarnContext(ctx, "notification_token_validation_skipped", "uid_hash", logger.HashUID(uid), "fcm_code", code)
	return nil
}

// RegisterDevice: see FirestoreRepo.RegisterDevice for what is read and written (a fresh registration writes nothing).
// The FCM dry-run validation (N-5) is a Google API call, not a Firestore operation, and a token it rejects returns
// INVALID_ARGUMENT before the repo is touched.
func (s *service) RegisterDevice(ctx context.Context, uid string, in DeviceInput) error {
	if !idempotency.KeyFormatValid(in.IdempotencyKey) {
		return apierr.Validation("idempotency_key", "idempotency_key must be 16-64 characters of [A-Za-z0-9_-]")
	}
	if !deviceIDPattern.MatchString(in.DeviceID) {
		return apierr.Validation("device_id", "device_id must be 16-64 characters of [A-Za-z0-9_-]")
	}
	if err := validateToken(in.Token); err != nil {
		return err
	}
	if in.Platform != PlatformIOS && in.Platform != PlatformAndroid {
		return apierr.Validation("platform", "platform must be ios or android")
	}
	if err := s.checkToken(ctx, uid, in.Token); err != nil {
		return err
	}
	err := s.d.Repo.RegisterDevice(ctx, uid, Device{ID: in.DeviceID, Token: in.Token, Platform: in.Platform}, s.d.Now().UTC())
	if err != nil {
		return logger.RedactErr(fmt.Errorf("notifications: register device: %w", err), uid)
	}
	slog.InfoContext(ctx, "notification_device_registered", "uid_hash", logger.HashUID(uid), "platform", string(in.Platform))
	return nil
}

// UnregisterDevice removes the device and its token index (see FirestoreRepo.RemoveDevice).
func (s *service) UnregisterDevice(ctx context.Context, uid, idempotencyKey, deviceID string) error {
	if !idempotency.KeyFormatValid(idempotencyKey) {
		return apierr.Validation("idempotency_key", "idempotency_key must be 16-64 characters of [A-Za-z0-9_-]")
	}
	if !deviceIDPattern.MatchString(deviceID) {
		return apierr.Validation("device_id", "device_id must be 16-64 characters of [A-Za-z0-9_-]")
	}
	if err := s.d.Repo.RemoveDevice(ctx, uid, deviceID, ""); err != nil {
		return logger.RedactErr(fmt.Errorf("notifications: unregister device: %w", err), uid)
	}
	return nil
}
