package posts

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// Create implements Repo for unit tests: an in-memory model of the CreatePost transaction that models the
// idempotency doc, the daily quota and the post counter.
func (r *fakeRepo) Create(ctx context.Context, p CreateParams) (CreateResult, error) {
	r.createCalls++
	if r.idem == nil {
		r.idem = map[string]fakeIdem{}
	}
	if rec, ok := r.idem[p.IdemKey]; ok {
		if rec.hash != p.RequestHash {
			return CreateResult{Attempts: 1}, ErrIdempotencyKeyReused
		}
		return CreateResult{ReplayID: rec.postID, Attempts: 1}, nil
	}
	if p.ParentID != "" {
		if _, ok := r.docs[p.ParentID]; !ok || r.parentGone {
			return CreateResult{Attempts: 1}, ErrParentGone
		}
	}
	if r.onCreate != nil {
		r.onCreate()
	}
	if r.createErr != nil {
		return CreateResult{Attempts: 1}, r.createErr
	}
	if r.quotaUsed >= p.QuotaLimit {
		return CreateResult{Attempts: 1}, apierr.New(connect.CodeResourceExhausted, commonv1.ErrorReason_ERROR_REASON_QUOTA_EXCEEDED, "daily limit reached").WithMeta("quota", "posts")
	}
	r.quotaUsed++
	r.nextID++
	id := fmt.Sprintf("%019d", r.nextID)
	post := p.Draft
	post.ID = id
	if post.ConversationID == "" {
		post.ConversationID = id
	}
	post.CreatedAt = time.UnixMilli(1_700_000_000_000 + r.nextID).UTC()
	if p.Poll != nil {
		post.Poll = p.Poll.newPoll(post.CreatedAt)
	}
	r.docs[id] = &post
	r.idem[p.IdemKey] = fakeIdem{hash: p.RequestHash, postID: id}
	r.postsCount++
	if p.ParentID != "" {
		r.docs[p.ParentID].ReplyCount++
	}
	r.lastCreate = p
	return CreateResult{Post: &post, Attempts: 1}, nil
}

// DeleteOwn implements Repo for unit tests: on success it decrements postsCount and removes the doc. A post that
// is absent models a lost Exists precondition (deleted=false).
func (r *fakeRepo) DeleteOwn(ctx context.Context, id, authorID string, stage ...func(store.Batch)) (bool, error) {
	r.deleteCalls++
	if r.deleteErr != nil {
		return false, r.deleteErr
	}
	if _, ok := r.docs[id]; !ok || r.deleteRace {
		delete(r.docs, id)
		return false, nil
	}
	delete(r.docs, id)
	r.postsCount--
	return true, nil
}

// Conversation implements Repo for unit tests: the conversation's posts in id order strictly after `after`,
// at most limit.
func (r *fakeRepo) Conversation(ctx context.Context, conversationID string, after *Position, limit int) ([]*Post, error) {
	r.conversationCalls++
	r.lastAfter, r.lastLimit = after, limit
	var ids []string
	for id, p := range r.docs {
		if p.ConversationID == conversationID && (after == nil || id > after.ID) {
			ids = append(ids, id)
		}
	}
	sort.Strings(ids)
	if len(ids) > limit {
		ids = ids[:limit]
	}
	out := make([]*Post, 0, len(ids))
	for _, id := range ids {
		out = append(out, r.docs[id])
	}
	return out, r.conversationErr
}

// AddReplyCount implements Repo for unit tests: bumps the parent when it exists.
func (r *fakeRepo) AddReplyCount(ctx context.Context, parentID string, delta int64) error {
	r.replyCountCalls++
	if r.replyCountErr != nil {
		return r.replyCountErr
	}
	if p, ok := r.docs[parentID]; ok {
		p.ReplyCount += delta
	}
	return nil
}

// AddQuoteCount implements Repo for unit tests: bumps the quoted post when it exists.
func (r *fakeRepo) AddQuoteCount(ctx context.Context, id string, delta int64) error {
	if p, ok := r.docs[id]; ok {
		p.QuoteCount += delta
	}
	return nil
}

type fakeIdem struct{ hash, postID string }

// fakeDirectory implements identity.Directory.
type fakeDirectory struct {
	profiles   map[string]identity.Profile
	handles    map[string]string
	resolved   [][]string
	profileErr error
	resolveErr error // ResolveHandles failure
	forgotten  []string
}

func (d *fakeDirectory) GetProfiles(_ context.Context, uids []string) (map[string]identity.Profile, error) {
	if d.profileErr != nil {
		return nil, d.profileErr
	}
	out := map[string]identity.Profile{}
	for _, u := range uids {
		if p, ok := d.profiles[u]; ok {
			out[u] = p
		}
	}
	return out, nil
}

func (d *fakeDirectory) LookupProfiles(ctx context.Context, uids []string) (map[string]identity.Profile, []string, error) {
	m, err := d.GetProfiles(ctx, uids)
	return m, nil, err
}

func (d *fakeDirectory) ResolveHandles(ctx context.Context, lowers []string) (map[string]string, error) {
	d.resolved = append(d.resolved, append([]string(nil), lowers...))
	if d.resolveErr != nil {
		return nil, d.resolveErr
	}
	out := map[string]string{}
	for _, h := range lowers {
		if u, ok := d.handles[h]; ok {
			out[h] = u
		}
	}
	return out, nil
}

func (d *fakeDirectory) Forget(uids ...string) { d.forgotten = append(d.forgotten, uids...) }

func (d *fakeDirectory) ForgetUnread(...string) {}

var _ identity.Directory = (*fakeDirectory)(nil)

// fakeGraph implements graph.Reader.
type fakeGraph struct {
	snap  graph.Snapshot
	snaps map[string]graph.Snapshot // per-uid override of snap
	calls int
	asked []string
	errs  map[string]error // per-uid Snapshot failure
}

func (g *fakeGraph) Snapshot(ctx context.Context, uid string) (graph.Snapshot, error) {
	g.calls++
	g.asked = append(g.asked, uid)
	if err := g.errs[uid]; err != nil {
		return graph.Snapshot{}, err
	}
	if s, ok := g.snaps[uid]; ok {
		return s, nil
	}
	return g.snap, nil
}

type recordingEvents struct {
	created []*Post
	deleted []string
}

func (e *recordingEvents) Created(_ context.Context, p *Post) { e.created = append(e.created, p) }
func (e *recordingEvents) Deleted(_ context.Context, postID, _ string) {
	e.deleted = append(e.deleted, postID)
}

// googleCtx is a caller context the verified-identity gate accepts.
func googleCtx(ctx context.Context, uid string) context.Context {
	return authn.WithClaims(ctx, authn.Claims{UID: uid, SignInProvider: authn.SignInProviderGoogle})
}

var errBoom = errors.New("boom")

// SearchHandles satisfies identity.Directory; this fake never serves handle-prefix search.
func (d *fakeDirectory) SearchHandles(context.Context, string, int) ([]identity.Profile, error) {
	return nil, nil
}
