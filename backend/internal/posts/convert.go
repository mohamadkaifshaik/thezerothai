package posts

import (
	"google.golang.org/protobuf/types/known/timestamppb"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
)

// ToProto converts a Post to its wire shape. Exported for the timeline module, which returns the same PostView.
// Embedded posts are not modelled yet and stay unset. Every MediaRef carries thumb_url (lists render it).
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
