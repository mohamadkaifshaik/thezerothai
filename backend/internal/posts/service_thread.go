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

	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/cursor"
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
}

// replyParent validates a reply target for CreatePost: the id shape, then the GetPost visibility rules
// (viewable). Every refusal is the one NOT_FOUND "post not found" answer, so the response reveals neither a
// deleted parent nor a block. Reads: parent 1 + its author 1 + caller graph 1 cold, 0 warm.
func (s *service) replyParent(ctx context.Context, uid, parentID string) (*Post, error) {
	if !postIDPattern.MatchString(parentID) {
		return nil, apierr.Validation("reply_to_post_id", "reply_to_post_id must be a 19-digit post id")
	}
	p, err := s.viewable(ctx, uid, parentID)
	if errors.Is(err, ErrNotFound) {
		logger.SetRequestField(ctx, fieldOutcome, outcomeNotFound)
		return nil, postNotFound()
	}
	if err != nil {
		return nil, err
	}
	return p, nil
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
// Limit(page) <= 30 => 38 cold; warm: the query only (1 .. 30). Writes 0.
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

	focal, err := s.viewable(ctx, callerUID, in.PostID)
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
		case p.Visibility != VisibilityPublic || !replyAllowed(snap, callerUID, p.AuthorID):
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
		if !ok || p.Visibility != VisibilityPublic {
			return nil
		}
		if _, ok := profiles[p.AuthorID]; !ok {
			return nil
		}
		if p.AuthorID != caller {
			// Fail closed on a blockedBy overflow rather than spend an author-graph read per context row.
			if snap.BlockedBy[p.AuthorID] || snap.Blocked[p.AuthorID] || snap.BlockedByOverflow {
				return nil
			}
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
	p.Draft.ConversationID = conv
}
