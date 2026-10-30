package posts

import (
	"time"

	"google.golang.org/protobuf/types/known/timestamppb"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
)

// ToProto converts a Post to its wire shape. Exported for the timeline module, which returns the same PostView.
// A QUOTE or REPOST carries its frozen Embedded snapshot (a tombstone has only post_id and unavailable). Every
// MediaRef carries thumb_url (lists render it).
func ToProto(p *Post) *postsv1.Post { return toProtoAt(p, ViewerSet{}, "", time.Now()) }

// ToProtoForViewer is ToProto for a known viewer: the author sees the per-choice counts of their own poll (ADR-0029 D4).
func ToProtoForViewer(p *Post, viewer string) *postsv1.Post {
	return toProtoAt(p, ViewerSet{}, viewer, time.Now())
}

func toProtoAt(p *Post, vs ViewerSet, viewer string, now time.Time) *postsv1.Post {
	out := &postsv1.Post{
		PostId: p.ID,
		Author: &commonv1.AuthorSnapshot{
			UserId: p.Author.UserID, Handle: p.Author.Handle, DisplayName: p.Author.DisplayName,
			AvatarUrl: p.Author.AvatarURL, Verified: p.Author.Verified,
		},
		Kind:           kindToProto(p.Kind),
		Text:           p.Text,
		ReplyToPostId:  p.ReplyToID,
		ReplyToHandle:  p.ReplyToHandle,
		ConversationId: p.ConversationID,
		Hashtags:       append([]string{}, p.Hashtags...),
		LikeCount:      p.LikeCount,
		RepostCount:    p.RepostCount,
		ReplyCount:     p.ReplyCount,
		QuoteCount:     p.QuoteCount,
		// The wire visibility is computed, never read from the stored field (always PUBLIC, ADR-0025 D2): PUBLIC here, and
		// ApplyWireVisibility raises it to FOLLOWERS while the author is in the protected set. Every converter caller that can
		// reach a protected author must apply it (GetPost, GetThread, CreatePost today; the lists and feeds in W3-29b and W3-30).
		Visibility: postsv1.Visibility_VISIBILITY_PUBLIC,
		CreatedAt:  timestamppb.New(p.CreatedAt),

		PaidPartnership: p.PaidPartnership,
		MadeWithAi:      p.MadeWithAI,
		ReplyPolicy:     policyToProto(p.ReplyPolicy),
	}
	if e := p.Embedded; e != nil {
		out.Embedded = embeddedToProto(e, now)
	}
	for _, m := range p.Mentions {
		out.Mentions = append(out.Mentions, &postsv1.Mention{UserId: m.UserID, Handle: m.Handle})
	}
	out.Media = mediaRefsToProto(p.Media)
	out.Poll = pollToProto(p, vs, viewer, now)
	return out
}

// mediaRefsToProto converts image refs to the wire shape (nil for none). Shared by posts, embeds and scheduled drafts.
func mediaRefsToProto(refs []MediaRef) []*commonv1.MediaRef {
	var out []*commonv1.MediaRef
	for _, m := range refs {
		out = append(out, &commonv1.MediaRef{
			MediaId: m.ID, Url: m.URL, ThumbUrl: m.ThumbURL, Width: int32(m.Width), Height: int32(m.Height), //nolint:gosec // validated <= 4096 at CreateUpload
			Blurhash: m.Blurhash, AltText: m.AltText, ContentType: m.ContentType,
		})
	}
	return out
}

func embeddedToProto(e *Embedded, now time.Time) *postsv1.EmbeddedPost {
	out := &postsv1.EmbeddedPost{PostId: e.PostID, Unavailable: e.Unavailable}
	if e.Unavailable {
		return out
	}
	out.Author = &commonv1.AuthorSnapshot{
		UserId: e.Author.UserID, Handle: e.Author.Handle, DisplayName: e.Author.DisplayName,
		AvatarUrl: e.Author.AvatarURL, Verified: e.Author.Verified,
	}
	out.Text = e.Text
	out.PaidPartnership, out.MadeWithAi = e.PaidPartnership, e.MadeWithAI
	out.ReplyPolicy = policyToProto(e.ReplyPolicy)
	out.CreatedAt = timestamppb.New(e.CreatedAt)
	out.Media = mediaRefsToProto(e.Media)
	out.Poll = embeddedPollToProto(e.Poll, now)
	return out
}

// ToView converts a Post to the PostView the clients render, with the viewer's like/repost/bookmark flags from vs
// (the zero ViewerSet gives false/false/false, which is what every response carried before P5) and the viewer's reply
// hint (replyPermissionFor, 0 reads; never flag-gated, it only describes stored data). bookmarked_by_viewer is
// ViewerSet.Bookmarked (ADR-0023 D3): HydrateViewer decides whether the set is filled, so this adds no read.
func ToView(p *Post, vs ViewerSet, viewer string) *postsv1.PostView {
	return ToViewAt(p, vs, viewer, time.Now())
}

// ToViewAt is ToView with the server clock passed in: the seam for poll closing in tests (ADR-0029 D4). Production callers use ToView.
func ToViewAt(p *Post, vs ViewerSet, viewer string, now time.Time) *postsv1.PostView {
	liked, reposted := vs.Flags(p)
	v := &postsv1.PostView{Post: toProtoAt(p, vs, viewer, now), LikedByViewer: liked, RepostedByViewer: reposted,
		BookmarkedByViewer:    vs.Bookmarked(p),
		ViewerReplyPermission: replyPermissionFor(p, viewer)}
	if i, voted := vs.PollChoice(p); voted {
		v.ViewerPollChoice = int32(i) + 1 // index + 1, 0 = none (ADR-0029 D4); for a REPOST row the original's choice
	}
	return v
}

// replyPermissionFor is the viewer hint the timelines compute with 0 reads (ADR-0021 D2, review I-6). It is
// advisory: CreatePost decides.
//   - a REPOST row has no policy of its own and EmbeddedPost has no mentions: the embedded policy decides, EVERYONE
//     is ALLOWED, anything restricted (or a tombstone) is UNKNOWN;
//   - a reply row: ALLOWED in an EVERYONE conversation, UNKNOWN in a restricted one (deciding it would need the
//     root, and ALLOWED vs NOT_ALLOWED for a mentioned viewer would recreate the M-1 oracle);
//   - a root post or QUOTE: EVERYONE and the viewer's own post are ALLOWED, MENTIONED_ONLY is ALLOWED for a
//     mentioned viewer and NOT_ALLOWED otherwise, FOLLOWING is UNKNOWN (it needs R's author's follows).
func replyPermissionFor(p *Post, viewer string) postsv1.ReplyPermission {
	switch {
	case p.Kind == KindRepost:
		if e := p.Embedded; e != nil && !e.Unavailable && !e.ReplyPolicy.Restricted() {
			return postsv1.ReplyPermission_REPLY_PERMISSION_ALLOWED
		}
		return postsv1.ReplyPermission_REPLY_PERMISSION_UNKNOWN
	case !p.ReplyPolicy.Restricted():
		return postsv1.ReplyPermission_REPLY_PERMISSION_ALLOWED
	case p.IsReply:
		return postsv1.ReplyPermission_REPLY_PERMISSION_UNKNOWN
	case p.AuthorID == viewer:
		return postsv1.ReplyPermission_REPLY_PERMISSION_ALLOWED
	case p.ReplyPolicy == ReplyPolicyMentionedOnly:
		for _, m := range p.Mentions {
			if m.UserID == viewer {
				return postsv1.ReplyPermission_REPLY_PERMISSION_ALLOWED
			}
		}
		return postsv1.ReplyPermission_REPLY_PERMISSION_NOT_ALLOWED
	}
	return postsv1.ReplyPermission_REPLY_PERMISSION_UNKNOWN
}

// policyToProto maps the stored policy to the wire enum; absent (EVERYONE) is UNSPECIFIED, as on older posts.
func policyToProto(r ReplyPolicy) postsv1.ReplyPolicy {
	switch r {
	case ReplyPolicyFollowing:
		return postsv1.ReplyPolicy_REPLY_POLICY_FOLLOWING
	case ReplyPolicyMentionedOnly:
		return postsv1.ReplyPolicy_REPLY_POLICY_MENTIONED_ONLY
	default:
		return postsv1.ReplyPolicy_REPLY_POLICY_UNSPECIFIED
	}
}

func kindToProto(k Kind) postsv1.PostKind {
	switch k {
	case KindPost:
		return postsv1.PostKind_POST_KIND_POST
	case KindReply:
		return postsv1.PostKind_POST_KIND_REPLY
	case KindQuote:
		return postsv1.PostKind_POST_KIND_QUOTE
	case KindRepost:
		return postsv1.PostKind_POST_KIND_REPOST
	default:
		return postsv1.PostKind_POST_KIND_UNSPECIFIED
	}
}

// pollToProto is the one rule for what a viewer may see of a post's poll (ADR-0029 D4). Hidden is the default: every
// per-choice votes is 0 and results_visible false, so the bytes are the same whatever the real counts; total_votes is
// always the real total. The counts are shown when the poll is closed (by the server clock passed in) or the viewer is the
// author, has voted (vs.PollChoice), or FEATURE_POLLS is globally off (vs, ADR-0029 D4). A new proto is built on every call: the cached *Post is
// shared by viewers and is never written to. nil for a post without a poll.
func pollToProto(p *Post, vs ViewerSet, viewer string, now time.Time) *postsv1.Poll {
	po := p.Poll
	if po == nil {
		return nil
	}
	closed := po.Closed(now)
	_, voted := vs.PollChoice(p)
	visible := closed || vs.pollsOff || voted || (viewer != "" && viewer == p.AuthorID)
	out := &postsv1.Poll{
		ClosesAt: timestamppb.New(po.ClosesAt), TotalVotes: po.Total, ResultsVisible: visible, Closed: closed,
		Choices: make([]*postsv1.PollChoice, len(po.Options)),
	}
	for i, label := range po.Options {
		c := &postsv1.PollChoice{Label: label}
		if visible && i < len(po.Counts) {
			c.Votes = po.Counts[i]
		}
		out.Choices[i] = c
	}
	return out
}

// embeddedPollToProto is the frozen definition of an embed (ADR-0029 D5): labels and closes_at, every count 0, total 0 and
// results_visible false always; closed is the server clock against closes_at.
func embeddedPollToProto(e *EmbeddedPoll, now time.Time) *postsv1.Poll {
	if e == nil {
		return nil
	}
	out := &postsv1.Poll{ClosesAt: timestamppb.New(e.ClosesAt), Closed: !now.Before(e.ClosesAt), Choices: make([]*postsv1.PollChoice, len(e.Options))}
	for i, label := range e.Options {
		out.Choices[i] = &postsv1.PollChoice{Label: label}
	}
	return out
}
