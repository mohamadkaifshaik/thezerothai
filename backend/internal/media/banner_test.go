package media

import (
	"bytes"
	"context"
	"encoding/json"
	"strings"
	"testing"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	mediav1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/media/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// bannerItem is a well-formed banner declaration: 1500 x 500 WebP.
func bannerItem(full, thumb []byte) UploadItem {
	it := item(full, thumb, "image/webp")
	it.Width, it.Height = 1500, 500
	return it
}

// bannerUpload runs CreateUpload(BANNER) and the client's two PUTs.
func (e *env) bannerUpload(t *testing.T, uid, tag string) UploadTarget {
	t.Helper()
	full, thumb := webpBytes("F"+tag), webpBytes("T"+tag)
	tgs, err := e.svc.CreateUpload(context.Background(), uid, CreateUploadInput{
		IdempotencyKey: "key-" + tag + "-0123456789", Purpose: PurposeBanner, Items: []UploadItem{bannerItem(full, thumb)},
	})
	if err != nil {
		t.Fatal(err)
	}
	e.put(uid, tgs[0], full, thumb, "image/webp")
	return tgs[0]
}

func TestCreateUpload_BannerValidation(t *testing.T) {
	good := bannerItem(webpBytes("a"), webpBytes("b"))
	with := func(f func(*UploadItem)) UploadItem { i := good; f(&i); return i }
	tests := []struct {
		name  string
		items []UploadItem
		field string // "" = accepted
	}{
		{"1500x500 is the exact shape", []UploadItem{good}, ""},
		{"1470x500 is the 2% lower bound", []UploadItem{with(func(i *UploadItem) { i.Width = 1470 })}, ""},
		{"1469x500 is just under", []UploadItem{with(func(i *UploadItem) { i.Width = 1469 })}, "items[0].width"},
		{"612x200 is the 2% upper bound", []UploadItem{with(func(i *UploadItem) { i.Width, i.Height = 612, 200 })}, ""},
		{"613x200 is just over", []UploadItem{with(func(i *UploadItem) { i.Width, i.Height = 613, 200 })}, "items[0].width"},
		{"1501x500 is wider than 1500", []UploadItem{with(func(i *UploadItem) { i.Width = 1501 })}, "items[0].width"},
		{"1500x501 is taller than 500", []UploadItem{with(func(i *UploadItem) { i.Height = 501 })}, "items[0].width"},
		{"3000x1000 is the right shape but too big", []UploadItem{with(func(i *UploadItem) { i.Width, i.Height = 3000, 1000 })}, "items[0].width"},
		{"a square is not a banner", []UploadItem{with(func(i *UploadItem) { i.Width, i.Height = 500, 500 })}, "items[0].width"},
		{"a post-shaped image is not a banner", []UploadItem{with(func(i *UploadItem) { i.Width, i.Height = 1200, 800 })}, "items[0].width"},
		{"two banners", []UploadItem{good, good}, "items"},
		{"full at the 1 MiB cap", []UploadItem{with(func(i *UploadItem) { i.FullBytes = BannerMaxFullBytes })}, ""},
		{"full over 1 MiB (under the 2 MiB post cap)", []UploadItem{with(func(i *UploadItem) { i.FullBytes = BannerMaxFullBytes + 1 })}, "items[0].full_size_bytes"},
		{"thumb at the 128 KiB cap", []UploadItem{with(func(i *UploadItem) { i.ThumbBytes = BannerMaxThumbBytes })}, ""},
		{"thumb over 128 KiB (under the 256 KiB post cap)", []UploadItem{with(func(i *UploadItem) { i.ThumbBytes = BannerMaxThumbBytes + 1 })}, "items[0].thumb_size_bytes"},
		{"bad content type", []UploadItem{with(func(i *UploadItem) { i.ContentType = "image/png" })}, "items[0].content_type"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := newEnv(t, envOpts{})
			_, err := e.svc.CreateUpload(context.Background(), uidA, CreateUploadInput{IdempotencyKey: key1, Purpose: PurposeBanner, Items: tt.items})
			if tt.field == "" {
				if err != nil {
					t.Fatalf("err = %v, want accepted", err)
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

// The same bytes and shape that a POST accepts are refused for a BANNER, and the POST caps are unchanged.
func TestCreateUpload_BannerCapsDoNotLeakToOtherPurposes(t *testing.T) {
	e := newEnv(t, envOpts{})
	big := item(webpBytes("a"), webpBytes("b"), "image/webp")
	big.FullBytes, big.ThumbBytes = BannerMaxFullBytes+1, BannerMaxThumbBytes+1
	for _, p := range []Purpose{PurposePost, PurposeAvatar} {
		if _, err := e.svc.CreateUpload(context.Background(), uidA, CreateUploadInput{IdempotencyKey: key1 + string(p), Purpose: p, Items: []UploadItem{big}}); err != nil {
			t.Fatalf("%s: %v", p, err)
		}
	}
}

func TestCreateUpload_BannerSignsBannerCapsAndStoresPurposeAndSizes(t *testing.T) {
	e := newEnv(t, envOpts{})
	full, thumb := webpBytes("full-image"), webpBytes("thumb")
	tgs, err := e.svc.CreateUpload(context.Background(), uidA, CreateUploadInput{
		IdempotencyKey: key1, Purpose: PurposeBanner, Items: []UploadItem{bannerItem(full, thumb)},
	})
	if err != nil {
		t.Fatal(err)
	}
	if got := tgs[0].Full.Headers["x-goog-content-length-range"]; got != "0,1048576" {
		t.Fatalf("full range = %q, want 0,1048576", got)
	}
	if got := tgs[0].Thumb.Headers["x-goog-content-length-range"]; got != "0,131072" {
		t.Fatalf("thumb range = %q, want 0,131072", got)
	}
	d := e.repo.docs[tgs[0].MediaID]
	if d.Purpose != string(PurposeBanner) || d.Status != string(StatusPending) || d.Bytes != int64(len(full)) ||
		d.ThumbBytes != int64(len(thumb)) || d.Width != 1500 || d.Height != 500 {
		t.Fatalf("doc = %+v", d)
	}
	// A replay returns the same ids and signs again with the same caps.
	again, err := e.svc.CreateUpload(context.Background(), uidA, CreateUploadInput{
		IdempotencyKey: key1, Purpose: PurposeBanner, Items: []UploadItem{bannerItem(full, thumb)},
	})
	if err != nil || again[0].MediaID != tgs[0].MediaID || again[0].Full.Headers["x-goog-content-length-range"] != "0,1048576" {
		t.Fatalf("replay = %+v, %v", again, err)
	}
	// The same body as an AVATAR is a different request: the purpose is part of the idempotency hash.
	_, err = e.svc.CreateUpload(context.Background(), uidA, CreateUploadInput{
		IdempotencyKey: key1, Purpose: PurposeAvatar, Items: []UploadItem{bannerItem(full, thumb)},
	})
	_ = wantAPI(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_IDEMPOTENCY_KEY_REUSED)
}

func TestFinalize_BannerHappyPathChargesTwoVisionUnits(t *testing.T) {
	// screenThumb is false: a banner screens the thumbnail regardless of VISION_SCREEN_THUMB (ADR-0024 D1).
	e := newEnv(t, envOpts{})
	tg := e.bannerUpload(t, uidA, "a")
	res, err := e.svc.FinalizeUpload(context.Background(), uidA, []FinalizeItem{{MediaID: tg.MediaID, Blurhash: "LEHV6n"}})
	if err != nil {
		t.Fatal(err)
	}
	r := res[0]
	if r.Status != StatusReady || r.Ref == nil || r.Ref.URL != "https://cdn.test/media/m/"+tg.MediaID+".webp" ||
		r.Ref.ThumbURL != "https://cdn.test/media/m/"+tg.MediaID+"_t.webp" || r.Ref.Width != 1500 || r.Ref.Height != 500 {
		t.Fatalf("result = %+v", r)
	}
	if len(e.mod.calls) != 2 {
		t.Fatalf("moderator calls = %v, want full + thumb", e.mod.calls)
	}
	if got := e.repo.vision[monthKey(testNow)]; got != BannerVisionUnits {
		t.Fatalf("vision units = %d, want %d", got, BannerVisionUnits)
	}
	if e.obj.publishes != 2 || len(e.obj.upload) != 0 {
		t.Fatalf("publishes=%d private left=%v", e.obj.publishes, e.obj.upload)
	}
	if d := e.repo.docs[tg.MediaID]; d.Purpose != string(PurposeBanner) || d.Bytes == 0 || d.ThumbBytes == 0 {
		t.Fatalf("doc = %+v", d)
	}
}

func TestFinalize_BannerRacyRule(t *testing.T) {
	tests := []struct {
		name   string
		object func(id string) string
		ss     SafeSearch
		want   Status
	}{
		{"likely racy full", func(id string) string { return uploadObject(uidA, id, "webp") }, SafeSearch{Racy: LikelihoodLikely}, StatusRejected},
		{"very likely racy thumb only", func(id string) string { return uploadThumbObject(uidA, id, "webp") }, SafeSearch{Racy: LikelihoodVeryLikely}, StatusRejected},
		{"possible racy passes", func(id string) string { return uploadObject(uidA, id, "webp") }, SafeSearch{Racy: LikelihoodPossible}, StatusReady},
		{"likely adult", func(id string) string { return uploadObject(uidA, id, "webp") }, SafeSearch{Adult: LikelihoodLikely}, StatusRejected},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := newEnv(t, envOpts{})
			tg := e.bannerUpload(t, uidA, "a")
			e.mod.by[tt.object(tg.MediaID)] = tt.ss
			res, err := e.svc.FinalizeUpload(context.Background(), uidA, []FinalizeItem{{MediaID: tg.MediaID}})
			if err != nil {
				t.Fatal(err)
			}
			if res[0].Status != tt.want {
				t.Fatalf("status = %s, want %s", res[0].Status, tt.want)
			}
			if tt.want == StatusRejected {
				if res[0].RejectionReason != reasonPolicy || res[0].Ref != nil || len(e.obj.public) != 0 {
					t.Fatalf("result = %+v public=%v", res[0], e.obj.public)
				}
				// Both screens were paid for: the counter is the cost meter.
				if got := e.repo.vision[monthKey(testNow)]; got != BannerVisionUnits {
					t.Fatalf("vision units = %d, want %d", got, BannerVisionUnits)
				}
			}
		})
	}
}

// A post image with the same racy score is not blocked (the rule is avatar and banner only).
func TestFinalize_RacyPostImageStillPasses(t *testing.T) {
	if blockedBySafeSearch(SafeSearch{Racy: LikelihoodVeryLikely}, PurposePost) {
		t.Fatal("racy must not block a post image")
	}
	for _, p := range []Purpose{PurposeAvatar, PurposeBanner} {
		if !blockedBySafeSearch(SafeSearch{Racy: LikelihoodLikely}, p) {
			t.Fatalf("racy must block %s", p)
		}
	}
}

func TestFinalize_BannerOverTheStoredSizeIsRejected(t *testing.T) {
	// The verify step uses the banner caps too: an object over 1 MiB that the doc declared (a doc that could not
	// have been created through CreateUpload) is refused, defence in depth.
	e := newEnv(t, envOpts{})
	tg := e.bannerUpload(t, uidA, "a")
	o := uploadObject(uidA, tg.MediaID, "webp")
	f := e.obj.upload[o]
	f.size = BannerMaxFullBytes + 1
	e.obj.upload[o] = f
	e.repo.docs[tg.MediaID].Bytes = BannerMaxFullBytes + 1
	res, err := e.svc.FinalizeUpload(context.Background(), uidA, []FinalizeItem{{MediaID: tg.MediaID}})
	if err != nil || res[0].Status != StatusRejected || res[0].RejectionReason != reasonInvalid || len(e.mod.calls) != 0 {
		t.Fatalf("res = %+v err=%v calls=%v", res, err, e.mod.calls)
	}
}

func TestFinalize_BannerAtTheVisionCap(t *testing.T) {
	tests := []struct {
		name   string
		used   int64
		policy config.VisionExhaustedPolicy
		want   Status
		calls  int
		spent  int64
	}{
		{"two units left: screened", 8, config.VisionPolicyEstablished, StatusReady, 2, 10},
		{"one unit left is not enough for a banner: established account publishes unscreened", 9, config.VisionPolicyEstablished, StatusReadyUnscreened, 0, 9},
		{"at the cap with reject policy", 10, config.VisionPolicyReject, StatusRejected, 0, 10},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := newEnv(t, envOpts{cap: 10, policy: tt.policy})
			e.repo.vision[monthKey(testNow)] = tt.used
			tg := e.bannerUpload(t, uidA, "a")
			res, err := e.svc.FinalizeUpload(context.Background(), uidA, []FinalizeItem{{MediaID: tg.MediaID}})
			if err != nil || res[0].Status != tt.want {
				t.Fatalf("res = %+v err=%v, want %s", res, err, tt.want)
			}
			if len(e.mod.calls) != tt.calls || e.repo.vision[monthKey(testNow)] != tt.spent {
				t.Fatalf("calls=%d counter=%d, want %d / %d", len(e.mod.calls), e.repo.vision[monthKey(testNow)], tt.calls, tt.spent)
			}
		})
	}
}

// bannerReq is a CreateUpload request for a good banner.
func bannerReq(key string) *mediav1.CreateUploadRequest {
	full, thumb := webpBytes("F"), webpBytes("T")
	return &mediav1.CreateUploadRequest{
		IdempotencyKey: key, Purpose: mediav1.MediaPurpose_MEDIA_PURPOSE_BANNER,
		Items: []*mediav1.UploadItem{{
			ContentType: "image/webp", FullSizeBytes: int64(len(full)), ThumbSizeBytes: int64(len(thumb)), Width: 1500, Height: 500,
			FullMd5: md5b64(full), ThumbMd5: md5b64(thumb),
		}},
	}
}

// Flag-mode matrix for CreateUpload(BANNER): media on is not enough, profile_extras must be on for the caller.
func TestServer_BannerNeedsProfileExtrasForTheCaller(t *testing.T) {
	registry := func(extras flags.Spec) FlagChecker {
		return flags.NewRegistry(flags.Spec{Name: FlagName, Mode: flags.On}, extras)
	}
	allow := func(uids ...string) map[string]struct{} {
		m := map[string]struct{}{}
		for _, u := range uids {
			m[u] = struct{}{}
		}
		return m
	}
	tests := []struct {
		name    string
		fc      FlagChecker
		uid     string
		allowed bool
	}{
		{"nil checker", nil, uidA, false},
		{"profile_extras off", registry(flags.Spec{Name: ProfileExtrasFlagName, Mode: flags.Off}), uidA, false},
		{"profile_extras unregistered", flags.NewRegistry(flags.Spec{Name: FlagName, Mode: flags.On}), uidA, false},
		{"allowlist, caller outside it", registry(flags.Spec{Name: ProfileExtrasFlagName, Mode: flags.Allowlist, Allowlist: allow(uidB)}), uidA, false},
		{"allowlist, caller inside it", registry(flags.Spec{Name: ProfileExtrasFlagName, Mode: flags.Allowlist, Allowlist: allow(uidA)}), uidA, true},
		{"percent 0", registry(flags.Spec{Name: ProfileExtrasFlagName, Mode: flags.Percent, Percent: 0}), uidA, false},
		{"percent 100", registry(flags.Spec{Name: ProfileExtrasFlagName, Mode: flags.Percent, Percent: 100}), uidA, true},
		{"on", registry(flags.Spec{Name: ProfileExtrasFlagName, Mode: flags.On}), uidA, true},
		{"media off beats profile_extras on", flags.NewRegistry(flags.Spec{Name: FlagName, Mode: flags.Off}, flags.Spec{Name: ProfileExtrasFlagName, Mode: flags.On}), uidA, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := newEnv(t, envOpts{})
			s := NewServer(e.svc, tt.fc)
			_, err := s.CreateUpload(authedCtx(tt.uid), connect.NewRequest(bannerReq(key1)))
			if tt.allowed {
				if err != nil {
					t.Fatalf("err = %v", err)
				}
				return
			}
			ae := wantAPI(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED)
			if tt.fc == nil || strings.HasPrefix(tt.name, "media off") {
				if ae.Metadata["feature"] != "" {
					t.Fatalf("a media-level answer (no checker, media off) names no sub-feature, got %q", ae.Metadata["feature"])
				}
			} else if ae.Metadata["feature"] != ProfileExtrasFlagName {
				t.Fatalf("feature = %q, want %q", ae.Metadata["feature"], ProfileExtrasFlagName)
			}
			if len(e.repo.docs) != 0 || e.sign.calls != 0 || e.repo.quota != 0 {
				t.Fatal("a disabled flag must do no work: 0 reads, 0 writes, nothing signed")
			}
		})
	}
}

// profile_extras gates the BANNER purpose only: an avatar or a post image upload works with it off.
func TestServer_ProfileExtrasDoesNotGateOtherPurposes(t *testing.T) {
	e := newEnv(t, envOpts{})
	s := NewServer(e.svc, fakeFlags{FlagName: true, ProfileExtrasFlagName: false})
	full, thumb := jpegBytes("F"), jpegBytes("T")
	for _, p := range []mediav1.MediaPurpose{mediav1.MediaPurpose_MEDIA_PURPOSE_POST, mediav1.MediaPurpose_MEDIA_PURPOSE_AVATAR} {
		_, err := s.CreateUpload(authedCtx(uidA), connect.NewRequest(&mediav1.CreateUploadRequest{
			IdempotencyKey: key1 + p.String(), Purpose: p,
			Items: []*mediav1.UploadItem{{
				ContentType: "image/jpeg", FullSizeBytes: int64(len(full)), ThumbSizeBytes: int64(len(thumb)), Width: 400, Height: 400,
				FullMd5: md5b64(full), ThumbMd5: md5b64(thumb),
			}},
		}))
		if err != nil {
			t.Fatalf("%s: %v", p, err)
		}
	}
}

func TestServer_BannerEndToEnd(t *testing.T) {
	e := newEnv(t, envOpts{})
	s := NewServer(e.svc, fakeFlags{FlagName: true, ProfileExtrasFlagName: true})
	resp, err := s.CreateUpload(authedCtx(uidA), connect.NewRequest(bannerReq(key1)))
	if err != nil {
		t.Fatal(err)
	}
	tg := resp.Msg.GetTargets()[0]
	if e.repo.docs[tg.GetMediaId()].Purpose != string(PurposeBanner) || tg.GetFull().GetHeaders()["x-goog-content-length-range"] != "0,1048576" {
		t.Fatalf("doc=%+v target=%v", e.repo.docs[tg.GetMediaId()], tg)
	}
	e.put(uidA, UploadTarget{MediaID: tg.GetMediaId()}, webpBytes("F"), webpBytes("T"), "image/webp")
	// Finalize is not flag-gated on profile_extras: an upload started before the flag was lowered can complete.
	s = NewServer(e.svc, fakeFlags{FlagName: true})
	fin, err := s.FinalizeUpload(authedCtx(uidA), connect.NewRequest(&mediav1.FinalizeUploadRequest{
		IdempotencyKey: key2, Items: []*mediav1.FinalizeItem{{MediaId: tg.GetMediaId()}},
	}))
	if err != nil {
		t.Fatal(err)
	}
	if r := fin.Msg.GetResults()[0]; r.GetStatus() != mediav1.MediaStatus_MEDIA_STATUS_READY || r.GetMedia().GetWidth() != 1500 {
		t.Fatalf("result = %v", r)
	}
}

func TestFinalizePurpose(t *testing.T) {
	docs := map[string]*Doc{
		"1": {Purpose: "BANNER"}, "2": {Purpose: "BANNER"}, "3": {Purpose: "POST"},
	}
	tests := []struct {
		ids  []string
		want string
	}{
		{[]string{"1"}, "BANNER"},
		{[]string{"1", "2"}, "BANNER"},
		{[]string{"1", "3"}, "MIXED"},
		{nil, ""},
	}
	for _, tt := range tests {
		if got := finalizePurpose(docs, tt.ids); got != tt.want {
			t.Errorf("finalizePurpose(%v) = %q, want %q", tt.ids, got, tt.want)
		}
	}
}

// Right to delete and to access (rule 10, ADR-0024 D11): the media eraser and export are purpose-agnostic, so a
// BANNER (published, with objects) is erased with the account and listed in the export. Replaced banners are
// never deleted before that (Option 5A), so two BANNER docs of one user both go.
func TestPurgeAndExport_CoverBannerDocuments(t *testing.T) {
	r, o := newFakeRepo(), newFakeObjects()
	idOld, idNew, idBob := "0000000000000008101", "0000000000000008102", "0000000000000008103"
	for _, id := range []string{idOld, idNew} {
		pub, thumb := publicObject(id, "webp"), publicThumbObject(id, "webp")
		r.docs[id] = &Doc{
			ID: id, OwnerID: uidA, Purpose: string(PurposeBanner), Status: string(StatusReady), ContentType: "image/webp",
			Width: 1500, Height: 500, PublicPath: pub, ThumbPath: thumb,
			UploadPath: uploadObject(uidA, id, "webp"), ThumbUploadPath: uploadThumbObject(uidA, id, "webp"), CreatedAt: testNow,
		}
		o.public[pub], o.public[thumb] = "image/webp", "image/webp"
	}
	r.docs[idBob] = &Doc{ID: idBob, OwnerID: uidB, Purpose: string(PurposeBanner), Status: string(StatusReady), ContentType: "image/webp",
		PublicPath: publicObject(idBob, "webp"), ThumbPath: publicThumbObject(idBob, "webp"), CreatedAt: testNow}
	o.public[publicObject(idBob, "webp")], o.public[publicThumbObject(idBob, "webp")] = "image/webp", "image/webp"

	p := NewPurger(r, o, "https://cdn.test/media")
	var buf bytes.Buffer
	if err := p.WriteSection(context.Background(), uidA, &buf); err != nil {
		t.Fatal(err)
	}
	var out struct {
		Media []map[string]any `json:"media"`
	}
	if err := json.Unmarshal(buf.Bytes(), &out); err != nil {
		t.Fatalf("export is not valid JSON: %v\n%s", err, buf.String())
	}
	if len(out.Media) != 2 {
		t.Fatalf("export lists %d media, want both banners: %s", len(out.Media), buf.String())
	}
	for _, m := range out.Media {
		if m["purpose"] != "BANNER" || m["width"] != float64(1500) || !strings.HasPrefix(m["url"].(string), "https://cdn.test/media/m/") {
			t.Fatalf("exported banner = %v", m)
		}
	}
	if strings.Contains(buf.String(), idBob) {
		t.Fatal("the export must not list another user's banner")
	}

	_, done, err := p.PurgeUser(context.Background(), uidA, Checkpoint{})
	if err != nil || !done {
		t.Fatalf("done=%v err=%v", done, err)
	}
	if len(r.docs) != 1 || r.docs[idBob] == nil {
		t.Fatalf("docs left = %v: only Bob's banner may remain", r.docs)
	}
	if len(o.public) != 2 || o.public[publicObject(idBob, "webp")] == "" {
		t.Fatalf("public objects left = %v: only Bob's two may remain", o.public)
	}
}
