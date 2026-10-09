// Package objstore is the thin Cloud Storage seam for private buckets that the API itself writes and reads
// (the account-export bucket, ADR-0011 D-B): write an object, delete one, and sign a short-lived V4 GET URL.
// Media never passes through the API (CLAUDE.md rule 7): clients upload with signed PUT URLs, which is a different
// path. The storage client is built lazily on first use, so no I/O happens before ListenAndServe, and
// STORAGE_EMULATOR_HOST is honored by the client itself.
package objstore

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/url"
	"sync"
	"time"

	"cloud.google.com/go/storage"
)

// opTimeout bounds one Put or Delete (every outbound call has a deadline); a Put also runs under the caller's
// own deadline, whichever is shorter.
const opTimeout = 25 * time.Second

// Store is one private bucket.
type Store struct {
	bucket string
	// sign signs a GET URL; tests replace it (the Storage emulator cannot validate V4 signatures).
	sign func(ctx context.Context, bucket, object string, opts *storage.SignedURLOptions) (string, error)

	mu     sync.Mutex
	client *storage.Client
}

// New returns a Store for bucket. It does no I/O.
func New(bucket string) (*Store, error) {
	if bucket == "" {
		return nil, errors.New("objstore: bucket is required")
	}
	return &Store{bucket: bucket}, nil
}

func (s *Store) handle(ctx context.Context, object string) (*storage.ObjectHandle, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.client == nil {
		c, err := storage.NewClient(context.WithoutCancel(ctx))
		if err != nil {
			return nil, fmt.Errorf("objstore: build client: %w", err)
		}
		s.client = c
	}
	return s.client.Bucket(s.bucket).Object(object), nil
}

// Put streams one object: write receives the object's writer. If write fails, the upload is aborted and no
// object is created or replaced (the writer's context is cancelled before Close), so a crash or error never
// leaves a truncated object. An existing object of the same name is replaced only on success.
func (s *Store) Put(ctx context.Context, object, contentType string, write func(io.Writer) error) error {
	ctx, cancel := context.WithTimeout(ctx, opTimeout)
	defer cancel()
	obj, err := s.handle(ctx, object)
	if err != nil {
		return err
	}
	wctx, abort := context.WithCancel(ctx)
	defer abort()
	w := obj.NewWriter(wctx)
	w.ContentType = contentType
	if err := write(w); err != nil {
		abort()
		_ = w.Close()
		return fmt.Errorf("objstore: write object: %w", err)
	}
	if err := w.Close(); err != nil {
		return fmt.Errorf("objstore: close object: %w", err)
	}
	return nil
}

// Delete removes one object; a missing object is success (free operation).
func (s *Store) Delete(ctx context.Context, object string) error {
	ctx, cancel := context.WithTimeout(ctx, opTimeout)
	defer cancel()
	obj, err := s.handle(ctx, object)
	if err != nil {
		return err
	}
	if err := obj.Delete(ctx); err != nil && !errors.Is(err, storage.ErrObjectNotExist) {
		return fmt.Errorf("objstore: delete object: %w", err)
	}
	return nil
}

// SignedGetURL returns a V4 signed GET URL valid for ttl that downloads object as an attachment named filename.
// On Cloud Run the client signs through IAM signBlob as the runtime service account (it holds
// roles/iam.serviceAccountTokenCreator on itself). The URL is a bearer credential: never log or store it.
func (s *Store) SignedGetURL(ctx context.Context, object, filename string, ttl time.Duration, now time.Time) (string, error) {
	opts := &storage.SignedURLOptions{
		Scheme:  storage.SigningSchemeV4,
		Method:  "GET",
		Expires: now.Add(ttl),
		QueryParameters: url.Values{
			"response-content-disposition": {`attachment; filename="` + filename + `"`},
			"response-content-type":        {"application/json"},
		},
	}
	if s.sign != nil {
		return s.sign(ctx, s.bucket, object, opts)
	}
	ctx, cancel := context.WithTimeout(ctx, opTimeout)
	defer cancel()
	if _, err := s.handle(ctx, object); err != nil { // builds the client once
		return "", err
	}
	s.mu.Lock()
	c := s.client
	s.mu.Unlock()
	u, err := c.Bucket(s.bucket).SignedURL(object, opts)
	if err != nil {
		return "", fmt.Errorf("objstore: sign url: %w", err)
	}
	return u, nil
}
