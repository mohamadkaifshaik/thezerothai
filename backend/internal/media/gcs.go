package media

import (
	"context"
	"errors"
	"time"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/objstore"
)

// publicCacheControl is the Cache-Control of every public object: object names embed the immutable media id, so
// the bytes never change (ADR-0005).
const publicCacheControl = "public, max-age=31536000, immutable"

// Buckets implements Signer and Objects over the private upload bucket and the public-read media bucket.
type Buckets struct {
	Upload *objstore.Store
	Public *objstore.Store
}

// NewBuckets builds the two bucket clients. It does no I/O.
func NewBuckets(uploadBucket, publicBucket string) (*Buckets, error) {
	if uploadBucket == "" || publicBucket == "" {
		return nil, errors.New("media: upload and public bucket names are required")
	}
	if uploadBucket == publicBucket {
		return nil, errors.New("media: the upload and public buckets must differ (unmoderated bytes must never be public)")
	}
	up, err := objstore.New(uploadBucket)
	if err != nil {
		return nil, err
	}
	pub, err := objstore.New(publicBucket)
	if err != nil {
		return nil, err
	}
	return &Buckets{Upload: up, Public: pub}, nil
}

var (
	_ Signer  = (*Buckets)(nil)
	_ Objects = (*Buckets)(nil)
)

// SignPut implements Signer.
func (b *Buckets) SignPut(ctx context.Context, object, contentType, md5b64 string, maxBytes int64, ttl time.Duration, now time.Time) (string, map[string]string, error) {
	return b.Upload.SignedPutURL(ctx, object, contentType, md5b64, maxBytes, ttl, now)
}

// UploadAttrs implements Objects.
func (b *Buckets) UploadAttrs(ctx context.Context, object string) (objstore.Attrs, error) {
	return b.Upload.Attrs(ctx, object)
}

// UploadHead implements Objects.
func (b *Buckets) UploadHead(ctx context.Context, object string, n int64) ([]byte, error) {
	return b.Upload.ReadHead(ctx, object, n)
}

// Publish implements Objects.
func (b *Buckets) Publish(ctx context.Context, uploadObject, publicObject, contentType string) error {
	return b.Upload.CopyTo(ctx, uploadObject, b.Public, publicObject, contentType, publicCacheControl)
}

// DeleteUpload implements Objects.
func (b *Buckets) DeleteUpload(ctx context.Context, object string) error {
	return b.Upload.Delete(ctx, object)
}

// DeletePublic implements Objects.
func (b *Buckets) DeletePublic(ctx context.Context, object string) error {
	return b.Public.Delete(ctx, object)
}
