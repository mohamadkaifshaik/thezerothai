package publicid

import (
	"context"
	"fmt"
	"testing"

	"google.golang.org/protobuf/proto"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	timelinev1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/timeline/v1"
)

// warmResolver answers from memory with no bookkeeping: a stand-in for identity's warm pair cache.
type warmResolver struct{ uidToPub, pubToUID map[string]string }

func (w warmResolver) PublicIDsForUIDs(_ context.Context, uids []string) (map[string]string, error) {
	out := make(map[string]string, len(uids))
	for _, u := range uids {
		if p, ok := w.uidToPub[u]; ok {
			out[u] = p
		}
	}
	return out, nil
}

func (w warmResolver) UIDsForPublicIDs(_ context.Context, pubs []string) (map[string]string, error) {
	out := make(map[string]string, len(pubs))
	for _, p := range pubs {
		if u, ok := w.pubToUID[p]; ok {
			out[p] = u
		}
	}
	return out, nil
}

func benchTranslator(b *testing.B) *Translator {
	b.Helper()
	w := warmResolver{uidToPub: map[string]string{}, pubToUID: map[string]string{}}
	for i := range 100 {
		w.uidToPub[uidN(i)] = pubN(i)
		w.pubToUID[pubN(i)] = uidN(i)
	}
	plans := realPlans(b)
	tr, err := NewTranslator(plans, w, canonicalValid, 500)
	if err != nil {
		b.Fatal(err)
	}
	return tr
}

func snapshot(uid string) *commonv1.AuthorSnapshot {
	return &commonv1.AuthorSnapshot{UserId: uid, Handle: "h" + uid[len(uid)-4:], DisplayName: "Name"}
}

// timelinePage is a 50-post home timeline page: each post has an author, an embedded post with its author and two
// mentions, over 30 distinct users (so pairs repeat, as on a real page).
func timelinePage() *timelinev1.GetHomeTimelineResponse {
	page := &timelinev1.GetHomeTimelineResponse{NextPageToken: "tok"}
	for i := range 50 {
		page.Posts = append(page.Posts, &postsv1.PostView{Post: &postsv1.Post{
			PostId: fmt.Sprintf("%d", 1000+i),
			Author: snapshot(uidN(i % 30)),
			Text:   "hello",
			Embedded: &postsv1.EmbeddedPost{
				PostId: fmt.Sprintf("%d", 5000+i),
				Author: snapshot(uidN((i + 7) % 30)),
			},
			Mentions: []*postsv1.Mention{{UserId: uidN((i + 3) % 30), Handle: "m1"}, {UserId: uidN((i + 11) % 30), Handle: "m2"}},
		}})
	}
	return page
}

// BenchmarkNilPlanResponse: a response type with no user reference costs one map lookup.
func BenchmarkNilPlanResponse(b *testing.B) {
	tr := benchTranslator(b)
	msg := &postsv1.DeletePostResponse{}
	if planned, hasSteps := tr.plans.Lookup(msg.ProtoReflect().Descriptor().FullName()); !planned || hasSteps {
		b.Fatalf("DeletePostResponse: planned=%v hasSteps=%v, want a nil plan", planned, hasSteps)
	}
	ctx := context.Background()
	b.ReportAllocs()
	for b.Loop() {
		if _, err := tr.TranslateResponse(ctx, nil, msg); err != nil {
			b.Fatal(err)
		}
	}
}

// BenchmarkTimelinePage50: outbound translation of a 50-post page with a warm resolver. Each iteration gets a fresh
// clone (made with the timer stopped), since translation mutates in place.
func BenchmarkTimelinePage50(b *testing.B) {
	tr := benchTranslator(b)
	base := timelinePage()
	ctx := context.Background()
	b.ReportAllocs()
	b.ResetTimer()
	for range b.N {
		b.StopTimer()
		page, ok := proto.Clone(base).(*timelinev1.GetHomeTimelineResponse)
		if !ok {
			b.Fatal("clone type")
		}
		b.StartTimer()
		if _, err := tr.TranslateResponse(ctx, nil, page); err != nil {
			b.Fatal(err)
		}
	}
}
