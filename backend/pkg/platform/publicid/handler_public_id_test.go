package publicid

import (
	"context"
	"testing"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	identityv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	timelinev1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/timeline/v1"
)

// TestHandlerPublicID_IsAuthoritative: a response whose PUBLIC_ID field the handler already set to a valid public id
// (GetMe right after its lazy mint) keeps it, the TRANSLATE sibling gets the same id, and the resolver is not asked for
// that uid. When the resolver would answer differently, the handler's value wins: it is fresher (it was just written
// or read for this very response).
func TestHandlerPublicID_IsAuthoritative(t *testing.T) {
	for name, pairs := range map[string]map[string]string{
		"resolver knows nothing":        {},
		"resolver disagrees (stale id)": {uidN(9): pubN(8)},
	} {
		t.Run(name, func(t *testing.T) {
			res := newFakeResolver(pairs)
			tr := newTranslatorT(t, realPlans(t), res, 500)
			me := &identityv1.GetMeResponse{Profile: &identityv1.Profile{UserId: uidN(9), PublicId: pubN(9)}}
			stats, err := tr.TranslateResponse(context.Background(), nil, me)
			if err != nil {
				t.Fatal(err)
			}
			if p := me.GetProfile(); p.GetUserId() != pubN(9) || p.GetPublicId() != pubN(9) {
				t.Errorf("profile = (%q, %q), want the handler's pub9 in both", p.GetUserId(), p.GetPublicId())
			}
			if len(res.calls) != 0 || stats.OutboundUnmapped != 0 {
				t.Errorf("resolver calls %v, stats %+v; want none and nothing unmapped", res.calls, stats)
			}
		})
	}
}

// TestHandlerPublicID_SeedsOtherSlotsOfTheSameUID: the authoritative pair also translates every other field of the
// same response that carries that uid, and an invalid value in the PUBLIC_ID field is not trusted.
func TestHandlerPublicID_SeedsOtherSlotsOfTheSameUID(t *testing.T) {
	res := newFakeResolver(map[string]string{uidN(2): pubN(2)})
	tr := newTranslatorT(t, realPlans(t), res, 500)
	page := &timelinev1.GetHomeTimelineResponse{Posts: []*postsv1.PostView{
		{Post: &postsv1.Post{PostId: "1", Author: &commonv1.AuthorSnapshot{UserId: uidN(9), PublicId: pubN(9)}, Mentions: []*postsv1.Mention{{UserId: uidN(9)}}}},
		{Post: &postsv1.Post{PostId: "2", Author: &commonv1.AuthorSnapshot{UserId: uidN(2), PublicId: "garbage"}}},
	}}
	if _, err := tr.TranslateResponse(context.Background(), nil, page); err != nil {
		t.Fatal(err)
	}
	if got := page.GetPosts()[0].GetPost().GetMentions()[0].GetUserId(); got != pubN(9) {
		t.Errorf("mention of the same uid = %q, want pub9", got)
	}
	if a := page.GetPosts()[1].GetPost().GetAuthor(); a.GetUserId() != pubN(2) || a.GetPublicId() != pubN(2) {
		t.Errorf("an invalid handler value was trusted: %v", a)
	}
	if len(res.calls) != 1 || len(res.calls[0]) != 1 || res.calls[0][0] != uidN(2) {
		t.Errorf("resolver calls = %v, want one call for uid2 only", res.calls)
	}
}

// TestHandlerPublicID_ClearsNegativeEntry is the GetMe-after-mint scenario end to end: a page tombstones a not yet
// minted uid and the negative cache remembers it; GetMe then mints and carries the id: it goes out in both fields
// (never the tombstone), and the cache forgets the negative entry, so the next page asks again and shows the id.
func TestHandlerPublicID_ClearsNegativeEntry(t *testing.T) {
	ctx := context.Background()
	inner := newFakeResolver(nil)
	neg := newNeg(t, inner, 10, newClock())
	tr := newTranslatorT(t, realPlans(t), neg, 500)

	page := func() *timelinev1.GetHomeTimelineResponse {
		return &timelinev1.GetHomeTimelineResponse{Posts: []*postsv1.PostView{{Post: &postsv1.Post{PostId: "1", Author: snapshot(uidN(9))}}}}
	}
	p1 := page()
	if _, err := tr.TranslateResponse(ctx, nil, p1); err != nil {
		t.Fatal(err)
	}
	if got := p1.GetPosts()[0].GetPost().GetAuthor().GetUserId(); got != Tombstone || neg.Len() != 1 {
		t.Fatalf("before the mint: author %q, negative entries %d; want the tombstone and one entry", got, neg.Len())
	}

	// GetMe mints (identity now knows the pair) and puts the id in the response.
	inner.mu.Lock()
	inner.uidToPub[uidN(9)] = pubN(9)
	inner.mu.Unlock()
	me := &identityv1.GetMeResponse{Profile: &identityv1.Profile{UserId: uidN(9), PublicId: pubN(9)}}
	if _, err := tr.TranslateResponse(ctx, nil, me); err != nil {
		t.Fatal(err)
	}
	if p := me.GetProfile(); p.GetUserId() != pubN(9) || p.GetPublicId() != pubN(9) {
		t.Fatalf("GetMe = (%q, %q), want pub9 in both, never the tombstone", p.GetUserId(), p.GetPublicId())
	}
	if neg.Len() != 0 {
		t.Errorf("negative entries after the mint = %d, want 0", neg.Len())
	}

	p2 := page()
	if _, err := tr.TranslateResponse(ctx, nil, p2); err != nil {
		t.Fatal(err)
	}
	if got := p2.GetPosts()[0].GetPost().GetAuthor().GetUserId(); got != pubN(9) {
		t.Errorf("after the mint: author %q, want pub9", got)
	}
}

// TestNegativeCache_ReverseLookupClearsEntry: a uid learned through a reverse lookup (someone sent its public id) is
// no longer negative.
func TestNegativeCache_ReverseLookupClearsEntry(t *testing.T) {
	ctx := context.Background()
	inner := newFakeResolver(nil)
	neg := newNeg(t, inner, 10, newClock())
	if _, err := neg.PublicIDsForUIDs(ctx, []string{uidN(4)}); err != nil || neg.Len() != 1 {
		t.Fatalf("setup: %v, %d entries", err, neg.Len())
	}
	inner.mu.Lock()
	inner.uidToPub[uidN(4)], inner.pubToUID[pubN(4)] = pubN(4), uidN(4)
	inner.mu.Unlock()
	if _, err := neg.UIDsForPublicIDs(ctx, []string{pubN(4)}); err != nil {
		t.Fatal(err)
	}
	if neg.Len() != 0 {
		t.Errorf("negative entries = %d after the pair was learned, want 0", neg.Len())
	}
}
