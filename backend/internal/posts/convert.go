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
	}
	if e := p.Embedded; e != nil {
		out.Embedded = embeddedToProto(e)
	}
	for _, m := range p.Mentions {
		out.Mentions = append(out.Mentions, &postsv1.Mention{UserId: m.UserID, Handle: m.Handle})
	}
	for _, m := range p.Media {
		out.Media = append(out.Media, &commonv1.MediaRef{
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
	out.CreatedAt = timestamppb.New(e.CreatedAt)
	for _, m := range e.Media {
		out.Media = append(out.Media, &commonv1.MediaRef{
			MediaId: m.ID, Url: m.URL, ThumbUrl: m.ThumbURL, Width: int32(m.Width), Height: int32(m.Height), //nolint:gosec // validated <= 4096 at CreateUpload
			Blurhash: m.Blurhash, AltText: m.AltText,
		})
	}
	return out
}

// ToView converts a Post to the PostView the clients render, with the viewer's like/repost flags from vs (the
// zero ViewerSet gives false/false, which is what every response carried before P5).
func ToView(p *Post, vs ViewerSet) *postsv1.PostView {
	liked, reposted := vs.Flags(p)
	return &postsv1.PostView{Post: ToProto(p), LikedByViewer: liked, RepostedByViewer: reposted}
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
