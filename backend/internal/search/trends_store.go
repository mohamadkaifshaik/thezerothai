package search

import (
	"context"
	"errors"
	"fmt"
	"time"

	"cloud.google.com/go/firestore"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
)

const (
	// trendsCollection and trendsDocID name the one document search owns (ADR-0028 D6): tags and counts only, no uid.
	trendsCollection = "trends"
	trendsDocID      = "current"
	// trendsSchemaVersion is the shape written today. A document with a higher version (a newer revision wrote it, then
	// this one was rolled back to) is read as "no list": the next refresh regenerates it.
	trendsSchemaVersion = 1
	// maxTrendItems keeps the document far below 100 KB (ADR-0028 D6: the top 100 tags).
	maxTrendItems = 100
)

// TrendItem is one ranked tag of the list: the tag body (lower-case NFC, no '#'), the posts that carried it and the
// distinct authors behind them. The authors are counted in memory and only the number is stored.
type TrendItem struct {
	Tag     string `firestore:"tag"`
	Posts   int64  `firestore:"posts"`
	Authors int64  `firestore:"authors"`
}

// TrendsDoc is trends/current (ADR-0028 D6). Items are in rank order. The window is [WindowStart, Watermark.CreatedAt]:
// the posts created since the previous run.
type TrendsDoc struct {
	SchemaVersion int         `firestore:"schemaVersion"`
	Items         []TrendItem `firestore:"items"`
	WindowStart   time.Time   `firestore:"windowStart"`
	// Watermark is the position of the newest post the run read; the next run resumes strictly after it.
	Watermark    Watermark `firestore:"watermark"`
	ComputedAt   time.Time `firestore:"computedAt"`
	PostsScanned int       `firestore:"postsScanned"`
	// Backlog is true when the run stopped at TRENDS_MAX_POSTS_PER_RUN with posts left; the next run resumes at once.
	Backlog bool `firestore:"backlog"`
}

// Watermark is the stored form of a posts.Position.
type Watermark struct {
	At time.Time `firestore:"at"`
	ID string    `firestore:"id"`
}

func (w Watermark) position() posts.Position { return posts.Position{CreatedAt: w.At, ID: w.ID} }

// TrendsStore is the Firestore seam of the module (the repo of the one collection it owns). Get returns (nil, nil) when
// there is no usable document. Reads and writes are charged to the context's budget.Counter by the implementation.
type TrendsStore interface {
	// Get reads trends/current: always 1 read, a missing document included.
	Get(ctx context.Context) (*TrendsDoc, error)
	// Put replaces trends/current in 1 write (Set, no merge: the document holds no user data, so a write racing an
	// eraser cannot resurrect anything).
	Put(ctx context.Context, doc *TrendsDoc) error
}

type trendsRepo struct{ fs *firestore.Client }

// NewTrendsRepo returns the Firestore TrendsStore.
func NewTrendsRepo(fs *firestore.Client) TrendsStore { return &trendsRepo{fs: fs} }

func (r *trendsRepo) ref() *firestore.DocumentRef {
	return r.fs.Collection(trendsCollection).Doc(trendsDocID)
}

func (r *trendsRepo) Get(ctx context.Context) (*TrendsDoc, error) {
	snap, err := r.ref().Get(ctx)
	budget.FromContext(ctx).AddReads(1) // a missing document is billed as one read too
	if err != nil {
		if status.Code(err) == codes.NotFound {
			return nil, nil
		}
		return nil, fmt.Errorf("search: read trends/current: %w", err)
	}
	var d TrendsDoc
	if err := snap.DataTo(&d); err != nil {
		return nil, fmt.Errorf("search: decode trends/current: %w", err)
	}
	if d.SchemaVersion > trendsSchemaVersion {
		return nil, nil
	}
	return &d, nil
}

func (r *trendsRepo) Put(ctx context.Context, doc *TrendsDoc) error {
	if doc == nil {
		return errors.New("search: nil trends document")
	}
	d := *doc
	d.SchemaVersion = trendsSchemaVersion
	if d.Items == nil {
		d.Items = []TrendItem{}
	}
	if _, err := r.ref().Set(ctx, &d); err != nil {
		return fmt.Errorf("search: write trends/current: %w", err)
	}
	budget.FromContext(ctx).AddWrites(1)
	return nil
}
