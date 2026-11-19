// messaging_wiring.go adapts messaging's outbound seams to the rest of the monolith (D9): the
// composition root is the one place that knows both messaging.Events and notifications.Emitter.
package apiserver

import (
	"context"
	"errors"
	"time"

	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	"github.com/dzeroth/dzeroth/backend/internal/keys"
	"github.com/dzeroth/dzeroth/backend/internal/messaging"
	"github.com/dzeroth/dzeroth/backend/internal/notifications"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
)

// messageNotifier implements messaging.Events: a delivered message to an accepted, non-silent recipient becomes one
// push-only `message` event (generic push) that names the conversation and nothing else.
type messageNotifier struct{ slot *emitterSlot }

var _ messaging.Events = messageNotifier{}

func (n messageNotifier) MessageSent(ctx context.Context, e messaging.MessageEvent) {
	n.slot.emit(ctx, notifications.Event{
		Type: notifications.TypeMessage, ActorID: e.ActorUID, RecipientIDs: []string{e.RecipientUID},
		ConversationID: e.ConversationID, At: e.At,
	})
}

// postShareCheck implements messaging.PostShareCheck over posts.Engagement (shares design D3): the GetPost rules
// (Viewable; a REPOST id is checked on itself and on its original), then the card's rule on the original (ViewableMany:
// a block either way, so a caller who blocked the author, or a QUOTE's embedded author, gets the same NOT_FOUND as for
// an invisible post and never sends a post its own card would show as unavailable), then the RepostPost rule for a
// protected author (RefuseShare: PROTECTED_ACCOUNT for anyone but the author).
type postShareCheck struct{ posts posts.Engagement }

var _ messaging.PostShareCheck = postShareCheck{}

func (c postShareCheck) CheckShare(ctx context.Context, uid, postID string) (messaging.SharedPost, error) {
	p, err := c.viewable(ctx, uid, postID)
	if err != nil {
		return messaging.SharedPost{}, err
	}
	if p.Kind == posts.KindRepost {
		if p.RepostOfID == "" {
			return messaging.SharedPost{}, messaging.ErrPostNotVisible
		}
		if p, err = c.viewable(ctx, uid, p.RepostOfID); err != nil {
			return messaging.SharedPost{}, err
		}
	}
	card, err := c.posts.ViewableMany(ctx, uid, []string{p.ID})
	if err != nil {
		return messaging.SharedPost{}, err
	}
	if card[p.ID] == nil {
		return messaging.SharedPost{}, messaging.ErrPostNotVisible
	}
	if err := c.posts.RefuseShare(ctx, uid, p); err != nil {
		return messaging.SharedPost{}, err
	}
	return messaging.SharedPost{ID: p.ID, AuthorID: p.AuthorID}, nil
}

func (c postShareCheck) viewable(ctx context.Context, uid, postID string) (*posts.Post, error) {
	p, err := c.posts.Viewable(ctx, uid, postID)
	if errors.Is(err, posts.ErrNotFound) {
		return nil, messaging.ErrPostNotVisible
	}
	return p, err
}

// postCards implements messaging.PostCards: posts.Engagement.ViewableMany (the GetPost rules over the batch) and the live
// one-level card of each visible post (posts.CardOf). An id the reader may not see is absent.
type postCards struct {
	posts posts.Engagement
	now   func() time.Time
}

var _ messaging.PostCards = postCards{}

func (c postCards) Cards(ctx context.Context, readerUID string, postIDs []string) (map[string]*postsv1.EmbeddedPost, error) {
	got, err := c.posts.ViewableMany(ctx, readerUID, postIDs)
	if err != nil {
		return nil, err
	}
	now := time.Now()
	if c.now != nil {
		now = c.now()
	}
	out := make(map[string]*postsv1.EmbeddedPost, len(got))
	for id, p := range got {
		out[id] = posts.CardOf(p, now)
	}
	return out, nil
}

// lateKeyDevices implements messaging.Devices over keys.DeviceDirectory, bound after the key directory is built (keys is
// built after messaging: it asks the messaging send rules through messaging.Permission). Unbound, it fails: an mls_init
// is then an internal error, never a send whose welcome devices all read as inactive.
type lateKeyDevices struct{ dir keys.DeviceDirectory }

var _ messaging.Devices = (*lateKeyDevices)(nil)

var errKeyDevicesUnbound = errors.New("messaging: key directory not bound")

func (l *lateKeyDevices) ActiveDeviceIDs(ctx context.Context, uid string) ([]string, error) {
	if l.dir == nil {
		return nil, errKeyDevicesUnbound
	}
	return l.dir.ActiveDeviceIDs(ctx, uid)
}

// DeviceIDs is every registered device id of uid, active or not (the device_id ownership check of ListWelcomes and
// AckWelcomes). Unbound, it fails like ActiveDeviceIDs: an internal error, never "not one of your devices".
func (l *lateKeyDevices) DeviceIDs(ctx context.Context, uid string) ([]string, error) {
	if l.dir == nil {
		return nil, errKeyDevicesUnbound
	}
	return l.dir.DeviceIDs(ctx, uid)
}
