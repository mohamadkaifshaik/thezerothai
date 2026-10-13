// attach.go is media's consumer-facing side for posts and identity: attaching READY images to a post inside the
// CreatePost transaction, and resolving an avatar for UpdateProfile. Both answer ErrNotReady for every failing
// case (missing, someone else's, wrong purpose, not READY, already attached): one answer, no oracle.
package media

import (
	"context"
	"errors"
	"fmt"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// Claim is the result of Attacher.LoadForPost: the published refs, in request order, and the documents to mark
// as attached to the post once its id is known.
type Claim struct {
	Refs []Ref
	refs []*firestore.DocumentRef
}

// Attach appends one write per image to b: media/{id}.postId = postID. Call it inside the same transaction that
// created the post. A post's images can therefore never be attached to a second post, and the post-delete job
// knows which post an image belonged to.
func (c *Claim) Attach(b store.Batch, postID string) {
	for _, r := range c.refs {
		b.Update(r, []firestore.Update{{Path: "postId", Value: postID}})
	}
}

// Attacher is what posts consumes (through its own consumer-side interface).
type Attacher interface {
	// LoadForPost reads ids inside tx and validates them for uid: every id must exist, be owned by uid, have
	// purpose POST, be READY or READY_UNSCREENED, and not be attached to a post yet. Reads: len(ids). It must be
	// called before the transaction's first write.
	LoadForPost(ctx context.Context, tx *firestore.Transaction, uid string, ids []string) (*Claim, error)
}

// Library implements Attacher and Reader over the media collection.
type Library struct {
	repo          *FirestoreRepo
	publicBaseURL string
}

// NewLibrary builds the consumer-facing side. publicBaseURL has no trailing slash.
func NewLibrary(repo *FirestoreRepo, publicBaseURL string) *Library {
	return &Library{repo: repo, publicBaseURL: publicBaseURL}
}

var (
	_ Attacher = (*Library)(nil)
	_ Reader   = (*Library)(nil)
)

func (l *Library) ref(d *Doc) Ref {
	return Ref{
		ID: d.ID, URL: l.publicBaseURL + "/" + d.PublicPath, ThumbURL: l.publicBaseURL + "/" + d.ThumbPath,
		Width: d.Width, Height: d.Height, Blurhash: d.Blurhash,
	}
}

// LoadForPost implements Attacher.
func (l *Library) LoadForPost(ctx context.Context, tx *firestore.Transaction, uid string, ids []string) (*Claim, error) {
	refs := make([]*firestore.DocumentRef, len(ids))
	for i, id := range ids {
		if !mediaIDPattern.MatchString(id) {
			return nil, ErrInvalidID
		}
		refs[i] = l.repo.ref(id)
	}
	snaps, err := tx.GetAll(refs)
	budget.FromContext(ctx).AddReads(int64(len(ids)))
	if err != nil {
		return nil, fmt.Errorf("media: load %d media for post: %w", len(ids), err)
	}
	c := &Claim{Refs: make([]Ref, 0, len(ids)), refs: refs}
	for _, s := range snaps {
		if !s.Exists() {
			return nil, ErrNotReady
		}
		d, err := decode(s)
		if err != nil {
			return nil, err
		}
		if d.OwnerID != uid || d.Purpose != string(PurposePost) || !d.Published() || d.PostID != "" {
			return nil, ErrNotReady
		}
		c.Refs = append(c.Refs, l.ref(d))
	}
	return c, nil
}

// ResolveAvatar implements Reader.
func (l *Library) ResolveAvatar(ctx context.Context, uid, mediaID string) (Ref, error) {
	if !mediaIDPattern.MatchString(mediaID) {
		return Ref{}, ErrNotReady
	}
	docs, err := l.repo.GetMany(ctx, []string{mediaID})
	if err != nil {
		return Ref{}, err
	}
	d, ok := docs[mediaID]
	if !ok || d.OwnerID != uid || d.Purpose != string(PurposeAvatar) || !d.Published() {
		return Ref{}, ErrNotReady
	}
	return l.ref(d), nil
}

// IsNotReady reports whether err is ErrNotReady or ErrInvalidID (both map to MEDIA_NOT_READY).
func IsNotReady(err error) bool { return errors.Is(err, ErrNotReady) || errors.Is(err, ErrInvalidID) }
