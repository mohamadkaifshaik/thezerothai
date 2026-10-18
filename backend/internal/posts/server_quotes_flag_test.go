package posts

import (
	"errors"
	"testing"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// quoteRegistry is the real flag registry with posts and replies on and the given modes for engagement and quotes.
func quoteRegistry(engagement, quotes flags.Spec) *flags.Registry {
	engagement.Name, quotes.Name = EngagementFlagName, QuotesFlagName
	return flags.NewRegistry(
		flags.Spec{Name: "posts", Mode: flags.On},
		flags.Spec{Name: RepliesFlagName, Mode: flags.On},
		engagement, quotes,
	)
}

func allowOnly(uid string) flags.Spec {
	return flags.Spec{Mode: flags.Allowlist, Allowlist: map[string]struct{}{uid: {}}}
}

// TestServer_CreatePost_QuoteFlagMatrix is the FEATURE_QUOTES regression: quote creation needs the dedicated
// quotes flag AND the engagement flag; engagement alone no longer lets a direct API request create a quote.
func TestServer_CreatePost_QuoteFlagMatrix(t *testing.T) {
	on, off := flags.Spec{Mode: flags.On}, flags.Spec{Mode: flags.Off}
	tests := []struct {
		name       string
		engagement flags.Spec
		quotes     flags.Spec
		wantQuote  bool
	}{
		{"both on", on, on, true},
		{"engagement on, quotes off (default)", on, off, false},
		{"quotes on, engagement off", off, on, false},
		{"both off", off, off, false},
		{"both allowlisted for the caller", allowOnly(testUID), allowOnly(testUID), true},
		{"quotes allowlisted for someone else", on, allowOnly("someone-else"), false},
		{"engagement allowlisted for someone else", allowOnly("someone-else"), on, false},
		{"quotes percent 0", on, flags.Spec{Mode: flags.Percent, Percent: 0}, false},
		{"quotes percent 100", on, flags.Spec{Mode: flags.Percent, Percent: 100}, true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := newDeleteEnv()
			srv := NewServer(e.svc, quoteRegistry(tt.engagement, tt.quotes))
			resp, err := srv.CreatePost(callerCtx(testUID), connect.NewRequest(&postsv1.CreatePostRequest{
				IdempotencyKey: key1, Text: "my take", QuoteOfPostId: pidOther}))
			if tt.wantQuote {
				if err != nil {
					t.Fatalf("quote create: %v", err)
				}
				if got := resp.Msg.GetPost().GetPost().GetKind(); got != postsv1.PostKind_POST_KIND_QUOTE {
					t.Fatalf("kind = %v, want QUOTE", got)
				}
				return
			}
			var ae *apierr.Error
			if !errors.As(err, &ae) || ae.Code != connect.CodeFailedPrecondition ||
				ae.Reason != commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED || ae.Metadata["feature"] != "quotes" {
				t.Fatalf("err = %v, want FEATURE_DISABLED feature=quotes", err)
			}
			if e.repo.createCalls != 0 {
				t.Fatalf("a refused quote reached the repo (%d create calls)", e.repo.createCalls)
			}
		})
	}
}

// TestServer_CreatePost_QuotesFlagLeavesOtherPathsAlone: with quotes off a plain post still works and the
// sub-feature order (replies before quotes) is unchanged.
func TestServer_CreatePost_QuotesFlagLeavesOtherPathsAlone(t *testing.T) {
	on, off := flags.Spec{Mode: flags.On}, flags.Spec{Mode: flags.Off}
	e := newDeleteEnv()
	srv := NewServer(e.svc, quoteRegistry(on, off))
	if _, err := srv.CreatePost(callerCtx(testUID), connect.NewRequest(&postsv1.CreatePostRequest{IdempotencyKey: key1, Text: "plain"})); err != nil {
		t.Fatalf("plain post with quotes off: %v", err)
	}

	reg := flags.NewRegistry(
		flags.Spec{Name: "posts", Mode: flags.On},
		flags.Spec{Name: RepliesFlagName, Mode: flags.Off},
		flags.Spec{Name: EngagementFlagName, Mode: flags.On},
		flags.Spec{Name: QuotesFlagName, Mode: flags.Off},
	)
	srv = NewServer(newDeleteEnv().svc, reg)
	_, err := srv.CreatePost(callerCtx(testUID), connect.NewRequest(&postsv1.CreatePostRequest{
		IdempotencyKey: key1, Text: "x", ReplyToPostId: pidOther, QuoteOfPostId: pidOther}))
	var ae *apierr.Error
	if !errors.As(err, &ae) || ae.Metadata["feature"] != "replies" {
		t.Fatalf("err = %v, want FEATURE_DISABLED feature=replies first", err)
	}
}

// TestServer_GetPost_QuoteStillDisplaysWithQuotesOff: display never consults FEATURE_QUOTES. A stored QUOTE post
// with its embedded snapshot is returned by GetPost with engagement on and quotes off.
func TestServer_GetPost_QuoteStillDisplaysWithQuotesOff(t *testing.T) {
	on, off := flags.Spec{Mode: flags.On}, flags.Spec{Mode: flags.Off}
	e := newDeleteEnv()
	q := e.repo.docs[pidOther]
	q.Kind = KindQuote
	q.QuoteOfID = pidMine
	q.Embedded = &Embedded{PostID: pidMine, Author: AuthorSnapshot{UserID: testUID, Handle: "Alice"}, Text: "original"}
	q.EmbeddedAuthorID = testUID
	srv := NewServer(e.svc, quoteRegistry(on, off))
	got, err := srv.GetPost(callerCtx(testUID), connect.NewRequest(&postsv1.GetPostRequest{PostId: pidOther}))
	if err != nil {
		t.Fatal(err)
	}
	p := got.Msg.GetPost().GetPost()
	if p.GetKind() != postsv1.PostKind_POST_KIND_QUOTE || p.GetEmbedded().GetPostId() != pidMine || p.GetEmbedded().GetText() != "original" {
		t.Fatalf("quote did not display: %v", p)
	}
}
