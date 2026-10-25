package posts

import (
	"context"
	"errors"
	"testing"
	"time"

	"connectrpc.com/connect"
	"google.golang.org/protobuf/types/known/timestamppb"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// fakeScheduler records its calls and returns canned results.
type fakeScheduler struct {
	scheduleIn    ScheduleInput
	scheduleUID   string
	listArgs      []any
	cancelArgs    []string
	calls         int
	item          *ScheduledPost
	page          ScheduledPage
	err           error
	ctxHadTimeout bool
}

func (f *fakeScheduler) Schedule(ctx context.Context, uid string, in ScheduleInput) (*ScheduledPost, error) {
	f.calls++
	f.scheduleUID, f.scheduleIn = uid, in
	_, f.ctxHadTimeout = ctx.Deadline()
	return f.item, f.err
}

func (f *fakeScheduler) ListScheduled(ctx context.Context, uid string, pageSize int, pageToken string) (ScheduledPage, error) {
	f.calls++
	f.listArgs = []any{uid, pageSize, pageToken}
	_, f.ctxHadTimeout = ctx.Deadline()
	return f.page, f.err
}

func (f *fakeScheduler) CancelScheduled(ctx context.Context, uid, key, id string) (*ScheduledPost, error) {
	f.calls++
	f.cancelArgs = []string{uid, key, id}
	_, f.ctxHadTimeout = ctx.Deadline()
	return f.item, f.err
}

type schedCall struct {
	name string
	call func(*Server, context.Context) error
}

func schedCalls() []schedCall {
	return []schedCall{
		{"SchedulePost", func(s *Server, ctx context.Context) error {
			_, err := s.SchedulePost(ctx, connect.NewRequest(&postsv1.SchedulePostRequest{IdempotencyKey: "k", Text: "t"}))
			return err
		}},
		{"ListScheduledPosts", func(s *Server, ctx context.Context) error {
			_, err := s.ListScheduledPosts(ctx, connect.NewRequest(&postsv1.ListScheduledPostsRequest{}))
			return err
		}},
		{"CancelScheduledPost", func(s *Server, ctx context.Context) error {
			_, err := s.CancelScheduledPost(ctx, connect.NewRequest(&postsv1.CancelScheduledPostRequest{}))
			return err
		}},
	}
}

// TestScheduledServer_FlagGate: FEATURE_POSTS first (plain FEATURE_DISABLED), then FEATURE_SCHEDULED_POSTS
// (FEATURE_DISABLED with feature=scheduled_posts); the scheduler is never reached when either is off.
func TestScheduledServer_FlagGate(t *testing.T) {
	tests := []struct {
		name        string
		on          map[string]bool
		wantFeature string
		wantReach   bool
	}{
		{"posts off", map[string]bool{"scheduled_posts": true}, "", false},
		{"scheduled_posts off", map[string]bool{"posts": true}, "scheduled_posts", false},
		{"both off", nil, "", false},
		{"both on", map[string]bool{"posts": true, "scheduled_posts": true}, "", true},
	}
	for _, tt := range tests {
		for _, c := range schedCalls() {
			t.Run(tt.name+"/"+c.name, func(t *testing.T) {
				sc := &fakeScheduler{item: &ScheduledPost{PublishAt: schedBase, CreatedAt: schedNow}}
				flags := namedFlags(tt.on)
				srv := NewServer(nil, flags, WithScheduler(sc)) // a nil Service: nothing but the scheduler may be touched
				ctx, info := logger.WithRequestInfo(callerCtx("u1"))
				err := c.call(srv, ctx)
				if tt.wantReach {
					if err != nil || sc.calls != 1 || !sc.ctxHadTimeout {
						t.Fatalf("err %v calls %d deadline %v, want one call with a deadline", err, sc.calls, sc.ctxHadTimeout)
					}
					return
				}
				ae := wantAPIError(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED)
				if ae.Metadata["feature"] != tt.wantFeature {
					t.Errorf("feature = %q, want %q", ae.Metadata["feature"], tt.wantFeature)
				}
				if sc.calls != 0 {
					t.Error("the scheduler (Firestore) was reached while a flag is off")
				}
				if v, _ := info.Get("outcome"); v != "rejected:feature_disabled" {
					t.Errorf("outcome = %v", v)
				}
			})
		}
	}
}

func TestScheduledServer_WithoutSchedulerIsUnimplemented(t *testing.T) {
	flags := namedFlags{"posts": true, "scheduled_posts": true}
	srv := NewServer(nil, flags)
	for _, c := range schedCalls() {
		if err := c.call(srv, callerCtx("u1")); connect.CodeOf(err) != connect.CodeUnimplemented {
			t.Errorf("%s: %v, want Unimplemented", c.name, err)
		}
	}
}

func TestScheduledServer_SchedulePostMapsTheRequest(t *testing.T) {
	at := time.Date(2026, 11, 3, 10, 0, 30, 0, time.UTC)
	tests := []struct {
		name   string
		flags  map[string]bool
		ts     *timestamppb.Timestamp
		wantAt time.Time
		want   [3]bool // media, reply_audience, content_disclosure
	}{
		{"all sub-features on", map[string]bool{"posts": true, "scheduled_posts": true, "media": true, "reply_audience": true, "content_disclosure": true},
			timestamppb.New(at), at, [3]bool{true, true, true}},
		{"sub-features off", map[string]bool{"posts": true, "scheduled_posts": true}, timestamppb.New(at), at, [3]bool{}},
		{"missing publish_at", map[string]bool{"posts": true, "scheduled_posts": true}, nil, time.Time{}, [3]bool{}},
		{"invalid timestamp", map[string]bool{"posts": true, "scheduled_posts": true}, &timestamppb.Timestamp{Seconds: 1 << 60}, time.Time{}, [3]bool{}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			created := schedNow
			sc := &fakeScheduler{item: &ScheduledPost{ID: "abc", PublishAt: at, Status: ScheduledPending, CreatedAt: created, Draft: &ScheduledDraft{Text: "hi", ReplyPolicy: ReplyPolicyFollowing}}}
			srv := NewServer(nil, namedFlags(tt.flags), WithScheduler(sc))
			resp, err := srv.SchedulePost(callerCtx("u1"), connect.NewRequest(&postsv1.SchedulePostRequest{
				IdempotencyKey: "0123456789abcdef", Text: "hi", MediaIds: []string{"1"}, MediaAltTexts: []string{"a"},
				ReplyPolicy: postsv1.ReplyPolicy_REPLY_POLICY_FOLLOWING, PaidPartnership: true, MadeWithAi: true, PublishAt: tt.ts,
			}))
			if err != nil {
				t.Fatal(err)
			}
			in := sc.scheduleIn
			if sc.scheduleUID != "u1" || in.IdempotencyKey != "0123456789abcdef" || in.Text != "hi" || len(in.MediaIDs) != 1 || in.MediaAltTexts[0] != "a" ||
				in.ReplyPolicy != int32(postsv1.ReplyPolicy_REPLY_POLICY_FOLLOWING) || !in.PaidPartnership || !in.MadeWithAI || !in.PublishAt.Equal(tt.wantAt) {
				t.Errorf("input = %+v uid %q", in, sc.scheduleUID)
			}
			if got := [3]bool{in.MediaEnabled, in.ReplyAudienceEnabled, in.DisclosureEnabled}; got != tt.want {
				t.Errorf("sub-feature flags = %v, want %v", got, tt.want)
			}
			if got := resp.Msg.GetScheduledPost(); got.GetScheduledId() != "abc" || got.GetText() != "hi" ||
				got.GetReplyPolicy() != postsv1.ReplyPolicy_REPLY_POLICY_FOLLOWING || !got.GetPublishAt().AsTime().Equal(at) {
				t.Errorf("response = %v", got)
			}
		})
	}
}

func TestScheduledServer_ListAndCancelMapArgumentsAndErrors(t *testing.T) {
	flags := namedFlags{"posts": true, "scheduled_posts": true}
	items := []*ScheduledPost{
		{ID: "a", PublishAt: schedBase, Status: ScheduledPending, CreatedAt: schedNow, Draft: &ScheduledDraft{Text: "one"}},
		{ID: "b", PublishAt: schedBase.Add(time.Minute), Status: ScheduledFailed, Failure: FailureExpired, CreatedAt: schedNow},
	}
	sc := &fakeScheduler{page: ScheduledPage{Items: items, NextPageToken: "next"}, item: items[0]}
	srv := NewServer(nil, flags, WithScheduler(sc))

	list, err := srv.ListScheduledPosts(callerCtx("u1"), connect.NewRequest(&postsv1.ListScheduledPostsRequest{PageSize: 7, PageToken: "tok"}))
	if err != nil {
		t.Fatal(err)
	}
	if sc.listArgs[0] != "u1" || sc.listArgs[1] != 7 || sc.listArgs[2] != "tok" {
		t.Errorf("list args = %v", sc.listArgs)
	}
	if got := list.Msg.GetScheduledPosts(); len(got) != 2 || got[1].GetFailure() != postsv1.ScheduledPostFailure_SCHEDULED_POST_FAILURE_EXPIRED || list.Msg.GetNextPageToken() != "next" {
		t.Errorf("list = %v", list.Msg)
	}

	cancelled, err := srv.CancelScheduledPost(callerCtx("u1"), connect.NewRequest(&postsv1.CancelScheduledPostRequest{IdempotencyKey: "kkkkkkkkkkkkkkkk", ScheduledId: "idid"}))
	if err != nil || cancelled.Msg.GetScheduledPost().GetScheduledId() != "a" {
		t.Fatalf("cancel = %v, %v", cancelled, err)
	}
	if want := []string{"u1", "kkkkkkkkkkkkkkkk", "idid"}; sc.cancelArgs[0] != want[0] || sc.cancelArgs[1] != want[1] || sc.cancelArgs[2] != want[2] {
		t.Errorf("cancel args = %v", sc.cancelArgs)
	}

	// A service error passes through untouched (the error-mapping interceptor shapes it).
	sc.err = apierr.New(connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "scheduled post not found")
	for _, c := range schedCalls() {
		if err := c.call(srv, callerCtx("u1")); !errors.Is(err, sc.err) {
			t.Errorf("%s: err = %v, want the service error", c.name, err)
		}
	}
}

func TestScheduledToProto(t *testing.T) {
	at := time.Date(2026, 11, 3, 10, 0, 0, 0, time.UTC)
	created := at.Add(-time.Hour)
	tests := []struct {
		name string
		in   *ScheduledPost
		want *postsv1.ScheduledPost
	}{
		{"pending with a draft", &ScheduledPost{
			ID: "id1", PublishAt: at, Status: ScheduledPending, CreatedAt: created,
			Draft: &ScheduledDraft{Text: "hello", Media: []MediaRef{{ID: "m1", URL: "u", ThumbURL: "t", Width: 4, Height: 3, AltText: "alt"}}, ReplyPolicy: ReplyPolicyMentionedOnly, PaidPartnership: true, MadeWithAI: true},
		}, &postsv1.ScheduledPost{
			ScheduledId: "id1", Text: "hello", ReplyPolicy: postsv1.ReplyPolicy_REPLY_POLICY_MENTIONED_ONLY, PaidPartnership: true, MadeWithAi: true,
			PublishAt: timestamppb.New(at), Status: postsv1.ScheduledPostStatus_SCHEDULED_POST_STATUS_PENDING, CreatedAt: timestamppb.New(created),
			Media: []*commonv1.MediaRef{{MediaId: "m1", Url: "u", ThumbUrl: "t", Width: 4, Height: 3, AltText: "alt"}},
		}},
		{"published has no text or media", &ScheduledPost{ID: "id2", PublishAt: at, Status: ScheduledPublished, PostID: "170", CreatedAt: created},
			&postsv1.ScheduledPost{ScheduledId: "id2", PublishAt: timestamppb.New(at), Status: postsv1.ScheduledPostStatus_SCHEDULED_POST_STATUS_PUBLISHED, PostId: "170", CreatedAt: timestamppb.New(created)}},
		{"cancelled", &ScheduledPost{ID: "id3", PublishAt: at, Status: ScheduledCancelled, CreatedAt: created},
			&postsv1.ScheduledPost{ScheduledId: "id3", PublishAt: timestamppb.New(at), Status: postsv1.ScheduledPostStatus_SCHEDULED_POST_STATUS_CANCELLED, CreatedAt: timestamppb.New(created)}},
		{"failed carries its reason", &ScheduledPost{ID: "id4", PublishAt: at, Status: ScheduledFailed, Failure: FailureMediaUnavailable, CreatedAt: created},
			&postsv1.ScheduledPost{ScheduledId: "id4", PublishAt: timestamppb.New(at), Status: postsv1.ScheduledPostStatus_SCHEDULED_POST_STATUS_FAILED, Failure: postsv1.ScheduledPostFailure_SCHEDULED_POST_FAILURE_MEDIA_UNAVAILABLE, CreatedAt: timestamppb.New(created)}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := ScheduledToProto(tt.in)
			if got.String() != tt.want.String() {
				t.Errorf("got  %v\nwant %v", got, tt.want)
			}
		})
	}
	// Every failure and status maps to a distinct, non-zero enum; unknown strings map to UNSPECIFIED.
	seen := map[postsv1.ScheduledPostFailure]bool{}
	for _, f := range []ScheduledFailure{FailureMediaUnavailable, FailureQuotaExceeded, FailureAccountRestricted, FailureInvalidContent, FailureExpired, FailureInternal, FailureUnsupported} {
		e := scheduledFailureToProto(f)
		if e == postsv1.ScheduledPostFailure_SCHEDULED_POST_FAILURE_UNSPECIFIED || seen[e] {
			t.Errorf("failure %s maps to %v", f, e)
		}
		seen[e] = true
	}
	if scheduledFailureToProto("nope") != postsv1.ScheduledPostFailure_SCHEDULED_POST_FAILURE_UNSPECIFIED ||
		scheduledStatusToProto("nope") != postsv1.ScheduledPostStatus_SCHEDULED_POST_STATUS_UNSPECIFIED {
		t.Error("unknown values must map to UNSPECIFIED")
	}
}
