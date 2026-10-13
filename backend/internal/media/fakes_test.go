package media

import (
	"context"
	"crypto/md5"
	"encoding/base64"
	"fmt"
	"sort"
	"sync"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/objstore"
)

// fakeRepo is an in-memory Repo. It charges nothing; budgets are asserted by the integration tests.
type fakeRepo struct {
	mu       sync.Mutex
	docs     map[string]*Doc
	idem     map[string]fakeIdem
	vision   map[string]int64
	quota    int64 // images reserved today
	visionRd int   // VisionUsed calls
	resolves int
	// failures
	createErr error
	resolveFn func(id string) error
}

type fakeIdem struct {
	hash string
	ids  []string
}

func newFakeRepo() *fakeRepo {
	return &fakeRepo{docs: map[string]*Doc{}, idem: map[string]fakeIdem{}, vision: map[string]int64{}}
}

func (r *fakeRepo) CreateUploads(_ context.Context, p CreateUploadsParams) (CreateUploadsResult, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.createErr != nil {
		return CreateUploadsResult{}, r.createErr
	}
	if rec, ok := r.idem[p.IdemKey]; ok {
		if rec.hash != p.RequestHash {
			return CreateUploadsResult{}, ErrKeyReused
		}
		return CreateUploadsResult{ReplayIDs: rec.ids}, nil
	}
	if r.quota+int64(len(p.Docs)) > p.QuotaLimit {
		return CreateUploadsResult{}, apierr.New(connect.CodeResourceExhausted, commonv1.ErrorReason_ERROR_REASON_QUOTA_EXCEEDED, "daily limit reached")
	}
	r.quota += int64(len(p.Docs))
	ids := make([]string, len(p.Docs))
	for i := range p.Docs {
		d := p.Docs[i]
		d.UpdateTime = time.Unix(1, 0)
		r.docs[d.ID] = &d
		ids[i] = d.ID
	}
	r.idem[p.IdemKey] = fakeIdem{hash: p.RequestHash, ids: ids}
	return CreateUploadsResult{}, nil
}

func (r *fakeRepo) GetMany(_ context.Context, ids []string) (map[string]*Doc, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := map[string]*Doc{}
	for _, id := range ids {
		if d, ok := r.docs[id]; ok {
			c := *d
			out[id] = &c
		}
	}
	return out, nil
}

func (r *fakeRepo) Resolve(_ context.Context, id string, updateTime time.Time, res Resolution) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.resolves++
	if r.resolveFn != nil {
		if err := r.resolveFn(id); err != nil {
			return err
		}
	}
	d, ok := r.docs[id]
	if !ok || !d.UpdateTime.Equal(updateTime) {
		return ErrConflict
	}
	d.Status, d.PublicPath, d.ThumbPath = string(res.Status), res.PublicPath, res.ThumbPath
	d.Blurhash, d.RejectionReason = res.Blurhash, res.RejectionReason
	if res.ExpireAt.IsZero() {
		d.ExpireAt = nil
	} else {
		e := res.ExpireAt
		d.ExpireAt = &e
	}
	d.UpdateTime = d.UpdateTime.Add(time.Second)
	return nil
}

func (r *fakeRepo) VisionUsed(_ context.Context, month string) (int64, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.visionRd++
	return r.vision[month], nil
}

func (r *fakeRepo) AddVisionUnits(_ context.Context, month string, n int64) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.vision[month] += n
	return nil
}

func (r *fakeRepo) ListByOwner(_ context.Context, uid, after string, limit int) ([]*Doc, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	var ids []string
	for id, d := range r.docs {
		if d.OwnerID == uid && id > after {
			ids = append(ids, id)
		}
	}
	sort.Strings(ids)
	if len(ids) > limit {
		ids = ids[:limit]
	}
	out := make([]*Doc, len(ids))
	for i, id := range ids {
		c := *r.docs[id]
		out[i] = &c
	}
	return out, nil
}

func (r *fakeRepo) DeleteDocs(_ context.Context, ids []string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	for _, id := range ids {
		delete(r.docs, id)
	}
	return nil
}

// fakeObjects models both buckets.
type fakeObjects struct {
	mu        sync.Mutex
	upload    map[string]fakeObject
	public    map[string]string // object -> content type
	deleted   []string
	publishes int
	// failures
	attrsErr   error
	publishErr error
	deletePub  error
}

type fakeObject struct {
	data        []byte
	contentType string
	// attrsMD5 overrides the stored MD5 (to model a corrupt upload); nil means md5(data).
	attrsMD5 []byte
	size     int64 // 0 means len(data)
}

func newFakeObjects() *fakeObjects {
	return &fakeObjects{upload: map[string]fakeObject{}, public: map[string]string{}}
}

func (o *fakeObjects) UploadAttrs(_ context.Context, object string) (objstore.Attrs, error) {
	o.mu.Lock()
	defer o.mu.Unlock()
	if o.attrsErr != nil {
		return objstore.Attrs{}, o.attrsErr
	}
	f, ok := o.upload[object]
	if !ok {
		return objstore.Attrs{}, objstore.ErrObjectNotFound
	}
	sum := md5.Sum(f.data)
	m := sum[:]
	if f.attrsMD5 != nil {
		m = f.attrsMD5
	}
	size := int64(len(f.data))
	if f.size != 0 {
		size = f.size
	}
	return objstore.Attrs{Size: size, ContentType: f.contentType, MD5: m}, nil
}

func (o *fakeObjects) UploadHead(_ context.Context, object string, n int64) ([]byte, error) {
	o.mu.Lock()
	defer o.mu.Unlock()
	f, ok := o.upload[object]
	if !ok {
		return nil, objstore.ErrObjectNotFound
	}
	if int64(len(f.data)) < n {
		n = int64(len(f.data))
	}
	return f.data[:n], nil
}

func (o *fakeObjects) Publish(_ context.Context, uploadObject, publicObject, contentType string) error {
	o.mu.Lock()
	defer o.mu.Unlock()
	if o.publishErr != nil {
		return o.publishErr
	}
	if _, ok := o.upload[uploadObject]; !ok {
		return objstore.ErrObjectNotFound
	}
	o.publishes++
	o.public[publicObject] = contentType
	return nil
}

func (o *fakeObjects) DeleteUpload(_ context.Context, object string) error {
	o.mu.Lock()
	defer o.mu.Unlock()
	delete(o.upload, object)
	o.deleted = append(o.deleted, "u:"+object)
	return nil
}

func (o *fakeObjects) DeletePublic(_ context.Context, object string) error {
	o.mu.Lock()
	defer o.mu.Unlock()
	if o.deletePub != nil {
		return o.deletePub
	}
	delete(o.public, object)
	o.deleted = append(o.deleted, "p:"+object)
	return nil
}

// fakeSigner returns a URL naming the object.
type fakeSigner struct{ calls int }

func (s *fakeSigner) SignPut(_ context.Context, object, contentType, md5b64 string, maxBytes int64, ttl time.Duration, now time.Time) (string, map[string]string, error) {
	s.calls++
	return "https://upload.test/" + object, map[string]string{
		"Content-Type": contentType, "Content-MD5": md5b64,
		"x-goog-content-length-range": fmt.Sprintf("0,%d", maxBytes),
	}, nil
}

// fakeModerator scripts SafeSearch answers per object.
type fakeModerator struct {
	mu    sync.Mutex
	calls []string
	by    map[string]SafeSearch
	err   error
}

func (m *fakeModerator) SafeSearch(_ context.Context, object string) (SafeSearch, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.calls = append(m.calls, object)
	if m.err != nil {
		return SafeSearch{}, m.err
	}
	return m.by[object], nil
}

type fakeDirectory struct {
	created time.Time
	err     error
}

func (d fakeDirectory) AccountCreatedAt(context.Context, string) (time.Time, error) {
	return d.created, d.err
}

type seqIDs struct {
	mu sync.Mutex
	n  int
}

func (s *seqIDs) Generate() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.n++
	return fmt.Sprintf("%019d", 1000+s.n)
}

func md5b64(data []byte) string {
	sum := md5.Sum(data)
	return base64.StdEncoding.EncodeToString(sum[:])
}

// jpegBytes and webpBytes are minimal files with the right magic bytes.
func jpegBytes(tag string) []byte { return append([]byte{0xFF, 0xD8, 0xFF, 0xE0}, []byte(tag)...) }
func webpBytes(tag string) []byte {
	return append([]byte("RIFF\x00\x00\x00\x00WEBPVP8 "), []byte(tag)...)
}

type fakeFlags map[string]bool

func (f fakeFlags) Enabled(_, name string) bool { return f[name] }

// fakePosts answers PostGone from a set of live posts.
type fakePosts struct {
	live map[string]bool
	err  error
}

func (p fakePosts) PostGone(_ context.Context, id string) (bool, error) {
	return !p.live[id], p.err
}

type fakePublisher struct {
	msgs [][]byte
	err  error
}

func (p *fakePublisher) Publish(_ context.Context, data []byte) error {
	p.msgs = append(p.msgs, data)
	return p.err
}
