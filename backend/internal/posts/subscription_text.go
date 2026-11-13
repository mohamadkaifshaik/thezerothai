package posts

import (
	"context"
	"unicode/utf8"

	"github.com/dzeroth/dzeroth/backend/internal/posts/text"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
)

// Parse against the absolute bound before I/O. Tier authorization is separate
// so idempotent replay is still possible after a downgrade.
func (s *service) parsePostText(raw string, optional bool) (text.Parsed, error) {
	limit := text.MaxRunes
	if s.postTextLimit != nil {
		limit = text.MaxPaidRunes
	}
	return text.ParseWithLimit(raw, limit, optional)
}

func (s *service) authorizePostText(ctx context.Context, uid, value string) error {
	if utf8.RuneCountInString(value) <= text.MaxRunes {
		return nil
	}
	limit := text.MaxRunes
	if s.postTextLimit != nil {
		var err error
		limit, err = s.postTextLimit(ctx, uid)
		if err != nil {
			return err
		}
	}
	if limit < text.MaxRunes || limit > text.MaxPaidRunes {
		limit = text.MaxRunes
	}
	if utf8.RuneCountInString(value) > limit {
		return apierr.Validation("text", "text exceeds your current subscription limit")
	}
	return nil
}
