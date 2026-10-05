package posts

import (
	"context"
	"errors"
	"fmt"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
)

// Create implements Repo for unit tests: an in-memory model of the CreatePost transaction that charges the same
// reads and writes as repo_create.go (replay 1 read; first call 2 reads and 4 writes) and models the idempotency
// doc, the daily quota and the post counter.
func (r *fakeRepo) Create(ctx context.Context, p CreateParams) (CreateResult, error) {
	r.createCalls++
	c := budget.FromContext(ctx)
	if r.idem == nil {
		r.idem = map[string]fakeIdem{}
	}
	c.AddReads(1)
	if rec, ok := r.idem[p.IdemKey]; ok {
		if rec.hash != p.RequestHash {
			return CreateResult{Attempts: 1}, ErrIdempotencyKeyReused
		}
		return CreateResult{ReplayID: rec.postID, Attempts: 1}, nil
	}
	c.AddReads(1)
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
	post.ID, post.ConversationID = id, id
	post.CreatedAt = time.UnixMilli(1_700_000_000_000 + r.nextID).UTC()
	r.docs[id] = &post
	r.idem[p.IdemKey] = fakeIdem{hash: p.RequestHash, postID: id}
	r.postsCount++
	c.AddWrites(4)
	r.lastCreate = p
	return CreateResult{Post: &post, Attempts: 1}, nil
}

// DeleteOwn implements Repo for unit tests: 0 reads; on success 1 write (postsCount) + 1 delete. A post that is
// absent models a lost Exists precondition (deleted=false, nothing charged).
func (r *fakeRepo) DeleteOwn(ctx context.Context, id, authorID string) (bool, error) {
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
	c := budget.FromContext(ctx)
	c.AddWrites(1)
	c.AddDeletes(1)
	return true, nil
}

type fakeIdem struct{ hash, postID string }

// fakeDirectory implements identity.Directory with counted reads.
type fakeDirectory struct {
	profiles   map[string]identity.Profile
	handles    map[string]string
	resolved   [][]string
	profileErr error
	resolveErr error // ResolveHandles failure
	forgotten  []string
	cachedH    map[string]bool // handles already cached (cost 0 reads)
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
	var reads int64
	for _, h := range lowers {
		if !d.cachedH[h] {
			reads++
		}
		if u, ok := d.handles[h]; ok {
			out[h] = u
		}
	}
	budget.FromContext(ctx).AddReads(reads)
	return out, nil
}

func (d *fakeDirectory) Forget(uids ...string) { d.forgotten = append(d.forgotten, uids...) }

var _ identity.Directory = (*fakeDirectory)(nil)

// fakeGraph implements graph.Reader; each uncached Snapshot costs 1 read.
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
	budget.FromContext(ctx).AddReads(1)
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
