// Package objstore is the thin Cloud Storage seam for buckets that the API itself writes and reads: write an
// object, delete one, and sign a short-lived V4 GET URL (the account-export bucket, ADR-0011 D-B); and, for the
// media pipeline (ADR-0005, P4), sign a V4 PUT URL, read object attributes and the first bytes of an object, and
// copy an object to another bucket. Media bytes never pass through the API (CLAUDE.md rule 7): clients upload with
// signed PUT URLs and the API only reads attributes and a 512-byte head. The storage client is built lazily on first use, so no I/O happens before ListenAndServe, and
// STORAGE_EMULATOR_HOST is honored by the client itself.
package objstore

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"sync"
	"time"

	"cloud.google.com/go/storage"
	"google.golang.org/api/googleapi"
)

// ErrObjectNotFound is returned by Attrs, ReadHead and CopyTo when the source object does not exist.
var ErrObjectNotFound = errors.New("objstore: object not found")

// ErrGenerationChanged is returned by ReadHead and CopyTo when a pinned object generation is no longer the live one: the
// object was replaced (or deleted) after the generation was read. The caller must not trust the bytes (W6-25, H-1).
var ErrGenerationChanged = errors.New("objstore: object generation changed")

// CreateOnlyHeader is the header the signed PUT URL binds (name and value, lower-case): the write succeeds only if the
// object does not exist yet, so a second PUT to the same URL is refused with 412 and can never replace screened bytes.
const CreateOnlyHeader, CreateOnlyValue = "x-goog-if-generation-match", "0"

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

// Attrs is the subset of object metadata the media pipeline verifies.
type Attrs struct {
	Size        int64
	ContentType string
	// MD5 is the raw 16-byte MD5 GCS computed for the stored bytes (not base64).
	MD5 []byte
	// Generation is the object generation these attributes describe; generations only increase, so a later read or copy that
	// pins it proves the object was not rewritten in between.
	Generation int64
}

// Attrs returns the object's size, content type and MD5 (1 Class B operation). A missing object is
// ErrObjectNotFound.
func (s *Store) Attrs(ctx context.Context, object string) (Attrs, error) {
	ctx, cancel := context.WithTimeout(ctx, opTimeout)
	defer cancel()
	obj, err := s.handle(ctx, object)
	if err != nil {
		return Attrs{}, err
	}
	a, err := obj.Attrs(ctx)
	if errors.Is(err, storage.ErrObjectNotExist) {
		return Attrs{}, ErrObjectNotFound
	}
	if err != nil {
		return Attrs{}, fmt.Errorf("objstore: object attrs: %w", err)
	}
	return Attrs{Size: a.Size, ContentType: a.ContentType, MD5: a.MD5, Generation: a.Generation}, nil
}

// ReadHead returns the first n bytes of the object (a ranged read, 1 Class B operation); a shorter object returns
// what it has. A missing object is ErrObjectNotFound. With generation != 0 the read is pinned to that generation (the
// bytes are exactly the ones whose attributes were verified) with an ifGenerationMatch precondition: 412 means the object was
// replaced (ErrGenerationChanged) and 404 means it is gone (ErrObjectNotFound, the same split CopyTo makes).
func (s *Store) ReadHead(ctx context.Context, object string, n, generation int64) ([]byte, error) {
	ctx, cancel := context.WithTimeout(ctx, opTimeout)
	defer cancel()
	obj, err := s.handle(ctx, object)
	if err != nil {
		return nil, err
	}
	if generation != 0 {
		obj = obj.If(storage.Conditions{GenerationMatch: generation}) // not Generation(): a 404 must stay "not found", only 412 is "changed"
	}
	r, err := obj.NewRangeReader(ctx, 0, n)
	var gerr *googleapi.Error
	if errors.As(err, &gerr) && gerr.Code == http.StatusPreconditionFailed {
		return nil, ErrGenerationChanged
	}
	if errors.Is(err, storage.ErrObjectNotExist) {
		return nil, ErrObjectNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("objstore: open object head: %w", err)
	}
	defer r.Close()
	b, err := io.ReadAll(io.LimitReader(r, n))
	if err != nil {
		return nil, fmt.Errorf("objstore: read object head: %w", err)
	}
	return b, nil
}

// CopyTo copies object to dstObject in dst's bucket with the given content type and Cache-Control (1 Class A
// operation, no egress when both buckets share a location). It replaces an existing destination, so a repeated
// call is harmless. A missing source is ErrObjectNotFound. With srcGeneration != 0 the copy carries an
// ifSourceGenerationMatch precondition (no extra call): if the live generation differs, nothing is copied and the answer
// is ErrGenerationChanged (W6-25, H-1).
func (s *Store) CopyTo(ctx context.Context, object string, srcGeneration int64, dst *Store, dstObject, contentType, cacheControl string) error {
	ctx, cancel := context.WithTimeout(ctx, opTimeout)
	defer cancel()
	src, err := s.handle(ctx, object)
	if err != nil {
		return err
	}
	to, err := dst.handle(ctx, dstObject)
	if err != nil {
		return err
	}
	if srcGeneration != 0 {
		src = src.If(storage.Conditions{GenerationMatch: srcGeneration}) // live generation must equal the verified one
	}
	c := to.CopierFrom(src)
	c.ContentType = contentType
	c.CacheControl = cacheControl
	_, err = c.Run(ctx)
	var gerr *googleapi.Error
	if errors.As(err, &gerr) && gerr.Code == http.StatusNotImplemented && os.Getenv("STORAGE_EMULATOR_HOST") != "" {
		// The Storage emulator does not implement objects.rewrite. Against it only (never against GCS, where
		// bytes must not pass through the API), stream the copy so local development and the integration
		// tests can finish a FinalizeUpload.
		err = streamCopy(ctx, src, srcGeneration, to, contentType, cacheControl)
	}
	if err != nil {
		if errors.As(err, &gerr) && gerr.Code == http.StatusPreconditionFailed {
			return ErrGenerationChanged
		}
		if errors.Is(err, storage.ErrObjectNotExist) {
			return ErrObjectNotFound
		}
		return fmt.Errorf("objstore: copy object: %w", err)
	}
	return nil
}

// streamCopy is the emulator-only copy: read the source, write the destination with the given attributes. The Storage
// emulator ignores read generations and ifGenerationMatch on media reads (probed, W6-25), so the Attrs comparison below is
// a best-effort check and NOT atomic with the read that follows: a rewrite between the two goes unnoticed. That is
// acceptable only because this path never runs against GCS, where the single rewrite call carries ifSourceGenerationMatch
// and is the real protection (TestCopyTo_SendsIfSourceGenerationMatch pins it on the wire).
func streamCopy(ctx context.Context, src *storage.ObjectHandle, srcGeneration int64, dst *storage.ObjectHandle, contentType, cacheControl string) error {
	if srcGeneration != 0 {
		a, err := src.Attrs(ctx)
		if err != nil {
			return err
		}
		if a.Generation != srcGeneration {
			return ErrGenerationChanged
		}
		src = src.Generation(srcGeneration)
	}
	r, err := src.NewReader(ctx)
	if err != nil {
		return err
	}
	defer r.Close()
	w := dst.NewWriter(ctx)
	w.ContentType, w.CacheControl = contentType, cacheControl
	if _, err := io.Copy(w, r); err != nil {
		_ = w.Close()
		return err
	}
	return w.Close()
}

// SignedPutURL returns a V4 signed PUT URL valid for ttl, bound to the object path, Content-Type, Content-MD5
// (base64), an x-goog-content-length-range of 0..maxBytes and x-goog-if-generation-match: 0 (create-only: a second PUT to the
// same URL gets 412, so the screened bytes cannot be replaced, W6-25), plus the exact headers the client must send. No GCS
// call is made (signing uses IAM signBlob as the runtime service account). The URL is a bearer credential.
func (s *Store) SignedPutURL(ctx context.Context, object, contentType, md5b64 string, maxBytes int64, ttl time.Duration, now time.Time) (string, map[string]string, error) {
	rangeHeader := "0," + strconv.FormatInt(maxBytes, 10)
	opts := &storage.SignedURLOptions{
		Scheme:      storage.SigningSchemeV4,
		Method:      "PUT",
		Expires:     now.Add(ttl),
		ContentType: contentType,
		MD5:         md5b64,
		Headers:     []string{"x-goog-content-length-range:" + rangeHeader, CreateOnlyHeader + ":" + CreateOnlyValue},
	}
	headers := map[string]string{
		"Content-Type":                contentType,
		"Content-MD5":                 md5b64,
		"x-goog-content-length-range": rangeHeader,
		CreateOnlyHeader:              CreateOnlyValue,
	}
	if s.sign != nil {
		u, err := s.sign(ctx, s.bucket, object, opts)
		return u, headers, err
	}
	ctx, cancel := context.WithTimeout(ctx, opTimeout)
	defer cancel()
	if _, err := s.handle(ctx, object); err != nil { // builds the client once
		return "", nil, err
	}
	s.mu.Lock()
	c := s.client
	s.mu.Unlock()
	u, err := c.Bucket(s.bucket).SignedURL(object, opts)
	if err != nil {
		return "", nil, fmt.Errorf("objstore: sign put url: %w", err)
	}
	return u, headers, nil
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

// SetCustomTime sets the object's customTime metadata to t (1 Class A operation, a metadata patch). It is the only
// place in the application that writes customTime: the media bucket's lifecycle rule deletes an object once
// daysSinceCustomTime reaches 1, so setting it is how the profile-image retire step (ADR-0024 Amendment 1 A4) schedules
// an object's deletion (TestCustomTimeIsSetOnlyByTheRetireStep pins that). A missing object is success: the lifecycle
// rule or the account eraser already removed it, and a redelivered retire message must converge. Cloud Storage never
// lets customTime move backwards, so repeating the same value is the redelivery case and is accepted.
//
// The Storage emulator does not implement objects.patch (it answers 501). Against the emulator only (STORAGE_EMULATOR_HOST
// set, never against GCS) that answer is treated as success, so local development and the integration tests can run
// the whole retire flow; the tag itself is verified on a real bucket in dev (docs/runbooks/media.md).
func (s *Store) SetCustomTime(ctx context.Context, object string, t time.Time) error {
	ctx, cancel := context.WithTimeout(ctx, opTimeout)
	defer cancel()
	obj, err := s.handle(ctx, object)
	if err != nil {
		return err
	}
	_, err = obj.Update(ctx, storage.ObjectAttrsToUpdate{CustomTime: t.UTC()})
	var gerr *googleapi.Error
	switch {
	case err == nil, errors.Is(err, storage.ErrObjectNotExist):
		return nil
	case errors.As(err, &gerr) && gerr.Code == http.StatusNotImplemented && os.Getenv("STORAGE_EMULATOR_HOST") != "":
		return nil
	}
	return fmt.Errorf("objstore: set custom time: %w", err)
}
