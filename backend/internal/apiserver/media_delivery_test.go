package apiserver

import (
	"context"
	"errors"
	"testing"
	"time"

	"connectrpc.com/connect"
	articles "github.com/dzeroth/dzeroth/backend/gen/dzeroth/articles/v1"
	common "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
)

func TestMediaDeliverySignsOnlyAuthorizedFields(t *testing.T) {
	const base = "https://storage.googleapis.com/test-media"
	const key = "m/1234567890123456789_t.jpg"
	raw := base + "/" + key
	var calls int
	d := newMediaDelivery(base, func(_ context.Context, object string, ttl time.Duration) (string, error) {
		calls++
		if object != key || ttl != 5*time.Minute {
			t.Fatalf("unexpected signing request %q %s", object, ttl)
		}
		return "signed", nil
	})
	shared := &common.MediaRef{Url: raw, ThumbUrl: base + "/m/../secret", AltText: raw}
	handler := d.interceptor().WrapUnary(func(context.Context, connect.AnyRequest) (connect.AnyResponse, error) {
		return connect.NewResponse(&articles.GetArticleResponse{Article: &articles.Article{CoverUrl: raw, Images: []*common.MediaRef{shared}}}), nil
	})
	for range 2 {
		resp, err := handler(context.Background(), connect.NewRequest(&articles.GetArticleRequest{}))
		if err != nil {
			t.Fatal(err)
		}
		a := resp.Any().(*articles.GetArticleResponse).Article
		if a.CoverUrl != "signed" || a.Images[0].Url != "signed" || a.Images[0].AltText != raw || a.Images[0].ThumbUrl != shared.ThumbUrl || shared.Url != raw {
			t.Fatal("unexpected rewritten reference")
		}
	}
	if calls != 1 {
		t.Fatalf("signed %d times", calls)
	}
	refused := errors.New("denied")
	_, err := d.interceptor().WrapUnary(func(context.Context, connect.AnyRequest) (connect.AnyResponse, error) { return nil, refused })(context.Background(), connect.NewRequest(&articles.GetArticleRequest{}))
	if err != refused || calls != 1 {
		t.Fatal("failed audience check reached signing")
	}
}
