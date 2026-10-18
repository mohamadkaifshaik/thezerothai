// notifications_wiring.go adapts the producers (graph FollowEvents, posts PostEvents) to notifications.Emitter
// (ADR-0017 D2). The notifications module never imports graph or posts types, and they never import it: the
// adapters live here, in the composition root, like the lifecycle adapters.
package apiserver

import (
	"context"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/notifications"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
)

// emitterSlot is a late-bound notifications.Emitter. graph is constructed before the module that needs graph (the
// notifications fan-out reads graph.Reader), so graph receives the slot and Build fills it once, synchronously,
// before ListenAndServe (the same pattern as graph.SetDirectory). An empty slot drops events.
type emitterSlot struct {
	em notifications.Emitter
}

func (s *emitterSlot) emit(ctx context.Context, e notifications.Event) {
	if s.em == nil {
		return
	}
	// Best effort: Emit already logged a failure, and a lost notification must never fail a follow or a post.
	_ = s.em.Emit(ctx, e)
}

// followNotifier implements graph.FollowEvents: a created edge notifies the followee. Replays and no-ops never
// reach it (graph only calls Followed on OutcomeCreated).
type followNotifier struct{ slot *emitterSlot }

func (f followNotifier) Followed(ctx context.Context, followerUID, followeeUID string, at time.Time) {
	f.slot.emit(ctx, notifications.Event{
		Type: notifications.TypeFollow, ActorID: followerUID, RecipientIDs: []string{followeeUID}, At: at,
	})
}

// postNotifier implements posts.PostEvents: a created post notifies the users it mentions, and a QUOTE (P5,
// ADR-0018 D9) notifies the author of the quoted post. Replies (P3) will add their own Emit here when that slice
// wires reply notifications.
type postNotifier struct{ slot *emitterSlot }

var _ posts.PostEvents = postNotifier{}

func (p postNotifier) Created(ctx context.Context, post *posts.Post) {
	if post == nil {
		return
	}
	if post.Visibility != "" && post.Visibility != posts.VisibilityPublic {
		return // never announce a post that is not publicly visible (moderation hold, followers-only)
	}
	quoted := ""
	if post.Kind == posts.KindQuote && post.Embedded != nil && !post.Embedded.Unavailable {
		quoted = post.Embedded.Author.UserID
		if quoted != "" && quoted != post.AuthorID {
			p.slot.emit(ctx, notifications.Event{
				Type: notifications.TypeQuote, ActorID: post.AuthorID, RecipientIDs: []string{quoted}, PostID: post.ID, At: post.CreatedAt,
			})
		}
	}
	// A mention of the quoted author is covered by the quote notification: one row per user per post.
	recipients := make([]string, 0, len(post.Mentions))
	for _, m := range post.Mentions {
		if m.UserID != quoted {
			recipients = append(recipients, m.UserID)
		}
	}
	if len(recipients) == 0 {
		return
	}
	p.slot.emit(ctx, notifications.Event{
		Type: notifications.TypeMention, ActorID: post.AuthorID, RecipientIDs: recipients, PostID: post.ID, At: post.CreatedAt,
	})
}

// Deleted implements posts.PostEvents: notifications about a deleted post are not retracted (ADR-0017 D11); the TTL
// clears them.
func (postNotifier) Deleted(context.Context, string, string) {}
