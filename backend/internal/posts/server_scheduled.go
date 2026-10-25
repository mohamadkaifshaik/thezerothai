// server_scheduled.go holds the Connect handlers of scheduled posts (ADR-0021 D4): thin, like the rest of server.go.
// Each checks FEATURE_POSTS (GuardFeature) and then FEATURE_SCHEDULED_POSTS before any Firestore access, and the
// rules are the Scheduler's (service_scheduled.go).
package posts

import (
	"context"
	"time"

	"connectrpc.com/connect"
	"google.golang.org/protobuf/types/known/timestamppb"

	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// WithScheduler wires the Scheduler behind SchedulePost, ListScheduledPosts and CancelScheduledPost. Without it they
// answer Unimplemented (after the flag checks).
func WithScheduler(sc Scheduler) ServerOption { return func(s *Server) { s.scheduler = sc } }

// guardScheduled is the flag gate of the three RPCs: FEATURE_POSTS, then FEATURE_SCHEDULED_POSTS for the caller. Off
// is FAILED_PRECONDITION + FEATURE_DISABLED with metadata feature=scheduled_posts (the latter), 0 reads.
func (s *Server) guardScheduled(ctx context.Context) (uid string, err error) {
	if err := GuardFeature(ctx, s.flags); err != nil {
		return "", err
	}
	uid, _ = authn.UIDFromContext(ctx) // GuardFeature proved it is set
	if !s.flags.Enabled(uid, ScheduledPostsFlagName) {
		logger.SetRequestField(ctx, "feature_disabled", true)
		logger.SetRequestField(ctx, fieldOutcome, "rejected:feature_disabled")
		logger.SetRequestField(ctx, fieldFeature, ScheduledPostsFlagName)
		return "", featureDisabled(ScheduledPostsFlagName)
	}
	return uid, nil
}

// SchedulePost is behind FEATURE_POSTS and FEATURE_SCHEDULED_POSTS. It shares the CreatePost rate-limit bucket (the
// apiserver rate-limit config). Worst case 9 reads, 2 writes (Scheduler.Schedule).
func (s *Server) SchedulePost(ctx context.Context, req *connect.Request[postsv1.SchedulePostRequest]) (*connect.Response[postsv1.SchedulePostResponse], error) {
	uid, err := s.guardScheduled(ctx)
	if err != nil {
		return nil, err
	}
	if s.scheduler == nil {
		return s.UnimplementedPostServiceHandler.SchedulePost(ctx, req)
	}
	ctx, cancel := context.WithTimeout(ctx, createDeadline)
	defer cancel()
	m := req.Msg
	var publishAt time.Time
	if ts := m.GetPublishAt(); ts != nil && ts.CheckValid() == nil {
		publishAt = ts.AsTime()
	}
	p, err := s.scheduler.Schedule(ctx, uid, ScheduleInput{
		IdempotencyKey:  m.GetIdempotencyKey(),
		Text:            m.GetText(),
		MediaIDs:        m.GetMediaIds(),
		MediaAltTexts:   m.GetMediaAltTexts(),
		ReplyPolicy:     int32(m.GetReplyPolicy()),
		PaidPartnership: m.GetPaidPartnership(),
		MadeWithAI:      m.GetMadeWithAi(),
		PublishAt:       publishAt,

		MediaEnabled:         s.mediaEnabled(uid),
		ReplyAudienceEnabled: s.replyAudienceEnabled(uid),
		DisclosureEnabled:    s.disclosureEnabled(uid),
	})
	if err != nil {
		return nil, err
	}
	return connect.NewResponse(&postsv1.SchedulePostResponse{ScheduledPost: ScheduledToProto(p)}), nil
}

// ListScheduledPosts is behind FEATURE_POSTS and FEATURE_SCHEDULED_POSTS; reads 1 + page.
func (s *Server) ListScheduledPosts(ctx context.Context, req *connect.Request[postsv1.ListScheduledPostsRequest]) (*connect.Response[postsv1.ListScheduledPostsResponse], error) {
	uid, err := s.guardScheduled(ctx)
	if err != nil {
		return nil, err
	}
	if s.scheduler == nil {
		return s.UnimplementedPostServiceHandler.ListScheduledPosts(ctx, req)
	}
	ctx, cancel := context.WithTimeout(ctx, readDeadline)
	defer cancel()
	page, err := s.scheduler.ListScheduled(ctx, uid, int(req.Msg.GetPageSize()), req.Msg.GetPageToken())
	if err != nil {
		return nil, err
	}
	out := &postsv1.ListScheduledPostsResponse{NextPageToken: page.NextPageToken}
	for _, p := range page.Items {
		out.ScheduledPosts = append(out.ScheduledPosts, ScheduledToProto(p))
	}
	return connect.NewResponse(out), nil
}

// CancelScheduledPost is behind FEATURE_POSTS and FEATURE_SCHEDULED_POSTS; reads 1 (+ the interceptor's), writes 1
// (0 when already terminal). It shares the CreatePost rate-limit bucket.
func (s *Server) CancelScheduledPost(ctx context.Context, req *connect.Request[postsv1.CancelScheduledPostRequest]) (*connect.Response[postsv1.CancelScheduledPostResponse], error) {
	uid, err := s.guardScheduled(ctx)
	if err != nil {
		return nil, err
	}
	if s.scheduler == nil {
		return s.UnimplementedPostServiceHandler.CancelScheduledPost(ctx, req)
	}
	ctx, cancel := context.WithTimeout(ctx, readDeadline)
	defer cancel()
	p, err := s.scheduler.CancelScheduled(ctx, uid, req.Msg.GetIdempotencyKey(), req.Msg.GetScheduledId())
	if err != nil {
		return nil, err
	}
	return connect.NewResponse(&postsv1.CancelScheduledPostResponse{ScheduledPost: ScheduledToProto(p)}), nil
}

// ScheduledToProto converts a stored item to its wire shape. Text, media, reply policy and the labels come from the
// draft, which exists only while PENDING (cleared on PUBLISHED, CANCELLED and, by founder decision 2026-10-24, FAILED), so
// only a PENDING item carries them. publish_at is the stored whole minute.
func ScheduledToProto(p *ScheduledPost) *postsv1.ScheduledPost {
	out := &postsv1.ScheduledPost{
		ScheduledId: p.ID,
		PublishAt:   timestamppb.New(p.PublishAt),
		Status:      scheduledStatusToProto(p.Status),
		PostId:      p.PostID,
		Failure:     scheduledFailureToProto(p.Failure),
		CreatedAt:   timestamppb.New(p.CreatedAt),
	}
	if d := p.Draft; d != nil {
		out.Text = d.Text
		out.Media = mediaRefsToProto(d.Media)
		out.ReplyPolicy = policyToProto(d.ReplyPolicy)
		out.PaidPartnership = d.PaidPartnership
		out.MadeWithAi = d.MadeWithAI
	}
	return out
}

func scheduledStatusToProto(s ScheduledStatus) postsv1.ScheduledPostStatus {
	switch s {
	case ScheduledPending:
		return postsv1.ScheduledPostStatus_SCHEDULED_POST_STATUS_PENDING
	case ScheduledPublished:
		return postsv1.ScheduledPostStatus_SCHEDULED_POST_STATUS_PUBLISHED
	case ScheduledCancelled:
		return postsv1.ScheduledPostStatus_SCHEDULED_POST_STATUS_CANCELLED
	case ScheduledFailed:
		return postsv1.ScheduledPostStatus_SCHEDULED_POST_STATUS_FAILED
	}
	return postsv1.ScheduledPostStatus_SCHEDULED_POST_STATUS_UNSPECIFIED
}

func scheduledFailureToProto(f ScheduledFailure) postsv1.ScheduledPostFailure {
	switch f {
	case FailureMediaUnavailable:
		return postsv1.ScheduledPostFailure_SCHEDULED_POST_FAILURE_MEDIA_UNAVAILABLE
	case FailureQuotaExceeded:
		return postsv1.ScheduledPostFailure_SCHEDULED_POST_FAILURE_QUOTA_EXCEEDED
	case FailureAccountRestricted:
		return postsv1.ScheduledPostFailure_SCHEDULED_POST_FAILURE_ACCOUNT_RESTRICTED
	case FailureInvalidContent:
		return postsv1.ScheduledPostFailure_SCHEDULED_POST_FAILURE_INVALID_CONTENT
	case FailureExpired:
		return postsv1.ScheduledPostFailure_SCHEDULED_POST_FAILURE_EXPIRED
	case FailureInternal:
		return postsv1.ScheduledPostFailure_SCHEDULED_POST_FAILURE_INTERNAL
	case FailureUnsupported:
		return postsv1.ScheduledPostFailure_SCHEDULED_POST_FAILURE_UNSUPPORTED
	}
	return postsv1.ScheduledPostFailure_SCHEDULED_POST_FAILURE_UNSPECIFIED
}
