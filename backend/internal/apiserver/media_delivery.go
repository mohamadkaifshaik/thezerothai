package apiserver

import (
	"context"
	"errors"
	"regexp"
	"strings"
	"time"

	"connectrpc.com/connect"
	"golang.org/x/sync/errgroup"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/reflect/protoreflect"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/cache"
)

// Only server-resolved attachment fields may mint a capability. Text, links in
// article bodies, request messages and upload/download URLs never enter the signer.
var mediaFields = map[protoreflect.FullName]bool{
	"dzeroth.common.v1.MediaRef.url":               true,
	"dzeroth.common.v1.MediaRef.thumb_url":         true,
	"dzeroth.common.v1.AuthorSnapshot.avatar_url":  true,
	"dzeroth.identity.v1.Profile.avatar_url":       true,
	"dzeroth.identity.v1.Profile.avatar_thumb_url": true,
	"dzeroth.articles.v1.Article.cover_url":        true,
	"dzeroth.posts.v1.ArticlePreview.cover_url":    true,
}
var servingName = regexp.MustCompile(`^m/[0-9]{19}(-[0-9a-f]{32})?(_t)?\.(jpg|jpeg|png|webp|gif|mp4)$`)

type mediaDelivery struct {
	prefix string
	sign   func(context.Context, string, time.Duration) (string, error)
	cache  *cache.LRU[string, string]
}

func newMediaDelivery(base string, sign func(context.Context, string, time.Duration) (string, error)) *mediaDelivery {
	return &mediaDelivery{prefix: strings.TrimRight(base, "/") + "/", sign: sign, cache: cache.New[string, string](2048, 4*time.Minute)}
}

func walkMedia(m protoreflect.Message, visit func(protoreflect.Message, protoreflect.FieldDescriptor, string)) {
	m.Range(func(f protoreflect.FieldDescriptor, v protoreflect.Value) bool {
		switch {
		case mediaFields[f.FullName()]:
			visit(m, f, v.String())
		case f.Message() != nil && !f.IsMap():
			if f.IsList() {
				for i := 0; i < v.List().Len(); i++ {
					walkMedia(v.List().Get(i).Message(), visit)
				}
			} else {
				walkMedia(v.Message(), visit)
			}
		}
		return true
	})
}

// Preserve Connect metadata and hand the wire encoder a detached protobuf.
type signedMediaResponse struct {
	connect.AnyResponse
	message proto.Message
}

func (r *signedMediaResponse) Any() any { return r.message }

func (d *mediaDelivery) interceptor() connect.UnaryInterceptorFunc {
	return func(next connect.UnaryFunc) connect.UnaryFunc {
		return func(ctx context.Context, req connect.AnyRequest) (connect.AnyResponse, error) {
			resp, err := next(ctx, req)
			if err != nil || resp == nil {
				return resp, err
			}
			msg, ok := resp.Any().(proto.Message)
			if !ok {
				return nil, errors.New("invalid media response")
			}
			urls := map[string]string{}
			walkMedia(msg.ProtoReflect(), func(_ protoreflect.Message, _ protoreflect.FieldDescriptor, raw string) {
				if name, found := strings.CutPrefix(raw, d.prefix); found && servingName.MatchString(name) {
					urls[raw] = ""
				}
			})
			if len(urls) == 0 {
				return resp, nil
			}
			type result struct{ raw, signed string }
			results := make(chan result, len(urls))
			group, ctx := errgroup.WithContext(ctx)
			group.SetLimit(8)
			for raw := range urls {
				group.Go(func() error {
					name := strings.TrimPrefix(raw, d.prefix)
					signed, ok := d.cache.Get(name)
					if !ok {
						var err error
						signed, err = d.sign(ctx, name, 5*time.Minute)
						if err != nil {
							return err
						}
						d.cache.Set(name, signed)
					}
					results <- result{raw, signed}
					return nil
				})
			}
			if err := group.Wait(); err != nil {
				return nil, connect.NewError(connect.CodeUnavailable, errors.New("media delivery unavailable"))
			}
			close(results)
			for r := range results {
				urls[r.raw] = r.signed
			}
			// Responses can reference cached submessages. Detach them before replacing stable object references.
			copy := proto.Clone(msg)
			walkMedia(copy.ProtoReflect(), func(m protoreflect.Message, f protoreflect.FieldDescriptor, raw string) {
				if signed, ok := urls[raw]; ok {
					m.Set(f, protoreflect.ValueOfString(signed))
				}
			})
			resp.Header().Set("Cache-Control", "private, no-store")
			return &signedMediaResponse{resp, copy}, nil
		}
	}
}
