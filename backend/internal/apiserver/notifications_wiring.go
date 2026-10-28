// notifications_wiring.go adapts the producers (graph FollowEvents, posts PostEvents) to notifications.Emitter
// (ADR-0017 D2). The notifications module never imports graph or posts types, and they never import it: the
// adapters live here, in the composition root, like the lifecycle adapters.
package apiserver

import (
	"context"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/notifications"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/cache"
)

// maxTrackedAccountAges bounds the per-instance createdAt memo (about 40 bytes per entry plus the key).
const maxTrackedAccountAges = 10_000

// accountAges remembers recently authenticated accounts' createdAt so the notifications recipient cap can tell a new
// account at emit time with 0 reads (N-1). Entries expire after an hour; the verdict is recomputed from createdAt
// on every call, so an account ages out of the new-account tier on time.
type accountAges struct {
	window time.Duration
	m      *cache.LRU[string, time.Time]
	now    func() time.Time
}

func newAccountAges(window time.Duration) *accountAges {
	return &accountAges{window: window, m: cache.New[string, time.Time](maxTrackedAccountAges, time.Hour), now: time.Now}
}

// Record stores uid's createdAt (a zero time is ignored).
func (a *accountAges) Record(uid string, createdAt time.Time) {
	if !createdAt.IsZero() {
		a.m.Set(uid, createdAt)
	}
}

// IsNew reports whether uid is younger than the window; known is false when the account was not recorded.
func (a *accountAges) IsNew(uid string) (isNew, known bool) {
	t, ok := a.m.Get(uid)
	if !ok {
		return false, false
	}
	return a.now().Sub(t) < a.window, true
}

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

// postNotifier implements posts.PostEvents: a created post notifies the users it mentions, a QUOTE (P5, ADR-0018
// D9) notifies the author of the quoted post, and a REPLY (P3, ADR-0017 T10) notifies the parent post's author
// (Post.ReplyToAuthorID, already read by the reply validation: 0 extra reads). Precedence, one row per user per
// post: quote/reply beats mention, so a mention of the quoted or parent author is dropped from the mention event.
type postNotifier struct{ slot *emitterSlot }

var _ posts.PostEvents = postNotifier{}

func (p postNotifier) Created(ctx context.Context, post *posts.Post) {
	if post == nil {
		return
	}
	if post.Visibility != "" && post.Visibility != posts.VisibilityPublic {
		return // never announce a post that is not publicly visible (moderation hold, followers-only)
	}
	covered := "" // the one user a quote or reply of this post already notifies
	typ := notifications.Type("")
	switch {
	case post.Kind == posts.KindQuote && post.Embedded != nil && !post.Embedded.Unavailable:
		covered, typ = post.Embedded.Author.UserID, notifications.TypeQuote
	case post.IsReply && post.ReplyToAuthorID != "":
		covered, typ = post.ReplyToAuthorID, notifications.TypeReply // a reply is never a quote
	}
	if covered != "" && covered != post.AuthorID { // quoting or replying to yourself notifies nobody
		p.slot.emit(ctx, notifications.Event{
			Type: typ, ActorID: post.AuthorID, RecipientIDs: []string{covered}, PostID: post.ID, At: post.CreatedAt,
		})
	}
	// A mention of the quoted or parent author is covered by that notification: one row per user per post.
	recipients := make([]string, 0, len(post.Mentions))
	for _, m := range post.Mentions {
		if m.UserID != covered {
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

// FollowRequested and FollowRequestAccepted are no-ops until W3-31 maps them to the follow_request and follow_accepted
// notification types (ADR-0025 D10); declared now so graph.FollowEvents compiles with its two new methods.
func (f followNotifier) FollowRequested(context.Context, string, string, time.Time) {}

func (f followNotifier) FollowRequestAccepted(context.Context, string, string, time.Time) {}
