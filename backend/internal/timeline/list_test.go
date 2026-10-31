package timeline

// GetListTimeline (ADR-0030 D5, W5-8). The fakes charge reads the way the real seams do, so the assertions here cover what
// timeline itself reads: the caller graph (1, a cache hit in production) and the member queries. The fixed reads of the list
// (list, owner profile, owner graph) belong to lists.Reader and are asserted by the emulator budget test.

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"strings"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	timelinev1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/timeline/v1"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/internal/lists"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

const testListID = "1000000000000000001"

// fakeLists is a lists.Reader with one list. calls counts Members calls; reads are charged to the request budget.
type fakeLists struct {
	lists.Reader
	owner   string
	members []string
	err     error
	reads   int64
	calls   int
}

func (f *fakeLists) Members(ctx context.Context, _, id string) (lists.ListMembers, error) {
	f.calls++
	budget.FromContext(ctx).AddReads(f.reads)
	if f.err != nil {
		return lists.ListMembers{}, f.err
	}
	return lists.ListMembers{
		Header:    lists.Header{ID: id, Name: "Friends", MemberCount: len(f.members)},
		Owner:     identity.Profile{UserID: f.owner, Handle: "owner"},
		MemberIDs: slices.Clone(f.members),
	}, nil
}

// listRig is a rig whose server reads fl.
func listRig(t *testing.T, members ...string) (*rig, *fakeLists) {
	t.Helper()
	r := newRig(t)
	fl := &fakeLists{owner: "me", members: members, reads: 3}
	r.srv.deps.Lists = fl
	for _, m := range members {
		r.dir.profiles[m] = identity.Profile{UserID: m, Status: identity.AccountStatusActive}
	}
	return r, fl
}

func names(prefix string, n int) []string {
	out := make([]string, n)
	for i := range out {
		out[i] = fmt.Sprintf("%s%d", prefix, i+1)
	}
	return out
}

func (r *rig) list(caller, listID, since, page string, size int32) (*timelinev1.GetListTimelineResponse, *budget.Counter, error) {
	r.t.Helper()
	ictx, info := logger.WithRequestInfo(ctxFor(caller))
	r.info = info
	ctx, counter := budget.WithCounter(ictx)
	resp, err := r.srv.GetListTimeline(ctx, connect.NewRequest(&timelinev1.GetListTimelineRequest{ListId: listID, PageSize: size, SinceToken: since, PageToken: page}))
	if err != nil {
		return nil, counter, err
	}
	return resp.Msg, counter, nil
}

func (r *rig) mustList(since, page string, size int32) *timelinev1.GetListTimelineResponse {
	r.t.Helper()
	resp, _, err := r.list("me", testListID, since, page, size)
	if err != nil {
		r.t.Fatalf("unexpected error: %v", err)
	}
	return resp
}

func listIDs(r *timelinev1.GetListTimelineResponse) []string {
	var out []string
	for _, v := range r.GetPosts() {
		out = append(out, v.GetPost().GetPostId())
	}
	return out
}

func TestList_FortyFiveMembersTwoChunksInHomeOrder(t *testing.T) {
	t.Parallel()
	members := names("m", 45)
	r, fl := listRig(t, members...)
	var want []string
	for i, m := range members {
		p := r.posts.add(m, r.ms(-time.Duration(i+1)*time.Second))
		want = append(want, p.ID)
	}
	resp, counter, err := r.list("me", testListID, "", "", 20)
	if err != nil {
		t.Fatal(err)
	}
	if got := listIDs(resp); !slices.Equal(got, want[:20]) {
		t.Fatalf("posts = %v, want the 20 newest in createdAt order %v", got, want[:20])
	}
	if n := r.posts.queryCount("ByAuthors"); n != 2 {
		t.Fatalf("queries = %d, want 2 (45 members, chunks of 30)", n)
	}
	if resp.GetList().GetListId() != testListID || resp.GetList().GetName() != "Friends" || resp.GetList().GetMemberCount() != 45 {
		t.Fatalf("header = %v", resp.GetList())
	}
	if resp.GetSinceToken() == "" || resp.GetNextPageToken() == "" {
		t.Fatalf("tokens: since=%q next=%q", resp.GetSinceToken(), resp.GetNextPageToken())
	}
	if fl.calls != 1 {
		t.Fatalf("Members calls = %d", fl.calls)
	}
	// Members (3 here) + caller graph 1 + k = ceil(40/2) = 20 per chunk, at most 40 docs.
	if got := counter.Reads(); got > 3+1+40 {
		t.Fatalf("reads = %d", got)
	}
}

func TestList_EmptyListAnswersAnEmptyPageWithTokens(t *testing.T) {
	t.Parallel()
	r, _ := listRig(t)
	resp, counter, err := r.list("me", testListID, "", "", 20)
	if err != nil {
		t.Fatal(err)
	}
	if len(resp.GetPosts()) != 0 || resp.GetSinceToken() == "" || resp.GetNextPageToken() != "" || resp.GetList().GetListId() != testListID {
		t.Fatalf("resp = %v", resp)
	}
	if n := r.posts.queryCount("ByAuthors"); n != 0 {
		t.Fatalf("an empty list queried %d times", n)
	}
	if counter.Reads() != 3+1 {
		t.Fatalf("reads = %d, want Members 3 + graph 1", counter.Reads())
	}
	// The since token it issued is usable for a refresh.
	if _, _, err := r.list("me", testListID, resp.GetSinceToken(), "", 20); err != nil {
		t.Fatalf("refresh: %v", err)
	}
}

func TestList_SinceRefreshWithNothingNewCostsOneQueryPerChunk(t *testing.T) {
	t.Parallel()
	members := names("m", 45)
	r, _ := listRig(t, members...)
	for i, m := range members {
		r.posts.add(m, r.ms(-time.Duration(i+1)*time.Minute))
	}
	cold := r.mustList("", "", 20)
	r.clock.Advance(2 * time.Minute) // the author-recent entries (60 s) expire
	before := r.posts.queryCount("ByAuthors")
	resp, _, err := r.list("me", testListID, cold.GetSinceToken(), "", 20)
	if err != nil {
		t.Fatal(err)
	}
	if len(resp.GetPosts()) != 0 || resp.GetSinceToken() == "" {
		t.Fatalf("resp = %v", resp)
	}
	if n := r.posts.queryCount("ByAuthors") - before; n != 2 {
		t.Fatalf("refresh queries = %d, want C = 2", n)
	}
}

func TestList_OlderPagesWalkTheWholeFeedOnce(t *testing.T) {
	t.Parallel()
	members := names("m", 40)
	r, _ := listRig(t, members...)
	for i, m := range members {
		r.posts.add(m, r.ms(-time.Duration(i+1)*time.Second))
	}
	var seen []string
	resp := r.mustList("", "", 15)
	for pages := 0; ; pages++ {
		seen = append(seen, listIDs(resp)...)
		if resp.GetNextPageToken() == "" {
			break
		}
		if pages > 10 {
			t.Fatal("too many pages")
		}
		resp = r.mustList("", resp.GetNextPageToken(), 15)
	}
	if len(seen) != 40 || len(slices.Compact(slices.Clone(seen))) != 40 {
		t.Fatalf("saw %d posts, want 40 distinct", len(seen))
	}
}

func TestList_PerViewerDrops(t *testing.T) {
	t.Parallel()
	r, _ := listRig(t, "a", "b", "c", "d", "me")
	pa := r.posts.add("a", r.ms(-1*time.Second))
	pb := r.posts.add("b", r.ms(-2*time.Second))
	pc := r.posts.add("c", r.ms(-3*time.Second))
	pd := r.posts.add("d", r.ms(-4*time.Second))
	pm := r.posts.add("me", r.ms(-5*time.Second))
	r.graph.snaps["me"] = graph.Snapshot{Muted: following("a"), Blocked: following("b"), BlockedBy: following("c")}
	got := listIDs(r.mustList("", "", 20))
	if want := []string{pd.ID, pm.ID}; !slices.Equal(got, want) {
		t.Fatalf("posts = %v, want only d and the caller's own %v (a muted, b blocked, c blocks me); all=%v", got, want, []string{pa.ID, pb.ID, pc.ID})
	}
}

func TestList_BlockedByOverflowKeepsOnlyOwnAndFollowedMembers(t *testing.T) {
	t.Parallel()
	r, _ := listRig(t, "a", "b", "me")
	pa := r.posts.add("a", r.ms(-1*time.Second))
	r.posts.add("b", r.ms(-2*time.Second))
	pm := r.posts.add("me", r.ms(-3*time.Second))
	r.graph.snaps["me"] = graph.Snapshot{Following: following("a"), BlockedByOverflow: true}
	got := listIDs(r.mustList("", "", 20))
	if want := []string{pa.ID, pm.ID}; !slices.Equal(got, want) {
		t.Fatalf("posts = %v, want %v", got, want)
	}
	// A stale author-recent entry for b must not leak either: the second call is served from the cache.
	if got := listIDs(r.mustList("", "", 20)); !slices.Equal(got, []string{pa.ID, pm.ID}) {
		t.Fatalf("warm posts = %v", got)
	}
}

func TestList_RepliesAndHiddenPostsAreNotShown(t *testing.T) {
	t.Parallel()
	r, _ := listRig(t, "a")
	root := r.posts.add("a", r.ms(-1*time.Second))
	reply := r.posts.add("a", r.ms(-2*time.Second))
	reply.IsReply = true
	hidden := r.posts.add("a", r.ms(-3*time.Second))
	hidden.Moderation = "TAKEN_DOWN" // posts.ModerationTakenDown; the import lint names no other identifier
	if got := listIDs(r.mustList("", "", 20)); !slices.Equal(got, []string{root.ID}) {
		t.Fatalf("posts = %v, want only the root post", got)
	}
}

func TestList_TokenBindingAndMalformedIDCostNothing(t *testing.T) {
	t.Parallel()
	r, fl := listRig(t, "a")
	r.posts.add("a", r.ms(-time.Second))
	for i := 0; i < 25; i++ {
		r.posts.add("a", r.ms(-time.Duration(i+2)*time.Second))
	}
	for i := 0; i < 15; i++ {
		r.posts.add("me", r.ms(-time.Duration(i+1)*time.Minute)) // Home needs its own second page
	}
	cold := r.mustList("", "", 10)
	home := r.mustHome("", "", 10)
	other := "1000000000000000002"
	cases := []struct {
		name         string
		caller, list string
		since, page  string
		field        string
	}{
		{"home since token", "me", testListID, home.GetSinceToken(), "", "since_token"},
		{"home page token", "me", testListID, "", home.GetNextPageToken(), "page_token"},
		{"other list", "me", other, cold.GetSinceToken(), "", "since_token"},
		{"other list page", "me", other, "", cold.GetNextPageToken(), "page_token"},
		{"other caller", "you", testListID, cold.GetSinceToken(), "", "since_token"},
		{"tampered", "me", testListID, cold.GetSinceToken() + "x", "", "since_token"},
		{"both tokens", "me", testListID, cold.GetSinceToken(), cold.GetNextPageToken(), "page_token"},
		{"malformed id", "me", "abc", "", "", "list_id"},
		{"empty id", "me", "", "", "", "list_id"},
	}
	if cold.GetSinceToken() == "" || cold.GetNextPageToken() == "" || home.GetSinceToken() == "" {
		t.Fatal("setup: missing tokens")
	}
	for _, c := range cases {
		before := fl.calls
		_, counter, err := r.list(c.caller, c.list, c.since, c.page, 10)
		wantField(t, err, c.field)
		if counter.Reads() != 0 || fl.calls != before {
			t.Errorf("%s: reads=%d members calls=%d, want 0", c.name, counter.Reads(), fl.calls-before)
		}
	}
	// And a list token on Home is rejected the other way round.
	if _, _, err := r.home("me", cold.GetSinceToken(), "", 10); err == nil {
		t.Fatal("a list token opened on Home")
	}
}

func TestList_NotFoundIsTheListsSentinelAnswer(t *testing.T) {
	t.Parallel()
	r, fl := listRig(t, "a")
	fl.err = fmt.Errorf("wrapped: %w", lists.ErrNotFound)
	_, counter, err := r.list("me", testListID, "", "", 20)
	var got *apierr.Error
	if !errors.As(err, &got) || got.Code != connect.CodeNotFound || got.Reason != commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED {
		t.Fatalf("err = %#v", err)
	}
	want := lists.NotFoundError()
	if got.Message != want.Message || got.Code != want.Code || got.Reason != want.Reason || fmt.Sprint(got.Metadata) != fmt.Sprint(want.Metadata) {
		t.Fatalf("answer %#v differs from lists.NotFoundError() %#v", got, want)
	}
	if r.posts.queryCount("ByAuthors") != 0 || r.graph.calls != nil || counter.Reads() != 3 {
		t.Fatalf("a refused list read posts or the graph: reads=%d graph=%v", counter.Reads(), r.graph.calls)
	}
}

func TestList_OtherMembersErrorsAreRedactedInternals(t *testing.T) {
	t.Parallel()
	r, fl := listRig(t, "a")
	fl.err = errors.New("firestore: lists/" + testListID + " boom for me")
	_, _, err := r.list("me", testListID, "", "", 20)
	if err == nil || strings.Contains(err.Error(), testListID) {
		t.Fatalf("err = %v, want a redacted error", err)
	}
	var ae *apierr.Error
	if !errors.As(err, &ae) {
		return
	}
	if ae.Code == connect.CodeNotFound {
		t.Fatalf("a read failure became NOT_FOUND: %v", err)
	}
}

func TestList_RemovedIDsAreScopedToTheMembers(t *testing.T) {
	t.Parallel()
	r, _ := listRig(t, "a", "b", "c")
	r.posts.add("a", r.ms(-time.Hour))
	r.graph.snaps["me"] = graph.Snapshot{Muted: following("c")}
	cold := r.mustList("", "", 20)
	f := withRemovals(r, &fakeRemovals{ids: []string{"77"}})
	resp := r.mustList(cold.GetSinceToken(), "", 20)
	if got := resp.GetRemovedIds(); !slices.Equal(got, []string{"77"}) {
		t.Fatalf("removed_ids = %v", got)
	}
	if len(f.scopes) != 1 || !slices.Equal(f.scopes[0].Authors, []string{"a", "b"}) {
		t.Fatalf("scope = %v, want the readable members [a b] (c is muted)", f.scopes)
	}
	// Not on a cold open or an older page.
	r.mustList("", "", 20)
	if len(f.scopes) != 1 {
		t.Fatalf("a cold open consulted the removal log")
	}
	// The takedown token reset is the same VALIDATION as Home.
	withRemovals(r, &fakeRemovals{truncated: true})
	_, _, err := r.list("me", testListID, cold.GetSinceToken(), "", 20)
	wantField(t, err, "since_token")
}

func TestList_ClosedGapReturnsHeaderOnly(t *testing.T) {
	t.Parallel()
	r, _ := listRig(t, "a")
	f := listFeed("me", testListID)
	up := posts.Position{CreatedAt: r.clock.Now().Add(-time.Hour), ID: pid(5)}
	tok := r.srv.codec.encodePage(f, up, &up)
	resp, counter, err := r.list("me", testListID, "", tok, 20)
	if err != nil {
		t.Fatal(err)
	}
	if len(resp.GetPosts()) != 0 || resp.GetNextPageToken() != "" || resp.GetList().GetListId() != testListID {
		t.Fatalf("resp = %v", resp)
	}
	if counter.Reads() != 3 || r.posts.queryCount("ByAuthors") != 0 {
		t.Fatalf("reads = %d", counter.Reads())
	}
}

func TestList_ProtectedMembers(t *testing.T) {
	t.Parallel()
	r, fp := protectedRig(t)
	fl := &fakeLists{owner: "o", members: []string{"P", "q"}, reads: 3}
	r.srv.deps.Lists = fl
	r.dir.profiles["q"] = identity.Profile{UserID: "q", Status: identity.AccountStatusActive}
	pp := pPost(r, 5)
	pq := r.posts.add("q", r.ms(-6*time.Second))
	fp.protect("P")

	got := listIDs(r.mustList("", "", 20))
	if !slices.Equal(got, []string{pq.ID}) {
		t.Fatalf("an unapproved viewer saw %v, want only q's post", got)
	}
	// Approved (follows P): the row appears.
	r.graph.snaps["me"] = graph.Snapshot{Following: following("P")}
	r.clock.Advance(2 * time.Minute)
	if got := listIDs(r.mustList("", "", 20)); !slices.Equal(got, []string{pp.ID, pq.ID}) {
		t.Fatalf("an approved viewer saw %v", got)
	}
	// Fail closed: no usable set is UNAVAILABLE, never an unfiltered page.
	r.graph.snaps["me"] = graph.Snapshot{}
	r.clock.Advance(2 * time.Minute)
	fp.mu.Lock()
	fp.err = errors.New("set unknown")
	fp.mu.Unlock()
	_, _, err := r.list("me", testListID, "", "", 20)
	if codeOf(err) != connect.CodeUnavailable {
		t.Fatalf("err = %v, want UNAVAILABLE", err)
	}
}

// allowFlags is a per-caller flag fake: a name is on for the uids in allow[name] (nil entry = on for everyone, missing = off).
type allowFlags map[string]map[string]bool

func (a allowFlags) Enabled(uid, name string) bool {
	set, ok := a[name]
	if !ok {
		return false
	}
	return set == nil || set[uid]
}

func TestList_FlagModes(t *testing.T) {
	t.Parallel()
	every := map[string]bool(nil)
	cases := []struct {
		name  string
		flags allowFlags
		uid   string
		ok    bool
	}{
		{"lists off", allowFlags{"posts": every}, "me", false},
		{"posts off", allowFlags{"lists": every}, "me", false},
		{"both off", allowFlags{}, "me", false},
		{"lists allowlist, caller on it", allowFlags{"posts": every, "lists": {"me": true}}, "me", true},
		{"lists allowlist, caller not on it", allowFlags{"posts": every, "lists": {"someone": true}}, "me", false},
		{"lists on", allowFlags{"posts": every, "lists": every}, "me", true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			t.Parallel()
			r, fl := listRig(t, "a")
			r.srv.deps.Flags = c.flags
			r.posts.add("a", r.ms(-time.Second))
			resp, counter, err := r.list(c.uid, testListID, "", "", 20)
			if c.ok {
				if err != nil || len(resp.GetPosts()) != 1 {
					t.Fatalf("err=%v resp=%v", err, resp)
				}
				return
			}
			var ae *apierr.Error
			if !errors.As(err, &ae) || ae.Reason != commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED || ae.Code != connect.CodeFailedPrecondition {
				t.Fatalf("err = %#v, want FEATURE_DISABLED", err)
			}
			if c.name != "posts off" && ae.Metadata["feature"] != "lists" {
				t.Fatalf("metadata = %v, want feature=lists", ae.Metadata)
			}
			if counter.Reads() != 0 || fl.calls != 0 || r.graph.calls != nil {
				t.Fatalf("a disabled call read: reads=%d members=%d graph=%v", counter.Reads(), fl.calls, r.graph.calls)
			}
		})
	}
}

func TestList_UnwiredListsIsUnimplementedBehindTheFlag(t *testing.T) {
	t.Parallel()
	r := newRig(t)
	_, _, err := r.list("me", testListID, "", "", 20)
	if connect.CodeOf(err) != connect.CodeUnimplemented {
		t.Fatalf("err = %v, want UNIMPLEMENTED", err)
	}
	r.srv.deps.Flags = nil
	_, _, err = r.list("me", testListID, "", "", 20)
	var ae *apierr.Error
	if !errors.As(err, &ae) || ae.Reason != commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED {
		t.Fatalf("nil flags: err = %v, want FEATURE_DISABLED (off for everyone)", err)
	}
}

func TestList_RequestLogFields(t *testing.T) {
	t.Parallel()
	r, _ := listRig(t, "a", "b")
	r.graph.snaps["me"] = graph.Snapshot{Muted: following("b")}
	r.posts.add("a", r.ms(-time.Second))
	r.mustList("", "", 20)
	for k, want := range map[string]any{"timeline_op": "list", "timeline_mode": "cold", "list_members": 2, "list_authors_dropped": 1, "items_returned": 1} {
		if got, _ := r.info.Get(k); fmt.Sprint(got) != fmt.Sprint(want) {
			t.Errorf("%s = %v, want %v", k, got, want)
		}
	}
	for _, k := range []string{"timeline_op", "timeline_mode"} {
		if got, _ := r.info.Get(k); strings.Contains(fmt.Sprint(got), testListID) {
			t.Errorf("field %s leaks an id: %v", k, got)
		}
	}
}
