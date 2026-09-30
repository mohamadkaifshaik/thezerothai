//go:build integration

// lists_t16b_integration_test.go (T16b): pagination completeness and stability, read budgets at page sizes 20
// and 50 for every list RPC, tampered/truncated/cross-user cursors, and the daily list cap. Everything is
// seeded through real Follow/Block/Mute calls and asserted over the real Connect handlers.
package graph_test

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	graphv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/cursor"
)

// pageResult is what one list page looked like: its uids in order, the next token and the Firestore reads.
type pageResult struct {
	uids  []string
	next  string
	reads int64
}

type pager func(token string, size int32) (pageResult, error)

// walkAll follows next_page_token to the end, asserting every page's size and reads budget. between(n) runs
// after page n (1-based) has been fetched, so tests can mutate the graph mid-walk.
func walkAll(t *testing.T, name string, list pager, size int32, budgetReads func(size int) int64, between func(page int)) (all []string, maxReads int64, pages int) {
	t.Helper()
	token := ""
	for {
		pages++
		if pages > 100 {
			t.Fatalf("%s: more than 100 pages, cursor not advancing", name)
		}
		res, err := list(token, size)
		if err != nil {
			t.Fatalf("%s page %d: %v", name, pages, err)
		}
		eff := int(size)
		if eff == 0 {
			eff = 20
		}
		if eff > 50 {
			eff = 50
		}
		if len(res.uids) > eff {
			t.Errorf("%s page %d: %d rows > page size %d", name, pages, len(res.uids), eff)
		}
		if res.reads > budgetReads(eff) {
			t.Errorf("%s page %d (size %d): reads = %d, want <= %d (documented budget)", name, pages, eff, res.reads, budgetReads(eff))
		}
		if res.reads > maxReads {
			maxReads = res.reads
		}
		all = append(all, res.uids...)
		if between != nil {
			between(pages)
		}
		if res.next == "" {
			return all, maxReads, pages
		}
		token = res.next
	}
}

func uidsOf(items []*graphv1.UserListItem) []string {
	out := make([]string, 0, len(items))
	for _, it := range items {
		out = append(out, it.GetUser().GetUserId())
	}
	return out
}

func assertExactlyOnce(t *testing.T, name string, got []string, mustSee []string, mayNotSee ...string) {
	t.Helper()
	count := map[string]int{}
	for _, u := range got {
		count[u]++
	}
	for u, n := range count {
		if n != 1 {
			t.Errorf("%s: %s appeared %d times across pages", name, u, n)
		}
	}
	for _, u := range mustSee {
		if count[u] != 1 {
			t.Errorf("%s: %s appeared %d times, want exactly once", name, u, count[u])
		}
	}
	for _, u := range mayNotSee {
		if count[u] != 0 {
			t.Errorf("%s: %s must not appear (count %d)", name, u, count[u])
		}
	}
}

func fUID(i int) string { return fmt.Sprintf("uid-f%03d", i) }

// paginationWorld:
//   - hub H is followed by f000..f119 (120 followers; newest = f119);
//   - hub2 follows f000..f049 (50 followees, the new-account follow quota, i.e. an exact multiple of 50);
//   - X blocks f000..f049 and Y mutes f000..f049 (50 each, the new-account block/mute quota);
//   - viewer V blocks five followers, so V's view of H's lists is short-paged (row filtering).
type paginationWorld struct {
	r *rig
	// cold makes every list request start with an empty identity profile cache (Directory.Forget of every
	// uid in the world), so profile hydration costs its documented worst case. The graph snapshot cache is
	// internal to graph and cannot be evicted from here; it only ever saves 1 read.
	cold    bool
	allUIDs []string
	visible []string // H's followers as V sees them (V's blocks removed)
	hidden  []string
}

const (
	uidH  = "uid-hub"
	uidH2 = "uid-hub2"
	uidV  = "uid-viewer"
	uidX  = "uid-blocker"
	uidY  = "uid-muter"
)

func buildPaginationWorld(t *testing.T) *paginationWorld {
	t.Helper()
	w := newWired(t)
	for _, u := range []string{uidH, uidH2, uidV, uidX, uidY} {
		mustCreateProfile(t, w.identity, u, "h"+strings.ReplaceAll(strings.TrimPrefix(u, "uid-"), "-", "_"))
	}
	ctx := context.Background()
	n := 1000
	key := func() string { n++; return t16bKey(n) }
	must := func(what string, err error) {
		t.Helper()
		if err != nil {
			t.Fatalf("setup %s: %v", what, err)
		}
	}
	for i := 0; i < 120; i++ {
		mustCreateProfile(t, w.identity, fUID(i), fmt.Sprintf("fol%03d", i))
		_, err := w.graph.Follow(ctx, fUID(i), key(), uidH)
		must("follower "+fUID(i), err)
	}
	for i := 0; i < 50; i++ {
		_, err := w.graph.Follow(ctx, uidH2, key(), fUID(i))
		must("hub2 follow", err)
		_, err = w.graph.Block(ctx, uidX, key(), fUID(i))
		must("X block", err)
		_, err = w.graph.Mute(ctx, uidY, key(), fUID(i))
		must("Y mute", err)
	}
	pw := &paginationWorld{r: newRig(t, w, 0), allUIDs: []string{uidH, uidH2, uidV, uidX, uidY}}
	for i := 0; i < 120; i++ {
		pw.allUIDs = append(pw.allUIDs, fUID(i))
	}
	hide := map[string]bool{}
	for _, i := range []int{10, 11, 50, 77, 100} {
		_, err := w.graph.Block(ctx, uidV, key(), fUID(i))
		must("V block", err)
		hide[fUID(i)] = true
		pw.hidden = append(pw.hidden, fUID(i))
	}
	for i := 0; i < 120; i++ {
		if !hide[fUID(i)] {
			pw.visible = append(pw.visible, fUID(i))
		}
	}
	return pw
}

func (pw *paginationWorld) evict() {
	if pw.cold {
		pw.r.w.identity.(identity.Directory).Forget(pw.allUIDs...)
	}
}

func (pw *paginationWorld) followersPager(viewer, target string) pager {
	c := pw.r.as(viewer)
	return func(token string, size int32) (pageResult, error) {
		pw.evict()
		resp, err := c.graph.ListFollowers(context.Background(), connect.NewRequest(&graphv1.ListFollowersRequest{UserId: target, PageSize: size, PageToken: token}))
		if err != nil {
			return pageResult{}, err
		}
		return pageResult{uids: uidsOf(resp.Msg.GetUsers()), next: resp.Msg.GetNextPageToken(), reads: pw.r.lastOps().Reads()}, nil
	}
}

func (pw *paginationWorld) followingPager(viewer, target string) pager {
	c := pw.r.as(viewer)
	return func(token string, size int32) (pageResult, error) {
		pw.evict()
		resp, err := c.graph.ListFollowing(context.Background(), connect.NewRequest(&graphv1.ListFollowingRequest{UserId: target, PageSize: size, PageToken: token}))
		if err != nil {
			return pageResult{}, err
		}
		return pageResult{uids: uidsOf(resp.Msg.GetUsers()), next: resp.Msg.GetNextPageToken(), reads: pw.r.lastOps().Reads()}, nil
	}
}

func (pw *paginationWorld) blockedPager(viewer string) pager {
	c := pw.r.as(viewer)
	return func(token string, size int32) (pageResult, error) {
		pw.evict()
		resp, err := c.graph.ListBlockedUsers(context.Background(), connect.NewRequest(&graphv1.ListBlockedUsersRequest{PageSize: size, PageToken: token}))
		if err != nil {
			return pageResult{}, err
		}
		return pageResult{uids: uidsOf(resp.Msg.GetUsers()), next: resp.Msg.GetNextPageToken(), reads: pw.r.lastOps().Reads()}, nil
	}
}

func (pw *paginationWorld) mutedPager(viewer string) pager {
	c := pw.r.as(viewer)
	return func(token string, size int32) (pageResult, error) {
		pw.evict()
		resp, err := c.graph.ListMutedUsers(context.Background(), connect.NewRequest(&graphv1.ListMutedUsersRequest{PageSize: size, PageToken: token}))
		if err != nil {
			return pageResult{}, err
		}
		return pageResult{uids: uidsOf(resp.Msg.GetUsers()), next: resp.Msg.GetNextPageToken(), reads: pw.r.lastOps().Reads()}, nil
	}
}

// Documented worst cases (ADR-0008 cost table, D-"List paging"): edge lists 2 + size + size (102 at 50, 42 at
// 20); own lists 1 + size (51 at 50).
func edgeListBudget(size int) int64 { return int64(2 + 2*size) }
func ownListBudget(size int) int64  { return int64(1 + size) }

func TestLists_Integration_PaginationBudgetsAndStability(t *testing.T) {
	pw := buildPaginationWorld(t)
	ctx := context.Background()
	_ = ctx

	type listCase struct {
		name   string
		pager  pager
		want   []string // set that must appear exactly once
		budget func(int) int64
	}
	f0to49 := make([]string, 50)
	for i := range f0to49 {
		f0to49[i] = fUID(i)
	}
	all120 := make([]string, 120)
	for i := range all120 {
		all120[i] = fUID(i)
	}
	cases := []listCase{
		{"ListFollowers(H) as V (5 rows filtered)", pw.followersPager(uidV, uidH), pw.visible, edgeListBudget},
		{"ListFollowers(H) as X (third party, all 120)", pw.followersPager(uidY, uidH), all120, edgeListBudget},
		{"ListFollowing(hub2) (exact multiple of 50)", pw.followingPager(uidY, uidH2), f0to49, edgeListBudget},
		{"ListBlockedUsers(X)", pw.blockedPager(uidX), f0to49, ownListBudget},
		{"ListMutedUsers(Y)", pw.mutedPager(uidY), f0to49, ownListBudget},
	}
	for _, cold := range []bool{false, true} {
		for _, size := range []int32{20, 50} {
			for _, c := range cases {
				t.Run(fmt.Sprintf("%s/size=%d/cold=%v", c.name, size, cold), func(t *testing.T) {
					pw.cold = cold
					defer func() { pw.cold = false }()
					got, maxReads, pages := walkAll(t, c.name, c.pager, size, c.budget, nil)
					assertExactlyOnce(t, c.name, got, c.want)
					if len(got) != len(c.want) {
						t.Errorf("%s: %d rows, want %d", c.name, len(got), len(c.want))
					}
					t.Logf("READS list=%q size=%d cold=%v pages=%d rows=%d max_page_reads=%d budget=%d", c.name, size, cold, pages, len(got), maxReads, c.budget(int(size)))
				})
			}
		}
	}

	// Oversized page_size is clamped to 50; 0 means the default 20.
	t.Run("page_size clamp and default", func(t *testing.T) {
		res, err := pw.followersPager(uidY, uidH)("", 100)
		if err != nil || len(res.uids) != 50 {
			t.Errorf("page_size 100: rows = %d, err = %v; want 50", len(res.uids), err)
		}
		res, err = pw.followersPager(uidY, uidH)("", 0)
		if err != nil || len(res.uids) != 20 {
			t.Errorf("page_size 0: rows = %d, err = %v; want 20", len(res.uids), err)
		}
	})

	// Exact multiple: hub2 follows exactly 50 users; page 1 (size 50) is full and carries a token, page 2 is
	// empty with no token (ADR-0008 "List paging": one empty final call).
	t.Run("exact multiple of page size ends with one empty page", func(t *testing.T) {
		p := pw.followingPager(uidY, uidH2)
		res1, err := p("", 50)
		if err != nil || len(res1.uids) != 50 || res1.next == "" {
			t.Fatalf("page 1: rows=%d next=%q err=%v", len(res1.uids), res1.next, err)
		}
		res2, err := p(res1.next, 50)
		if err != nil || len(res2.uids) != 0 || res2.next != "" {
			t.Fatalf("page 2: rows=%d next=%q err=%v; want empty and no token", len(res2.uids), res2.next, err)
		}
		if res2.reads > 3 {
			t.Errorf("empty final page cost %d reads, want <= 3 (target check + 1 empty edge query)", res2.reads)
		}
	})

	// Own lists: removing an item between pages (cursor resume), and unblocking the last-seen uid.
	t.Run("own list: removal between pages does not skip or repeat", func(t *testing.T) {
		w := pw.r.w
		bl := pw.blockedPager(uidX)
		res1, err := bl("", 20)
		if err != nil {
			t.Fatal(err)
		}
		last := res1.uids[len(res1.uids)-1]
		// The last-returned uid (cursor anchor) is unblocked before page 2.
		if _, err := w.graph.Unblock(context.Background(), uidX, t16bKey(5000), last); err != nil {
			t.Fatal(err)
		}
		var rest []string
		token := res1.next
		for token != "" {
			res, err := bl(token, 20)
			if err != nil {
				t.Fatal(err)
			}
			rest = append(rest, res.uids...)
			token = res.next
		}
		seen := append(append([]string{}, res1.uids...), rest...)
		assertExactlyOnce(t, "ListBlockedUsers(after anchor removed)", seen, without(f0to49, last))
		if len(seen) != 50 {
			t.Errorf("rows = %d, want 50 (49 remaining + the anchor already seen once)", len(seen))
		}
	})

	// Stability: inserts (newer followers) and deletions between page fetches. Runs last: it mutates H.
	t.Run("edge list: inserts and deletes between pages", func(t *testing.T) {
		w := pw.r.w
		ctx := context.Background()
		fresh := []string{"uid-new1", "uid-new2", "uid-new3"}
		for i, u := range fresh {
			mustCreateProfile(t, w.identity, u, fmt.Sprintf("newfol%d", i))
		}
		seenGone := fUID(119) // newest: already delivered on page 1 when it is removed
		unseenGone := fUID(5) // oldest region: removed before it is reached
		got, _, pages := walkAll(t, "ListFollowers(H) with concurrent writes", pw.followersPager(uidV, uidH), 20, edgeListBudget, func(page int) {
			switch page {
			case 1:
				for i, u := range fresh {
					if _, err := w.graph.Follow(ctx, u, t16bKey(6000+i), uidH); err != nil {
						t.Fatalf("mid-walk follow: %v", err)
					}
				}
			case 2:
				for i, u := range []string{seenGone, unseenGone} {
					if _, err := w.graph.Unfollow(ctx, u, t16bKey(6100+i), uidH); err != nil {
						t.Fatalf("mid-walk unfollow: %v", err)
					}
				}
			}
		})
		stable := without(without(append([]string{}, pw.visible...), seenGone), unseenGone)
		assertExactlyOnce(t, "ListFollowers(H) with concurrent writes", got, stable, fresh...)
		if n := countOf(got, seenGone); n != 1 {
			t.Errorf("%s was already delivered on page 1 and must appear exactly once, got %d", seenGone, n)
		}
		if n := countOf(got, unseenGone); n > 1 {
			t.Errorf("%s appeared %d times", unseenGone, n)
		}
		t.Logf("stability walk: %d pages, %d rows", pages, len(got))
		assertGraphInvariants(t, w.client)
	})
}

func without(in []string, drop string) []string {
	out := make([]string, 0, len(in))
	for _, u := range in {
		if u != drop {
			out = append(out, u)
		}
	}
	return out
}

func countOf(in []string, v string) int {
	n := 0
	for _, u := range in {
		if u == v {
			n++
		}
	}
	return n
}

// TestCursors_Integration_TamperedTruncatedCrossUser: every list RPC rejects bad page tokens with
// INVALID_ARGUMENT + VALIDATION (field page_token) and reads nothing.
func TestCursors_Integration_TamperedTruncatedCrossUser(t *testing.T) {
	pw := buildPaginationWorld(t)
	r := pw.r
	a := r.as(uidV)
	ctx := context.Background()

	lists := map[string]func(token string) error{
		"ListFollowers": func(tok string) error {
			_, err := a.graph.ListFollowers(ctx, connect.NewRequest(&graphv1.ListFollowersRequest{UserId: uidH, PageSize: 20, PageToken: tok}))
			return err
		},
		"ListFollowing": func(tok string) error {
			_, err := a.graph.ListFollowing(ctx, connect.NewRequest(&graphv1.ListFollowingRequest{UserId: uidH2, PageSize: 20, PageToken: tok}))
			return err
		},
		"ListBlockedUsers": func(tok string) error {
			_, err := r.as(uidX).graph.ListBlockedUsers(ctx, connect.NewRequest(&graphv1.ListBlockedUsersRequest{PageSize: 20, PageToken: tok}))
			return err
		},
		"ListMutedUsers": func(tok string) error {
			_, err := r.as(uidY).graph.ListMutedUsers(ctx, connect.NewRequest(&graphv1.ListMutedUsersRequest{PageSize: 20, PageToken: tok}))
			return err
		},
	}
	// A real, valid token per list (every list has more than 20 rows).
	valid := map[string]string{
		"ListFollowers":    firstToken(t, pw.followersPager(uidV, uidH)),
		"ListFollowing":    firstToken(t, pw.followingPager(uidV, uidH2)),
		"ListBlockedUsers": firstToken(t, pw.blockedPager(uidX)),
		"ListMutedUsers":   firstToken(t, pw.mutedPager(uidY)),
	}

	mutate := func(tok string, at int) string {
		b := []byte(tok)
		if b[at] == 'A' {
			b[at] = 'B'
		} else {
			b[at] = 'A'
		}
		return string(b)
	}
	wrongKey := []byte("some-other-key-entirely")
	for name, call := range lists {
		tok := valid[name]
		if err := call(tok); err != nil {
			t.Fatalf("%s: valid token rejected: %v", name, err)
		}
		bad := map[string]string{
			"flip first char":           mutate(tok, 0),
			"flip middle char":          mutate(tok, len(tok)/2),
			"truncated by 5":            tok[:len(tok)-5],
			"truncated to 10 chars":     tok[:10],
			"appended junk":             tok + "AAAA",
			"garbage":                   "not-a-token!!",
			"signed with the wrong key": cursor.Encode(wrongKey, "any-binding", cursor.Cursor{CreatedAt: time.Now().UTC(), DocID: "uid-f001_" + uidH}),
			"another list's token":      valid[otherList(name)],
		}
		for label, token := range bad {
			t.Run(name+"/"+label, func(t *testing.T) {
				err := call(token)
				if err == nil {
					t.Fatalf("token accepted")
				}
				info := decodeErr(t, err)
				if info.Code != connect.CodeInvalidArgument || info.Reason != commonv1.ErrorReason_ERROR_REASON_VALIDATION || info.Meta["field"] != "page_token" {
					t.Errorf("error = code %v reason %v meta %v, want InvalidArgument/VALIDATION/field=page_token", info.Code, info.Reason, info.Meta)
				}
				if ops := r.lastOps(); ops.Reads() != 0 {
					t.Errorf("rejected token still cost %d reads, want 0", ops.Reads())
				}
			})
		}
	}

	// Cross-user (edge lists): a validly signed token whose doc id belongs to another user's list is rejected
	// rather than silently skipping rows.
	t.Run("cross-user edge cursors", func(t *testing.T) {
		key := []byte("test-cursor-key")
		forged := map[string]func() error{
			"followers cursor of another target": func() error {
				tok := cursor.Encode(key, "any-binding", cursor.Cursor{CreatedAt: time.Now().UTC(), DocID: "uid-f001_" + uidH2})
				_, err := a.graph.ListFollowers(ctx, connect.NewRequest(&graphv1.ListFollowersRequest{UserId: uidH, PageToken: tok}))
				return err
			},
			"following cursor of another user": func() error {
				tok := cursor.Encode(key, "any-binding", cursor.Cursor{CreatedAt: time.Now().UTC(), DocID: uidH + "_uid-f001"})
				_, err := a.graph.ListFollowing(ctx, connect.NewRequest(&graphv1.ListFollowingRequest{UserId: uidH2, PageToken: tok}))
				return err
			},
			"followers token replayed as following token": func() error {
				_, err := a.graph.ListFollowing(ctx, connect.NewRequest(&graphv1.ListFollowingRequest{UserId: uidH, PageToken: valid["ListFollowers"]}))
				return err
			},
			"following token replayed as followers token": func() error {
				_, err := a.graph.ListFollowers(ctx, connect.NewRequest(&graphv1.ListFollowersRequest{UserId: uidH2, PageToken: valid["ListFollowing"]}))
				return err
			},
			"followers token of H used on followers of H2": func() error {
				_, err := a.graph.ListFollowers(ctx, connect.NewRequest(&graphv1.ListFollowersRequest{UserId: uidH2, PageToken: valid["ListFollowers"]}))
				return err
			},
		}
		for label, call := range forged {
			err := call()
			if err == nil {
				t.Errorf("%s: accepted", label)
				continue
			}
			if info := decodeErr(t, err); info.Code != connect.CodeInvalidArgument || info.Meta["field"] != "page_token" {
				t.Errorf("%s: error = %+v", label, info)
			}
		}
	})

	// Own lists (T16b D-5, security review M1): tokens are bound to the caller and the list. Another user's
	// blocked-list token is rejected outright instead of paging the presenter's own array from a foreign
	// position.
	t.Run("own-list token is bound to the caller", func(t *testing.T) {
		tokX := valid["ListBlockedUsers"] // X's blocked-list token
		_, err := r.as(uidV).graph.ListBlockedUsers(ctx, connect.NewRequest(&graphv1.ListBlockedUsersRequest{PageSize: 20, PageToken: tokX}))
		if err == nil {
			t.Fatal("cross-user own-list token accepted")
		}
		if info := decodeErr(t, err); info.Code != connect.CodeInvalidArgument || info.Meta["field"] != "page_token" {
			t.Errorf("error = %+v", info)
		}
		if ops := r.lastOps(); ops.Reads() != 0 {
			t.Errorf("rejected token still cost %d reads, want 0", ops.Reads())
		}
	})
	assertGraphInvariants(t, r.w.client)
}

func otherList(name string) string {
	order := []string{"ListFollowers", "ListFollowing", "ListBlockedUsers", "ListMutedUsers"}
	for i, n := range order {
		if n == name {
			return order[(i+1)%len(order)]
		}
	}
	return name
}

func firstToken(t *testing.T, p pager) string {
	t.Helper()
	res, err := p("", 20)
	if err != nil {
		t.Fatal(err)
	}
	if res.next == "" {
		t.Fatal("expected a next_page_token on page 1")
	}
	return res.next
}

// TestLists_Integration_DailyCap: the 101st list call in a day is RATE_LIMITED before any Firestore read; the
// cap is shared by the four list RPCs, per uid, and never touches GetRelationships or mutations.
func TestLists_Integration_DailyCap(t *testing.T) {
	w := newWired(t)
	for _, u := range []string{uidV, uidH, uidX} {
		mustCreateProfile(t, w.identity, u, "cap"+strings.TrimPrefix(u, "uid-"))
	}
	r := newRig(t, w, 100)
	v := r.as(uidV)
	other := r.as(uidX)
	ctx := context.Background()

	calls := []func() error{
		func() error {
			_, err := v.graph.ListFollowers(ctx, connect.NewRequest(&graphv1.ListFollowersRequest{UserId: uidH}))
			return err
		},
		func() error {
			_, err := v.graph.ListFollowing(ctx, connect.NewRequest(&graphv1.ListFollowingRequest{UserId: uidH}))
			return err
		},
		func() error {
			_, err := v.graph.ListBlockedUsers(ctx, connect.NewRequest(&graphv1.ListBlockedUsersRequest{}))
			return err
		},
		func() error {
			_, err := v.graph.ListMutedUsers(ctx, connect.NewRequest(&graphv1.ListMutedUsersRequest{}))
			return err
		},
	}
	for i := 0; i < 100; i++ {
		if err := calls[i%len(calls)](); err != nil {
			t.Fatalf("call %d of 100 rejected: %v", i+1, err)
		}
	}
	for i, call := range calls {
		err := call()
		if err == nil {
			t.Fatalf("list RPC #%d: call 101+ accepted", i)
		}
		info := decodeErr(t, err)
		if info.Code != connect.CodeResourceExhausted || info.Reason != commonv1.ErrorReason_ERROR_REASON_RATE_LIMITED {
			t.Errorf("list RPC #%d: error = %v/%v, want ResourceExhausted/RATE_LIMITED", i, info.Code, info.Reason)
		}
		budgettest.Assert(t, fmt.Sprintf("capped list RPC #%d", i), r.lastOps(), budgettest.Budget{})
	}

	// Not capped: GetRelationships and mutations by the same uid; other uids have their own budget.
	if _, err := v.graph.GetRelationships(ctx, connect.NewRequest(&graphv1.GetRelationshipsRequest{UserIds: []string{uidH}})); err != nil {
		t.Errorf("GetRelationships after cap: %v", err)
	}
	if _, err := v.graph.Follow(ctx, connect.NewRequest(&graphv1.FollowRequest{IdempotencyKey: t16bKey(1), UserId: uidH})); err != nil {
		t.Errorf("Follow after cap: %v", err)
	}
	if err := func() error {
		_, err := other.graph.ListFollowers(ctx, connect.NewRequest(&graphv1.ListFollowersRequest{UserId: uidH}))
		return err
	}(); err != nil {
		t.Errorf("another uid's first list call rejected: %v", err)
	}
	assertGraphInvariants(t, w.client)
}
