package media

import (
	"context"
	"strconv"
	"strings"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	mediav1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/media/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
)

// W6-9 (ADR-0029 D10): image/gif for post media. The sampled-frame screening is W6-10; these tests cover the content-type
// table, the thumbnail's own type, magic bytes, the flag, the cap rule and the cleanup names.

func gifBytes(tag string) []byte { return append([]byte("GIF89a"), []byte(tag)...) }

func pngBytes(tag string) []byte {
	return append([]byte{0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A}, []byte(tag)...)
}

func gifItem(full, thumb []byte, thumbType string) UploadItem {
	it := item(full, thumb, ContentTypeGIF)
	it.ThumbContentType = thumbType
	return it
}

// putGIF models the client's two PUTs for a GIF target: the thumbnail object is named and typed by thumbType.
func (e *env) putGIF(uid string, tg UploadTarget, full, thumb []byte, thumbType string) {
	e.obj.upload[uploadObject(uid, tg.MediaID, "gif")] = fakeObject{data: full, contentType: ContentTypeGIF}
	e.obj.upload[uploadThumbObject(uid, tg.MediaID, extension(thumbType))] = fakeObject{data: thumb, contentType: thumbType}
}

func (e *env) createGIF(t *testing.T, uid, tag, thumbType string) UploadTarget {
	t.Helper()
	full, thumb := gifBytes("F"+tag), jpegBytes("T"+tag)
	if thumbType == ContentTypeWebP {
		thumb = webpBytes("T" + tag)
	}
	tgs, err := e.svc.CreateUpload(context.Background(), uid, CreateUploadInput{
		IdempotencyKey: "key-" + tag + "-0123456789", Purpose: PurposePost, Items: []UploadItem{gifItem(full, thumb, thumbType)},
	})
	if err != nil {
		t.Fatal(err)
	}
	e.putGIF(uid, tgs[0], full, thumb, thumbType)
	return tgs[0]
}

func TestGIF_CreateUploadMatrix(t *testing.T) {
	g := gifItem(gifBytes("a"), jpegBytes("b"), ContentTypeJPEG)
	photo := item(jpegBytes("c"), jpegBytes("d"), ContentTypeJPEG)
	with := func(base UploadItem, f func(*UploadItem)) UploadItem { f(&base); return base }
	tests := []struct {
		name    string
		purpose Purpose
		items   []UploadItem
		field   string // "" = accepted
	}{
		{"gif with a jpeg thumbnail", PurposePost, []UploadItem{g}, ""},
		{"gif with a webp thumbnail", PurposePost, []UploadItem{with(g, func(i *UploadItem) { i.ThumbContentType = ContentTypeWebP })}, ""},
		{"gif at the edge limit", PurposePost, []UploadItem{with(g, func(i *UploadItem) { i.Width, i.Height = 1280, 1280 })}, ""},
		{"gif too wide", PurposePost, []UploadItem{with(g, func(i *UploadItem) { i.Width = 1281 })}, "items[0].width"},
		{"gif too tall", PurposePost, []UploadItem{with(g, func(i *UploadItem) { i.Height = 1281 })}, "items[0].width"},
		{"photo may be wider than the gif edge", PurposePost, []UploadItem{with(photo, func(i *UploadItem) { i.Width = 1600 })}, ""},
		{"gif without a thumbnail type", PurposePost, []UploadItem{with(g, func(i *UploadItem) { i.ThumbContentType = "" })}, "items[0].thumb_content_type"},
		{"gif with a gif thumbnail", PurposePost, []UploadItem{with(g, func(i *UploadItem) { i.ThumbContentType = ContentTypeGIF })}, "items[0].thumb_content_type"},
		{"gif with a png thumbnail", PurposePost, []UploadItem{with(g, func(i *UploadItem) { i.ThumbContentType = "image/png" })}, "items[0].thumb_content_type"},
		{"avatar gif", PurposeAvatar, []UploadItem{g}, "items[0].content_type"},
		{"banner gif", PurposeBanner, []UploadItem{g}, "items[0].content_type"},
		{"gif plus a photo", PurposePost, []UploadItem{g, photo}, "items"},
		{"photo plus a gif", PurposePost, []UploadItem{photo, g}, "items"},
		{"two gifs", PurposePost, []UploadItem{g, g}, "items"},
		{"oversize gif", PurposePost, []UploadItem{with(g, func(i *UploadItem) { i.FullBytes = MaxFullBytes + 1 })}, "items[0].full_size_bytes"},
		{"oversize gif thumbnail", PurposePost, []UploadItem{with(g, func(i *UploadItem) { i.ThumbBytes = MaxThumbBytes + 1 })}, "items[0].thumb_size_bytes"},
		{"png is still refused", PurposePost, []UploadItem{with(photo, func(i *UploadItem) { i.ContentType = "image/png" })}, "items[0].content_type"},
		{"photo with an equal thumb type (older clients send none)", PurposePost, []UploadItem{with(photo, func(i *UploadItem) { i.ThumbContentType = ContentTypeJPEG })}, ""},
		{"photo with a different thumb type", PurposePost, []UploadItem{with(photo, func(i *UploadItem) { i.ThumbContentType = ContentTypeWebP })}, "items[0].thumb_content_type"},
		{"photo with a gif thumb type", PurposePost, []UploadItem{with(photo, func(i *UploadItem) { i.ThumbContentType = ContentTypeGIF })}, "items[0].thumb_content_type"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := newEnv(t, envOpts{})
			_, err := e.svc.CreateUpload(context.Background(), uidA, CreateUploadInput{IdempotencyKey: key1, Purpose: tt.purpose, Items: tt.items})
			if tt.field == "" {
				if err != nil {
					t.Fatalf("err = %v", err)
				}
				return
			}
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

func TestGIF_GifMaxEdgeIsConfigurable(t *testing.T) {
	e := newEnv(t, envOpts{})
	e.svc.(*service).GifMaxEdge = 640
	it := gifItem(gifBytes("a"), jpegBytes("b"), ContentTypeJPEG)
	it.Width, it.Height = 800, 600
	_, err := e.svc.CreateUpload(context.Background(), uidA, CreateUploadInput{IdempotencyKey: key1, Purpose: PurposePost, Items: []UploadItem{it}})
	ae := wantAPI(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION)
	if ae.Metadata["field"] != "items[0].width" {
		t.Fatalf("field = %q", ae.Metadata["field"])
	}
}

func TestGIF_CreateUploadSignsEachObjectWithItsOwnType(t *testing.T) {
	for _, tc := range []struct{ thumbType, thumbExt string }{{ContentTypeJPEG, "jpg"}, {ContentTypeWebP, "webp"}} {
		t.Run(tc.thumbType, func(t *testing.T) {
			e := newEnv(t, envOpts{})
			full, thumb := gifBytes("a"), jpegBytes("b")
			in := CreateUploadInput{IdempotencyKey: key1, Purpose: PurposePost, Items: []UploadItem{gifItem(full, thumb, tc.thumbType)}}
			tgs, err := e.svc.CreateUpload(context.Background(), uidA, in)
			if err != nil {
				t.Fatal(err)
			}
			id := tgs[0].MediaID
			if tgs[0].Full.URL != "https://upload.test/u/"+uidA+"/"+id+".gif" || tgs[0].Thumb.URL != "https://upload.test/u/"+uidA+"/"+id+"_t."+tc.thumbExt {
				t.Fatalf("urls = %q / %q", tgs[0].Full.URL, tgs[0].Thumb.URL)
			}
			if tgs[0].Full.Headers["Content-Type"] != ContentTypeGIF || tgs[0].Thumb.Headers["Content-Type"] != tc.thumbType ||
				tgs[0].Full.Headers["x-goog-content-length-range"] != "0,2097152" || tgs[0].Thumb.Headers["x-goog-content-length-range"] != "0,262144" {
				t.Fatalf("headers = %v / %v", tgs[0].Full.Headers, tgs[0].Thumb.Headers)
			}
			d := e.repo.docs[id]
			if d.ContentType != ContentTypeGIF || d.ThumbContentType != tc.thumbType || d.ThumbType() != tc.thumbType ||
				d.UploadPath != "u/"+uidA+"/"+id+".gif" || d.ThumbUploadPath != "u/"+uidA+"/"+id+"_t."+tc.thumbExt {
				t.Fatalf("doc = %+v", d)
			}
			// A replay signs the same objects with the same types (the doc is not rewritten).
			again, err := e.svc.CreateUpload(context.Background(), uidA, in)
			if err != nil || again[0].MediaID != id || again[0].Thumb.URL != tgs[0].Thumb.URL || again[0].Thumb.Headers["Content-Type"] != tc.thumbType {
				t.Fatalf("replay = %+v err=%v", again, err)
			}
		})
	}
}

func TestGIF_PhotoDocKeepsNoThumbType(t *testing.T) {
	for i, tt := range []string{"", ContentTypeJPEG} {
		e := newEnv(t, envOpts{})
		it := item(jpegBytes("a"), jpegBytes("b"), ContentTypeJPEG)
		it.ThumbContentType = tt
		tgs, err := e.svc.CreateUpload(context.Background(), uidA, CreateUploadInput{IdempotencyKey: "key-" + strconv.Itoa(i) + "-0123456789", Purpose: PurposePost, Items: []UploadItem{it}})
		if err != nil {
			t.Fatal(err)
		}
		d := e.repo.docs[tgs[0].MediaID]
		if d.ThumbContentType != "" || d.ThumbType() != ContentTypeJPEG {
			t.Fatalf("thumb type %q: doc = %+v, want absent (= same as the full image)", tt, d)
		}
	}
}

// TestGIF_RequestHashUnchangedForPhotos pins the pre-W6 format: an idempotency record written before the deploy must still
// match a retry across it, and "equal to content_type" hashes like "empty".
func TestGIF_RequestHashUnchangedForPhotos(t *testing.T) {
	it := item(jpegBytes("a"), jpegBytes("b"), ContentTypeJPEG)
	old := idempotency.HashRequest("v1|purpose=POST|image/jpeg," + strconv.FormatInt(it.FullBytes, 10) + "," + strconv.FormatInt(it.ThumbBytes, 10) + ",1200,800," + it.FullMD5 + "," + it.ThumbMD5)
	if got := requestHash(PurposePost, []UploadItem{it}); got != old {
		t.Fatalf("hash changed for a photo: %s vs %s", got, old)
	}
	eq := it
	eq.ThumbContentType = ContentTypeJPEG
	if requestHash(PurposePost, []UploadItem{eq}) != old {
		t.Fatal("thumb type equal to content type must hash like empty")
	}
	g1, g2 := gifItem(gifBytes("a"), jpegBytes("b"), ContentTypeJPEG), gifItem(gifBytes("a"), jpegBytes("b"), ContentTypeWebP)
	if requestHash(PurposePost, []UploadItem{g1}) == requestHash(PurposePost, []UploadItem{g2}) {
		t.Fatal("a different GIF thumbnail type must be a different request")
	}
}

func TestGIF_SniffTable(t *testing.T) {
	tests := []struct {
		name string
		head []byte
		want string
	}{
		{"GIF89a", []byte("GIF89a\x01\x00"), ContentTypeGIF},
		{"GIF87a", []byte("GIF87a\x01\x00"), ContentTypeGIF},
		{"exactly six bytes", []byte("GIF89a"), ContentTypeGIF},
		{"five bytes", []byte("GIF89"), ""},
		{"lower case", []byte("gif89a"), ""},
		{"GIF88a", []byte("GIF88a"), ""},
		{"png", pngBytes("x"), ""},
		{"jpeg", jpegBytes("x"), ContentTypeJPEG},
		{"webp", webpBytes("x"), ContentTypeWebP},
		{"empty", nil, ""},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := sniffImage(tt.head); got != tt.want {
				t.Fatalf("sniffImage = %q, want %q", got, tt.want)
			}
		})
	}
	for ct, want := range map[string]string{ContentTypeGIF: "gif", ContentTypeWebP: "webp", ContentTypeJPEG: "jpg", "": "jpg"} {
		if got := extension(ct); got != want {
			t.Errorf("extension(%q) = %q, want %q", ct, got, want)
		}
	}
}

func TestGIF_FinalizeHappyPath(t *testing.T) {
	for _, tc := range []struct{ thumbType, thumbExt string }{{ContentTypeJPEG, "jpg"}, {ContentTypeWebP, "webp"}} {
		t.Run(tc.thumbType, func(t *testing.T) {
			e := newEnv(t, envOpts{screenThumb: true})
			tg := e.createGIF(t, uidA, "a", tc.thumbType)
			res, err := e.svc.FinalizeUpload(context.Background(), uidA, []FinalizeItem{{MediaID: tg.MediaID}})
			if err != nil {
				t.Fatal(err)
			}
			r, d := res[0], e.repo.docs[tg.MediaID]
			if r.Status != StatusReady || r.Ref == nil {
				t.Fatalf("result = %+v", r)
			}
			wantURL := "https://cdn.test/media/m/" + tg.MediaID + "-" + d.NameSuffix
			if r.Ref.URL != wantURL+".gif" || r.Ref.ThumbURL != wantURL+"_t."+tc.thumbExt || r.Ref.ContentType != ContentTypeGIF {
				t.Fatalf("ref = %+v", r.Ref)
			}
			// The full object is published as image/gif and the thumbnail with its own type.
			if e.obj.public["m/"+tg.MediaID+"-"+d.NameSuffix+".gif"] != ContentTypeGIF ||
				e.obj.public["m/"+tg.MediaID+"-"+d.NameSuffix+"_t."+tc.thumbExt] != tc.thumbType || len(e.obj.public) != 2 {
				t.Fatalf("public = %v", e.obj.public)
			}
			if len(e.obj.upload) != 0 {
				t.Fatalf("private copies not deleted: %v", e.obj.upload)
			}
			// Interim (W6-10 adds the sampled sheet): full by URI plus the thumbnail = 2 units, as for a photo pair.
			if got := e.repo.vision[monthKey(testNow)]; got != 2 {
				t.Fatalf("vision units = %d, want 2", got)
			}
			if RefToProto(*r.Ref).GetContentType() != ContentTypeGIF {
				t.Fatal("content_type must reach the wire")
			}
		})
	}
}

func TestGIF_FinalizeAccepts87a(t *testing.T) {
	e := newEnv(t, envOpts{})
	full, thumb := []byte("GIF87a-body"), jpegBytes("t")
	tgs, err := e.svc.CreateUpload(context.Background(), uidA, CreateUploadInput{IdempotencyKey: key1, Purpose: PurposePost, Items: []UploadItem{gifItem(full, thumb, ContentTypeJPEG)}})
	if err != nil {
		t.Fatal(err)
	}
	e.putGIF(uidA, tgs[0], full, thumb, ContentTypeJPEG)
	res, err := e.svc.FinalizeUpload(context.Background(), uidA, []FinalizeItem{{MediaID: tgs[0].MediaID}})
	if err != nil || res[0].Status != StatusReady {
		t.Fatalf("res = %+v err=%v", res, err)
	}
}

func TestGIF_FinalizeRejections(t *testing.T) {
	tests := []struct {
		name  string
		setup func(e *env, id string)
	}{
		{"declared gif but png bytes", func(e *env, id string) {
			o := uploadObject(uidA, id, "gif")
			f := e.obj.upload[o]
			f.data = pngBytes("x")
			e.obj.upload[o] = f
			e.repo.docs[id].Bytes, e.repo.docs[id].FullMD5 = int64(len(f.data)), md5b64(f.data)
		}},
		{"gif object stored as image/jpeg", func(e *env, id string) {
			o := uploadObject(uidA, id, "gif")
			f := e.obj.upload[o]
			f.contentType = ContentTypeJPEG
			e.obj.upload[o] = f
		}},
		{"thumbnail bytes are a gif, declared jpeg", func(e *env, id string) {
			o := uploadThumbObject(uidA, id, "jpg")
			f := e.obj.upload[o]
			f.data = gifBytes("t")
			e.obj.upload[o] = f
			e.repo.docs[id].ThumbBytes, e.repo.docs[id].ThumbMD5 = int64(len(f.data)), md5b64(f.data)
		}},
		{"thumbnail object typed as the gif", func(e *env, id string) {
			o := uploadThumbObject(uidA, id, "jpg")
			f := e.obj.upload[o]
			f.contentType = ContentTypeGIF
			e.obj.upload[o] = f
		}},
		{"oversize gif", func(e *env, id string) {
			o := uploadObject(uidA, id, "gif")
			f := e.obj.upload[o]
			f.size = MaxFullBytes + 1
			e.obj.upload[o] = f
		}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := newEnv(t, envOpts{})
			tg := e.createGIF(t, uidA, "a", ContentTypeJPEG)
			tt.setup(e, tg.MediaID)
			res, err := e.svc.FinalizeUpload(context.Background(), uidA, []FinalizeItem{{MediaID: tg.MediaID}})
			if err != nil {
				t.Fatal(err)
			}
			if res[0].Status != StatusRejected || res[0].RejectionReason != reasonInvalid {
				t.Fatalf("result = %+v, want REJECTED %q", res[0], reasonInvalid)
			}
			if len(e.mod.calls) != 0 || e.repo.vision[monthKey(testNow)] != 0 {
				t.Fatal("a rejected upload must not spend Vision units")
			}
			if len(e.obj.upload) != 0 || len(e.obj.public) != 0 {
				t.Fatalf("objects left: %v / %v", e.obj.upload, e.obj.public)
			}
		})
	}
}

// TestGIF_AtTheVisionCapIsRejectedForEveryAccount: ADR-0029 F11 point 4. A photo of the same account stays READY_UNSCREENED.
func TestGIF_AtTheVisionCapIsRejectedForEveryAccount(t *testing.T) {
	for _, policy := range []config.VisionExhaustedPolicy{config.VisionPolicyEstablished, config.VisionPolicyReject} {
		for _, age := range []string{"established", "new"} {
			t.Run(string(policy)+"/"+age, func(t *testing.T) {
				opts := envOpts{cap: 10, policy: policy}
				if age == "new" {
					opts.accountAge = 2 * 24 * time.Hour
				}
				e := newEnv(t, opts)
				e.repo.vision[monthKey(testNow)] = 10
				tg := e.createGIF(t, uidA, "a", ContentTypeJPEG)
				res, err := e.svc.FinalizeUpload(context.Background(), uidA, []FinalizeItem{{MediaID: tg.MediaID}})
				if err != nil {
					t.Fatal(err)
				}
				if res[0].Status != StatusRejected || res[0].RejectionReason != reasonCapacity || len(e.mod.calls) != 0 {
					t.Fatalf("result = %+v calls=%v, want REJECTED %q with no Vision call", res[0], e.mod.calls, reasonCapacity)
				}
				if len(e.obj.public) != 0 {
					t.Fatalf("a rejected GIF must publish nothing: %v", e.obj.public)
				}
			})
		}
	}
	e := newEnv(t, envOpts{cap: 10, policy: config.VisionPolicyEstablished})
	e.repo.vision[monthKey(testNow)] = 10
	photo := e.upload(t, uidA, PurposePost, "p")
	res, err := e.svc.FinalizeUpload(context.Background(), uidA, []FinalizeItem{{MediaID: photo.MediaID}})
	if err != nil || res[0].Status != StatusReadyUnscreened {
		t.Fatalf("photo at the cap = %+v err=%v, want READY_UNSCREENED as before", res[0], err)
	}
}

func TestGIF_BlockedVerdictRejects(t *testing.T) {
	e := newEnv(t, envOpts{})
	tg := e.createGIF(t, uidA, "a", ContentTypeJPEG)
	e.mod.by[uploadObject(uidA, tg.MediaID, "gif")] = SafeSearch{Adult: LikelihoodVeryLikely}
	res, err := e.svc.FinalizeUpload(context.Background(), uidA, []FinalizeItem{{MediaID: tg.MediaID}})
	if err != nil || res[0].Status != StatusRejected || res[0].RejectionReason != reasonPolicy {
		t.Fatalf("res = %+v err=%v", res, err)
	}
}

// TestGIF_CleanupNamesUseTheThumbnailsOwnExtension: the lost-race cleanup and the account purge must delete "_t.jpg", not
// the never-written "_t.gif".
func TestGIF_CleanupNamesUseTheThumbnailsOwnExtension(t *testing.T) {
	d := &Doc{ID: "0000000000000000301", ContentType: ContentTypeGIF, ThumbContentType: ContentTypeJPEG, NameSuffix: "abcd"}
	got := strings.Join(publicNames(d), " ")
	if !strings.Contains(got, "m/0000000000000000301-abcd.gif") || !strings.Contains(got, "m/0000000000000000301-abcd_t.jpg") || strings.Contains(got, "_t.gif") {
		t.Fatalf("publicNames = %s", got)
	}
	all := strings.Join(allPublicNames(d), " ")
	if !strings.Contains(all, "m/0000000000000000301.gif") || !strings.Contains(all, "m/0000000000000000301_t.jpg") || strings.Contains(all, "_t.gif") {
		t.Fatalf("allPublicNames = %s", all)
	}
	if photo := (&Doc{ID: "0000000000000000302", ContentType: ContentTypeWebP}); !strings.Contains(strings.Join(publicNames(photo), " "), "_t.webp") {
		t.Fatalf("photo names = %v", publicNames(photo))
	}
}

func TestGIF_ServerFlagModes(t *testing.T) {
	const alice, bob = "uid-alice", "uid-bob"
	mk := func(spec flags.Spec) FlagChecker {
		return flags.NewRegistry(flags.Spec{Name: FlagName, Mode: flags.On}, flags.Spec{Name: ProfileExtrasFlagName, Mode: flags.On}, spec)
	}
	allow := map[string]struct{}{alice: {}}
	tests := []struct {
		name string
		spec flags.Spec
		uid  string
		on   bool
	}{
		{"off", flags.Spec{Name: GifFlagName, Mode: flags.Off}, alice, false},
		{"allowlist, listed", flags.Spec{Name: GifFlagName, Mode: flags.Allowlist, Allowlist: allow}, alice, true},
		{"allowlist, not listed", flags.Spec{Name: GifFlagName, Mode: flags.Allowlist, Allowlist: allow}, bob, false},
		{"percent 0", flags.Spec{Name: GifFlagName, Mode: flags.Percent, Percent: 0}, alice, false},
		{"percent 100", flags.Spec{Name: GifFlagName, Mode: flags.Percent, Percent: 100}, bob, true},
		{"on", flags.Spec{Name: GifFlagName, Mode: flags.On}, bob, true},
	}
	full, thumb := gifBytes("F"), jpegBytes("T")
	req := func(purpose mediav1.MediaPurpose) *connect.Request[mediav1.CreateUploadRequest] {
		return connect.NewRequest(&mediav1.CreateUploadRequest{
			IdempotencyKey: key1, Purpose: purpose,
			Items: []*mediav1.UploadItem{{
				ContentType: ContentTypeGIF, ThumbContentType: ContentTypeJPEG, FullSizeBytes: int64(len(full)), ThumbSizeBytes: int64(len(thumb)),
				Width: 400, Height: 300, FullMd5: md5b64(full), ThumbMd5: md5b64(thumb),
			}},
		})
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := newEnv(t, envOpts{})
			s := NewServer(e.svc, mk(tt.spec))
			resp, err := s.CreateUpload(authedCtx(tt.uid), req(mediav1.MediaPurpose_MEDIA_PURPOSE_POST))
			if !tt.on {
				ae := wantAPI(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED)
				if ae.Metadata["feature"] != "gif" || len(e.repo.docs) != 0 || e.sign.calls != 0 {
					t.Fatalf("feature=%q docs=%d signs=%d: a disabled flag must do no work", ae.Metadata["feature"], len(e.repo.docs), e.sign.calls)
				}
				// The flag is checked before the purpose: an avatar GIF is FEATURE_DISABLED too.
				_, err = s.CreateUpload(authedCtx(tt.uid), req(mediav1.MediaPurpose_MEDIA_PURPOSE_AVATAR))
				_ = wantAPI(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED)
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if d := e.repo.docs[resp.Msg.GetTargets()[0].GetMediaId()]; d == nil || d.ThumbContentType != ContentTypeJPEG {
				t.Fatalf("doc = %+v: thumb_content_type must reach the service", d)
			}
			_, err = s.CreateUpload(authedCtx(tt.uid), req(mediav1.MediaPurpose_MEDIA_PURPOSE_AVATAR))
			ae := wantAPI(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION)
			if ae.Metadata["field"] != "items[0].content_type" {
				t.Fatalf("avatar gif field = %q", ae.Metadata["field"])
			}
		})
	}
	t.Run("a photo never touches the gif flag", func(t *testing.T) {
		e := newEnv(t, envOpts{})
		s := NewServer(e.svc, mk(flags.Spec{Name: GifFlagName, Mode: flags.Off}))
		p, q := jpegBytes("a"), jpegBytes("b")
		_, err := s.CreateUpload(authedCtx(alice), connect.NewRequest(&mediav1.CreateUploadRequest{
			IdempotencyKey: key1, Purpose: mediav1.MediaPurpose_MEDIA_PURPOSE_POST,
			Items: []*mediav1.UploadItem{{ContentType: ContentTypeJPEG, FullSizeBytes: int64(len(p)), ThumbSizeBytes: int64(len(q)), Width: 400, Height: 300, FullMd5: md5b64(p), ThumbMd5: md5b64(q)}},
		}))
		if err != nil {
			t.Fatal(err)
		}
	})
	t.Run("a checker that does not know gif is off", func(t *testing.T) {
		e := newEnv(t, envOpts{})
		s := NewServer(e.svc, fakeFlags{FlagName: true})
		_, err := s.CreateUpload(authedCtx(alice), req(mediav1.MediaPurpose_MEDIA_PURPOSE_POST))
		_ = wantAPI(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED)
	})
}
