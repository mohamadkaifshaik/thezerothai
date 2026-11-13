package apiserver

import (
	"context"
	"errors"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/internal/messaging"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
)

// sharePosts is a posts.Engagement over a fixed set of posts the caller may see; protected lists protected authors.
type sharePosts struct {
	visible   map[string]*posts.Post
	protected map[string]bool
	manyErr   error
}

func (f sharePosts) Viewable(_ context.Context, _, id string) (*posts.Post, error) {
	if p, ok := f.visible[id]; ok {
		return p, nil
	}
	return nil, posts.ErrNotFound
}

func (f sharePosts) ViewableMany(_ context.Context, _ string, ids []string) (map[string]*posts.Post, error) {
	if f.manyErr != nil {
		return nil, f.manyErr
	}
	out := map[string]*posts.Post{}
	for _, id := range ids {
		if p, ok := f.visible[id]; ok && p.Kind != posts.KindRepost {
			out[id] = p
		}
	}
	return out, nil
}

func (f sharePosts) RefuseShare(_ context.Context, caller string, p *posts.Post) error {
	if f.protected[p.AuthorID] && p.AuthorID != caller {
		return apierr.New(connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_PROTECTED_ACCOUNT, "this account's posts are protected")
	}
	return nil
}

func (sharePosts) CountsChanged(string, int64, int64)           {}
func (sharePosts) SharesChanged(string, int64)                  {}
func (sharePosts) PollVoted(string, int) *posts.Post            { return nil }
func (sharePosts) PollVoteChanged(string, int, int) *posts.Post { return nil }
func (sharePosts) RepostCreated(*posts.Post)                    {}
func (sharePosts) RepostRemoved(string, string)                 {}

const (
	spOrig      = "0000000000000000201"
	spRepost    = "0000000000000000202"
	spDangling  = "0000000000000000203" // a REPOST whose original the caller may not see
	spProtected = "0000000000000000204"
	spNoOrig    = "0000000000000000205" // a REPOST without an original id
)

func shareWorld() sharePosts {
	return sharePosts{
		visible: map[string]*posts.Post{
			spOrig:      {ID: spOrig, AuthorID: "carol", Kind: posts.KindPost, Text: "hello"},
			spRepost:    {ID: spRepost, AuthorID: "dave", Kind: posts.KindRepost, RepostOfID: spOrig},
			spDangling:  {ID: spDangling, AuthorID: "dave", Kind: posts.KindRepost, RepostOfID: "0000000000000000299"},
			spProtected: {ID: spProtected, AuthorID: "erin", Kind: posts.KindPost},
			spNoOrig:    {ID: spNoOrig, AuthorID: "dave", Kind: posts.KindRepost},
		},
		protected: map[string]bool{"erin": true},
	}
}

// postShareCheck: the GetPost rules (a REPOST id on itself and on its original), then the protected-author rule.
func TestPostShareCheck(t *testing.T) {
	tests := []struct {
		name, caller, id string
		want             messaging.SharedPost
		notVisible       bool
		protected        bool
	}{
		{"original", "alice", spOrig, messaging.SharedPost{ID: spOrig, AuthorID: "carol"}, false, false},
		{"a REPOST id resolves to its original", "alice", spRepost, messaging.SharedPost{ID: spOrig, AuthorID: "carol"}, false, false},
		{"missing", "alice", "0000000000000000999", messaging.SharedPost{}, true, false},
		{"a REPOST whose original is not visible", "alice", spDangling, messaging.SharedPost{}, true, false},
		{"a REPOST without an original", "alice", spNoOrig, messaging.SharedPost{}, true, false},
		{"protected author, another caller", "alice", spProtected, messaging.SharedPost{}, false, true},
		{"protected author, the author", "erin", spProtected, messaging.SharedPost{ID: spProtected, AuthorID: "erin"}, false, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := postShareCheck{posts: shareWorld()}.CheckShare(context.Background(), tt.caller, tt.id)
			switch {
			case tt.notVisible:
				if !errors.Is(err, messaging.ErrPostNotVisible) {
					t.Fatalf("err = %v, want ErrPostNotVisible", err)
				}
			case tt.protected:
				var ae *apierr.Error
				if !errors.As(err, &ae) || ae.Reason != commonv1.ErrorReason_ERROR_REASON_PROTECTED_ACCOUNT {
					t.Fatalf("err = %v, want PROTECTED_ACCOUNT", err)
				}
			default:
				if err != nil || got != tt.want {
					t.Fatalf("got %+v, %v; want %+v", got, err, tt.want)
				}
			}
		})
	}
}

// postCards: a live card for every post the reader may see, nothing for the rest; an error is passed on.
func TestPostCards(t *testing.T) {
	c := postCards{posts: shareWorld(), now: func() time.Time { return time.Unix(1_700_000_000, 0) }}
	got, err := c.Cards(context.Background(), "alice", []string{spOrig, spRepost, "0000000000000000999"})
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 1 || got[spOrig].GetText() != "hello" || got[spOrig].GetUnavailable() {
		t.Fatalf("cards = %v, want only the live card of %s", got, spOrig)
	}
	w := shareWorld()
	w.manyErr = errors.New("boom")
	if _, err := (postCards{posts: w}).Cards(context.Background(), "alice", []string{spOrig}); err == nil {
		t.Fatal("a batch error must be returned")
	}
}
