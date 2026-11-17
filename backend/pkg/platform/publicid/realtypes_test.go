package publicid

import (
	"context"
	"testing"

	"google.golang.org/protobuf/reflect/protoreflect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	timelinev1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/timeline/v1"
)

// TestRealTypes_SharedSnapshotAndFill: on generated types, one *AuthorSnapshot shared by two posts (as handlers reuse
// snapshots within a page) is resolved once and written once: user_id and the filled public_id both hold the public
// id. The home timeline request has a nil plan, so the state is nil, and the returned stats still count the response.
func TestRealTypes_SharedSnapshotAndFill(t *testing.T) {
	res := newFakeResolver(pairs())
	tr := newTranslatorT(t, realPlans(t), res, 500)
	ctx := context.Background()

	st, err := tr.TranslateRequest(ctx, &timelinev1.GetHomeTimelineRequest{PageSize: 20})
	if err != nil || st != nil {
		t.Fatalf("GetHomeTimelineRequest = (%v, %v), want (nil, nil): a nil plan", st, err)
	}
	shared := &commonv1.AuthorSnapshot{UserId: uidN(1), Handle: "one"}
	gone := &commonv1.AuthorSnapshot{UserId: uidN(9), Handle: "gone"}
	page := &timelinev1.GetHomeTimelineResponse{Posts: []*postsv1.PostView{
		{Post: &postsv1.Post{PostId: "1", Author: shared, Mentions: []*postsv1.Mention{{UserId: uidN(2)}}}},
		{Post: &postsv1.Post{PostId: "2", Author: shared, Embedded: &postsv1.EmbeddedPost{PostId: "3", Author: gone}}},
	}}
	stats, err := tr.TranslateResponse(ctx, st, page)
	if err != nil {
		t.Fatal(err)
	}
	if shared.GetUserId() != pubN(1) || shared.GetPublicId() != pubN(1) {
		t.Errorf("shared snapshot = (%q, %q), want pub1 in both", shared.GetUserId(), shared.GetPublicId())
	}
	if gone.GetUserId() != Tombstone || gone.GetPublicId() != Tombstone {
		t.Errorf("unmapped snapshot = (%q, %q), want the tombstone in both", gone.GetUserId(), gone.GetPublicId())
	}
	if got := page.GetPosts()[0].GetPost().GetMentions()[0].GetUserId(); got != pubN(2) {
		t.Errorf("mention = %q, want pub2", got)
	}
	if len(res.calls) != 1 || len(res.calls[0]) != 3 {
		t.Errorf("resolver calls = %v, want one call with the 3 distinct uids", res.calls)
	}
	if want := (Stats{OutboundIDs: 3, OutboundUnmapped: 1, ResolverCalls: 1}); stats != want {
		t.Errorf("stats = %+v, want %+v", stats, want)
	}
}

// TestStats_IncludeInboundCounters: the stats returned by TranslateResponse cover the request half too.
func TestStats_IncludeInboundCounters(t *testing.T) {
	api := newTestAPI(t)
	tr := newTranslatorT(t, api.plans, newFakeResolver(pairs()), 500)
	req := api.msg("Req")
	setStr(req, "user_id", pubN(1))
	st, err := tr.TranslateRequest(context.Background(), req)
	if err != nil {
		t.Fatal(err)
	}
	out := api.msg("Post")
	setMsg(out, "author", author(api, uidN(1)))
	list(out, "ids").Append(protoreflect.ValueOfString(uidN(2)))
	stats, err := tr.TranslateResponse(context.Background(), st, out)
	if err != nil {
		t.Fatal(err)
	}
	if want := (Stats{InboundIDs: 1, OutboundIDs: 2, ResolverCalls: 2}); stats != want {
		t.Errorf("stats = %+v, want %+v", stats, want)
	}
	// A nil-plan response still returns the request's counters.
	stats, err = tr.TranslateResponse(context.Background(), st, api.msg("Plain"))
	if err != nil || stats.InboundIDs != 1 {
		t.Errorf("nil-plan response stats = %+v, %v", stats, err)
	}
}
