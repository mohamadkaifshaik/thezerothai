// server.go is the thin Connect handler for PostService: extract the caller's uid, check the FEATURE_POSTS
// flag, call Service, map the result. No business logic and no Firestore here (CLAUDE.md: handlers stay thin;
// errors are mapped to Connect codes by pkg/platform/mw.ErrorMapping).
//
// T5 registers the service with every RPC behind the flag guard and otherwise Unimplemented; T8 (CreatePost)
// and T9 (DeletePost, GetPost) replace the bodies; GetThread and the reply path of CreatePost (P3) sit behind
// the extra FEATURE_REPLIES flag.
package posts

import (
	"context"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1/postsv1connect"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// FlagChecker is the minimal seam posts and timeline need from pkg/platform/flags.Registry (ADR-0002: depend
// on interfaces, not the concrete platform type). *flags.Registry satisfies it.
type FlagChecker interface {
	Enabled(uid, name string) bool
}

// GuardFeature is the ADR-0010 D1 flag check shared by PostService and TimelineService: it runs before any
// Firestore access and returns FAILED_PRECONDITION + FEATURE_DISABLED (0 reads from this code) when the posts
// flag is off for the caller. A rejected call logs feature_disabled=true and outcome=rejected:feature_disabled.
// A missing caller identity is UNAUTHENTICATED (unreachable: authn.IDTokenInterceptor runs first).
func GuardFeature(ctx context.Context, fc FlagChecker) error {
	uid, ok := authn.UIDFromContext(ctx)
	if !ok || uid == "" {
		return apierr.New(connect.CodeUnauthenticated, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "unauthenticated")
	}
	if fc == nil {
		return flags.Guard(ctx, nil, uid, FlagName)
	}
	return flags.Guard(ctx, fc.Enabled, uid, FlagName)
}

// Server adapts Service to postsv1connect.PostServiceHandler.
type Server struct {
	postsv1connect.UnimplementedPostServiceHandler
	svc    Service
	flags  FlagChecker
	viewer ViewerFlags
	// scheduler serves the three scheduled-post RPCs (WithScheduler); nil answers Unimplemented once the flags pass.
	scheduler Scheduler
}

// ServerOption configures NewServer.
type ServerOption func(*Server)

// WithViewerFlags supplies the engagement implementation of viewer flags (liked/reposted by the caller). Without
// it, or with FEATURE_ENGAGEMENT off for the caller, every flag is false and no userLikes read happens.
func WithViewerFlags(v ViewerFlags) ServerOption { return func(s *Server) { s.viewer = v } }

// NewServer builds the Connect handler. Use with postsv1connect.NewPostServiceHandler.
func NewServer(svc Service, fc FlagChecker, opts ...ServerOption) *Server {
	s := &Server{svc: svc, flags: fc}
	for _, o := range opts {
		o(s)
	}
	return s
}

// viewerSet is the caller's ViewerSet: one cached userLikes read when FEATURE_ENGAGEMENT or FEATURE_BOOKMARKS is on for
// uid, else the empty set with no read (ADR-0018 D5, ADR-0023 D5; HydrateViewer).
func (s *Server) viewerSet(ctx context.Context, uid string) ViewerSet {
	return HydrateViewer(ctx, s.flags, s.viewer, uid)
}

var _ postsv1connect.PostServiceHandler = (*Server)(nil)

// createDeadline bounds one CreatePost call (<= 10 s, go-service skill); the transaction itself has 5 s.
const createDeadline = 8 * time.Second

// CreatePost is behind the flag; everything else (validation order, mentions, the transaction) is
// Service.Create (T8).
func (s *Server) CreatePost(ctx context.Context, req *connect.Request[postsv1.CreatePostRequest]) (*connect.Response[postsv1.CreatePostResponse], error) {
	if err := GuardFeature(ctx, s.flags); err != nil {
		return nil, err
	}
	uid, _ := authn.UIDFromContext(ctx) // GuardFeature proved it is set
	ctx, cancel := context.WithTimeout(ctx, createDeadline)
	defer cancel()
	m := req.Msg
	post, err := s.svc.Create(ctx, uid, CreateInput{
		IdempotencyKey: m.GetIdempotencyKey(),
		Text:           m.GetText(),
		MediaIDs:       m.GetMediaIds(),
		MediaAltTexts:  m.GetMediaAltTexts(),
		ReplyToPostID:  m.GetReplyToPostId(),
		QuoteOfPostID:  m.GetQuoteOfPostId(),
		MediaEnabled:   s.mediaEnabled(uid),
		RepliesEnabled: s.repliesEnabled(uid),
		QuotesEnabled:  s.quotesEnabled(uid),

		PaidPartnership:   m.GetPaidPartnership(),
		MadeWithAI:        m.GetMadeWithAi(),
		DisclosureEnabled: s.disclosureEnabled(uid),

		ReplyPolicy:          int32(m.GetReplyPolicy()),
		ReplyAudienceEnabled: s.replyAudienceEnabled(uid),
	})
	if err != nil {
		return nil, err
	}
	return connect.NewResponse(&postsv1.CreatePostResponse{Post: &postsv1.PostView{Post: ToProto(post)}}), nil
}

// mediaFlagName is the wire name of FEATURE_MEDIA (media.FlagName; posts does not import media).
const mediaFlagName = "media"

// mediaEnabled reports FEATURE_MEDIA for uid; a nil checker means off (fail closed).
func (s *Server) mediaEnabled(uid string) bool {
	return s.flags != nil && s.flags.Enabled(uid, mediaFlagName)
}

// readDeadline bounds DeletePost and GetPost (<= 10 s, go-service skill).
const readDeadline = 5 * time.Second

// DeletePost is behind the flag; the rules (ownership, no-op cases, the batch) are Service.Delete (T9).
func (s *Server) DeletePost(ctx context.Context, req *connect.Request[postsv1.DeletePostRequest]) (*connect.Response[postsv1.DeletePostResponse], error) {
	if err := GuardFeature(ctx, s.flags); err != nil {
		return nil, err
	}
	uid, _ := authn.UIDFromContext(ctx) // GuardFeature proved it is set
	ctx, cancel := context.WithTimeout(ctx, readDeadline)
	defer cancel()
	if err := s.svc.Delete(ctx, uid, req.Msg.GetIdempotencyKey(), req.Msg.GetPostId()); err != nil {
		return nil, err
	}
	return connect.NewResponse(&postsv1.DeletePostResponse{}), nil
}

// GetPost is behind the flag; the visibility rules are Service.GetForViewer (T9). Viewer flags come from one
// cached userLikes read while FEATURE_ENGAGEMENT is on for the caller (ADR-0018 D5), else they are false.
// viewer_reply_permission (ADR-0021 D2) adds 0 reads, except <= +1 cold (R's author graph) for a FOLLOWING root;
// a reply in a restricted conversation is UNKNOWN. Never flag-gated.
func (s *Server) GetPost(ctx context.Context, req *connect.Request[postsv1.GetPostRequest]) (*connect.Response[postsv1.GetPostResponse], error) {
	if err := GuardFeature(ctx, s.flags); err != nil {
		return nil, err
	}
	uid, _ := authn.UIDFromContext(ctx)
	ctx, cancel := context.WithTimeout(ctx, readDeadline)
	defer cancel()
	post, err := s.svc.GetForViewer(ctx, uid, req.Msg.GetPostId())
	if err != nil {
		return nil, err
	}
	v := ToView(post, s.viewerSet(ctx, uid), uid)
	if h, ok := s.svc.(ReplyHinter); ok {
		v.ViewerReplyPermission = h.ReplyPermission(ctx, uid, post) // <= +1 read cold for a FOLLOWING root
	}
	if h, ok := s.svc.(EmbedHinter); ok {
		v.EmbedViewerState = h.EmbedViewerState(ctx, uid, post) // 0 reads without an embed, else the cached graph
	}
	return connect.NewResponse(&postsv1.GetPostResponse{Post: v}), nil
}

// RepliesFlagName is the wire name of FEATURE_REPLIES (P3). It is independent of FEATURE_POSTS but needs it:
// every RPC still passes GuardFeature first.
const RepliesFlagName = "replies"

// repliesEnabled is the FEATURE_REPLIES decision for uid (off when no checker is wired).
func (s *Server) repliesEnabled(uid string) bool {
	return s.flags != nil && s.flags.Enabled(uid, RepliesFlagName)
}

// QuotesFlagName is the wire name of FEATURE_QUOTES (amendment 2026-10-18 to ADR-0018 D8). It gates only quote
// CREATION; quote display (hydration, embeds) never consults it.
const QuotesFlagName = "quotes"

// quotesEnabled is the quote-creation decision for uid: the dedicated FEATURE_QUOTES flag AND FEATURE_ENGAGEMENT
// (quote embeds, counters and notifications need engagement). Off when no checker is wired (fail closed).
func (s *Server) quotesEnabled(uid string) bool {
	return s.flags != nil && s.flags.Enabled(uid, EngagementFlagName) && s.flags.Enabled(uid, QuotesFlagName)
}

// ContentDisclosureFlagName is the wire name of FEATURE_CONTENT_DISCLOSURE (ADR-0021 D3). It gates only SETTING a
// label on CreatePost; rendering the labels of existing posts never consults it.
const ContentDisclosureFlagName = "content_disclosure"

// disclosureEnabled is the FEATURE_CONTENT_DISCLOSURE decision for uid (off when no checker is wired).
func (s *Server) disclosureEnabled(uid string) bool {
	return s.flags != nil && s.flags.Enabled(uid, ContentDisclosureFlagName)
}

// ReplyAudienceFlagName is the wire name of FEATURE_REPLY_AUDIENCE (ADR-0021 D2). It gates only SETTING a reply
// policy on CreatePost; enforcing a stored policy and the viewer hint never consult it, so switching it off cannot
// reopen a restricted conversation.
const ReplyAudienceFlagName = "reply_audience"

// replyAudienceEnabled is the FEATURE_REPLY_AUDIENCE decision for uid (off when no checker is wired).
func (s *Server) replyAudienceEnabled(uid string) bool {
	return s.flags != nil && s.flags.Enabled(uid, ReplyAudienceFlagName)
}

// ReplyHinter is implemented by the concrete service (like Engagement, reached by type assertion so Service and
// its fakes stay unchanged): the GetPost viewer hint for a restricted root, which may spend one cached graph read.
type ReplyHinter interface {
	ReplyPermission(ctx context.Context, viewer string, p *Post) postsv1.ReplyPermission
}

// EmbedHinter is implemented by the concrete service (reached by type assertion like ReplyHinter): the viewer's
// block/mute state for the original a REPOST or QUOTE embeds (issue #152).
type EmbedHinter interface {
	EmbedViewerState(ctx context.Context, viewer string, p *Post) postsv1.EmbedViewerState
}

// GetThread is behind FEATURE_POSTS and FEATURE_REPLIES; the rules are Service.GetThread (P3).
func (s *Server) GetThread(ctx context.Context, req *connect.Request[postsv1.GetThreadRequest]) (*connect.Response[postsv1.GetThreadResponse], error) {
	if err := GuardFeature(ctx, s.flags); err != nil {
		return nil, err
	}
	uid, _ := authn.UIDFromContext(ctx)
	if !s.repliesEnabled(uid) {
		logger.SetRequestField(ctx, "feature_disabled", true)
		logger.SetRequestField(ctx, "outcome", "rejected:feature_disabled")
		return nil, featureDisabled("replies")
	}
	ctx, cancel := context.WithTimeout(ctx, readDeadline)
	defer cancel()
	t, err := s.svc.GetThread(ctx, uid, ThreadInput{
		PostID: req.Msg.GetPostId(), PageSize: req.Msg.GetPageSize(), PageToken: req.Msg.GetPageToken(),
	})
	if err != nil {
		return nil, err
	}
	vs := s.viewerSet(ctx, uid)
	view := func(p *Post) *postsv1.PostView { // the policy is per conversation: one hint for every row
		v := ToView(p, vs, uid)
		v.ViewerReplyPermission = t.ReplyPermission
		if h, ok := s.svc.(EmbedHinter); ok {
			v.EmbedViewerState = h.EmbedViewerState(ctx, uid, p)
		}
		return v
	}
	out := &postsv1.GetThreadResponse{
		Focal:             view(t.Focal),
		ParentUnavailable: t.ParentUnavailable,
		RootUnavailable:   t.RootUnavailable,
		NextPageToken:     t.NextPageToken,
	}
	if t.Parent != nil {
		out.Parent = view(t.Parent)
	}
	if t.Root != nil {
		out.Root = view(t.Root)
	}
	for _, p := range t.Replies {
		out.Replies = append(out.Replies, view(p))
	}
	return connect.NewResponse(out), nil
}
