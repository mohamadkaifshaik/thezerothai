// service_thread.go is the replies slice (P3, plan docs/plans/replies-and-threads.md): the reply path of
// CreatePost (parent resolution), the parent's replyCount release on delete, and GetThread.
//
// Pull model (ADR-0004): a reply is an ordinary posts doc with isReply = true. It is never written to, nor
// fanned out to, any timeline: the Home and Posts-tab queries filter isReply == false, and the Replies tab is
// the author query without that filter.
package posts

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"strings"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/cursor"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ids"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/snowflake"
)

// Thread page sizes (cost-model lever 6.2): the first page is small; the cap keeps GetThread's worst case well
// inside the 55-read plan budget even with three author-profile reads (CLAUDE.md rule 5: <= 50).
const (
	ThreadDefaultPageSize = 10
	ThreadMaxPageSize     = 30
)

// Request-log fields for GetThread (counts only, never ids).
const (
	fieldThreadReturned = "thread_replies_returned"
	fieldThreadDropped  = "thread_replies_dropped"
	fieldThreadContext  = "thread_context_unavailable"
	outcomeThread       = "thread"
)

// ThreadInput is the GetThread request at the domain layer.
type ThreadInput struct {
	PostID    string
	PageSize  int32
	PageToken string
}

// Thread is the GetThread result. Parent/Root are nil when the focal post is a root, or when the context post
// is unavailable (then the matching *Unavailable flag is true and the client renders a tombstone).
type Thread struct {
	Focal             *Post
	Parent            *Post
	Root              *Post
	ParentUnavailable bool
	RootUnavailable   bool
	Replies           []*Post
	NextPageToken     string
	// ReplyPermission is the viewer hint shared by every row of the thread (ADR-0021 D2).
	ReplyPermission postsv1.ReplyPermission
}

// replyParent validates a reply target for CreatePost: the id shape, then the GetPost visibility rules
// (viewable). Every refusal is the one NOT_FOUND "post not found" answer, so the response reveals neither a
// deleted parent nor a block. A REPOST parent resolves to the original (ADR-0018 D17, shared resolver): the reply's
// parent, conversationId and replyToHandle come from the original, which gets the replyCount; the REPOST's
// counters stay 0. Reads: parent 1 + its author 1 + caller graph 1 cold, 0 warm; +2 cold for a REPOST (the
// original and its author).
func (s *service) replyParent(ctx context.Context, uid, parentID string) (*Post, error) {
	if !ids.ValidPostID(parentID) {
		return nil, apierr.Validation("reply_to_post_id", "reply_to_post_id must be a 19-digit post id")
	}
	return s.resolveTarget(ctx, uid, parentID)
}

// releaseParent decrements a deleted reply's parent counter. It runs after the reply's own delete committed
// (exactly one caller wins the Exists precondition, so it runs once per reply) and is best effort: a failure
// leaves the count one too high, which is cosmetic, and is logged (no ids).
func (s *service) releaseParent(ctx context.Context, p *Post) {
	if p.ReplyToID == "" {
		return
	}
	if err := s.repo.AddReplyCount(ctx, p.ReplyToID, -1); err != nil {
		slog.WarnContext(ctx, "posts_reply_count_release_failed", "error", logger.RedactErr(err, p.AuthorID).Error())
	}
	s.cache.DeletePost(p.ReplyToID) // its replyCount changed; other instances converge within the cache TTL
}

func threadPageSize(requested int32) int {
	switch {
	case requested <= 0:
		return ThreadDefaultPageSize
	case requested > ThreadMaxPageSize:
		return ThreadMaxPageSize
	default:
		return int(requested)
	}
}

func threadBinding(caller, focal string) string { return "thread|" + caller + "|" + focal }

// GetThread implements Service.
//
// Firestore, worst case with the interceptor's caller read: 1 + focal 1 + focal author 1 + caller graph 1 (+1
// author graph on blockedBy overflow) + parent and root 2 + their authors <= 2 + one conversation query of
// Limit(page) <= 30 => 38 cold (+2 when the focal id is a REPOST: its original and that author => 40); warm: the query only (1 .. 30). Writes 0.
// The viewer_reply_permission hint (ADR-0021 D2) adds <= +1 cold (R's author graph, FOLLOWING conversations only;
// +0 warm, +0 for EVERYONE / MENTIONED_ONLY / the root author): 39 cold, 41 for a REPOST focal. A QUOTE or REPOST parent or root is
// checked against the caller's blockedBy set already in the snapshot: 0 extra reads (overflow fails closed).
func (s *service) GetThread(ctx context.Context, callerUID string, in ThreadInput) (_ *Thread, err error) {
	logger.SetRequestField(ctx, fieldOp, "thread")
	defer func() {
		if err != nil && !isPostNotFound(err) {
			noteRejected(ctx, err)
		}
	}()
	if err := validatePostID(in.PostID); err != nil {
		return nil, err
	}
	limit := threadPageSize(in.PageSize)
	var after *Position
	if in.PageToken != "" {
		cur, err := cursor.DecodeAt(s.cursorKey, threadBinding(callerUID, in.PostID), in.PageToken, s.now())
		if err != nil || cursor.IsFirstPage(cur) {
			return nil, apierr.Validation("page_token", "page_token is invalid or expired")
		}
		after = &Position{CreatedAt: cur.CreatedAt, ID: cur.DocID}
	}

	focal, err := s.viewableResolved(ctx, callerUID, in.PostID) // a REPOST id opens the original's thread (D17)
	if errors.Is(err, ErrNotFound) {
		return nil, s.notFound(ctx)
	}
	if err != nil {
		return nil, err
	}
	snap, err := s.graph.Snapshot(ctx, callerUID) // cached by viewable (or the first read for the caller's own post)
	if err != nil {
		return nil, logger.RedactErr(fmt.Errorf("posts: thread: caller graph: %w", err), callerUID)
	}

	out := &Thread{Focal: focal}
	root := focal.ConversationID
	if root == "" {
		root = focal.ID
	}
	if focal.ReplyToID != "" {
		if err := s.threadContext(ctx, callerUID, snap, focal, root, out); err != nil {
			return nil, err
		}
	}

	out.ReplyPermission = s.threadReplyPermission(ctx, callerUID, snap, focal, out)

	// The conversation page. The root is skipped by starting strictly after its position, which a Snowflake id
	// carries (no read, and it works when the root is deleted).
	if after == nil {
		if t, err := snowflake.Time(root); err == nil {
			after = &Position{CreatedAt: t, ID: root}
		}
	}
	readAt := s.now()
	docs, err := s.repo.Conversation(ctx, root, after, limit)
	if err != nil {
		return nil, logger.RedactErr(fmt.Errorf("posts: thread: conversation: %w", err), callerUID)
	}
	s.fill(docs, readAt)
	skip := map[string]bool{focal.ID: true, root: true, focal.ReplyToID: true}
	dropped := 0
	for _, p := range docs {
		switch {
		case skip[p.ID]:
		case p.Visibility != VisibilityPublic || p.Hidden() || !replyAllowed(snap, callerUID, p.AuthorID): // ADR-0016: hidden replies are dropped
			dropped++
		default:
			out.Replies = append(out.Replies, p)
		}
	}
	if len(docs) >= limit { // a full page always gets a next token, even when everything on it was dropped
		last := docs[len(docs)-1]
		out.NextPageToken = cursor.EncodeAt(s.cursorKey, threadBinding(callerUID, in.PostID),
			cursor.Cursor{CreatedAt: last.CreatedAt, DocID: last.ID}, s.now())
	}
	logger.SetRequestField(ctx, fieldThreadReturned, len(out.Replies))
	logger.SetRequestField(ctx, fieldThreadDropped, dropped)
	logger.SetRequestField(ctx, fieldOutcome, outcomeThread)
	return out, nil
}

// threadContext resolves the parent and the conversation root of a reply in one GetAll plus one profile batch.
// A context post that is missing, not public, by a non-ACTIVE author, by an author who blocks the caller (or
// whom the caller blocks) is unavailable: flagged, never an error, and never distinguishable by cause.
func (s *service) threadContext(ctx context.Context, caller string, snap graph.Snapshot, focal *Post, root string, out *Thread) error {
	ids := []string{focal.ReplyToID}
	if root != focal.ReplyToID && root != focal.ID {
		ids = append(ids, root)
	}
	found, err := s.GetMany(ctx, ids)
	if err != nil {
		return logger.RedactErr(fmt.Errorf("posts: thread: load context: %w", err), caller)
	}
	var authors []string
	seen := map[string]bool{}
	for _, p := range found {
		if !seen[p.AuthorID] {
			seen[p.AuthorID] = true
			authors = append(authors, p.AuthorID)
		}
	}
	profiles, err := s.directory.GetProfiles(ctx, authors)
	if err != nil {
		return logger.RedactErr(fmt.Errorf("posts: thread: load context authors: %w", err), caller)
	}
	usable := func(id string) *Post {
		p, ok := found[id]
		if !ok {
			return nil
		}
		_, active := profiles[p.AuthorID]
		if !contextUsable(p, active, caller, snap) {
			return nil
		}
		return p
	}
	out.Parent = usable(focal.ReplyToID)
	out.ParentUnavailable = out.Parent == nil
	if root == focal.ReplyToID {
		out.Root, out.RootUnavailable = out.Parent, out.ParentUnavailable
	} else {
		out.Root = usable(root)
		out.RootUnavailable = out.Root == nil
	}
	if out.ParentUnavailable || out.RootUnavailable {
		logger.SetRequestField(ctx, fieldThreadContext, true)
	}
	return nil
}

// contextUsable is the one "context post is usable" predicate (ADR-0021 D2, security review M-1), shared by
// GetThread's parent/root rows and by reply enforcement, so both give the same answer and neither can become a
// block oracle. It reads nothing. p is usable when it is public and not hidden by a moderator (ADR-0016), its
// author has an ACTIVE profile (authorActive: GetProfiles omits SUSPENDED, DELETING and missing authors), and,
// unless the caller is its author, no block either way (snap.BlockedBy / snap.Blocked), the caller's blockedBy
// set has not overflowed (fail closed rather than spend an author-graph read per row) and, for a QUOTE or
// REPOST, the embedded author does not block the caller (ADR-0018 D13). The caller's own posts are exempt, same
// as a direct post, and then snap is not consulted.
func contextUsable(p *Post, authorActive bool, caller string, snap graph.Snapshot) bool {
	if p == nil || p.Visibility != VisibilityPublic || p.Hidden() || !authorActive {
		return false
	}
	if p.AuthorID == caller {
		return true
	}
	if snap.BlockedBy[p.AuthorID] || snap.Blocked[p.AuthorID] || snap.BlockedByOverflow {
		return false
	}
	if emb := p.EmbeddedAuthor(); emb != "" && emb != caller && snap.BlockedBy[emb] {
		return false
	}
	return true
}

// enforceReplyPolicy refuses a reply the conversation's reply policy does not allow (ADR-0021 D2). It runs in
// Create right after replyParent, so a parent the caller cannot see has already answered NOT_FOUND. It is NOT
// flag-gated: switching FEATURE_REPLY_AUDIENCE off must never reopen a restricted conversation. An EVERYONE /
// absent policy returns at once: +0 reads, the root is never loaded.
//
// parent is the resolved parent (a REPOST already resolved to its original) and carries the conversation's
// effective policy. The root R is the parent itself for a direct reply, else posts.Get(conversationId), cache
// first. R must be usable (contextUsable): any unusable R is the single NOT_FOUND, so REPLY_NOT_ALLOWED can never
// mean "R's author blocked me" (review M-1). Only then: R's author always may reply; MENTIONED_ONLY needs the
// caller in R.Mentions; FOLLOWING needs R's author to follow the caller (one graph.Reader.Snapshot, cached 60 s).
//
// Extra reads over a plain reply, cold (0 warm): parent = R: MENTIONED_ONLY +0, FOLLOWING +1 (R's author graph);
// deeper: R +1, R's author profile +1 (0 when it is the parent's author), the caller's graph +1 (only when the
// caller wrote the parent, since viewable skipped it), FOLLOWING +1: MENTIONED_ONLY +3, FOLLOWING +4 worst case.
// A refusal costs the same reads and writes nothing.
func (s *service) enforceReplyPolicy(ctx context.Context, uid string, parent *Post) error {
	policy := parent.ReplyPolicy
	if !policy.Restricted() {
		return nil
	}
	rootID := parent.ConversationID
	if rootID == "" {
		rootID = parent.ID
	}
	root := parent
	if rootID != parent.ID {
		p, err := s.Get(ctx, rootID)
		if errors.Is(err, ErrNotFound) {
			return s.notFound(ctx)
		}
		if err != nil {
			return logger.RedactErr(fmt.Errorf("posts: reply policy: load root: %w", err), uid)
		}
		root = p
	}
	var snap graph.Snapshot
	active := true // the caller is ACTIVE (interceptor); the parent's author was proven ACTIVE by viewable
	if root.AuthorID != uid {
		if root != parent && root.AuthorID != parent.AuthorID {
			profiles, err := s.directory.GetProfiles(ctx, []string{root.AuthorID})
			if err != nil {
				return logger.RedactErr(fmt.Errorf("posts: reply policy: load root author: %w", err), uid, root.AuthorID)
			}
			_, active = profiles[root.AuthorID]
		}
		var err error
		if snap, err = s.graph.Snapshot(ctx, uid); err != nil {
			return logger.RedactErr(fmt.Errorf("posts: reply policy: caller graph: %w", err), uid)
		}
	}
	if !contextUsable(root, active, uid, snap) {
		return s.notFound(ctx)
	}
	if root.AuthorID == uid {
		return nil
	}
	switch policy {
	case ReplyPolicyMentionedOnly:
		for _, m := range root.Mentions {
			if m.UserID == uid {
				return nil
			}
		}
	case ReplyPolicyFollowing:
		rs, err := s.graph.Snapshot(ctx, root.AuthorID)
		if err != nil {
			return logger.RedactErr(fmt.Errorf("posts: reply policy: root author graph: %w", err), uid, root.AuthorID)
		}
		if rs.Following[uid] {
			return nil
		}
	}
	return replyNotAllowed(policy)
}

// replyNotAllowed is the REPLY_NOT_ALLOWED refusal (PERMISSION_DENIED, ADR-0021 D2) with metadata["policy"] set to
// the lower-snake-case policy name ("following", "mentioned_only").
func replyNotAllowed(policy ReplyPolicy) error {
	return apierr.New(connect.CodePermissionDenied, commonv1.ErrorReason_ERROR_REASON_REPLY_NOT_ALLOWED,
		"you can't reply to this conversation").WithMeta("policy", strings.ToLower(string(policy)))
}

// rootReplyPermission is the viewer hint for a conversation whose root R is loaded (ADR-0021 D2 "Viewer hint"):
// the decision CreatePost would make, but UNKNOWN whenever R is not usable for the viewer (contextUsable), so a
// hint never tells a blocked viewer anything. EVERYONE and R's author are ALLOWED without a read; MENTIONED_ONLY
// reads R.Mentions; FOLLOWING is one cached graph snapshot of R's author (1 read cold, an error is UNKNOWN).
// R's author is ACTIVE for every caller (R came from viewable or from threadContext).
func (s *service) rootReplyPermission(ctx context.Context, viewer string, root *Post, snap graph.Snapshot) postsv1.ReplyPermission {
	switch {
	case !root.ReplyPolicy.Restricted(), root.AuthorID == viewer:
		return postsv1.ReplyPermission_REPLY_PERMISSION_ALLOWED
	case !contextUsable(root, true, viewer, snap):
		return postsv1.ReplyPermission_REPLY_PERMISSION_UNKNOWN
	case root.ReplyPolicy == ReplyPolicyMentionedOnly:
		for _, m := range root.Mentions {
			if m.UserID == viewer {
				return postsv1.ReplyPermission_REPLY_PERMISSION_ALLOWED
			}
		}
		return postsv1.ReplyPermission_REPLY_PERMISSION_NOT_ALLOWED
	}
	rs, err := s.graph.Snapshot(ctx, root.AuthorID)
	if err != nil {
		return postsv1.ReplyPermission_REPLY_PERMISSION_UNKNOWN
	}
	if rs.Following[viewer] {
		return postsv1.ReplyPermission_REPLY_PERMISSION_ALLOWED
	}
	return postsv1.ReplyPermission_REPLY_PERMISSION_NOT_ALLOWED
}

// ReplyPermission implements ReplyHinter for GetPost: p is a post the viewer may see (viewable passed). Rows the
// timelines decide for free (replyPermissionFor) keep that answer; only a restricted root that is not the viewer's
// own goes through rootReplyPermission, with the viewer's graph snapshot GetPost has just cached (0 reads) and, for
// FOLLOWING, R's author graph (<= +1 read cold). A reply in a restricted conversation stays UNKNOWN: deriving its
// hint from R's usability would recreate the M-1 oracle.
func (s *service) ReplyPermission(ctx context.Context, viewer string, p *Post) postsv1.ReplyPermission {
	pure := replyPermissionFor(p, viewer)
	if p.Kind == KindRepost || p.IsReply || !p.ReplyPolicy.Restricted() || p.AuthorID == viewer {
		return pure
	}
	snap, err := s.graph.Snapshot(ctx, viewer)
	if err != nil {
		return postsv1.ReplyPermission_REPLY_PERMISSION_UNKNOWN
	}
	return s.rootReplyPermission(ctx, viewer, p, snap)
}

// threadReplyPermission is GetThread's single hint: the policy is per conversation, so every row shares it. R is
// the focal post for a root focal, else the context root threadContext just loaded; when that root is unavailable
// the hint is UNKNOWN. <= +1 read cold (FOLLOWING).
func (s *service) threadReplyPermission(ctx context.Context, caller string, snap graph.Snapshot, focal *Post, out *Thread) postsv1.ReplyPermission {
	root := focal
	if focal.ReplyToID != "" {
		if out.RootUnavailable || out.Root == nil {
			return postsv1.ReplyPermission_REPLY_PERMISSION_UNKNOWN
		}
		root = out.Root
	}
	return s.rootReplyPermission(ctx, caller, root, snap)
}

// replyAllowed is the per-reply filter: the caller's own replies are always kept; replies by authors the
// caller blocks or mutes, or who block the caller, are dropped (the same set the timelines use).
func replyAllowed(snap graph.Snapshot, caller, author string) bool {
	if author == caller {
		return true
	}
	return !snap.Blocked[author] && !snap.Muted[author] && !snap.BlockedBy[author]
}

// The page token uses cursor.TTL (24 h): a thread is read in one sitting, and a stale token only restarts the
// page (VALIDATION, the client reloads the thread).

// applyReply turns a root-post draft into a reply to parent (P3): kind, isReply, the parent link, the
// "Replying to @handle" label and the parent's conversation (a reply to a root starts the conversation at that
// root; deeper replies share it). The parent's replyCount increment rides in the CreatePost transaction.
func applyReply(p *CreateParams, parent *Post) {
	conv := parent.ConversationID
	if conv == "" {
		conv = parent.ID
	}
	p.ParentID = parent.ID
	p.Draft.Kind, p.Draft.IsReply = KindReply, true
	p.Draft.ReplyToID, p.Draft.ReplyToHandle = parent.ID, parent.Author.Handle
	p.Draft.ReplyToAuthorID = parent.AuthorID // transient, for PostEvents.Created only (never persisted)
	p.Draft.ConversationID = conv
	p.Draft.ReplyPolicy = parent.ReplyPolicy // inherited, 0 reads; never a user id (ADR-0021 D2)
}
