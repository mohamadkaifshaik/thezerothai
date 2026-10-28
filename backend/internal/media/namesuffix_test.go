package media

import (
	"context"
	"regexp"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
)

// W3-39 (W3-36 M-2): new uploads publish under unguessable names, old documents keep theirs.

const (
	sfxA = "0123456789abcdef0123456789abcdef"
	sfxB = "fedcba9876543210fedcba9876543210"
	idN1 = "0000000000000000801"
)

func TestNewNameSuffix_FormatAndUniqueness(t *testing.T) {
	t.Parallel()
	hex32 := regexp.MustCompile(`^[0-9a-f]{32}$`)
	seen := map[string]bool{}
	for i := 0; i < 1000; i++ {
		s, err := newNameSuffix()
		if err != nil {
			t.Fatal(err)
		}
		if !hex32.MatchString(s) || strings.ContainsAny(s, "_-") {
			t.Fatalf("suffix %q is not 32 lowercase hex characters", s)
		}
		if seen[s] {
			t.Fatalf("suffix %q was issued twice in 1,000 draws", s)
		}
		seen[s] = true
	}
}

func TestPublicObjectShapes(t *testing.T) {
	t.Parallel()
	tests := []struct {
		suffix, ext, full, thumb string
	}{
		{"", "jpg", "m/" + idN1 + ".jpg", "m/" + idN1 + "_t.jpg"},
		{sfxA, "webp", "m/" + idN1 + "-" + sfxA + ".webp", "m/" + idN1 + "-" + sfxA + "_t.webp"},
	}
	for _, tt := range tests {
		if got := publicObject(idN1, tt.suffix, tt.ext); got != tt.full {
			t.Errorf("publicObject = %q, want %q", got, tt.full)
		}
		if got := publicThumbObject(idN1, tt.suffix, tt.ext); got != tt.thumb {
			t.Errorf("publicThumbObject = %q, want %q", got, tt.thumb)
		}
		// What media writes, media parses back, with the same suffix on both objects.
		f, ok1 := ParseObjectName(tt.full)
		th, ok2 := ParseObjectName(tt.thumb)
		if !ok1 || !ok2 || f.Suffix != tt.suffix || th.Suffix != tt.suffix || f.Thumb || !th.Thumb || f.ID != idN1 {
			t.Errorf("round trip failed: %+v %+v", f, th)
		}
	}
}

func TestParseObjectName_Suffixed(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name string
		in   string
		want ImageObject
		ok   bool
	}{
		{"new full webp", "m/" + idN1 + "-" + sfxA + ".webp", ImageObject{Name: "m/" + idN1 + "-" + sfxA + ".webp", ID: idN1, Suffix: sfxA, Ext: "webp"}, true},
		{"new thumb jpg", "m/" + idN1 + "-" + sfxA + "_t.jpg", ImageObject{Name: "m/" + idN1 + "-" + sfxA + "_t.jpg", ID: idN1, Suffix: sfxA, Ext: "jpg", Thumb: true}, true},
		{"old full", "m/" + idN1 + ".jpg", ImageObject{Name: "m/" + idN1 + ".jpg", ID: idN1, Ext: "jpg"}, true},
		{"old thumb", "m/" + idN1 + "_t.webp", ImageObject{Name: "m/" + idN1 + "_t.webp", ID: idN1, Ext: "webp", Thumb: true}, true},
		{"upper-case hex", "m/" + idN1 + "-" + strings.ToUpper(sfxA) + ".jpg", ImageObject{}, false},
		{"31 hex", "m/" + idN1 + "-" + sfxA[:31] + ".jpg", ImageObject{}, false},
		{"33 hex", "m/" + idN1 + "-" + sfxA + "a.jpg", ImageObject{}, false},
		{"underscore inside", "m/" + idN1 + "-" + sfxA[:10] + "_" + sfxA[11:] + ".jpg", ImageObject{}, false},
		{"dash inside", "m/" + idN1 + "-" + sfxA[:10] + "-" + sfxA[11:] + ".jpg", ImageObject{}, false},
		{"non-hex", "m/" + idN1 + "-" + strings.Repeat("g", 32) + ".jpg", ImageObject{}, false},
		{"empty suffix", "m/" + idN1 + "-.jpg", ImageObject{}, false},
		{"suffix on a short id", "m/123-" + sfxA + ".jpg", ImageObject{}, false},
		{"thumb marker before suffix", "m/" + idN1 + "_t-" + sfxA + ".jpg", ImageObject{}, false},
		{"double thumb", "m/" + idN1 + "-" + sfxA + "_t_t.jpg", ImageObject{}, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			got, ok := ParseObjectName(tt.in)
			if ok != tt.ok || got != tt.want {
				t.Errorf("ParseObjectName(%q) = %+v, %v; want %+v, %v", tt.in, got, ok, tt.want, tt.ok)
			}
		})
	}
}

func TestParseRetiredImage_Suffixes(t *testing.T) {
	t.Parallel()
	base := retireBase + "/m/" + idN1
	tests := []struct {
		name        string
		full, thumb string
		ok          bool
	}{
		{"matching suffixes", base + "-" + sfxA + ".webp", base + "-" + sfxA + "_t.webp", true},
		{"full only", base + "-" + sfxA + ".webp", "", true},
		{"old pair", base + ".webp", base + "_t.webp", true},
		{"different suffixes", base + "-" + sfxA + ".webp", base + "-" + sfxB + "_t.webp", false},
		{"suffixed full, old thumb", base + "-" + sfxA + ".webp", base + "_t.webp", false},
		{"old full, suffixed thumb", base + ".webp", base + "-" + sfxA + "_t.webp", false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			id, ok := parseRetiredImage(tt.full, tt.thumb)
			if ok != tt.ok || (ok && id != idN1) {
				t.Errorf("parseRetiredImage = %q, %v; want ok=%v", id, ok, tt.ok)
			}
		})
	}
}

// Every purpose gets a suffix at CreateUpload, stored on the PENDING document; finalize publishes and records the
// suffixed names that the URLs carry, and a second finalize is the idempotent answer.
func TestCreateUpload_StoresASuffixAndFinalizePublishesIt(t *testing.T) {
	hex32 := regexp.MustCompile(`^[0-9a-f]{32}$`)
	for _, purpose := range []Purpose{PurposePost, PurposeAvatar, PurposeBanner} {
		t.Run(string(purpose), func(t *testing.T) {
			e := newEnv(t, envOpts{})
			var tg UploadTarget
			if purpose == PurposeBanner {
				tg = e.bannerUpload(t, uidA, "a")
			} else {
				tg = e.upload(t, uidA, purpose, "a")
			}
			d := e.repo.docs[tg.MediaID]
			if !hex32.MatchString(d.NameSuffix) {
				t.Fatalf("NameSuffix = %q", d.NameSuffix)
			}
			if strings.Contains(d.UploadPath, d.NameSuffix) || strings.Contains(d.ThumbUploadPath, d.NameSuffix) {
				t.Fatal("the private upload names must not carry the suffix")
			}
			suffix := d.NameSuffix
			fin := []FinalizeItem{{MediaID: tg.MediaID, Blurhash: "LEHV6nWB2yk8pyo0adR*.7kCMdnj"}}
			res, err := e.svc.FinalizeUpload(context.Background(), uidA, fin)
			if err != nil || res[0].Status != StatusReady || res[0].Ref == nil {
				t.Fatalf("finalize = %+v, %v", res, err)
			}
			ext := extension(d.ContentType)
			wantFull, wantThumb := "m/"+tg.MediaID+"-"+suffix+"."+ext, "m/"+tg.MediaID+"-"+suffix+"_t."+ext
			d = e.repo.docs[tg.MediaID]
			if d.PublicPath != wantFull || d.ThumbPath != wantThumb || d.NameSuffix != suffix {
				t.Fatalf("doc paths = %q %q suffix %q, want %q %q %q", d.PublicPath, d.ThumbPath, d.NameSuffix, wantFull, wantThumb, suffix)
			}
			if res[0].Ref.URL != "https://cdn.test/media/"+wantFull || res[0].Ref.ThumbURL != "https://cdn.test/media/"+wantThumb {
				t.Fatalf("ref = %+v", res[0].Ref)
			}
			if len(e.obj.public) != 2 || e.obj.public[wantFull] == "" || e.obj.public[wantThumb] == "" {
				t.Fatalf("public objects = %v", e.obj.public)
			}
			again, err := e.svc.FinalizeUpload(context.Background(), uidA, fin)
			if err != nil || again[0].Ref == nil || *again[0].Ref != *res[0].Ref {
				t.Fatalf("second finalize = %+v, %v", again, err)
			}
		})
	}
}

func TestCreateUpload_ReplayKeepsTheFirstSuffixAndTwoImagesDiffer(t *testing.T) {
	e := newEnv(t, envOpts{})
	in := CreateUploadInput{IdempotencyKey: "key-replay-0123456789", Purpose: PurposePost, Items: []UploadItem{
		item(jpegBytes("F1"), jpegBytes("T1"), "image/jpeg"), item(jpegBytes("F2"), jpegBytes("T2"), "image/jpeg"),
	}}
	first, err := e.svc.CreateUpload(context.Background(), uidA, in)
	if err != nil {
		t.Fatal(err)
	}
	a, b := e.repo.docs[first[0].MediaID].NameSuffix, e.repo.docs[first[1].MediaID].NameSuffix
	if a == "" || b == "" || a == b {
		t.Fatalf("suffixes %q %q: want two distinct non-empty values", a, b)
	}
	second, err := e.svc.CreateUpload(context.Background(), uidA, in)
	if err != nil || second[0].MediaID != first[0].MediaID || second[1].MediaID != first[1].MediaID {
		t.Fatalf("replay = %+v, %v", second, err)
	}
	if e.repo.docs[first[0].MediaID].NameSuffix != a || e.repo.docs[first[1].MediaID].NameSuffix != b || len(e.repo.docs) != 2 {
		t.Fatal("a replay must not change a stored suffix or create documents")
	}
}

// Concurrent finalizes of one document publish one pair of names.
func TestFinalize_ConcurrentCallsPublishOneSuffixedPair(t *testing.T) {
	e := newEnv(t, envOpts{})
	tg := e.upload(t, uidA, PurposePost, "a")
	suffix := e.repo.docs[tg.MediaID].NameSuffix
	out, _ := raceFinalize(t, e, e.repo, uidA, tg.MediaID, 2, 6, true)
	checkRaceOutcomes(t, out)
	want := []string{"m/" + tg.MediaID + "-" + suffix + ".jpg", "m/" + tg.MediaID + "-" + suffix + "_t.jpg"}
	var got []string
	for n := range e.obj.public {
		got = append(got, n)
	}
	sort.Strings(got)
	if len(got) != 2 || got[0] != want[0] || got[1] != want[1] {
		t.Fatalf("public objects = %v, want %v", got, want)
	}
}

// A document without nameSuffix (created by the pre-W3-39 code path) finalizes under the old names, and its erase
// works on them.
func TestOldDocumentWithoutSuffixStillWorksEndToEnd(t *testing.T) {
	e := newEnv(t, envOpts{})
	tg := e.upload(t, uidA, PurposePost, "a")
	e.repo.docs[tg.MediaID].NameSuffix = "" // as the old code path would have written it
	res, err := e.svc.FinalizeUpload(context.Background(), uidA, []FinalizeItem{{MediaID: tg.MediaID, Blurhash: "LEHV6nWB2yk8pyo0adR*.7kCMdnj"}})
	if err != nil || res[0].Ref == nil {
		t.Fatalf("finalize = %+v, %v", res, err)
	}
	if res[0].Ref.URL != "https://cdn.test/media/m/"+tg.MediaID+".jpg" || res[0].Ref.ThumbURL != "https://cdn.test/media/m/"+tg.MediaID+"_t.jpg" {
		t.Fatalf("ref = %+v: an old document keeps the old names", res[0].Ref)
	}
	if _, ok := e.obj.public["m/"+tg.MediaID+".jpg"]; !ok || len(e.obj.public) != 2 {
		t.Fatalf("public = %v", e.obj.public)
	}
	if got := allPublicNames(e.repo.docs[tg.MediaID]); len(got) != 2 {
		t.Fatalf("allPublicNames of an old document = %v, want only the old pair", got)
	}
	if _, done, err := NewPurger(e.repo, e.obj, "").PurgeUser(context.Background(), uidA, Checkpoint{}); err != nil || !done {
		t.Fatalf("purge done=%v err=%v", done, err)
	}
	if len(e.obj.public) != 0 || len(e.repo.docs) != 0 {
		t.Fatalf("after purge public=%v docs=%d", e.obj.public, len(e.repo.docs))
	}
}

// seedSuffixed seeds a published document (and its objects) under the suffixed names.
func seedSuffixed(r *fakeRepo, o *fakeObjects, id, owner string, purpose Purpose, postID string) {
	pub, thumb := publicObject(id, sfxA, "webp"), publicThumbObject(id, sfxA, "webp")
	r.docs[id] = &Doc{
		ID: id, OwnerID: owner, Purpose: string(purpose), Status: string(StatusReady), ContentType: "image/webp",
		NameSuffix: sfxA, PublicPath: pub, ThumbPath: thumb, PostID: postID, UpdateTime: time.Unix(5, 0),
	}
	o.public[pub], o.public[thumb] = "image/webp", "image/webp"
}

func TestDeleteBothShapes(t *testing.T) {
	id := idN1
	oldPair := []string{publicObject(id, "", "webp"), publicThumbObject(id, "", "webp")}
	newPair := []string{publicObject(id, sfxA, "webp"), publicThumbObject(id, sfxA, "webp")}
	swapToOld := func(r *fakeRepo, o *fakeObjects) {
		for _, n := range newPair {
			delete(o.public, n)
		}
		for _, n := range oldPair {
			o.public[n] = "image/webp"
		}
	}
	tests := []struct {
		name  string
		setup func(r *fakeRepo, o *fakeObjects)
	}{
		{"suffixed, recorded", func(r *fakeRepo, o *fakeObjects) { seedSuffixed(r, o, id, uidA, PurposePost, postP) }},
		{"suffixed, copied then lost the record race", func(r *fakeRepo, o *fakeObjects) {
			seedSuffixed(r, o, id, uidA, PurposePost, postP)
			r.docs[id].PublicPath, r.docs[id].ThumbPath = "", ""
		}},
		{"suffixed doc finalized by an older revision, record lost", func(r *fakeRepo, o *fakeObjects) {
			seedSuffixed(r, o, id, uidA, PurposePost, postP)
			r.docs[id].PublicPath, r.docs[id].ThumbPath = "", ""
			swapToOld(r, o)
		}},
		{"both pairs exist", func(r *fakeRepo, o *fakeObjects) {
			seedSuffixed(r, o, id, uidA, PurposePost, postP)
			for _, n := range oldPair {
				o.public[n] = "image/webp"
			}
		}},
		{"old document", func(r *fakeRepo, o *fakeObjects) {
			seedSuffixed(r, o, id, uidA, PurposePost, postP)
			d := r.docs[id]
			d.NameSuffix, d.PublicPath, d.ThumbPath = "", oldPair[0], oldPair[1]
			swapToOld(r, o)
		}},
	}
	for _, tt := range tests {
		t.Run("eraser/"+tt.name, func(t *testing.T) {
			r, o := newFakeRepo(), newFakeObjects()
			tt.setup(r, o)
			o.public["m/unrelated.jpg"] = "image/jpeg"
			if _, done, err := NewPurger(r, o, "").PurgeUser(context.Background(), uidA, Checkpoint{}); err != nil || !done {
				t.Fatalf("done=%v err=%v", done, err)
			}
			if len(o.public) != 1 || len(r.docs) != 0 {
				t.Fatalf("public=%v docs=%d: no object of either shape may remain", o.public, len(r.docs))
			}
		})
		t.Run("post_delete/"+tt.name, func(t *testing.T) {
			r, o := newFakeRepo(), newFakeObjects()
			tt.setup(r, o)
			o.public["m/unrelated.jpg"] = "image/jpeg"
			j := NewJobs(r, o, fakePosts{}, &fakePublisher{})
			got, err := j.Handle(context.Background(), msg(t, PostDeleteMessage{UID: uidA, PostID: postP, MediaIDs: []string{id}}))
			if err != nil || got != "done" {
				t.Fatalf("Handle = %q, %v", got, err)
			}
			if len(o.public) != 1 || len(r.docs) != 0 {
				t.Fatalf("public=%v docs=%d: no object of either shape may remain", o.public, len(r.docs))
			}
		})
	}
}

// The retire step retires a replaced suffixed avatar and banner: exactly 2 customTime calls per image, on the
// document's own names.
func TestRetire_SuffixedAvatarAndBanner(t *testing.T) {
	for _, purpose := range []Purpose{PurposeAvatar, PurposeBanner} {
		t.Run(string(purpose), func(t *testing.T) {
			e := newRetireEnv(config.ProfileMediaRetireAll)
			seedSuffixed(e.repo, e.obj, idAvatarOld, uidA, purpose, "")
			e.users.urls[uidA] = nil
			full, thumb := retireBase+"/"+publicObject(idAvatarOld, sfxA, "webp"), retireBase+"/"+publicThumbObject(idAvatarOld, sfxA, "webp")
			at := retireNow.Add(-time.Hour)
			m := RetireMessage{Kind: JobKindProfileMediaRetired, UID: uidA, Purpose: string(purpose), OldURL: full, OldThumbURL: thumb, ChangedAt: at}
			got, err := e.jobs.Retire(context.Background(), m)
			if err != nil || got != "retired" {
				t.Fatalf("Retire = %q, %v", got, err)
			}
			want := []taggedObject{{publicObject(idAvatarOld, sfxA, "webp"), at}, {publicThumbObject(idAvatarOld, sfxA, "webp"), at}}
			if len(e.tagger.calls) != 2 || e.tagger.calls[0] != want[0] || e.tagger.calls[1] != want[1] {
				t.Fatalf("tagged = %v, want %v", e.tagger.calls, want)
			}
			if e.repo.docs[idAvatarOld].RetiredAt == nil {
				t.Fatal("document not marked retired")
			}
			// A message whose thumbnail carries another suffix is unparseable and touches nothing.
			e2 := newRetireEnv(config.ProfileMediaRetireAll)
			seedSuffixed(e2.repo, e2.obj, idAvatarOld, uidA, purpose, "")
			e2.users.urls[uidA] = nil
			m.OldThumbURL = retireBase + "/" + publicThumbObject(idAvatarOld, sfxB, "webp")
			if got, err := e2.jobs.Retire(context.Background(), m); err != nil || got == "retired" || len(e2.tagger.calls) != 0 {
				t.Fatalf("mismatched thumbnail suffix: Retire = %q, %v, tagged %v", got, err, e2.tagger.calls)
			}
		})
	}
}

// opsctl clear-profile-fields reads names only through ObjectNameFromURL: a suffixed URL yields its suffixed name
// untouched, and ParseImageURL accepts it (W3-39: opsctl needs no change).
func TestObjectNameFromURL_Suffixed(t *testing.T) {
	t.Parallel()
	for _, base := range []string{retireBucket, "https://cdn.example.com", retireBase} {
		for _, name := range []string{"m/" + idN1 + "-" + sfxA + ".webp", "m/" + idN1 + "-" + sfxA + "_t.jpg"} {
			if got := ObjectNameFromURL(base + "/" + name); got != name {
				t.Errorf("ObjectNameFromURL(%q) = %q, want %q", base+"/"+name, got, name)
			}
			if o, ok := ParseImageURL(base + "/" + name); !ok || o.Name != name || o.Suffix != sfxA || o.ID != idN1 {
				t.Errorf("ParseImageURL(%q) = %+v, %v", base+"/"+name, o, ok)
			}
		}
	}
}
