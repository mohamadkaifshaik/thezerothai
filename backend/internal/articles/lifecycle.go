package articles

import (
	"context"
	"encoding/json"
	"io"

	"cloud.google.com/go/firestore"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// Lifecycle removes and exports all owned drafts and bodies, independent of
// feature availability. Root posts and claimed media use their existing steps.
type Lifecycle struct{ client *firestore.Client }

func NewLifecycle(client *firestore.Client) *Lifecycle { return &Lifecycle{client} }
func (*Lifecycle) Name() string                        { return "articles" }
func (l *Lifecycle) Run(ctx context.Context, uid string, _ []byte) ([]byte, bool, error) {
	docs, err := l.client.Collection("articles").Where("authorId", "==", uid).Limit(100).Documents(ctx).GetAll()
	if err != nil {
		return nil, false, err
	}
	if len(docs) == 0 {
		return nil, true, nil
	}
	b := store.NewFirestoreBatch(l.client)
	for _, d := range docs {
		b.Delete(d.Ref)
	}
	if err = b.Commit(ctx); err != nil {
		return nil, false, err
	}
	return nil, len(docs) < 100, nil
}
func (l *Lifecycle) WriteSection(ctx context.Context, uid string, w io.Writer) error {
	if _, err := io.WriteString(w, "["); err != nil {
		return err
	}
	after := ""
	first := true
	for {
		q := l.client.Collection("articles").Where("authorId", "==", uid).OrderBy(firestore.DocumentID, firestore.Asc).Limit(100)
		if after != "" {
			q = q.StartAfter(after)
		}
		docs, err := q.Documents(ctx).GetAll()
		if err != nil {
			return err
		}
		for _, d := range docs {
			var a record
			if err = d.DataTo(&a); err != nil {
				return err
			}
			a.ID = d.Ref.ID
			if !first {
				if _, err = io.WriteString(w, ","); err != nil {
					return err
				}
			}
			first = false
			// Exports contain user content, never publication replay keys.
			value := map[string]any{"articleId": a.ID, "title": a.Title, "bodyJson": a.Body, "coverMediaId": a.CoverMediaID, "postId": a.PostID, "revision": a.Revision, "updatedAt": a.UpdatedAt}
			if err = json.NewEncoder(w).Encode(value); err != nil {
				return err
			}
		}
		if len(docs) < 100 {
			break
		}
		after = docs[len(docs)-1].Ref.ID
	}
	_, err := io.WriteString(w, "]")
	return err
}
