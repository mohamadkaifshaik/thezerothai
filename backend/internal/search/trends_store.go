package search

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"time"
	"unicode/utf8"

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
	// hiddenDocID is trends/hidden, the operator hide list (ADR-0028 note 2026-10-31 part 1): written only by opsctl, never by
	// the sweep, so a hide cannot race the whole-document Set of trends/current and runbook 4.2's delete cannot wipe it.
	hiddenDocID = "hidden"
	// maxHiddenTags caps the list; a raise needs a trends.tags index exemption (gate files).
	maxHiddenTags = 100
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
	// Load reads trends/current and trends/hidden in one GetAll: always 2 reads, missing documents included. The hide list
	// is returned as stored (keys). Used by GetTrends.
	Load(ctx context.Context) (*TrendsDoc, []string, error)
	// Hidden reads trends/hidden: always 1 read. Used by the sweep and `opsctl trends list`.
	Hidden(ctx context.Context) ([]string, error)
	// Hide adds TrendKey(tag) to the hide list; Unhide removes it. See HideResult for the cost.
	Hide(ctx context.Context, tag string) (HideResult, error)
	Unhide(ctx context.Context, tag string) (HideResult, error)
}

// Errors of Hide.
var (
	ErrEmptyTrendKey   = errors.New("search: the tag has no letters left after folding")
	ErrTrendKeyTooLong = errors.New("search: the tag is longer than a hashtag can be")
	ErrHiddenFull      = errors.New("search: the hide list is full (100 keys); unhide one first")
)

// HideResult is what Hide or Unhide did. Key is the folded key; Changed is true when the document was written; Count is
// the number of keys on the list afterwards. Hide and Unhide are transactions: 1 read, and 1 write only when Changed.
type HideResult struct {
	Key     string
	Changed bool
	Count   int
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

// hiddenDoc is trends/hidden: folded keys only, no uid, and it does not record who acted (the audit line of opsctl does).
type hiddenDoc struct {
	SchemaVersion int       `firestore:"schemaVersion"`
	Tags          []string  `firestore:"tags"`
	UpdatedAt     time.Time `firestore:"updatedAt"`
}

func (r *trendsRepo) hiddenRef() *firestore.DocumentRef {
	return r.fs.Collection(trendsCollection).Doc(hiddenDocID)
}

// decodeHidden reads the tags of a hide-list snapshot; a missing document is the empty list. The tags are read whatever
// the schema version: a newer revision only ever adds fields.
func decodeHidden(snap *firestore.DocumentSnapshot) ([]string, error) {
	if snap == nil || !snap.Exists() {
		return nil, nil
	}
	var d hiddenDoc
	if err := snap.DataTo(&d); err != nil {
		return nil, fmt.Errorf("search: decode trends/hidden: %w", err)
	}
	return d.Tags, nil
}

func (r *trendsRepo) Load(ctx context.Context) (*TrendsDoc, []string, error) {
	snaps, err := r.fs.GetAll(ctx, []*firestore.DocumentRef{r.ref(), r.hiddenRef()})
	budget.FromContext(ctx).AddReads(2) // a missing document is billed as one read too
	if err != nil {
		return nil, nil, fmt.Errorf("search: read trends: %w", err)
	}
	if len(snaps) != 2 {
		return nil, nil, fmt.Errorf("search: read trends: %d documents, want 2", len(snaps))
	}
	hidden, err := decodeHidden(snaps[1])
	if err != nil {
		return nil, nil, err
	}
	if !snaps[0].Exists() {
		return nil, hidden, nil
	}
	var d TrendsDoc
	if err := snaps[0].DataTo(&d); err != nil {
		return nil, nil, fmt.Errorf("search: decode trends/current: %w", err)
	}
	if d.SchemaVersion > trendsSchemaVersion {
		return nil, hidden, nil
	}
	return &d, hidden, nil
}

func (r *trendsRepo) Hidden(ctx context.Context) ([]string, error) {
	snap, err := r.hiddenRef().Get(ctx)
	budget.FromContext(ctx).AddReads(1)
	if err != nil {
		if status.Code(err) == codes.NotFound {
			return nil, nil
		}
		return nil, fmt.Errorf("search: read trends/hidden: %w", err)
	}
	return decodeHidden(snap)
}

// HideKey is TrendKey for an operator's input, refusing an empty key and one longer than a hashtag can be.
func HideKey(tag string) (string, error) {
	key := TrendKey(tag)
	switch {
	case key == "":
		return "", ErrEmptyTrendKey
	case utf8.RuneCountInString(key) > maxTrendKeyPoints:
		return "", ErrTrendKeyTooLong
	}
	return key, nil
}

// Hide: a transaction with 1 read and, when the key is new, 1 write (Set with MergeAll and ArrayUnion, so the document is
// created by the first hide and nothing else is touched). A repeat writes 0; at 100 keys it is refused with 0 writes.
func (r *trendsRepo) Hide(ctx context.Context, tag string) (HideResult, error) {
	key, err := HideKey(tag)
	if err != nil {
		return HideResult{}, err
	}
	res := HideResult{Key: key}
	err = r.fs.RunTransaction(ctx, func(ctx context.Context, tx *firestore.Transaction) error {
		res = HideResult{Key: key}
		snap, gerr := tx.Get(r.hiddenRef())
		budget.FromContext(ctx).AddReads(1)
		if gerr != nil && status.Code(gerr) != codes.NotFound {
			return gerr
		}
		var tags []string
		if gerr == nil {
			var derr error
			if tags, derr = decodeHidden(snap); derr != nil {
				return derr
			}
		}
		res.Count = len(tags)
		if slices.Contains(tags, key) {
			return nil
		}
		if len(tags) >= maxHiddenTags {
			return ErrHiddenFull
		}
		res.Changed, res.Count = true, len(tags)+1
		return tx.Set(r.hiddenRef(), map[string]any{
			"schemaVersion": trendsSchemaVersion,
			"tags":          firestore.ArrayUnion(key),
			"updatedAt":     firestore.ServerTimestamp,
		}, firestore.MergeAll)
	})
	if err != nil {
		if errors.Is(err, ErrHiddenFull) {
			return HideResult{Key: key, Count: res.Count}, err
		}
		return HideResult{}, fmt.Errorf("search: hide trend: %w", err)
	}
	if res.Changed {
		budget.FromContext(ctx).AddWrites(1)
	}
	return res, nil
}

// Unhide: a transaction with 1 read and, when the key is on the list, 1 write (Update with ArrayRemove). A missing
// document or key is success with 0 writes and creates nothing.
func (r *trendsRepo) Unhide(ctx context.Context, tag string) (HideResult, error) {
	key, err := HideKey(tag)
	if err != nil {
		return HideResult{}, err
	}
	res := HideResult{Key: key}
	err = r.fs.RunTransaction(ctx, func(ctx context.Context, tx *firestore.Transaction) error {
		res = HideResult{Key: key}
		snap, gerr := tx.Get(r.hiddenRef())
		budget.FromContext(ctx).AddReads(1)
		if gerr != nil {
			if status.Code(gerr) == codes.NotFound {
				return nil
			}
			return gerr
		}
		tags, derr := decodeHidden(snap)
		if derr != nil {
			return derr
		}
		res.Count = len(tags)
		if !slices.Contains(tags, key) {
			return nil
		}
		res.Changed, res.Count = true, len(tags)-1
		return tx.Update(r.hiddenRef(), []firestore.Update{
			{Path: "tags", Value: firestore.ArrayRemove(key)},
			{Path: "updatedAt", Value: firestore.ServerTimestamp},
		})
	})
	if err != nil {
		return HideResult{}, fmt.Errorf("search: unhide trend: %w", err)
	}
	if res.Changed {
		budget.FromContext(ctx).AddWrites(1)
	}
	return res, nil
}
