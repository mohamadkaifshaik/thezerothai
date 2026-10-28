//go:build integration

package apiserver

// W3-29a (ADR-0025 D3 to D5) through the real Build chain on the emulators, with the real protected-set loader and the
// real UpdateProfile(is_private) toggle (FEATURE_PRIVATE_ACCOUNTS on):
//   - for an unapproved viewer, GetPost, LikePost, AddBookmark, ReportContent, a reply to and a quote of the protected
//     author's post answer exactly what the same RPC answers for a deleted post: HTTP status, content type and body (the
//     W3-20 comparator of TestW320_TabNotFoundBytesMatchGetProfile);
//   - an approved follower reads the post at the unchanged 4 cold reads, and reposting or quoting it is
//     PROTECTED_ACCOUNT with 0 writes; the author may quote their own post;
//   - a quote made while the author was public is stripped for an unapproved viewer (no text, no media, post_id and the
//     author's handle kept);
//   - undo is never gated: UnlikePost and RemoveBookmark of a post the caller liked and bookmarked while it was public
//     still succeed after the author protected.

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"testing"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	engagementv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/engagement/v1"
	identityv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/moderation/v1/moderationv1connect"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1/postsv1connect"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

func w329aOn(c *config.Config) {
	c.FeatureQuotes = flags.Spec{Name: "quotes", Mode: flags.On}
	c.FeatureReplies = flags.Spec{Name: "replies", Mode: flags.On}
	c.FeatureBookmarks = flags.Spec{Name: "bookmarks", Mode: flags.On}
	c.FeatureReports = flags.Spec{Name: "reports", Mode: flags.On}
	c.FeaturePrivateAccounts = flags.Spec{Name: "private_accounts", Mode: flags.On}
	c.RateLimit.BookmarksPerUserPerMinute = 1_000_000
}

func TestW329a_ProtectedPostsThroughTheChain(t *testing.T) {
	ctx := context.Background()
	w := newW320Chain(t, w329aOn)
	p, stranger, follower, quoter := w.user(t), w.user(t), w.user(t), w.user(t)

	pid := w.post(t, p, "protected author's post")
	gone := w.post(t, p, "deleted soon")
	if _, err := w.posts.DeletePost(ctx, authed(p.token, &postsv1.DeletePostRequest{IdempotencyKey: contractKey("w329a-del"), PostId: gone})); err != nil {
		t.Fatal(err)
	}
	// Seeded while P is public: the quoter's quote of P's post, and the stranger's like and bookmark of it.
	qr, err := w.posts.CreatePost(ctx, authed(quoter.token, &postsv1.CreatePostRequest{IdempotencyKey: contractKey("w329a-q"), Text: "my take", QuoteOfPostId: pid}))
	if err != nil {
		t.Fatalf("quote while public: %v", err)
	}
	quoteID := qr.Msg.GetPost().GetPost().GetPostId()
	w.like(t, stranger, pid)
	if _, err := w.add(stranger, contractKey("w329a-bm"), pid); err != nil {
		t.Fatal(err)
	}
	w.w320Follow(t, follower, p.uid)

	// P protects through the real toggle.
	prot := true
	if _, err := w.w320Update(p, &identityv1.UpdateProfileRequest{IsPrivate: &prot}); err != nil {
		t.Fatalf("protect: %v", err)
	}

	// A cold instance: nothing cached from the seeding, the set loaded from Firestore.
	r := newW320Chain(t, w329aOn)
	const (
		rpcGet    = postsv1connect.PostServiceGetPostProcedure
		rpcCreate = postsv1connect.PostServiceCreatePostProcedure
		rpcLike   = "/dzeroth.engagement.v1.EngagementService/LikePost"
		rpcReport = moderationv1connect.ModerationServiceReportContentProcedure
	)
	body := func(rpc, id string, n int) string {
		key := fmt.Sprintf("w329a-key-%s-%02d-padpad", strings.ToLower(rpc[strings.LastIndex(rpc, "/")+1:]), n)
		switch rpc {
		case rpcGet:
			return fmt.Sprintf(`{"postId":%q}`, id)
		case rpcLike, rpcAddBookmark:
			return fmt.Sprintf(`{"idempotencyKey":%q,"postId":%q}`, key, id)
		case rpcReport:
			return fmt.Sprintf(`{"idempotencyKey":%q,"targetType":"REPORT_TARGET_TYPE_POST","targetId":%q,"reason":"REPORT_REASON_SPAM"}`, key, id)
		}
		panic("unknown rpc " + rpc)
	}
	type call struct{ name, rpc, protected, deleted string }
	calls := []call{
		{"GetPost", rpcGet, body(rpcGet, pid, 1), body(rpcGet, gone, 1)},
		{"LikePost", rpcLike, body(rpcLike, pid, 1), body(rpcLike, gone, 1)},
		{"AddBookmark", rpcAddBookmark, body(rpcAddBookmark, pid, 1), body(rpcAddBookmark, gone, 1)},
		{"ReportContent", rpcReport, body(rpcReport, pid, 1), body(rpcReport, gone, 1)},
		{"reply", rpcCreate, fmt.Sprintf(`{"idempotencyKey":"w329a-key-reply-01-padpad","text":"hi","replyToPostId":%q}`, pid),
			fmt.Sprintf(`{"idempotencyKey":"w329a-key-reply-01-padpad","text":"hi","replyToPostId":%q}`, gone)},
		{"quote", rpcCreate, fmt.Sprintf(`{"idempotencyKey":"w329a-key-quote-01-padpad","text":"q","quoteOfPostId":%q}`, pid),
			fmt.Sprintf(`{"idempotencyKey":"w329a-key-quote-01-padpad","text":"q","quoteOfPostId":%q}`, gone)},
	}
	for _, c := range calls {
		t.Run("stranger "+c.name, func(t *testing.T) {
			wantSt, wantCT, wantBody := r.rawRPC(t, stranger.token, c.rpc, c.deleted)
			if wantSt != http.StatusNotFound {
				t.Fatalf("oracle (deleted post) = %d %s", wantSt, wantBody)
			}
			st, ct, b := r.rawRPC(t, stranger.token, c.rpc, c.protected)
			if st != wantSt || ct != wantCT || b != wantBody {
				t.Errorf("protected post differs from deleted post\n  deleted:   %d %s %s\n  protected: %d %s %s", wantSt, wantCT, wantBody, st, ct, b)
			}
			budgettest.Assert(t, c.name+" refusal", r.lineBudget(t, c.rpc), budgettest.Budget{Reads: 12})
		})
	}

	t.Run("GetPost budget: stranger refusal and follower read, cold, interceptor included", func(t *testing.T) {
		cold := newW320Chain(t, w329aOn)
		st, _, b := cold.rawRPC(t, stranger.token, rpcGet, body(rpcGet, pid, 2))
		if st != http.StatusNotFound {
			t.Fatalf("stranger = %d %s", st, b)
		}
		budgettest.Assert(t, "GetPost stranger cold", cold.lineBudget(t, rpcGet), budgettest.Budget{Reads: 4})
		cold2 := newW320Chain(t, w329aOn)
		st, _, b = cold2.rawRPC(t, follower.token, rpcGet, body(rpcGet, pid, 3))
		if st != http.StatusOK {
			t.Fatalf("follower = %d %s", st, b)
		}
		budgettest.Assert(t, "GetPost follower cold (4 + the documented userLikes read, FEATURE_ENGAGEMENT on)", cold2.lineBudget(t, rpcGet), budgettest.Budget{Reads: 5})
		var v struct {
			Post struct {
				Post struct {
					Visibility string `json:"visibility"`
				} `json:"post"`
			} `json:"post"`
		}
		if err := json.Unmarshal([]byte(b), &v); err != nil {
			t.Fatal(err)
		}
		if v.Post.Post.Visibility != "VISIBILITY_FOLLOWERS" {
			t.Errorf("wire visibility = %q, want VISIBILITY_FOLLOWERS (stored stays PUBLIC)", v.Post.Post.Visibility)
		}
		if got := w.w320Field(t, "posts/"+pid, "visibility"); got != "PUBLIC" {
			t.Errorf("stored visibility = %v, want PUBLIC", got)
		}
	})

	t.Run("an old quote of P is stripped for a stranger", func(t *testing.T) {
		st, _, b := r.rawRPC(t, stranger.token, rpcGet, body(rpcGet, quoteID, 4))
		if st != http.StatusOK {
			t.Fatalf("GetPost(quote) = %d %s", st, b)
		}
		if !strings.Contains(b, "EMBED_VIEWER_STATE_PROTECTED") {
			t.Errorf("no PROTECTED state: %s", b)
		}
		if strings.Contains(b, "protected author's post") || strings.Contains(b, `"media"`) && strings.Contains(b, "/m/") {
			t.Errorf("the copy leaked: %s", b)
		}
		var v struct {
			Post struct {
				Post struct {
					Embedded struct {
						PostID string `json:"postId"`
						Author struct {
							Handle string `json:"handle"`
						} `json:"author"`
						Text string `json:"text"`
					} `json:"embedded"`
				} `json:"post"`
			} `json:"post"`
		}
		if err := json.Unmarshal([]byte(b), &v); err != nil {
			t.Fatal(err)
		}
		if e := v.Post.Post.Embedded; e.PostID != pid || e.Author.Handle == "" || e.Text != "" {
			t.Errorf("embed = %+v, want post_id and handle only", e)
		}
	})

	t.Run("the quoter's own copy of P's post costs at most 4 cold (+1 graph read)", func(t *testing.T) {
		cold := newW320Chain(t, w329aOn)
		st, _, b := cold.rawRPC(t, quoter.token, rpcGet, body(rpcGet, quoteID, 5))
		if st != http.StatusOK {
			t.Fatalf("own quote = %d %s", st, b)
		}
		budgettest.Assert(t, "GetPost own quote of P, cold", cold.lineBudget(t, rpcGet), budgettest.Budget{Reads: 4})
	})

	t.Run("an approved follower cannot repost or quote: PROTECTED_ACCOUNT, 0 writes; the author can", func(t *testing.T) {
		_, err := r.eng.RepostPost(ctx, authed(follower.token, &engagementv1.RepostPostRequest{IdempotencyKey: contractKey("w329a-rp"), PostId: pid}))
		d := wireError(t, err, connect.CodeFailedPrecondition)
		if d.GetReason() != commonv1.ErrorReason_ERROR_REASON_PROTECTED_ACCOUNT {
			t.Errorf("repost reason = %v", d.GetReason())
		}
		budgettest.Assert(t, "RepostPost refusal", r.lineBudget(t, "/dzeroth.engagement.v1.EngagementService/RepostPost"), budgettest.Budget{Reads: 12})
		if w := r.lineBudget(t, "/dzeroth.engagement.v1.EngagementService/RepostPost").Writes(); w != 0 {
			t.Errorf("repost refusal writes = %d", w)
		}

		_, err = r.posts.CreatePost(ctx, authed(follower.token, &postsv1.CreatePostRequest{IdempotencyKey: contractKey("w329a-fq"), Text: "q", QuoteOfPostId: pid}))
		d = wireError(t, err, connect.CodeFailedPrecondition)
		if d.GetReason() != commonv1.ErrorReason_ERROR_REASON_PROTECTED_ACCOUNT {
			t.Errorf("quote reason = %v", d.GetReason())
		}
		if w := r.lineBudget(t, rpcCreate).Writes(); w != 0 {
			t.Errorf("quote refusal writes = %d", w)
		}

		if _, err := r.posts.CreatePost(ctx, authed(p.token, &postsv1.CreatePostRequest{IdempotencyKey: contractKey("w329a-pq"), Text: "self", QuoteOfPostId: pid})); err != nil {
			t.Errorf("the author quoting their own post: %v", err)
		}
		if _, err := r.eng.RepostPost(ctx, authed(p.token, &engagementv1.RepostPostRequest{IdempotencyKey: contractKey("w329a-prp"), PostId: pid})); err != nil {
			t.Errorf("the author reposting their own post: %v", err)
		}
	})

	t.Run("undo is never gated", func(t *testing.T) {
		if _, err := r.eng.UnlikePost(ctx, authed(stranger.token, &engagementv1.UnlikePostRequest{IdempotencyKey: contractKey("w329a-ul"), PostId: pid})); err != nil {
			t.Errorf("UnlikePost after protect: %v", err)
		}
		if _, err := r.remove(stranger, contractKey("w329a-rb"), pid); err != nil {
			t.Errorf("RemoveBookmark after protect: %v", err)
		}
	})

}
