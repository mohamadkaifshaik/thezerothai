package notifications

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"time"

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
	case e.Type.needsPost() && !validPostID(e.PostID):
		return "invalid_post"
	}
	for _, r := range e.RecipientIDs {
		if !ids.ValidUID(r) {
			return "invalid_recipient"
		}
	}
	return ""
}

func validPostID(id string) bool {
	if len(id) != 19 {
		return false
	}
	for _, c := range id {
		if c < '0' || c > '9' {
			return false
		}
	}
	return true
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
// Budget per recipient: users batch for actor+recipients (cached: 0-11 reads, one GetAll), graph snapshot of the
// recipient (cached 60 s: 0-1 read), 1 write for the row (a duplicate costs 1 read), devices <= 5 reads, a like
// folded into an existing row +1 write.
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

	profiles, err := f.d.Directory.GetProfiles(ctx, append([]string{e.ActorID}, recipients...))
	if err != nil {
		return out, fmt.Errorf("notifications: load profiles: %w", err)
	}
	ap, ok := profiles[e.ActorID]
	if !ok {
		out.Dropped++ // the actor is gone, suspended or being deleted: nothing to say
		return out, nil
	}
	actor := Actor{UserID: ap.UserID, Handle: ap.Handle, DisplayName: ap.DisplayName, AvatarURL: ap.AvatarThumbURL, Verified: ap.Verified}
	if actor.AvatarURL == "" {
		actor.AvatarURL = ap.AvatarURL
	}

	now := f.d.Now().UTC().Truncate(time.Microsecond)
	// The collapse bucket comes from the event time, so a redelivery that crosses an hour boundary still folds into
	// the same row; createdAt is the commit time (D3).
	bucketAt := e.At
	if bucketAt.IsZero() {
		bucketAt = now
	}
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
		if snap.Blocked[e.ActorID] || snap.Muted[e.ActorID] || snap.BlockedBy[e.ActorID] {
			out.Suppressed++
			continue
		}
		n := Notification{
			ID: notificationID(e.Type, e.ActorID, e.PostID, bucketAt), Type: e.Type, Actor: actor,
			ActorIDs: []string{e.ActorID}, PostID: e.PostID, CreatedAt: now,
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
		pushed, pruned := f.push(ctx, r, Push{Type: e.Type, NotificationID: n.ID, PostID: e.PostID, ActorID: e.ActorID})
		out.Pushed += pushed
		out.Pruned += pruned
	}
	return out, errors.Join(errs...)
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
			f.d.Log.WarnContext(ctx, "notification_push_failed", "uid_hash", logger.HashUID(uid), "platform", string(d.Platform), "type", string(p.Type))
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
