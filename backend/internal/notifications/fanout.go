package notifications

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ids"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/pubsubpush"
)

// eventVersion is the wire version of the Pub/Sub message. Unknown versions are acknowledged and dropped.
const eventVersion = 1

// handlerBudget bounds one push delivery (Cloud Run request deadline is far above; Pub/Sub ack deadline is 10 s+).
const handlerBudget = 8 * time.Second

// wireEvent is the Pub/Sub message body (< 400 bytes with 10 recipients).
type wireEvent struct {
	V            int      `json:"v"`
	Type         Type     `json:"type"`
	ActorID      string   `json:"actorId"`
	RecipientIDs []string `json:"recipientIds"`
	PostID       string   `json:"postId,omitempty"`
	AtMillis     int64    `json:"at"`
}

func encodeEvent(e Event) ([]byte, error) {
	return json.Marshal(wireEvent{V: eventVersion, Type: e.Type, ActorID: e.ActorID, RecipientIDs: e.RecipientIDs, PostID: e.PostID, AtMillis: e.At.UnixMilli()})
}

// validateEvent reports why e can never become deliverable ("" when it is valid).
func validateEvent(e Event) string {
	switch {
	case !e.Type.Valid():
		return "unknown_type"
	case !ids.ValidUID(e.ActorID):
		return "invalid_actor"
	case len(e.RecipientIDs) == 0 || len(e.RecipientIDs) > MaxRecipientsPerEvent:
		return "invalid_recipients"
	case e.Type.needsPost() && !ids.ValidPostID(e.PostID):
		return "invalid_post"
	}
	for _, r := range e.RecipientIDs {
		if !ids.ValidUID(r) {
			return "invalid_recipient"
		}
	}
	return ""
}

// actorFromProfile is the denormalized actor snapshot stored on a row: the thumbnail avatar when there is one.
func actorFromProfile(p identity.Profile) Actor {
	a := Actor{UserID: p.UserID, Handle: p.Handle, DisplayName: p.DisplayName, AvatarURL: p.AvatarThumbURL, Verified: p.Verified}
	if a.AvatarURL == "" {
		a.AvatarURL = p.AvatarURL
	}
	return a
}

// notificationID is the deterministic row id (ADR-0017 D1): the natural key that makes redelivery a no-op.
func notificationID(t Type, actorID, postID string, at time.Time) string {
	switch t {
	case TypeFollow:
		return "follow_" + actorID
	case TypeMention, TypeReply, TypeQuote:
		return string(t) + "_" + postID
	case TypeRepost:
		return "repost_" + postID + "_" + actorID
	case TypeLike:
		return "like_" + postID + "_" + at.UTC().Format("2006010215")
	}
	return ""
}

// FanoutDeps are the handler's collaborators.
type FanoutDeps struct {
	Repo      Repo
	Directory Directory
	Social    Social
	Sender    PushSender
	Flags     FlagChecker
	Log       *slog.Logger
	ProjectID string
	// ReadOnly makes the handler acknowledge and drop every event (DEGRADED_MODE=readonly: no Firestore writes).
	ReadOnly bool
	Now      func() time.Time
}

// Fanout turns one event into rows and pushes. It is both the Pub/Sub push handler and, in local dev, called inline.
type Fanout struct {
	d FanoutDeps
}

// NewFanout builds the fan-out. Sender may be nil (no push, rows only).
func NewFanout(d FanoutDeps) *Fanout {
	if d.Now == nil {
		d.Now = time.Now
	}
	if d.Log == nil {
		d.Log = slog.Default()
	}
	return &Fanout{d: d}
}

// Outcome counts what one delivery did, for the one log line per delivery.
type Outcome struct {
	Created, Duplicate, Suppressed, Dropped, Pushed, Pruned int
}

// Deliver processes one event idempotently (ADR-0017 D3). A non-nil error means "retry": at least one recipient hit
// a transient failure; the recipients that succeeded are unaffected by the redelivery (natural keys).
//
// Budget: the actor and recipients are evicted from the profile cache first so the ACTIVE check is fresh (see
// below), then one GetAll: 1 + R reads (R <= 10 recipients; typically 2). Per recipient: graph snapshot (cached
// 60 s: 0-1 read, +1 when the recipient's blockedBy overflowed and the actor's graph is read), 1 write for the row
// (a duplicate costs 1 read), devices <= 5 reads; a like folded into an existing row costs 1 read and 1 write (0
// writes when that actor is already in the row: a redelivery is write-free).
//
// Right to delete (ADR-0017 D10): the fresh status read narrows the race with an account purge from "the profile
// cache TTL plus any redelivery delay" to the milliseconds between that read and the Create. It cannot be zero
// without a transaction across users/{uid} and the row, so a row written in that window outlives the purge
// until its 90-day TTL; the purge cannot find it by uid afterwards (the account-lifecycle backstop keys on
// users/{uid}, deleted last).
func (f *Fanout) Deliver(ctx context.Context, e Event) (Outcome, error) {
	var out Outcome
	if reason := validateEvent(e); reason != "" {
		out.Dropped++
		return out, nil
	}
	if f.d.ReadOnly {
		out.Dropped++
		return out, nil
	}
	recipients := make([]string, 0, len(e.RecipientIDs))
	seen := map[string]bool{}
	for _, r := range e.RecipientIDs {
		if r == e.ActorID || seen[r] {
			continue // self-actions never notify
		}
		seen[r] = true
		if f.d.Flags != nil && !f.d.Flags.Enabled(r, FlagName) {
			continue
		}
		recipients = append(recipients, r)
	}
	if len(recipients) == 0 {
		return out, nil
	}

	// A purge starts by flipping the account to DELETING, and a cached ACTIVE profile (60 s, longer across Pub/Sub
	// redeliveries) would let this delivery write into a subtree the purge has already swept. Evict, then read.
	f.d.Directory.Forget(append([]string{e.ActorID}, recipients...)...)
	profiles, err := f.d.Directory.GetProfiles(ctx, append([]string{e.ActorID}, recipients...))
	if err != nil {
		return out, fmt.Errorf("notifications: load profiles: %w", err)
	}
	ap, ok := profiles[e.ActorID]
	if !ok {
		out.Dropped++ // the actor is gone, suspended or being deleted: nothing to say
		return out, nil
	}
	actor := actorFromProfile(ap)

	// The collapse bucket comes from the event time, so a redelivery that crosses an hour boundary still folds into
	// the same row; createdAt is the commit time (D3), taken per recipient immediately before its write so that
	// slow work for an earlier recipient can never stamp a row older than its commit and slip behind a since token.
	bucketAt := e.At
	if bucketAt.IsZero() {
		bucketAt = f.d.Now()
	}
	type pending struct {
		uid string
		p   Push
	}
	var toPush []pending
	var createdFor []string
	var errs []error
	for _, r := range recipients {
		if _, ok := profiles[r]; !ok {
			out.Dropped++ // recipient is gone, suspended or being deleted: never write into their subtree
			continue
		}
		snap, err := f.d.Social.Snapshot(ctx, r)
		if err != nil {
			errs = append(errs, fmt.Errorf("snapshot: %w", err))
			continue
		}
		suppressed := snap.Blocked[e.ActorID] || snap.Muted[e.ActorID]
		if !suppressed {
			// graph.IsBlockedBy semantics: trust the recipient's blockedBy unless it overflowed its cap, then
			// also read the actor's own blocked list.
			blocked, err := f.blockedBy(ctx, r, e.ActorID, snap)
			if err != nil {
				errs = append(errs, fmt.Errorf("block check: %w", err))
				continue
			}
			suppressed = blocked
		}
		if suppressed {
			out.Suppressed++
			continue
		}
		now := f.d.Now().UTC().Truncate(time.Microsecond)
		n := Notification{
			ID: notificationID(e.Type, e.ActorID, e.PostID, bucketAt), Type: e.Type, Actor: actor,
			ActorIDs: []string{e.ActorID}, ActorCount: 1, PostID: e.PostID, CreatedAt: now,
		}
		created, err := f.d.Repo.Create(ctx, r, n)
		if err != nil {
			errs = append(errs, err)
			continue
		}
		if !created {
			out.Duplicate++
			if e.Type == TypeLike {
				if err := f.d.Repo.AddActor(ctx, r, n.ID, actor, now); err != nil {
					errs = append(errs, err)
				}
			}
			continue // no second push: the call that created the row owns the push
		}
		out.Created++
		createdFor = append(createdFor, r)
		toPush = append(toPush, pending{r, Push{Type: e.Type, NotificationID: n.ID, PostID: e.PostID, ActorID: e.ActorID}})
	}
	// The fresh status read above re-cached each recipient's unread count as of before this Create; evict only
	// that (no reads) so their next GetMe counts the new row instead of serving the old badge. The profile just
	// read stays cached: it is current and a full Forget would re-read it on the next request.
	if len(createdFor) > 0 {
		f.d.Directory.ForgetUnread(createdFor...)
	}
	// Every row is committed before the first push: FCM latency (up to the handler budget) must not delay a later
	// recipient's commit past the 5 s since-token settle window.
	for _, pd := range toPush {
		pushed, pruned := f.push(ctx, pd.uid, pd.p)
		out.Pushed += pushed
		out.Pruned += pruned
	}
	return out, errors.Join(errs...)
}

// blockedBy reports whether actor has blocked recipient. The recipient's snapshot (already fetched) answers
// unless its blockedBy set overflowed, in which case the actor's own graph is consulted (+1 read, cached).
func (f *Fanout) blockedBy(ctx context.Context, recipient, actor string, snap graph.Snapshot) (bool, error) {
	if snap.BlockedBy[actor] {
		return true, nil
	}
	if !snap.BlockedByOverflow {
		return false, nil
	}
	as, err := f.d.Social.Snapshot(ctx, actor)
	if err != nil {
		return false, err
	}
	return as.Blocked[recipient], nil
}

// push sends to every registered device of uid. Delivery is at most once and best effort: the row is the source of
// truth, and a push failure never fails the delivery (a redelivery would find the row and not push again anyway).
func (f *Fanout) push(ctx context.Context, uid string, p Push) (pushed, pruned int) {
	if f.d.Sender == nil {
		return 0, 0
	}
	devices, err := f.d.Repo.Devices(ctx, uid, MaxDevicesPerUser)
	if err != nil {
		f.d.Log.WarnContext(ctx, "notification_devices_failed", "uid_hash", logger.HashUID(uid), "err", logger.RedactErr(err, uid))
		return 0, 0
	}
	for _, d := range devices {
		err := f.d.Sender.Send(ctx, d.Token, p)
		switch {
		case err == nil:
			pushed++
		case errors.Is(err, ErrTokenUnregistered):
			if rerr := f.d.Repo.RemoveDevice(ctx, uid, d.ID, d.Token); rerr != nil {
				f.d.Log.WarnContext(ctx, "notification_device_prune_failed", "uid_hash", logger.HashUID(uid))
			} else {
				pruned++
			}
		default:
			code := "UNKNOWN"
			var pe *PushError
			if errors.As(err, &pe) {
				code = pe.Code
			}
			// A fixed FCM code only (never err.Error(), which may echo the token). The device is kept.
			f.d.Log.WarnContext(ctx, "notification_push_failed", "uid_hash", logger.HashUID(uid), "platform", string(d.Platform), "type", string(p.Type), "fcm_code", code)
		}
	}
	return pushed, pruned
}

// Handler is the Pub/Sub push endpoint (/internal/pubsub/notifications-fanout, behind the OIDC middleware).
// 2xx acknowledges (including malformed or permanently undeliverable messages, so they never reach the DLQ);
// 5xx asks Pub/Sub to redeliver, and after max_delivery_attempts (5) the message dead-letters.
func (f *Fanout) Handler() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		ctx := logger.WithTrace(r.Context(), logger.TraceFromRequest(r, f.d.ProjectID))
		d, err := pubsubpush.ReadDelivery(w, r)
		if err != nil {
			f.d.Log.WarnContext(ctx, "notification_event_dropped", append([]any{"reason", "malformed_envelope"}, logger.TraceAttrs(ctx)...)...)
			w.WriteHeader(http.StatusNoContent)
			return
		}
		var m wireEvent
		if err := json.Unmarshal(d.Data, &m); err != nil || m.V != eventVersion {
			f.d.Log.WarnContext(ctx, "notification_event_dropped", append([]any{"reason", "malformed_message", "message_id", d.MessageID}, logger.TraceAttrs(ctx)...)...)
			w.WriteHeader(http.StatusNoContent)
			return
		}
		ctx, cancel := context.WithTimeout(ctx, handlerBudget)
		defer cancel()
		ctx, counter := budget.WithCounter(ctx)
		started := f.d.Now()
		out, derr := f.Deliver(ctx, Event{Type: m.Type, ActorID: m.ActorID, RecipientIDs: m.RecipientIDs, PostID: m.PostID, At: time.UnixMilli(m.AtMillis)})
		attrs := append([]any{
			"event", "notification_delivery", "type", string(m.Type), "message_id", d.MessageID, "delivery_attempt", d.Attempt,
			"recipients", len(m.RecipientIDs), "created", out.Created, "duplicate", out.Duplicate, "suppressed", out.Suppressed,
			"dropped", out.Dropped, "pushed", out.Pushed, "pruned", out.Pruned,
			"fs_reads", counter.Reads(), "fs_writes", counter.Writes(), "fs_deletes", counter.Deletes(),
			"elapsed_ms", f.d.Now().Sub(started).Milliseconds(),
		}, logger.TraceAttrs(ctx)...)
		if derr != nil {
			f.d.Log.ErrorContext(ctx, "notification_delivery_failed", append(attrs, "outcome", "retry", "err", logger.RedactErr(derr, append([]string{m.ActorID}, m.RecipientIDs...)...).Error())...)
			http.Error(w, "retry", http.StatusInternalServerError)
			return
		}
		f.d.Log.InfoContext(ctx, "notification_delivery", append(attrs, "outcome", "ok")...)
		w.WriteHeader(http.StatusNoContent)
	})
}
