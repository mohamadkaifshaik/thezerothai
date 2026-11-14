// server.go is the thin Connect handler for PostService: extract the caller's uid, check the FEATURE_POSTS
// flag, call Service, map the result. No business logic and no Firestore here (project rule: handlers stay thin;
// errors are mapped to Connect codes by pkg/platform/mw.ErrorMapping).
//
// The service is registered with every RPC behind the flag guard and otherwise Unimplemented. CreatePost,
// DeletePost and GetPost have real bodies; GetThread and the reply path of CreatePost sit behind
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

// FlagChecker is the minimal seam posts and timeline need from pkg/platform/flags.Registry (depend on interfaces, not the concrete platform type).
// *flags.Registry satisfies it.
type FlagChecker interface {
	Enabled(uid, name string) bool
}

// GuardFeature is the flag check shared by PostService and TimelineService: it runs before any
// Firestore access and returns FAILED_PRECONDITION + FEATURE_DISABLED when the posts
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
	// plans is the beacons reader of Post.beacon (SetBeaconPlans); nil renders every plan card unavailable.
	plans BeaconPlans
	// scheduler serves the three scheduled-post RPCs (WithScheduler); nil answers Unimplemented once the flags pass.
	scheduler Scheduler
	// editor serves PublishScheduledPostNow and UpdateScheduledPost (WithScheduledEditor).
	editor ScheduledEditor
}

// ServerOption configures NewServer.
type ServerOption func(*Server)

// WithViewerFlags supplies the engagement implementation of viewer flags (liked/reposted by the caller). Without
// it, or with both FEATURE_ENGAGEMENT and FEATURE_BOOKMARKS off for the caller, every flag is false and no userLikes read happens
// (with only bookmarks on, only bookmarked_by_viewer is set; HydrateViewer).
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
// uid, else the empty set with no read (HydrateViewer).
func (s *Server) viewerSet(ctx context.Context, uid string) ViewerSet {
	return HydrateViewer(ctx, s.flags, s.viewer, uid)
}

var _ postsv1connect.PostServiceHandler = (*Server)(nil)

// SetBeaconPlans wires the plan reader that hydrates Post.beacon (CreatePost, GetPost, GetThread). Like SetCommunityGate it is
// set once at startup, before ListenAndServe, because beacons is built after posts.
func (s *Server) SetBeaconPlans(p BeaconPlans) { s.plans = p }

// createDeadline bounds one CreatePost call (<= 10 s); the transaction itself has 5 s.
const createDeadline = 8 * time.Second

// CreatePost is behind the flag; everything else (validation order, mentions, the transaction) is
// Service.Create.
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
		GifEnabled:     s.gifEnabled(uid),
		RepliesEnabled: s.repliesEnabled(uid),
		QuotesEnabled:  s.quotesEnabled(uid),

		PaidPartnership:   m.GetPaidPartnership(),
		MadeWithAI:        m.GetMadeWithAi(),
		DisclosureEnabled: s.disclosureEnabled(uid),

		ReplyPolicy:          int32(m.GetReplyPolicy()),
		ReplyAudienceEnabled: s.replyAudienceEnabled(uid),

		Poll:         pollInputOf(m.GetPoll()),
		PollsEnabled: s.pollsEnabled(uid),

		CommunityID:            m.GetCommunityId(),
		CommunitiesEnabled:     s.communitiesEnabled(uid),
		CommunitiesGloballyOff: s.communitiesGloballyOff(),

		BeaconID:           m.GetBeaconId(),
		BeaconEmbedEnabled: s.flags != nil && s.flags.Enabled(uid, PostBeaconFlagName),
	})
	if err != nil {
		return nil, err
	}
	view := &postsv1.PostView{Post: ToProtoForViewer(post, uid)}
	// The plan card is decided for the creator like for any viewer (one batch read, only when the post carries a plan).
	view.Post.Beacon = beaconToProto(post, HydrateBeacons(ctx, s.flags, s.plans, ViewerSet{}, uid, post))
	view.Post.Community = communityRef(post, false) // the creator just passed the community gate: the flag is on for them
	if h, ok := s.svc.(VisibilityHinter); ok {      // a protected author sees their own post as FOLLOWERS
		ApplyWireVisibility(view, h.ProtectedAuthor(ctx, uid, post))
	}
	return connect.NewResponse(&postsv1.CreatePostResponse{Post: view}), nil
}

// mediaFlagName is the wire name of FEATURE_MEDIA (media.FlagName; posts does not import media).
const mediaFlagName = "media"

// mediaEnabled reports FEATURE_MEDIA for uid; a nil checker means off (fail closed).
func (s *Server) mediaEnabled(uid string) bool {
	return s.flags != nil && s.flags.Enabled(uid, mediaFlagName)
}

// readDeadline bounds DeletePost and GetPost (<= 10 s).
const readDeadline = 5 * time.Second

// DeletePost is behind the flag; the rules (ownership, no-op cases, the batch) are Service.Delete.
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

// GetPost is behind the flag; the visibility rules are Service.GetForViewer. Viewer flags come from one
// cached userLikes read while FEATURE_ENGAGEMENT or FEATURE_BOOKMARKS is on for the caller (with only bookmarks on just bookmarked_by_viewer is set),
// else they are false and nothing is read.
// viewer_reply_permission reads R's author graph only for a FOLLOWING root;
// a reply in a restricted conversation is UNKNOWN. Never flag-gated. A post in a community conversation is NOT_ALLOWED for a
// viewer who is not a JOINED member (a member doc lookup), skipped while communities is globally off. PostView.post.community
// (the label) is decided by ToView: absent when hidden or when communities is globally off. A community conversation has the EVERYONE policy, so the community hint never adds to the FOLLOWING lookup.
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
	vs := HydrateBeacons(ctx, s.flags, s.plans, s.viewerSet(ctx, uid), uid, post)
	if h, ok := s.svc.(PollBlockHinter); ok {
		vs = vs.WithBlockedAuthors(h.PollBlockedAuthors(ctx, uid, post)) // a poll by an author the viewer blocks: viewer_poll_vote_blocked
	}
	v := ToView(post, vs, uid)
	if h, ok := s.svc.(ReplyHinter); ok {
		v.ViewerReplyPermission = h.ReplyPermission(ctx, uid, post) // reads R's author graph for a FOLLOWING root
	}
	if perm, ok := s.communityReplyHint(ctx, uid, post, vs); ok && perm != postsv1.ReplyPermission_REPLY_PERMISSION_ALLOWED { // members only: NOT_ALLOWED, or UNKNOWN when the lookup failed; never loosens
		v.ViewerReplyPermission = perm
	}
	if h, ok := s.svc.(EmbedHinter); ok {
		ApplyEmbedState(v, h.EmbedViewerState(ctx, uid, post)) // no lookup without an embed, else the cached graph; PROTECTED strips the copy
	}
	if h, ok := s.svc.(VisibilityHinter); ok {
		protected := h.ProtectedAuthor(ctx, uid, post)
		ApplyWireVisibility(v, protected)
		ApplyPublicViews(v, post, protected)
	}
	s.applyAuthorLiveViews(ctx, v, uid, post) // the author's exact count (F1 post insights)
	return connect.NewResponse(&postsv1.GetPostResponse{Post: v}), nil
}

// RepliesFlagName is the wire name of FEATURE_REPLIES. It is independent of FEATURE_POSTS but needs it:
// every RPC still passes GuardFeature first.
const RepliesFlagName = "replies"

// repliesEnabled is the FEATURE_REPLIES decision for uid (off when no checker is wired).
func (s *Server) repliesEnabled(uid string) bool {
	return s.flags != nil && s.flags.Enabled(uid, RepliesFlagName)
}

// QuotesFlagName is the wire name of FEATURE_QUOTES. It gates only quote
// CREATION; quote display (hydration, embeds) never consults it.
const QuotesFlagName = "quotes"

// quotesEnabled is the quote-creation decision for uid: the dedicated FEATURE_QUOTES flag AND FEATURE_ENGAGEMENT
// (quote embeds, counters and notifications need engagement). Off when no checker is wired (fail closed).
func (s *Server) quotesEnabled(uid string) bool {
	return s.flags != nil && s.flags.Enabled(uid, EngagementFlagName) && s.flags.Enabled(uid, QuotesFlagName)
}

// ContentDisclosureFlagName is the wire name of FEATURE_CONTENT_DISCLOSURE. It gates only SETTING a
// label on CreatePost; rendering the labels of existing posts never consults it.
const ContentDisclosureFlagName = "content_disclosure"

// disclosureEnabled is the FEATURE_CONTENT_DISCLOSURE decision for uid (off when no checker is wired).
func (s *Server) disclosureEnabled(uid string) bool {
	return s.flags != nil && s.flags.Enabled(uid, ContentDisclosureFlagName)
}

// PollsFlagName is the wire name of FEATURE_POLLS. It gates CREATING a poll on CreatePost; voting
// (engagement) needs it only not globally off, and rendering a stored poll never consults it.
const PollsFlagName = "polls"

// pollsEnabled is the FEATURE_POLLS decision for uid (off when no checker is wired).
func (s *Server) pollsEnabled(uid string) bool {
	return s.flags != nil && s.flags.Enabled(uid, PollsFlagName)
}

// CommunitiesFlagName is the wire name of FEATURE_COMMUNITIES (communities.FlagName, posts does not import communities).
// It gates SETTING CreatePost.community_id.
const CommunitiesFlagName = "communities"

// communitiesEnabled is the FEATURE_COMMUNITIES decision for uid (off when no checker is wired).
func (s *Server) communitiesEnabled(uid string) bool {
	return s.flags != nil && s.flags.Enabled(uid, CommunitiesFlagName)
}

// communitiesGloballyOff is FEATURE_COMMUNITIES off for everyone (the kill switch). A checker that cannot tell (no GloballyOff) is "not off":
// the label and the reply gate stay as stored, which only matters in tests.
func (s *Server) communitiesGloballyOff() bool {
	g, ok := s.flags.(GloballyOffChecker)
	return ok && g.GloballyOff(CommunitiesFlagName)
}

// CommunityReplyHinter is implemented by the concrete service (reached by type assertion like ReplyHinter): the members-only viewer hint of a
// community conversation. GetPost and GetThread ask it only while communities is not globally off.
type CommunityReplyHinter interface {
	CommunityReplyPermission(ctx context.Context, viewer string, p *Post) (postsv1.ReplyPermission, bool)
}

// communityReplyHint overrides v.ViewerReplyPermission with the members-only hint when p's conversation is a community's and the lookup said something.
func (s *Server) communityReplyHint(ctx context.Context, viewer string, p *Post, vs ViewerSet) (postsv1.ReplyPermission, bool) {
	if vs.communitiesOff {
		return 0, false
	}
	h, ok := s.svc.(CommunityReplyHinter)
	if !ok {
		return 0, false
	}
	return h.CommunityReplyPermission(ctx, viewer, p)
}

// ReplyAudienceFlagName is the wire name of FEATURE_REPLY_AUDIENCE. It gates only SETTING a reply
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

// PollBlockHinter is implemented by the concrete service (reached by type assertion like ReplyHinter): the viewer's blocked set for a post with
// a live poll by another author, for PostView.viewer_poll_vote_blocked. It uses the snapshot GetPost cached.
type PollBlockHinter interface {
	PollBlockedAuthors(ctx context.Context, viewer string, p *Post) map[string]bool
}

// VisibilityHinter is implemented by the concrete service: whether the post's author is protected, for the computed wire
// visibility (VISIBILITY_FOLLOWERS). It costs the caller no lookup.
type VisibilityHinter interface {
	ProtectedAuthor(ctx context.Context, viewer string, p *Post) bool
}

// GetThread is behind FEATURE_POSTS and FEATURE_REPLIES; the rules are Service.GetThread.
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
	page := append([]*Post{t.Focal, t.Parent, t.Root}, t.Replies...)
	vs := HydrateBeacons(ctx, s.flags, s.plans, s.viewerSet(ctx, uid), uid, page...).WithBlockedAuthors(t.BlockedAuthors)
	replyPerm := t.ReplyPermission
	if perm, ok := s.communityReplyHint(ctx, uid, t.Focal, vs); ok && perm != postsv1.ReplyPermission_REPLY_PERMISSION_ALLOWED { // members only
		replyPerm = perm
	}
	view := func(p *Post) *postsv1.PostView { // the policy is per conversation: one hint for every row
		v := ToView(p, vs, uid)
		v.ViewerReplyPermission = replyPerm
		if h, ok := s.svc.(EmbedHinter); ok {
			ApplyEmbedState(v, h.EmbedViewerState(ctx, uid, p))
		}
		if h, ok := s.svc.(VisibilityHinter); ok {
			protected := h.ProtectedAuthor(ctx, uid, p)
			ApplyWireVisibility(v, protected)
			ApplyPublicViews(v, p, protected)
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

// GifFlagName is the wire name of FEATURE_GIF (media.GifFlagName, a test keeps them equal).
const GifFlagName = "gif"

// gifEnabled is the FEATURE_GIF decision for uid (off when no checker is wired).
func (s *Server) gifEnabled(uid string) bool {
	return s.flags != nil && s.flags.Enabled(uid, GifFlagName)
}
