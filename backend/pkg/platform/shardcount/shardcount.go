// Package shardcount is the distributed (sharded) counter: one logical counter on a parent document is spread over N
// shard documents at <parent>/<sub>/{0..N-1}, so its writes are not bound by Firestore's sustained limit of about one
// write per second on one document. A write increments ONE shard, picked at random; a read sums the N shards (one
// bounded GetAll); a rollup folds the sums into fields on the parent document, where every ordinary read finds them.
//
// The write is a store.Batch operation, so it joins the caller's atomic unit of work exactly like the single-field
// counter helpers it is meant to replace (posts' StageLikeCount, StageRepostCount, StageShareCount, StagePollVote and
// StagePollChange, posts' bumpCount, identity's followersCount): the caller opens the batch or transaction, the owning
// module stages its writes, the caller commits once. Several fields may move in one write (a poll vote moves
// poll.counts.<choice> and poll.total together), and field paths are firestore.FieldPath values, so numeric map keys
// ("poll", "counts", "2") are never parsed as dotted strings.
//
// One difference from those helpers matters to every call site: they Update the parent, which carries an implicit
// Exists precondition (a parent deleted in between fails the whole commit with NotFound). A shard write is a Set with
// MergeAll, because the shard document may not exist yet, so it carries NO precondition on the parent and creates the
// shard when it is missing. A caller that needs the parent to exist must check it itself (a read in its transaction,
// or the Update of another parent field in the same batch), and whoever deletes the parent deletes its shards too
// (StageDelete: N blind deletes, no read). A rollup that finds the parent gone should delete the shards it read.
//
// Costs: a write is 1 document write. A read is N document reads per parent. A rollup is N reads plus 1 write per parent.
package shardcount

import (
	"context"
	"errors"
	"fmt"
	"math/rand/v2"
	"strconv"
	"strings"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// MaxShards bounds N: a read costs N document reads per parent.
const MaxShards = 100

// MaxReadDocs bounds one Read: the number of shard documents (parents x N) one GetAll may fetch.
const MaxReadDocs = 500

// ErrTooManyDocs is returned by Read when parents x N is above MaxReadDocs; the caller pages its parents.
var ErrTooManyDocs = errors.New("shardcount: read exceeds MaxReadDocs shard documents")

// Counter is one sharded counter family: its shards live in the subcollection Sub of each parent, N of them. The zero
// value is not usable; build one with New. A Counter is immutable and safe for concurrent use.
type Counter struct {
	sub    string
	shards int
	intN   func(n int) int
}

// Option configures New.
type Option func(*Counter)

// WithIntN replaces the random source of the shard choice: intN(n) must return a value in [0, n). Tests pass a
// deterministic one; the default is math/rand/v2.IntN (not a secret, so not crypto/rand).
func WithIntN(intN func(n int) int) Option { return func(c *Counter) { c.intN = intN } }

// New returns the counter whose shards are <parent>/<sub>/{0..shards-1}. sub must be one path segment (no "/") and
// shards in 1..MaxShards. A family's sub and shards are part of its storage layout: changing shards later leaves the
// shards above the new N unread, so only ever grow it after a fold that reads the old N.
func New(sub string, shards int, opts ...Option) (Counter, error) {
	if sub == "" || strings.Contains(sub, "/") {
		return Counter{}, fmt.Errorf("shardcount: invalid subcollection %q", sub)
	}
	if shards < 1 || shards > MaxShards {
		return Counter{}, fmt.Errorf("shardcount: shards must be 1..%d (got %d)", MaxShards, shards)
	}
	c := Counter{sub: sub, shards: shards, intN: rand.IntN}
	for _, o := range opts {
		o(&c)
	}
	return c, nil
}

// MustNew is New for package-level families with constant arguments; it panics on an invalid one.
func MustNew(sub string, shards int, opts ...Option) Counter {
	c, err := New(sub, shards, opts...)
	if err != nil {
		panic(err)
	}
	return c
}

// Sub is the shard subcollection name (for lifecycle tables and collection-group scans).
func (c Counter) Sub() string { return c.sub }

// Shards is N.
func (c Counter) Shards() int { return c.shards }

// ShardRef is <parent>/<sub>/<i>, for i in 0..N-1.
func (c Counter) ShardRef(parent *firestore.DocumentRef, i int) *firestore.DocumentRef {
	return parent.Collection(c.sub).Doc(strconv.Itoa(i))
}

// Refs are the N shard refs of parent, in shard order.
func (c Counter) Refs(parent *firestore.DocumentRef) []*firestore.DocumentRef {
	out := make([]*firestore.DocumentRef, c.shards)
	for i := range out {
		out[i] = c.ShardRef(parent, i)
	}
	return out
}

// Pick is the shard the next write goes to: uniform in [0, N). A source that answers out of range is clamped into it.
func (c Counter) Pick() int {
	i := c.intN(c.shards)
	if i < 0 || i >= c.shards {
		i = ((i % c.shards) + c.shards) % c.shards
	}
	return i
}

// Delta is one field change of a write: Increment(N) on Field (a shard field, e.g. {"count"} or {"poll", "counts", "2"}).
type Delta struct {
	Field firestore.FieldPath
	N     int64
}

// StageIncrement appends ONE write to b: a Set with MergeAll on a random shard of parent that increments every delta's
// field (deltas on the same field are added up first; a zero total is still written, as Increment(0)). It returns the
// shard index used. There is no precondition on parent (see the package comment). With no deltas it appends nothing and
// returns -1.
func (c Counter) StageIncrement(b store.Batch, parent *firestore.DocumentRef, deltas ...Delta) int {
	if len(deltas) == 0 {
		return -1
	}
	i := c.Pick()
	b.Set(c.ShardRef(parent, i), incrementData(deltas), firestore.MergeAll)
	return i
}

// incrementData is the nested map of Increment transforms MergeAll writes: {"poll": {"counts": {"2": Increment(1)}}}.
func incrementData(deltas []Delta) map[string]any {
	sums := make(map[string]int64, len(deltas))
	paths := make(map[string]firestore.FieldPath, len(deltas))
	order := make([]string, 0, len(deltas))
	for _, d := range deltas {
		k := Key(d.Field)
		if _, seen := sums[k]; !seen {
			order = append(order, k)
			paths[k] = d.Field
		}
		sums[k] += d.N
	}
	root := map[string]any{}
	for _, k := range order {
		fp := paths[k]
		m := root
		for _, seg := range fp[:len(fp)-1] {
			next, ok := m[seg].(map[string]any)
			if !ok {
				next = map[string]any{}
				m[seg] = next
			}
			m = next
		}
		m[fp[len(fp)-1]] = firestore.Increment(sums[k])
	}
	return root
}

// StageDelete appends the N blind deletes of parent's shards (no read; a missing shard deletes nothing). The caller
// deleting parent stages them in the same unit of work, so a parent never leaves its shards behind.
func (c Counter) StageDelete(b store.Batch, parent *firestore.DocumentRef) {
	for _, ref := range c.Refs(parent) {
		b.Delete(ref)
	}
}

// Key is the Totals key of a field path: its segments joined by NUL (which no Firestore field name contains, so two
// different paths never share a key).
func Key(fp firestore.FieldPath) string { return strings.Join(fp, "\x00") }

// Totals are the summed shard values of one parent, by field (Key). A field no shard carries is absent (Get gives 0).
type Totals map[string]int64

// Get is the total of fp; 0 when no shard carries it.
func (t Totals) Get(fp firestore.FieldPath) int64 { return t[Key(fp)] }

// Sum adds up fields over shard documents' data (DocumentSnapshot.Data(); nil for a missing shard). A value that is
// not an integer (absent, or a different type) counts as 0. Pure: the unit of the read and the rollup math.
func Sum(docs []map[string]any, fields ...firestore.FieldPath) Totals {
	out := make(Totals, len(fields))
	for _, fp := range fields {
		k := Key(fp)
		var total int64
		for _, d := range docs {
			total += intAt(d, fp)
		}
		out[k] = total
	}
	return out
}

// intAt is the integer at fp inside a document's data, 0 when it is absent or not an integer.
func intAt(data map[string]any, fp firestore.FieldPath) int64 {
	var v any = data
	for _, seg := range fp {
		m, ok := v.(map[string]any)
		if !ok {
			return 0
		}
		v = m[seg]
	}
	switch n := v.(type) {
	case int64:
		return n
	case int:
		return int64(n)
	}
	return 0
}

// Getter is the read side Read needs: *firestore.Client and *firestore.Transaction both have it, so a sum can be read
// inside the caller's transaction too.
type Getter interface {
	GetAll(ctx context.Context, refs []*firestore.DocumentRef) ([]*firestore.DocumentSnapshot, error)
}

// Read sums fields over the shards of each parent in ONE GetAll (len(parents) x N reads, at most MaxReadDocs, else
// ErrTooManyDocs before any read). The answer is in parents' order. Missing shards count as 0, so a parent with no
// shard at all totals 0 (Read does not tell a missing parent from an unviewed one).
func (c Counter) Read(ctx context.Context, g Getter, parents []*firestore.DocumentRef, fields ...firestore.FieldPath) ([]Totals, error) {
	if len(parents) == 0 {
		return nil, nil
	}
	if len(parents)*c.shards > MaxReadDocs {
		return nil, ErrTooManyDocs
	}
	refs := make([]*firestore.DocumentRef, 0, len(parents)*c.shards)
	for _, p := range parents {
		refs = append(refs, c.Refs(p)...)
	}
	snaps, err := g.GetAll(ctx, refs)
	if err != nil {
		return nil, fmt.Errorf("shardcount: read %s shards: %w", c.sub, err)
	}
	if len(snaps) != len(refs) {
		return nil, fmt.Errorf("shardcount: read %s shards: got %d documents for %d refs", c.sub, len(snaps), len(refs))
	}
	return c.sumSnapshots(snaps, len(parents), fields), nil
}

// sumSnapshots splits GetAll's answer (parents x N, in Refs order) into one Totals per parent.
func (c Counter) sumSnapshots(snaps []*firestore.DocumentSnapshot, parents int, fields []firestore.FieldPath) []Totals {
	out := make([]Totals, parents)
	for p := range out {
		docs := make([]map[string]any, 0, c.shards)
		for _, s := range snaps[p*c.shards : (p+1)*c.shards] {
			if s != nil && s.Exists() {
				docs = append(docs, s.Data())
			}
		}
		out[p] = Sum(docs, fields...)
	}
	return out
}

// Fold maps a shard field to the parent field its total is written to (the rollup): {From: {"count"}, To: {"viewCount"}}.
type Fold struct {
	From firestore.FieldPath
	To   firestore.FieldPath
}

// FoldUpdates are the parent Updates of one rollup: each To set to the ABSOLUTE total of its From (never an Increment),
// so a redelivered or repeated rollup writes the same value again. A negative total is written as 0 (a counter that
// only counts never goes below zero; a decrementing family that may not either should fold through this too).
func FoldUpdates(t Totals, folds ...Fold) []firestore.Update {
	out := make([]firestore.Update, 0, len(folds))
	for _, f := range folds {
		out = append(out, firestore.Update{FieldPath: f.To, Value: max(t.Get(f.From), 0)})
	}
	return out
}

// StageFold appends the rollup Update of parent (FoldUpdates). The Update carries the implicit Exists precondition: a
// parent deleted since the read fails the commit with NotFound and nothing is written. No folds appends nothing.
func StageFold(b store.Batch, parent *firestore.DocumentRef, t Totals, folds ...Fold) {
	if len(folds) == 0 {
		return
	}
	b.Update(parent, FoldUpdates(t, folds...))
}
