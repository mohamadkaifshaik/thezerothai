package media

import (
	"context"
	"errors"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/objstore"
)

const (
	uidA = "uid-alice"
	uidB = "uid-bob"
	key1 = "0123456789abcdef"
	key2 = "fedcba9876543210"
)

var testNow = time.Date(2026, 10, 11, 12, 0, 0, 0, time.UTC)

type env struct {
	svc  Service
	repo *fakeRepo
	obj  *fakeObjects
	mod  *fakeModerator
	sign *fakeSigner
}

type envOpts struct {
	cap         int64
	policy      config.VisionExhaustedPolicy
	screenThumb bool
	accountAge  time.Duration // age of every account
	perDay      int64
	newPerDay   int64
	dirErr      error
}

func newEnv(t *testing.T, o envOpts) *env {
	t.Helper()
	if o.cap == 0 && o.perDay == 0 {
		o.cap = 100
	}
	if o.perDay == 0 {
		o.perDay = 20
	}
	if o.newPerDay == 0 {
		o.newPerDay = 8
	}
	if o.accountAge == 0 {
		o.accountAge = 30 * 24 * time.Hour
	}
	e := &env{repo: newFakeRepo(), obj: newFakeObjects(), mod: &fakeModerator{by: map[string]SafeSearch{}}, sign: &fakeSigner{}}
	svc, err := New(Deps{
		Repo: e.repo, Signer: e.sign, Objects: e.obj, Moderator: e.mod,
		Directory: fakeDirectory{created: testNow.Add(-o.accountAge), err: o.dirErr}, IDs: &seqIDs{},
		PublicBaseURL: "https://cdn.test/media", MediaPerDay: o.perDay, NewAccountMediaPerDay: o.newPerDay,
		NewAccountWindow: 24 * time.Hour, VisionMonthlyCap: o.cap, Policy: o.policy, ScreenThumb: o.screenThumb,
		Now: func() time.Time { return testNow },
	})
	if err != nil {
		t.Fatal(err)
	}
	e.svc = svc
	return e
}

func item(full, thumb []byte, ct string) UploadItem {
	return UploadItem{
		ContentType: ct, FullBytes: int64(len(full)), ThumbBytes: int64(len(thumb)), Width: 1200, Height: 800,
		FullMD5: md5b64(full), ThumbMD5: md5b64(thumb),
	}
}

// put models the client's two PUTs for a target.
func (e *env) put(uid string, tg UploadTarget, full, thumb []byte, ct string) {
	ext := extension(ct)
	e.obj.upload[uploadObject(uid, tg.MediaID, ext)] = fakeObject{data: full, contentType: ct}
	e.obj.upload[uploadThumbObject(uid, tg.MediaID, ext)] = fakeObject{data: thumb, contentType: ct}
}

// upload runs CreateUpload and the client's PUTs for one good JPEG.
func (e *env) upload(t *testing.T, uid string, purpose Purpose, tag string) UploadTarget {
	t.Helper()
	full, thumb := jpegBytes("F"+tag), jpegBytes("T"+tag)
	tgs, err := e.svc.CreateUpload(context.Background(), uid, CreateUploadInput{
		IdempotencyKey: "key-" + tag + "-0123456789", Purpose: purpose, Items: []UploadItem{item(full, thumb, "image/jpeg")},
	})
	if err != nil {
		t.Fatal(err)
	}
	e.put(uid, tgs[0], full, thumb, "image/jpeg")
	return tgs[0]
}

func wantAPI(t *testing.T, err error, code connect.Code, reason commonv1.ErrorReason) *apierr.Error {
	t.Helper()
	var ae *apierr.Error
	if !errors.As(err, &ae) {
		t.Fatalf("error %v (%T) is not an *apierr.Error", err, err)
	}
	if ae.Code != code || ae.Reason != reason {
		t.Fatalf("got %v/%v (%q), want %v/%v", ae.Code, ae.Reason, ae.Message, code, reason)
	}
	return ae
}

func TestCreateUpload_Validation(t *testing.T) {
	good := item(jpegBytes("a"), jpegBytes("b"), "image/jpeg")
	with := func(f func(*UploadItem)) UploadItem { i := good; f(&i); return i }
	tests := []struct {
		name  string
		in    CreateUploadInput
		field string
	}{
		{"short key", CreateUploadInput{IdempotencyKey: "short", Purpose: PurposePost, Items: []UploadItem{good}}, "idempotency_key"},
		{"no purpose", CreateUploadInput{IdempotencyKey: key1, Items: []UploadItem{good}}, "purpose"},
		{"no items", CreateUploadInput{IdempotencyKey: key1, Purpose: PurposePost}, "items"},
		{"five items", CreateUploadInput{IdempotencyKey: key1, Purpose: PurposePost, Items: []UploadItem{good, good, good, good, good}}, "items"},
		{"two avatars", CreateUploadInput{IdempotencyKey: key1, Purpose: PurposeAvatar, Items: []UploadItem{good, good}}, "items"},
		{"gif", CreateUploadInput{IdempotencyKey: key1, Purpose: PurposePost, Items: []UploadItem{with(func(i *UploadItem) { i.ContentType = "image/gif" })}}, "items[0].content_type"},
		{"oversize full", CreateUploadInput{IdempotencyKey: key1, Purpose: PurposePost, Items: []UploadItem{with(func(i *UploadItem) { i.FullBytes = MaxFullBytes + 1 })}}, "items[0].full_size_bytes"},
		{"zero full", CreateUploadInput{IdempotencyKey: key1, Purpose: PurposePost, Items: []UploadItem{with(func(i *UploadItem) { i.FullBytes = 0 })}}, "items[0].full_size_bytes"},
		{"oversize thumb", CreateUploadInput{IdempotencyKey: key1, Purpose: PurposePost, Items: []UploadItem{with(func(i *UploadItem) { i.ThumbBytes = MaxThumbBytes + 1 })}}, "items[0].thumb_size_bytes"},
		{"huge dimension", CreateUploadInput{IdempotencyKey: key1, Purpose: PurposePost, Items: []UploadItem{with(func(i *UploadItem) { i.Width = MaxDimension + 1 })}}, "items[0].width"},
		{"bad md5", CreateUploadInput{IdempotencyKey: key1, Purpose: PurposePost, Items: []UploadItem{with(func(i *UploadItem) { i.FullMD5 = "nope" })}}, "items[0].full_md5"},
		{"bad thumb md5", CreateUploadInput{IdempotencyKey: key1, Purpose: PurposePost, Items: []UploadItem{with(func(i *UploadItem) { i.ThumbMD5 = "" })}}, "items[0].thumb_md5"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := newEnv(t, envOpts{})
			_, err := e.svc.CreateUpload(context.Background(), uidA, tt.in)
			ae := wantAPI(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION)
			if ae.Metadata["field"] != tt.field {
				t.Fatalf("field = %q, want %q", ae.Metadata["field"], tt.field)
			}
			if e.sign.calls != 0 || len(e.repo.docs) != 0 {
				t.Fatal("a rejected request must sign nothing and write nothing")
			}
		})
	}
}

func TestCreateUpload_ReservesPendingDocsAndSignsBoundURLs(t *testing.T) {
	e := newEnv(t, envOpts{})
	full, thumb := webpBytes("a"), webpBytes("b")
	tgs, err := e.svc.CreateUpload(context.Background(), uidA, CreateUploadInput{
		IdempotencyKey: key1, Purpose: PurposePost,
		Items: []UploadItem{item(full, thumb, "image/webp"), item(jpegBytes("c"), jpegBytes("d"), "image/jpeg")},
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(tgs) != 2 || len(e.repo.docs) != 2 || e.sign.calls != 4 {
		t.Fatalf("targets=%d docs=%d signs=%d", len(tgs), len(e.repo.docs), e.sign.calls)
	}
	d := e.repo.docs[tgs[0].MediaID]
	if d.Status != string(StatusPending) || d.OwnerID != uidA || d.Purpose != string(PurposePost) || d.ExpireAt == nil || !d.ExpireAt.Equal(testNow.Add(PendingTTL)) {
		t.Fatalf("doc = %+v", d)
	}
	// The signed object is under the caller's own prefix, and the headers pin type, MD5 and size.
	wantObj := "u/" + uidA + "/" + tgs[0].MediaID + ".webp"
	if tgs[0].Full.URL != "https://upload.test/"+wantObj {
		t.Fatalf("full url = %q", tgs[0].Full.URL)
	}
	if tgs[0].Full.Headers["Content-MD5"] != md5b64(full) || tgs[0].Full.Headers["x-goog-content-length-range"] != "0,2097152" ||
		tgs[0].Thumb.Headers["x-goog-content-length-range"] != "0,262144" || tgs[0].Full.Headers["Content-Type"] != "image/webp" {
		t.Fatalf("headers = %v / %v", tgs[0].Full.Headers, tgs[0].Thumb.Headers)
	}
	if !tgs[0].Full.ExpiresAt.Equal(testNow.Add(UploadURLTTL)) {
		t.Fatalf("expiry = %v", tgs[0].Full.ExpiresAt)
	}
}

func TestCreateUpload_ReplayAndKeyReuse(t *testing.T) {
	e := newEnv(t, envOpts{})
	in := CreateUploadInput{IdempotencyKey: key1, Purpose: PurposePost, Items: []UploadItem{item(jpegBytes("a"), jpegBytes("b"), "image/jpeg")}}
	first, err := e.svc.CreateUpload(context.Background(), uidA, in)
	if err != nil {
		t.Fatal(err)
	}
	replay, err := e.svc.CreateUpload(context.Background(), uidA, in)
	if err != nil || replay[0].MediaID != first[0].MediaID || len(e.repo.docs) != 1 {
		t.Fatalf("replay: %v ids %v vs %v docs=%d", err, replay, first, len(e.repo.docs))
	}
	other := in
	other.Items = []UploadItem{item(jpegBytes("zzz"), jpegBytes("b"), "image/jpeg")}
	_, err = e.svc.CreateUpload(context.Background(), uidA, other)
	_ = wantAPI(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_IDEMPOTENCY_KEY_REUSED)
}

func TestCreateUpload_QuotaTiers(t *testing.T) {
	e := newEnv(t, envOpts{accountAge: time.Hour, perDay: 20, newPerDay: 8})
	mk := func(n int, key string) error {
		items := make([]UploadItem, n)
		for i := range items {
			items[i] = item(jpegBytes("a"), jpegBytes("b"), "image/jpeg")
		}
		_, err := e.svc.CreateUpload(context.Background(), uidA, CreateUploadInput{IdempotencyKey: key, Purpose: PurposePost, Items: items})
		return err
	}
	if err := mk(4, key1); err != nil {
		t.Fatal(err)
	}
	if err := mk(4, key2); err != nil {
		t.Fatal(err)
	}
	// The 9th image exceeds the new-account limit of 8, as a whole call.
	err := mk(1, "third-key-0123456789")
	_ = wantAPI(t, err, connect.CodeResourceExhausted, commonv1.ErrorReason_ERROR_REASON_QUOTA_EXCEEDED)
}

func TestCreateUpload_DirectoryFailureIsInternal(t *testing.T) {
	e := newEnv(t, envOpts{dirErr: errors.New("boom")})
	_, err := e.svc.CreateUpload(context.Background(), uidA, CreateUploadInput{
		IdempotencyKey: key1, Purpose: PurposePost, Items: []UploadItem{item(jpegBytes("a"), jpegBytes("b"), "image/jpeg")},
	})
	var ae *apierr.Error
	if err == nil || errors.As(err, &ae) {
		t.Fatalf("err = %v: an infrastructure failure must not be shaped as an API error", err)
	}
}

func TestFinalize_HappyPath(t *testing.T) {
	e := newEnv(t, envOpts{})
	tg := e.upload(t, uidA, PurposePost, "a")
	res, err := e.svc.FinalizeUpload(context.Background(), uidA, []FinalizeItem{{MediaID: tg.MediaID, Blurhash: "LEHV6nWB2yk8pyo0adR*.7kCMdnj"}})
	if err != nil {
		t.Fatal(err)
	}
	r := res[0]
	if r.Status != StatusReady || r.Ref == nil {
		t.Fatalf("result = %+v", r)
	}
	if r.Ref.URL != "https://cdn.test/media/m/"+tg.MediaID+".jpg" || r.Ref.ThumbURL != "https://cdn.test/media/m/"+tg.MediaID+"_t.jpg" {
		t.Fatalf("ref = %+v", r.Ref)
	}
	if len(e.obj.public) != 2 {
		t.Fatalf("public objects = %v", e.obj.public)
	}
	if len(e.obj.upload) != 0 {
		t.Fatalf("private copies not deleted: %v", e.obj.upload)
	}
	d := e.repo.docs[tg.MediaID]
	if d.Status != string(StatusReady) || d.ExpireAt != nil || d.Blurhash == "" {
		t.Fatalf("doc = %+v: READY must drop the TTL", d)
	}
	// Full only by default: the thumbnail is the config switch.
	if got := e.repo.vision[monthKey(testNow)]; got != 1 || len(e.mod.calls) != 1 {
		t.Fatalf("vision units=%d calls=%v, want 1 / full only", got, e.mod.calls)
	}
}

func TestFinalize_ScreensThumbnailWhenConfigured(t *testing.T) {
	e := newEnv(t, envOpts{screenThumb: true})
	tg := e.upload(t, uidA, PurposePost, "a")
	// The thumbnail is explicit even though the full image is not: it must be caught.
	e.mod.by[uploadThumbObject(uidA, tg.MediaID, "jpg")] = SafeSearch{Adult: LikelihoodVeryLikely}
	res, err := e.svc.FinalizeUpload(context.Background(), uidA, []FinalizeItem{{MediaID: tg.MediaID}})
	if err != nil {
		t.Fatal(err)
	}
	if res[0].Status != StatusRejected || res[0].Ref != nil || len(e.obj.public) != 0 {
		t.Fatalf("result = %+v public=%v", res[0], e.obj.public)
	}
	if e.repo.vision[monthKey(testNow)] != 2 {
		t.Fatalf("vision units = %d, want 2 (full + thumb)", e.repo.vision[monthKey(testNow)])
	}
}

func TestFinalize_Rejections(t *testing.T) {
	tests := []struct {
		name   string
		setup  func(e *env, tg UploadTarget)
		purp   Purpose
		reason string
	}{
		{"md5 mismatch", func(e *env, tg UploadTarget) {
			o := uploadObject(uidA, tg.MediaID, "jpg")
			f := e.obj.upload[o]
			f.attrsMD5 = make([]byte, 16)
			e.obj.upload[o] = f
		}, PurposePost, reasonInvalid},
		{"size differs from declared", func(e *env, tg UploadTarget) {
			o := uploadObject(uidA, tg.MediaID, "jpg")
			f := e.obj.upload[o]
			f.size = MaxFullBytes
			e.obj.upload[o] = f
		}, PurposePost, reasonInvalid},
		{"oversize thumb", func(e *env, tg UploadTarget) {
			o := uploadThumbObject(uidA, tg.MediaID, "jpg")
			f := e.obj.upload[o]
			f.size = MaxThumbBytes + 1
			e.obj.upload[o] = f
		}, PurposePost, reasonInvalid},
		{"content type differs", func(e *env, tg UploadTarget) {
			o := uploadObject(uidA, tg.MediaID, "jpg")
			f := e.obj.upload[o]
			f.contentType = "image/png"
			e.obj.upload[o] = f
		}, PurposePost, reasonInvalid},
		{"magic bytes are not a jpeg", func(e *env, tg UploadTarget) {
			// Same size, matching MD5 of the new bytes would be needed: keep attrs honest by faking only the head.
			o := uploadObject(uidA, tg.MediaID, "jpg")
			data := []byte("<?php echo 1; ?>")
			e.repo.docs[tg.MediaID].Bytes = int64(len(data))
			e.repo.docs[tg.MediaID].FullMD5 = md5b64(data)
			e.obj.upload[o] = fakeObject{data: data, contentType: "image/jpeg"}
		}, PurposePost, reasonInvalid},
		{"webp magic on a jpeg declaration", func(e *env, tg UploadTarget) {
			o := uploadObject(uidA, tg.MediaID, "jpg")
			data := webpBytes("x")
			e.repo.docs[tg.MediaID].Bytes = int64(len(data))
			e.repo.docs[tg.MediaID].FullMD5 = md5b64(data)
			e.obj.upload[o] = fakeObject{data: data, contentType: "image/jpeg"}
		}, PurposePost, reasonInvalid},
		{"adult likely", func(e *env, tg UploadTarget) {
			e.mod.by[uploadObject(uidA, tg.MediaID, "jpg")] = SafeSearch{Adult: LikelihoodLikely}
		}, PurposePost, reasonPolicy},
		{"violence very likely", func(e *env, tg UploadTarget) {
			e.mod.by[uploadObject(uidA, tg.MediaID, "jpg")] = SafeSearch{Violence: LikelihoodVeryLikely}
		}, PurposePost, reasonPolicy},
		{"racy avatar", func(e *env, tg UploadTarget) {
			e.mod.by[uploadObject(uidA, tg.MediaID, "jpg")] = SafeSearch{Racy: LikelihoodLikely}
		}, PurposeAvatar, reasonPolicy},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := newEnv(t, envOpts{})
			tg := e.upload(t, uidA, tt.purp, "a")
			tt.setup(e, tg)
			res, err := e.svc.FinalizeUpload(context.Background(), uidA, []FinalizeItem{{MediaID: tg.MediaID}})
			if err != nil {
				t.Fatal(err)
			}
			r := res[0]
			if r.Status != StatusRejected || r.RejectionReason != tt.reason || r.Ref != nil {
				t.Fatalf("result = %+v, want REJECTED %q", r, tt.reason)
			}
			if len(e.obj.public) != 0 || e.obj.publishes != 0 {
				t.Fatal("rejected bytes must never be copied to the public bucket")
			}
			if len(e.obj.upload) != 0 {
				t.Fatalf("rejected private objects must be deleted: %v", e.obj.upload)
			}
			d := e.repo.docs[tg.MediaID]
			if d.Status != string(StatusRejected) || d.ExpireAt == nil || d.PublicPath != "" {
				t.Fatalf("doc = %+v", d)
			}
			// A replayed FinalizeUpload gets the same answer without new work.
			calls := len(e.mod.calls)
			again, err := e.svc.FinalizeUpload(context.Background(), uidA, []FinalizeItem{{MediaID: tg.MediaID}})
			if err != nil || again[0].Status != StatusRejected || len(e.mod.calls) != calls {
				t.Fatalf("replay = %+v err=%v moderator calls %d -> %d", again, err, calls, len(e.mod.calls))
			}
		})
	}
}

func TestFinalize_RacyPostImageIsAllowed(t *testing.T) {
	e := newEnv(t, envOpts{})
	tg := e.upload(t, uidA, PurposePost, "a")
	e.mod.by[uploadObject(uidA, tg.MediaID, "jpg")] = SafeSearch{Racy: LikelihoodVeryLikely, Adult: LikelihoodPossible}
	res, err := e.svc.FinalizeUpload(context.Background(), uidA, []FinalizeItem{{MediaID: tg.MediaID}})
	if err != nil || res[0].Status != StatusReady {
		t.Fatalf("res=%+v err=%v: only avatars block on racy (ADR-0005)", res, err)
	}
}

func TestFinalize_NotUploadedYet(t *testing.T) {
	e := newEnv(t, envOpts{})
	tgs, err := e.svc.CreateUpload(context.Background(), uidA, CreateUploadInput{
		IdempotencyKey: key1, Purpose: PurposePost, Items: []UploadItem{item(jpegBytes("a"), jpegBytes("b"), "image/jpeg")},
	})
	if err != nil {
		t.Fatal(err)
	}
	_, err = e.svc.FinalizeUpload(context.Background(), uidA, []FinalizeItem{{MediaID: tgs[0].MediaID}})
	_ = wantAPI(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_MEDIA_NOT_READY)
	if e.repo.docs[tgs[0].MediaID].Status != string(StatusPending) {
		t.Fatal("an incomplete upload stays PENDING so the client can retry")
	}
	if len(e.mod.calls) != 0 {
		t.Fatal("nothing is screened before the bytes are there")
	}
}

func TestFinalize_NotTheOwnersIsNotFound(t *testing.T) {
	e := newEnv(t, envOpts{})
	tg := e.upload(t, uidA, PurposePost, "a")
	_, err := e.svc.FinalizeUpload(context.Background(), uidB, []FinalizeItem{{MediaID: tg.MediaID}})
	_ = wantAPI(t, err, connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED)
	_, err = e.svc.FinalizeUpload(context.Background(), uidA, []FinalizeItem{{MediaID: "0000000000000009999"}})
	_ = wantAPI(t, err, connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED)
	if len(e.obj.public) != 0 || len(e.mod.calls) != 0 {
		t.Fatal("a foreign id must not trigger any work")
	}
}

func TestFinalize_Validation(t *testing.T) {
	tests := []struct {
		name  string
		items []FinalizeItem
	}{
		{"none", nil},
		{"five", []FinalizeItem{{MediaID: "0000000000000000001"}, {MediaID: "0000000000000000002"}, {MediaID: "0000000000000000003"}, {MediaID: "0000000000000000004"}, {MediaID: "0000000000000000005"}}},
		{"bad id", []FinalizeItem{{MediaID: "abc"}}},
		{"duplicate", []FinalizeItem{{MediaID: "0000000000000000001"}, {MediaID: "0000000000000000001"}}},
		{"blurhash too long", []FinalizeItem{{MediaID: "0000000000000000001", Blurhash: string(make([]byte, 65))}}},
		{"blurhash bad chars", []FinalizeItem{{MediaID: "0000000000000000001", Blurhash: "<script>"}}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := newEnv(t, envOpts{})
			_, err := e.svc.FinalizeUpload(context.Background(), uidA, tt.items)
			_ = wantAPI(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION)
		})
	}
}

func TestFinalize_ModerationOutageFailsClosed(t *testing.T) {
	e := newEnv(t, envOpts{})
	tg := e.upload(t, uidA, PurposePost, "a")
	e.mod.err = errors.New("vision 503")
	_, err := e.svc.FinalizeUpload(context.Background(), uidA, []FinalizeItem{{MediaID: tg.MediaID}})
	_ = wantAPI(t, err, connect.CodeUnavailable, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED)
	if len(e.obj.public) != 0 || e.repo.docs[tg.MediaID].Status != string(StatusPending) {
		t.Fatal("nothing is published without an answer, and the image stays retryable")
	}
	if e.repo.vision[monthKey(testNow)] != 0 {
		t.Fatalf("units = %d: a failed screening spends nothing", e.repo.vision[monthKey(testNow)])
	}
	// The retry after the outage succeeds.
	e.mod.err = nil
	res, err := e.svc.FinalizeUpload(context.Background(), uidA, []FinalizeItem{{MediaID: tg.MediaID}})
	if err != nil || res[0].Status != StatusReady {
		t.Fatalf("retry = %+v err=%v", res, err)
	}
}

func TestFinalize_ReFinalizeIsIdempotent(t *testing.T) {
	e := newEnv(t, envOpts{})
	tg := e.upload(t, uidA, PurposePost, "a")
	first, err := e.svc.FinalizeUpload(context.Background(), uidA, []FinalizeItem{{MediaID: tg.MediaID, Blurhash: "LEHV6n"}})
	if err != nil {
		t.Fatal(err)
	}
	calls, publishes, units := len(e.mod.calls), e.obj.publishes, e.repo.vision[monthKey(testNow)]
	second, err := e.svc.FinalizeUpload(context.Background(), uidA, []FinalizeItem{{MediaID: tg.MediaID, Blurhash: "different"}})
	if err != nil || second[0].Status != StatusReady || *second[0].Ref != *first[0].Ref {
		t.Fatalf("second = %+v err=%v", second, err)
	}
	if len(e.mod.calls) != calls || e.obj.publishes != publishes || e.repo.vision[monthKey(testNow)] != units {
		t.Fatal("a re-finalize must not screen, copy or count again")
	}
}

func TestFinalize_VisionCap(t *testing.T) {
	tests := []struct {
		name       string
		cap        int64
		used       int64
		policy     config.VisionExhaustedPolicy
		age        time.Duration
		wantStatus Status
		wantReason string
		wantCalls  int
	}{
		{"under the cap", 10, 9, config.VisionPolicyEstablished, 30 * 24 * time.Hour, StatusReady, "", 1},
		{"at the cap, established account: unscreened", 10, 10, config.VisionPolicyEstablished, 30 * 24 * time.Hour, StatusReadyUnscreened, "", 0},
		{"at the cap, new account: rejected", 10, 10, config.VisionPolicyEstablished, 2 * 24 * time.Hour, StatusRejected, reasonCapacity, 0},
		{"at the cap, policy reject", 10, 10, config.VisionPolicyReject, 30 * 24 * time.Hour, StatusRejected, reasonCapacity, 0},
		{"cap 0 disables screening spend", -1, 0, config.VisionPolicyEstablished, 30 * 24 * time.Hour, StatusReadyUnscreened, "", 0},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// envOpts treats cap 0 as "default", so a disabled cap (tt.cap < 0) is built explicitly.
			var e *env
			if tt.cap < 0 {
				e = newEnvCap0(t, tt.policy, tt.age)
			} else {
				e = newEnv(t, envOpts{cap: tt.cap, policy: tt.policy, accountAge: tt.age})
			}
			e.repo.vision[monthKey(testNow)] = tt.used
			tg := e.upload(t, uidA, PurposePost, "a")
			res, err := e.svc.FinalizeUpload(context.Background(), uidA, []FinalizeItem{{MediaID: tg.MediaID}})
			if err != nil {
				t.Fatal(err)
			}
			r := res[0]
			if r.Status != tt.wantStatus || r.RejectionReason != tt.wantReason {
				t.Fatalf("result = %+v, want %s %q", r, tt.wantStatus, tt.wantReason)
			}
			if len(e.mod.calls) != tt.wantCalls {
				t.Fatalf("moderator calls = %d, want %d: the cap must stop Vision spend", len(e.mod.calls), tt.wantCalls)
			}
			if tt.wantStatus == StatusRejected && len(e.obj.public) != 0 {
				t.Fatal("rejected bytes were published")
			}
			if tt.wantStatus == StatusReadyUnscreened && (r.Ref == nil || len(e.obj.public) != 2) {
				t.Fatalf("unscreened publish: ref=%v public=%v", r.Ref, e.obj.public)
			}
		})
	}
}

func newEnvCap0(t *testing.T, policy config.VisionExhaustedPolicy, age time.Duration) *env {
	t.Helper()
	e := &env{repo: newFakeRepo(), obj: newFakeObjects(), mod: &fakeModerator{by: map[string]SafeSearch{}}, sign: &fakeSigner{}}
	svc, err := New(Deps{
		Repo: e.repo, Signer: e.sign, Objects: e.obj, Moderator: e.mod,
		Directory: fakeDirectory{created: testNow.Add(-age)}, IDs: &seqIDs{}, PublicBaseURL: "https://cdn.test/media",
		MediaPerDay: 20, NewAccountMediaPerDay: 8, NewAccountWindow: 24 * time.Hour,
		VisionMonthlyCap: 0, Policy: policy, Now: func() time.Time { return testNow },
	})
	if err != nil {
		t.Fatal(err)
	}
	e.svc = svc
	return e
}

func TestFinalize_CapIsSharedAcrossAFinalizeAndNeverExceeded(t *testing.T) {
	// Three images, 2 units left: the first two are screened, the third takes the exhausted path.
	e := newEnv(t, envOpts{cap: 10})
	e.repo.vision[monthKey(testNow)] = 8
	var items []FinalizeItem
	for _, tag := range []string{"a", "b", "c"} {
		tg := e.upload(t, uidA, PurposePost, tag)
		items = append(items, FinalizeItem{MediaID: tg.MediaID})
	}
	res, err := e.svc.FinalizeUpload(context.Background(), uidA, items)
	if err != nil {
		t.Fatal(err)
	}
	var ready, unscreened int
	for _, r := range res {
		switch r.Status {
		case StatusReady:
			ready++
		case StatusReadyUnscreened:
			unscreened++
		}
	}
	if ready != 2 || unscreened != 1 || len(e.mod.calls) != 2 {
		t.Fatalf("ready=%d unscreened=%d calls=%d", ready, unscreened, len(e.mod.calls))
	}
	if got := e.repo.vision[monthKey(testNow)]; got != 10 {
		t.Fatalf("counter = %d, want exactly the cap", got)
	}
}

func TestFinalize_VisionCounterReadIsCached(t *testing.T) {
	e := newEnv(t, envOpts{cap: 100})
	for _, tag := range []string{"a", "b", "c"} {
		tg := e.upload(t, uidA, PurposePost, tag)
		if _, err := e.svc.FinalizeUpload(context.Background(), uidA, []FinalizeItem{{MediaID: tg.MediaID}}); err != nil {
			t.Fatal(err)
		}
	}
	if e.repo.visionRd != 1 {
		t.Fatalf("counter reads = %d, want 1 (cached 60 s per instance)", e.repo.visionRd)
	}
}

func TestBlockedBySafeSearch(t *testing.T) {
	tests := []struct {
		name string
		ss   SafeSearch
		p    Purpose
		want bool
	}{
		{"clean", SafeSearch{LikelihoodVeryUnlikely, LikelihoodUnlikely, LikelihoodUnlikely}, PurposePost, false},
		{"possible adult passes", SafeSearch{Adult: LikelihoodPossible}, PurposePost, false},
		{"likely adult blocks", SafeSearch{Adult: LikelihoodLikely}, PurposePost, true},
		{"likely violence blocks", SafeSearch{Violence: LikelihoodLikely}, PurposePost, true},
		{"racy post passes", SafeSearch{Racy: LikelihoodVeryLikely}, PurposePost, false},
		{"racy avatar blocks", SafeSearch{Racy: LikelihoodLikely}, PurposeAvatar, true},
		{"possible racy avatar passes", SafeSearch{Racy: LikelihoodPossible}, PurposeAvatar, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := blockedBySafeSearch(tt.ss, tt.p); got != tt.want {
				t.Fatalf("got %v", got)
			}
		})
	}
}

func TestSniffImage(t *testing.T) {
	tests := []struct {
		name string
		in   []byte
		want string
	}{
		{"jpeg", []byte{0xFF, 0xD8, 0xFF, 0xE1, 0, 0}, "image/jpeg"},
		{"webp", append([]byte("RIFF\x01\x02\x03\x04WEBPVP8L"), 0), "image/webp"},
		{"png is not accepted", []byte("\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR"), ""},
		{"gif is not accepted", []byte("GIF89a......"), ""},
		{"riff but not webp", []byte("RIFF\x00\x00\x00\x00WAVEfmt "), ""},
		{"html", []byte("<html></html>"), ""},
		{"short", []byte{0xFF, 0xD8}, ""},
		{"empty", nil, ""},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := sniffImage(tt.in); got != tt.want {
				t.Fatalf("sniffImage = %q, want %q", got, tt.want)
			}
		})
	}
}

func TestNew_RequiresDependencies(t *testing.T) {
	if _, err := New(Deps{}); err == nil {
		t.Fatal("empty Deps must be refused at startup")
	}
	if _, err := New(Deps{Repo: newFakeRepo(), Signer: &fakeSigner{}, Objects: newFakeObjects(), Moderator: &fakeModerator{},
		Directory: fakeDirectory{}, IDs: &seqIDs{}}); err == nil {
		t.Fatal("missing PublicBaseURL must be refused")
	}
}

// Compile-time guard that the fakes keep satisfying the seams.
var (
	_ Repo      = (*fakeRepo)(nil)
	_ Objects   = (*fakeObjects)(nil)
	_ Signer    = (*fakeSigner)(nil)
	_ Moderator = (*fakeModerator)(nil)
	_           = objstore.ErrObjectNotFound
)
