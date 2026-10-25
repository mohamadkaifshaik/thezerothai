package posts

import (
	"google.golang.org/protobuf/types/known/timestamppb"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
)

// ToProto converts a Post to its wire shape. Exported for the timeline module, which returns the same PostView.
// A QUOTE or REPOST carries its frozen Embedded snapshot (a tombstone has only post_id and unavailable). Every
// MediaRef carries thumb_url (lists render it).
func ToProto(p *Post) *postsv1.Post {
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
		Visibility:     visibilityToProto(p.Visibility),
		CreatedAt:      timestamppb.New(p.CreatedAt),

		PaidPartnership: p.PaidPartnership,
		MadeWithAi:      p.MadeWithAI,
		ReplyPolicy:     policyToProto(p.ReplyPolicy),
	}
	if e := p.Embedded; e != nil {
		out.Embedded = embeddedToProto(e)
	}
	for _, m := range p.Mentions {
		out.Mentions = append(out.Mentions, &postsv1.Mention{UserId: m.UserID, Handle: m.Handle})
	}
	out.Media = mediaRefsToProto(p.Media)
	return out
}

// mediaRefsToProto converts image refs to the wire shape (nil for none). Shared by posts, embeds and scheduled drafts.
func mediaRefsToProto(refs []MediaRef) []*commonv1.MediaRef {
	var out []*commonv1.MediaRef
	for _, m := range refs {
		out = append(out, &commonv1.MediaRef{
			MediaId: m.ID, Url: m.URL, ThumbUrl: m.ThumbURL, Width: int32(m.Width), Height: int32(m.Height), //nolint:gosec // validated <= 4096 at CreateUpload
			Blurhash: m.Blurhash, AltText: m.AltText,
		})
	}
	return out
}

func embeddedToProto(e *Embedded) *postsv1.EmbeddedPost {
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
	return out
}

// ToView converts a Post to the PostView the clients render, with the viewer's like/repost flags from vs (the
// zero ViewerSet gives false/false, which is what every response carried before P5) and the viewer's reply hint
// (replyPermissionFor, 0 reads; never flag-gated, it only describes stored data).
func ToView(p *Post, vs ViewerSet, viewer string) *postsv1.PostView {
	liked, reposted := vs.Flags(p)
	return &postsv1.PostView{Post: ToProto(p), LikedByViewer: liked, RepostedByViewer: reposted,
		ViewerReplyPermission: replyPermissionFor(p, viewer)}
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

func visibilityToProto(v Visibility) postsv1.Visibility {
	switch v {
	case VisibilityPublic:
		return postsv1.Visibility_VISIBILITY_PUBLIC
	case VisibilityFollowers:
		return postsv1.Visibility_VISIBILITY_FOLLOWERS
	default:
		return postsv1.Visibility_VISIBILITY_UNSPECIFIED
	}
}
