package posts

import (
	"context"
	"errors"
	"reflect"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

const (
	pidMine  = "0000000000000000101"
	pidOther = "0000000000000000102"
	otherUID = "uid-zed"
)

// deleteEnv seeds testUID's post pidMine and otherUID's post pidOther.
func newDeleteEnv() *createEnv {
	e := newCreateEnv()
	mine, other := post(pidMine, testUID), post(pidOther, otherUID)
	other.Author = AuthorSnapshot{UserID: otherUID, Handle: "zed"}
	e.repo.docs[pidMine], e.repo.docs[pidOther] = mine, other
	e.dir.profiles[otherUID] = identity.Profile{UserID: otherUID, Handle: "zed", Status: identity.AccountStatusActive}
	return e
}

func (e *createEnv) del(id string) (*budget.Counter, string, error) {
	ctx, info := logger.WithRequestInfo(googleCtx(context.Background(), testUID))
	ctx, c := budget.WithCounter(ctx)
	err := e.svc.Delete(ctx, testUID, key1, id)
	out, _ := info.Get(fieldOutcome)
	s, _ := out.(string)
	return c, s, err
}

func TestDelete_Own(t *testing.T) {
	e := newDeleteEnv()
	p := e.repo.docs[pidMine]
	e.cache.SetPost(p)
	e.cache.StoreAuthorRecent(testUID, []*Post{p}, false, time.Now())

	c, outcome, err := e.del(pidMine)
	if err != nil {
		t.Fatal(err)
	}
	if outcome != outcomeDeleted || c.Reads() != 0 || c.Writes() != 1 || c.Deletes() != 1 {
		t.Fatalf("outcome=%s reads=%d writes=%d deletes=%d, want deleted 0/1/1 (warm)", outcome, c.Reads(), c.Writes(), c.Deletes())
	}
	if _, ok := e.cache.GetPost(pidMine); ok {
		t.Fatal("posts cache not evicted")
	}
	if r, ok := e.cache.AuthorRecent(testUID); !ok || len(r.Posts) != 0 {
		t.Fatalf("author-recent not updated: %v %v", r, ok)
	}
	if !reflect.DeepEqual(e.dir.forgotten, []string{testUID}) || !reflect.DeepEqual(e.events.deleted, []string{pidMine}) {
		t.Fatalf("forgotten=%v deleted events=%v", e.dir.forgotten, e.events.deleted)
	}
	if e.repo.postsCount != -1 {
		t.Fatalf("postsCount delta = %d", e.repo.postsCount)
	}

	// Second delete: the post is gone, 1 read (cache evicted), 0 writes, success.
	c, outcome, err = e.del(pidMine)
	if err != nil || outcome != outcomeNoop || c.Reads() != 1 || c.Writes() != 0 || c.Deletes() != 0 {
		t.Fatalf("repeat: err=%v outcome=%s reads=%d writes=%d deletes=%d", err, outcome, c.Reads(), c.Writes(), c.Deletes())
	}
	if e.repo.deleteCalls != 1 {
		t.Fatalf("deleteCalls = %d, want 1", e.repo.deleteCalls)
	}
}

func TestDelete_ColdOwnIsOneRead(t *testing.T) {
	e := newDeleteEnv()
	c, outcome, err := e.del(pidMine)
	if err != nil || outcome != outcomeDeleted || c.Reads() != 1 || c.Writes() != 1 || c.Deletes() != 1 {
		t.Fatalf("err=%v outcome=%s reads=%d writes=%d deletes=%d", err, outcome, c.Reads(), c.Writes(), c.Deletes())
	}
}

func TestDelete_EveryNonOwnCaseLooksTheSame(t *testing.T) {
	tests := []struct {
		name    string
		id      string
		outcome string
	}{
		{"another user's post", pidOther, outcomeNoopNotOwn},
		{"unknown id", "0000000000000000999", outcomeNoop},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := newDeleteEnv()
			c, outcome, err := e.del(tt.id)
			if err != nil {
				t.Fatalf("err = %v, want success", err)
			}
			if outcome != tt.outcome || c.Reads() != 1 || c.Writes() != 0 || c.Deletes() != 0 || e.repo.deleteCalls != 0 {
				t.Fatalf("outcome=%s reads=%d writes=%d deletes=%d batch calls=%d", outcome, c.Reads(), c.Writes(), c.Deletes(), e.repo.deleteCalls)
			}
			if tt.id == pidOther {
				if _, ok := e.repo.docs[pidOther]; !ok {
					t.Fatal("another user's post was deleted")
				}
			}
			if len(e.dir.forgotten) != 0 || len(e.events.deleted) != 0 {
				t.Fatal("no-op must not forget or publish")
			}
		})
	}
}

func TestDelete_LostRaceIsASuccessWithNoWrites(t *testing.T) {
	e := newDeleteEnv()
	e.repo.deleteRace = true
	c, outcome, err := e.del(pidMine)
	if err != nil || outcome != outcomeNoop || c.Writes() != 0 || c.Deletes() != 0 {
		t.Fatalf("err=%v outcome=%s writes=%d deletes=%d", err, outcome, c.Writes(), c.Deletes())
	}
	if len(e.events.deleted) != 0 || len(e.dir.forgotten) != 0 {
		t.Fatal("the loser must not publish or forget")
	}
}

func TestDelete_Validation(t *testing.T) {
	tests := []struct {
		name, id, key, field string
	}{
		{"short id", "abc", key1, "post_id"},
		{"empty id", "", key1, "post_id"},
		{"20 digits", "00000000000000000001", key1, "post_id"},
		{"letters", "000000000000000010a", key1, "post_id"},
		{"bad key", pidMine, "short", "idempotency_key"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := newDeleteEnv()
			ctx, c := budget.WithCounter(googleCtx(context.Background(), testUID))
			err := e.svc.Delete(ctx, testUID, tt.key, tt.id)
			ae := wantAPIError(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION)
			if ae.Metadata["field"] != tt.field {
				t.Fatalf("field = %q, want %q", ae.Metadata["field"], tt.field)
			}
			if c.Reads() != 0 || e.repo.getAllCalls != 0 {
				t.Fatal("validation must cost 0 reads")
			}
		})
	}
}

func TestDelete_StorageErrorsAreWrapped(t *testing.T) {
	e := newDeleteEnv()
	e.repo.deleteErr = errBoom
	_, _, err := e.del(pidMine)
	if !errors.Is(err, errBoom) {
		t.Fatalf("err = %v", err)
	}
	e = newDeleteEnv()
	e.repo.getAllErr = errBoom
	if _, _, err = e.del(pidMine); !errors.Is(err, errBoom) {
		t.Fatalf("err = %v", err)
	}
}

// ---- GetForViewer ----

func (e *createEnv) get(id string) (*budget.Counter, *Post, error) {
	ctx, c := budget.WithCounter(googleCtx(context.Background(), testUID))
	p, err := e.svc.GetForViewer(ctx, testUID, id)
	return c, p, err
}

func wantPostNotFound(t *testing.T, err error) {
	t.Helper()
	ae := wantAPIError(t, err, connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED)
	if ae.Message != "post not found" || len(ae.Metadata) != 0 {
		t.Fatalf("message=%q meta=%v", ae.Message, ae.Metadata)
	}
}

// The unit budgets count what the posts service itself reads (post + graph); the author profile is read through
// identity.Directory, whose cost the emulator test in service_delete_integration_test.go measures end to end.
func TestGetForViewer(t *testing.T) {
	overflow := graph.Snapshot{BlockedByOverflow: true}
	tests := []struct {
		name      string
		mutate    func(e *createEnv)
		wantFound bool
		wantReads int64
	}{
		{"public post", func(*createEnv) {}, true, 2},
		{"own post skips the graph", func(e *createEnv) { e.repo.docs[pidOther].AuthorID = testUID }, true, 1},
		{"missing", func(e *createEnv) { delete(e.repo.docs, pidOther) }, false, 1},
		{"author suspended or deleting or gone", func(e *createEnv) { delete(e.dir.profiles, otherUID) }, false, 1},
		{"author blocked the caller", func(e *createEnv) {
			e.graph.snaps = map[string]graph.Snapshot{testUID: {BlockedBy: map[string]bool{otherUID: true}}}
		}, false, 2},
		{"caller blocked the author", func(e *createEnv) {
			e.graph.snaps = map[string]graph.Snapshot{testUID: {Blocked: map[string]bool{otherUID: true}}}
		}, true, 2},
		{"caller muted the author", func(e *createEnv) {
			e.graph.snaps = map[string]graph.Snapshot{testUID: {Muted: map[string]bool{otherUID: true}}}
		}, true, 2},
		{"overflow and author blocked the caller", func(e *createEnv) {
			e.graph.snaps = map[string]graph.Snapshot{testUID: overflow, otherUID: {Blocked: map[string]bool{testUID: true}}}
		}, false, 3},
		{"overflow and no block", func(e *createEnv) {
			e.graph.snaps = map[string]graph.Snapshot{testUID: overflow}
		}, true, 3},
		{"followers-only post, not following", func(e *createEnv) { e.repo.docs[pidOther].Visibility = VisibilityFollowers }, false, 2},
		{"followers-only post, following", func(e *createEnv) {
			e.repo.docs[pidOther].Visibility = VisibilityFollowers
			e.graph.snaps = map[string]graph.Snapshot{testUID: {Following: map[string]bool{otherUID: true}}}
		}, true, 2},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := newDeleteEnv()
			tt.mutate(e)
			c, p, err := e.get(pidOther)
			if c.Reads() != tt.wantReads || c.Writes() != 0 || c.Deletes() != 0 {
				t.Fatalf("reads=%d writes=%d, want reads=%d", c.Reads(), c.Writes(), tt.wantReads)
			}
			if tt.wantFound {
				if err != nil || p == nil || p.ID != pidOther {
					t.Fatalf("p=%v err=%v", p, err)
				}
				return
			}
			wantPostNotFound(t, err)
		})
	}
}

// TestGetForViewer_NotFoundIsByteIdentical: missing, hidden and blocked posts produce the same error.
func TestGetForViewer_NotFoundIsByteIdentical(t *testing.T) {
	var errs []error
	for _, mutate := range []func(e *createEnv){
		func(e *createEnv) { delete(e.repo.docs, pidOther) },
		func(e *createEnv) { delete(e.dir.profiles, otherUID) },
		func(e *createEnv) {
			e.graph.snaps = map[string]graph.Snapshot{testUID: {BlockedBy: map[string]bool{otherUID: true}}}
		},
	} {
		e := newDeleteEnv()
		mutate(e)
		_, _, err := e.get(pidOther)
		errs = append(errs, err)
	}
	for _, err := range errs[1:] {
		a, b := errs[0].(*apierr.Error), err.(*apierr.Error)
		if a.Code != b.Code || a.Reason != b.Reason || a.Message != b.Message || !reflect.DeepEqual(a.Metadata, b.Metadata) {
			t.Fatalf("not byte-identical: %+v vs %+v", a, b)
		}
	}
}

func TestGetForViewer_WarmPostCache(t *testing.T) {
	e := newDeleteEnv()
	e.cache.SetPost(e.repo.docs[pidOther])
	c, _, err := e.get(pidOther)
	if err != nil {
		t.Fatal(err)
	}
	// The fake directory is uncharged and the fake graph charges every call (the real ones are cache-first, 0
	// warm); the posts module's own read is cached, so only the graph snapshot shows.
	if e.repo.getAllCalls != 0 || c.Reads() != 1 {
		t.Fatalf("getAllCalls=%d reads=%d", e.repo.getAllCalls, c.Reads())
	}
}

func TestGetForViewer_Validation(t *testing.T) {
	e := newDeleteEnv()
	c, _, err := e.get("abc")
	ae := wantAPIError(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION)
	if ae.Metadata["field"] != "post_id" || c.Reads() != 0 {
		t.Fatalf("field=%q reads=%d", ae.Metadata["field"], c.Reads())
	}
}

func TestGetForViewer_DeletedPostIsNotFoundAfterCacheExpiry(t *testing.T) {
	e := newDeleteEnv()
	if _, _, err := e.get(pidOther); err != nil {
		t.Fatal(err)
	}
	delete(e.repo.docs, pidOther) // deleted by its author on another instance
	e.cache.DeletePost(pidOther)  // models the 60 s TTL expiring
	_, _, err := e.get(pidOther)
	wantPostNotFound(t, err)
}

// TestGetForViewer_EmbeddedAuthorBlock: a QUOTE or REPOST is NOT_FOUND when the author of the post it copies
// blocks the caller (ADR-0018 D13), including through the blockedBy overflow path; the caller's own embedded
// posts, tombstones and a block the other way round never hide it.
func TestGetForViewer_EmbeddedAuthorBlock(t *testing.T) {
	const embUID = "uid-embedded"
	embedded := &Embedded{PostID: "9", Author: AuthorSnapshot{UserID: embUID}}
	overflow := graph.Snapshot{BlockedByOverflow: true}
	tests := []struct {
		name      string
		kind      Kind
		embedded  *Embedded
		embAuthor string
		snaps     map[string]graph.Snapshot
		wantFound bool
	}{
		{"plain post is unaffected", KindPost, nil, "", nil, true},
		{"repost, embedded author blocks the caller", KindRepost, embedded, embUID,
			map[string]graph.Snapshot{testUID: {BlockedBy: map[string]bool{embUID: true}}}, false},
		{"quote, embedded author blocks the caller", KindQuote, embedded, embUID,
			map[string]graph.Snapshot{testUID: {BlockedBy: map[string]bool{embUID: true}}}, false},
		{"repost, caller blocked the embedded author", KindRepost, embedded, embUID,
			map[string]graph.Snapshot{testUID: {Blocked: map[string]bool{embUID: true}}}, true},
		{"overflow, embedded author blocks the caller", KindQuote, embedded, embUID,
			map[string]graph.Snapshot{testUID: overflow, embUID: {Blocked: map[string]bool{testUID: true}}}, false},
		{"overflow, no block", KindQuote, embedded, embUID,
			map[string]graph.Snapshot{testUID: overflow}, true},
		{"embedded author is the caller", KindQuote, &Embedded{PostID: "9", Author: AuthorSnapshot{UserID: testUID}}, testUID,
			map[string]graph.Snapshot{testUID: {BlockedBy: map[string]bool{testUID: true}}}, true},
		{"tombstone has no author", KindRepost, &Embedded{PostID: "9", Unavailable: true}, "",
			map[string]graph.Snapshot{testUID: {BlockedBy: map[string]bool{embUID: true}}}, true},
		{"top-level author id only", KindRepost, &Embedded{PostID: "9"}, embUID,
			map[string]graph.Snapshot{testUID: {BlockedBy: map[string]bool{embUID: true}}}, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := newDeleteEnv()
			d := e.repo.docs[pidOther]
			d.Kind, d.Embedded, d.EmbeddedAuthorID = tt.kind, tt.embedded, tt.embAuthor
			if tt.snaps != nil {
				e.graph.snaps = tt.snaps
			}
			_, p, err := e.get(pidOther)
			if tt.wantFound {
				if err != nil || p == nil {
					t.Fatalf("p=%v err=%v", p, err)
				}
				return
			}
			wantPostNotFound(t, err)
		})
	}
}

// The caller's own QUOTE or REPOST is exempt from the embedded-author check (ADR-0018 D13, same as a direct post):
// it stays viewable even when the copied author blocks the caller, and costs no caller-graph read.
func TestGetForViewer_OwnCopyIsExempt(t *testing.T) {
	const embUID = "uid-embedded"
	e := newDeleteEnv()
	d := e.repo.docs[pidOther]
	d.AuthorID = testUID
	d.Author = AuthorSnapshot{UserID: testUID}
	d.Kind = KindQuote
	d.Embedded = &Embedded{PostID: "9", Author: AuthorSnapshot{UserID: embUID}}
	d.EmbeddedAuthorID = embUID
	e.graph.snaps = map[string]graph.Snapshot{testUID: {BlockedBy: map[string]bool{embUID: true}, BlockedByOverflow: true}}
	e.dir.profiles[testUID] = identity.Profile{UserID: testUID, Handle: "alice", Status: identity.AccountStatusActive}
	_, p, err := e.get(pidOther)
	if err != nil || p == nil {
		t.Fatalf("own copy hidden: p=%v err=%v", p, err)
	}
	if e.graph.calls != 0 {
		t.Errorf("caller-graph reads = %d, want 0 for the caller's own copy", e.graph.calls)
	}
}
