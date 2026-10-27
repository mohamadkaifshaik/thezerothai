package media

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
)

// ADR-0024 Amendment 1 A4: the profile_media_retired job over fakes. The Firestore side (the LastUpdateTime
// precondition, the field-level Update, 2 reads and 1 write) is in retire_integration_test.go.

const (
	idAvatarOld  = "0000000000000000701"
	idBannerOld  = "0000000000000000702"
	idAvatarNew  = "0000000000000000703"
	idBannerNew  = "0000000000000000704"
	retireBase   = "https://cdn.test/media"
	retireBucket = "https://storage.googleapis.com/proj-media"
)

var retireNow = time.Date(2026, 10, 27, 12, 0, 0, 0, time.UTC)

// imgURLs are the full and thumbnail URLs of a media id, as UpdateProfile stores them.
func imgURLs(id, ext string) (full, thumb string) {
	return retireBase + "/m/" + id + "." + ext, retireBase + "/m/" + id + "_t." + ext
}

func seedProfileImage(r *fakeRepo, o *fakeObjects, id, owner string, purpose Purpose, ext string) {
	ct := "image/webp"
	if ext == "jpg" {
		ct = "image/jpeg"
	}
	r.docs[id] = &Doc{
		ID: id, OwnerID: owner, Purpose: string(purpose), Status: string(StatusReady), ContentType: ct,
		PublicPath: "m/" + id + "." + ext, ThumbPath: "m/" + id + "_t." + ext, UpdateTime: time.Unix(5, 0),
	}
	o.public["m/"+id+"."+ext] = ct
	o.public["m/"+id+"_t."+ext] = ct
}

type retireEnv struct {
	repo   *fakeRepo
	obj    *fakeObjects
	tagger *fakeTagger
	users  *fakeProfileImages
	pub    *fakePublisher
	jobs   *Jobs
}

func newRetireEnv(mode config.ProfileMediaRetire) *retireEnv {
	e := &retireEnv{repo: newFakeRepo(), obj: newFakeObjects(), tagger: &fakeTagger{}, users: &fakeProfileImages{urls: map[string][]string{}}, pub: &fakePublisher{}}
	e.jobs = NewJobs(e.repo, e.obj, fakePosts{}, e.pub).WithProfileRetire(RetireDeps{
		Mode: mode, Users: e.users, Tagger: e.tagger, Now: func() time.Time { return retireNow },
	})
	return e
}

// setCurrent sets what the fresh users/{uid} read reports: the avatar and banner URLs the profile shows now.
func (e *retireEnv) setCurrent(uid string, ids ...string) {
	var urls []string
	for _, id := range ids {
		f, th := imgURLs(id, "webp")
		urls = append(urls, f, th)
	}
	e.users.urls[uid] = urls
}

func retireMsg(uid string, purpose Purpose, id string, at time.Time) RetireMessage {
	f, th := imgURLs(id, "webp")
	return RetireMessage{Kind: JobKindProfileMediaRetired, UID: uid, Purpose: string(purpose), OldURL: f, OldThumbURL: th, ChangedAt: at}
}

func TestParseObjectName(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name string
		in   string
		want ImageObject
		ok   bool
	}{
		{"full webp", "m/0000000000000000701.webp", ImageObject{Name: "m/0000000000000000701.webp", ID: "0000000000000000701", Ext: "webp"}, true},
		{"thumb jpg", "m/0000000000000000701_t.jpg", ImageObject{Name: "m/0000000000000000701_t.jpg", ID: "0000000000000000701", Ext: "jpg", Thumb: true}, true},
		{"short id", "m/123.webp", ImageObject{}, false},
		{"long id", "m/00000000000000007010.webp", ImageObject{}, false},
		{"non-digit id", "m/000000000000000070a.webp", ImageObject{}, false},
		{"png is not written by media", "m/0000000000000000701.png", ImageObject{}, false},
		{"upload object", "u/uid-alice/0000000000000000701.jpg", ImageObject{}, false},
		{"nested", "m/x/0000000000000000701.jpg", ImageObject{}, false},
		{"double thumb", "m/0000000000000000701_t_t.jpg", ImageObject{}, false},
		{"empty", "", ImageObject{}, false},
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

// TestObjectNameFromURL keys on the last "/m/" segment, because the public base URL is deployment config.
func TestObjectNameFromURL(t *testing.T) {
	t.Parallel()
	tests := []struct{ name, in, want string }{
		{"default base", retireBucket + "/m/0000000000000000701.webp", "m/0000000000000000701.webp"},
		{"thumbnail", retireBucket + "/m/0000000000000000701_t.webp", "m/0000000000000000701_t.webp"},
		{"cdn base", "https://cdn.example.com/m/0000000000000000701.jpg", "m/0000000000000000701.jpg"},
		{"bucket named m", "https://storage.googleapis.com/m/m/0000000000000000701.jpg", "m/0000000000000000701.jpg"},
		{"query string is not part of the name", retireBase + "/m/0000000000000000701.jpg?x=1", "m/0000000000000000701.jpg"},
		{"no m segment", "https://cdn.example.com/img/0000000000000000701.jpg", ""},
		{"nothing after m", "https://cdn.example.com/m/", ""},
		{"nested after m", "https://cdn.example.com/m/a/b.jpg", ""},
		{"not a url", "%zz", ""},
		{"empty", "", ""},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			if got := ObjectNameFromURL(tt.in); got != tt.want {
				t.Errorf("ObjectNameFromURL(%q) = %q, want %q", tt.in, got, tt.want)
			}
		})
	}
}

func TestParseRetiredImage(t *testing.T) {
	t.Parallel()
	full, thumb := imgURLs(idBannerOld, "webp")
	jpgFull, jpgThumb := imgURLs(idBannerOld, "jpg")
	otherFull, otherThumb := imgURLs(idAvatarOld, "webp")
	tests := []struct {
		name          string
		full, thumb   string
		wantID        string
		wantParseable bool
	}{
		{"pair", full, thumb, idBannerOld, true},
		{"full only", full, "", idBannerOld, true},
		{"thumb as the full url", thumb, "", "", false},
		{"full as the thumb url", full, full, "", false},
		{"thumb of another image", full, otherThumb, "", false},
		{"thumb with another extension", full, jpgThumb, "", false},
		{"jpg pair", jpgFull, jpgThumb, idBannerOld, true},
		{"garbage full", "https://x.test/pic.png", thumb, "", false},
		{"empty full", "", thumb, "", false},
		{"other id pair", otherFull, otherThumb, idAvatarOld, true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			id, ok := parseRetiredImage(tt.full, tt.thumb)
			if ok != tt.wantParseable || id != tt.wantID {
				t.Errorf("parseRetiredImage = %q, %v; want %q, %v", id, ok, tt.wantID, tt.wantParseable)
			}
		})
	}
}

// TestRetire_Matrix is the full outcome matrix of the step: every row states the outcome, the reads it cost, what was
// tagged and whether the document was written.
func TestRetire_Matrix(t *testing.T) {
	changed := retireNow.Add(-10 * time.Minute)
	tests := []struct {
		name  string
		mode  config.ProfileMediaRetire
		setup func(e *retireEnv)
		msg   func() RetireMessage
		want  string
		// reads: ProfileImageURLs calls and GetMany calls. tagged: customTime patches. retired: whether the doc was written.
		userReads, docReads, tagged int
		retired                     bool
	}{
		{
			name: "banner replaced, mode banner",
			mode: config.ProfileMediaRetireBanner,
			setup: func(e *retireEnv) {
				seedProfileImage(e.repo, e.obj, idBannerOld, uidA, PurposeBanner, "webp")
				e.setCurrent(uidA, idBannerNew)
			},
			msg:  func() RetireMessage { return retireMsg(uidA, PurposeBanner, idBannerOld, changed) },
			want: "retired", userReads: 1, docReads: 1, tagged: 2, retired: true,
		},
		{
			name: "banner removed (nothing current), mode all",
			mode: config.ProfileMediaRetireAll,
			setup: func(e *retireEnv) {
				seedProfileImage(e.repo, e.obj, idBannerOld, uidA, PurposeBanner, "webp")
				e.users.urls[uidA] = nil
			},
			msg:  func() RetireMessage { return retireMsg(uidA, PurposeBanner, idBannerOld, changed) },
			want: "retired", userReads: 1, docReads: 1, tagged: 2, retired: true,
		},
		{
			name: "avatar replaced, mode all",
			mode: config.ProfileMediaRetireAll,
			setup: func(e *retireEnv) {
				seedProfileImage(e.repo, e.obj, idAvatarOld, uidA, PurposeAvatar, "webp")
				e.setCurrent(uidA, idAvatarNew)
			},
			msg:  func() RetireMessage { return retireMsg(uidA, PurposeAvatar, idAvatarOld, changed) },
			want: "retired", userReads: 1, docReads: 1, tagged: 2, retired: true,
		},
		{
			name: "a jpg image is retired too",
			mode: config.ProfileMediaRetireAll,
			setup: func(e *retireEnv) {
				seedProfileImage(e.repo, e.obj, idAvatarOld, uidA, PurposeAvatar, "jpg")
				e.setCurrent(uidA, idAvatarNew)
			},
			msg: func() RetireMessage {
				m := retireMsg(uidA, PurposeAvatar, idAvatarOld, changed)
				m.OldURL, m.OldThumbURL = imgURLs(idAvatarOld, "jpg")
				return m
			},
			want: "retired", userReads: 1, docReads: 1, tagged: 2, retired: true,
		},
		{
			name: "the account's profile is gone: still retired (found is not an error)",
			mode: config.ProfileMediaRetireAll,
			setup: func(e *retireEnv) {
				seedProfileImage(e.repo, e.obj, idBannerOld, uidA, PurposeBanner, "webp")
			},
			msg:  func() RetireMessage { return retireMsg(uidA, PurposeBanner, idBannerOld, changed) },
			want: "retired", userReads: 1, docReads: 1, tagged: 2, retired: true,
		},
		{
			name: "switch off: acked before any read",
			mode: config.ProfileMediaRetireOff,
			setup: func(e *retireEnv) {
				seedProfileImage(e.repo, e.obj, idBannerOld, uidA, PurposeBanner, "webp")
			},
			msg:  func() RetireMessage { return retireMsg(uidA, PurposeBanner, idBannerOld, changed) },
			want: "disabled",
		},
		{
			name: "zero value mode is off",
			mode: "",
			setup: func(e *retireEnv) {
				seedProfileImage(e.repo, e.obj, idBannerOld, uidA, PurposeBanner, "webp")
			},
			msg:  func() RetireMessage { return retireMsg(uidA, PurposeBanner, idBannerOld, changed) },
			want: "disabled",
		},
		{
			name: "mode banner never retires an avatar",
			mode: config.ProfileMediaRetireBanner,
			setup: func(e *retireEnv) {
				seedProfileImage(e.repo, e.obj, idAvatarOld, uidA, PurposeAvatar, "webp")
			},
			msg:  func() RetireMessage { return retireMsg(uidA, PurposeAvatar, idAvatarOld, changed) },
			want: "disabled",
		},
		{
			name: "the old url is still the current avatar",
			mode: config.ProfileMediaRetireAll,
			setup: func(e *retireEnv) {
				seedProfileImage(e.repo, e.obj, idAvatarOld, uidA, PurposeAvatar, "webp")
				e.setCurrent(uidA, idAvatarOld)
			},
			msg:  func() RetireMessage { return retireMsg(uidA, PurposeAvatar, idAvatarOld, changed) },
			want: "still_current", userReads: 1,
		},
		{
			name: "the old url is still the current banner",
			mode: config.ProfileMediaRetireBanner,
			setup: func(e *retireEnv) {
				seedProfileImage(e.repo, e.obj, idBannerOld, uidA, PurposeBanner, "webp")
				e.setCurrent(uidA, idAvatarNew, idBannerOld)
			},
			msg:  func() RetireMessage { return retireMsg(uidA, PurposeBanner, idBannerOld, changed) },
			want: "still_current", userReads: 1,
		},
		{
			name: "a forged message naming the current avatar as a BANNER is still current (either purpose)",
			mode: config.ProfileMediaRetireAll,
			setup: func(e *retireEnv) {
				seedProfileImage(e.repo, e.obj, idAvatarOld, uidA, PurposeAvatar, "webp")
				e.setCurrent(uidA, idAvatarOld)
			},
			msg:  func() RetireMessage { return retireMsg(uidA, PurposeBanner, idAvatarOld, changed) },
			want: "still_current", userReads: 1,
		},
		{
			name: "only the thumbnail is still current",
			mode: config.ProfileMediaRetireAll,
			setup: func(e *retireEnv) {
				seedProfileImage(e.repo, e.obj, idAvatarOld, uidA, PurposeAvatar, "webp")
				_, th := imgURLs(idAvatarOld, "webp")
				e.users.urls[uidA] = []string{th}
			},
			msg:  func() RetireMessage { return retireMsg(uidA, PurposeAvatar, idAvatarOld, changed) },
			want: "still_current", userReads: 1,
		},
		{
			name: "another host with the same object name is still current (names are compared, not hosts)",
			mode: config.ProfileMediaRetireAll,
			setup: func(e *retireEnv) {
				seedProfileImage(e.repo, e.obj, idAvatarOld, uidA, PurposeAvatar, "webp")
				e.users.urls[uidA] = []string{retireBucket + "/m/" + idAvatarOld + ".webp"}
			},
			msg:  func() RetireMessage { return retireMsg(uidA, PurposeAvatar, idAvatarOld, changed) },
			want: "still_current", userReads: 1,
		},
		{
			name: "unparseable url is acked with no read",
			mode: config.ProfileMediaRetireAll,
			setup: func(e *retireEnv) {
				seedProfileImage(e.repo, e.obj, idAvatarOld, uidA, PurposeAvatar, "webp")
			},
			msg: func() RetireMessage {
				m := retireMsg(uidA, PurposeAvatar, idAvatarOld, changed)
				m.OldURL, m.OldThumbURL = "https://elsewhere.test/avatar.png", ""
				return m
			},
			want: "unparseable",
		},
		{
			name: "thumbnail url naming another image is unparseable",
			mode: config.ProfileMediaRetireAll,
			setup: func(e *retireEnv) {
				seedProfileImage(e.repo, e.obj, idAvatarOld, uidA, PurposeAvatar, "webp")
				seedProfileImage(e.repo, e.obj, idBannerOld, uidA, PurposeBanner, "webp")
			},
			msg: func() RetireMessage {
				m := retireMsg(uidA, PurposeAvatar, idAvatarOld, changed)
				_, m.OldThumbURL = imgURLs(idBannerOld, "webp")
				return m
			},
			want: "unparseable",
		},
		{
			name: "redelivery of a retired image: duplicate, 0 writes, no GCS call",
			mode: config.ProfileMediaRetireAll,
			setup: func(e *retireEnv) {
				seedProfileImage(e.repo, e.obj, idBannerOld, uidA, PurposeBanner, "webp")
				done := changed
				e.repo.docs[idBannerOld].RetiredAt = &done
			},
			msg:  func() RetireMessage { return retireMsg(uidA, PurposeBanner, idBannerOld, changed) },
			want: "duplicate", userReads: 1, docReads: 1,
		},
		{
			name:  "no media document: duplicate (gone with its account or its TTL)",
			mode:  config.ProfileMediaRetireAll,
			setup: func(e *retireEnv) {},
			msg:   func() RetireMessage { return retireMsg(uidA, PurposeBanner, idBannerOld, changed) },
			want:  "duplicate", userReads: 1, docReads: 1,
		},
		{
			name: "another owner's image is refused",
			mode: config.ProfileMediaRetireAll,
			setup: func(e *retireEnv) {
				seedProfileImage(e.repo, e.obj, idBannerOld, uidB, PurposeBanner, "webp")
			},
			msg:  func() RetireMessage { return retireMsg(uidA, PurposeBanner, idBannerOld, changed) },
			want: "refused", userReads: 1, docReads: 1,
		},
		{
			name: "the wrong purpose is refused (an avatar named as a banner)",
			mode: config.ProfileMediaRetireAll,
			setup: func(e *retireEnv) {
				seedProfileImage(e.repo, e.obj, idAvatarOld, uidA, PurposeAvatar, "webp")
			},
			msg:  func() RetireMessage { return retireMsg(uidA, PurposeBanner, idAvatarOld, changed) },
			want: "refused", userReads: 1, docReads: 1,
		},
		{
			name: "a POST image is refused (a profile message never reaches a post's image)",
			mode: config.ProfileMediaRetireAll,
			setup: func(e *retireEnv) {
				seedProfileImage(e.repo, e.obj, idAvatarOld, uidA, PurposePost, "webp")
			},
			msg:  func() RetireMessage { return retireMsg(uidA, PurposeAvatar, idAvatarOld, changed) },
			want: "refused", userReads: 1, docReads: 1,
		},
		{
			name: "an unpublished document is refused",
			mode: config.ProfileMediaRetireAll,
			setup: func(e *retireEnv) {
				seedProfileImage(e.repo, e.obj, idBannerOld, uidA, PurposeBanner, "webp")
				e.repo.docs[idBannerOld].Status = string(StatusPending)
			},
			msg:  func() RetireMessage { return retireMsg(uidA, PurposeBanner, idBannerOld, changed) },
			want: "refused", userReads: 1, docReads: 1,
		},
		{
			name:  "invalid uid",
			mode:  config.ProfileMediaRetireAll,
			setup: func(e *retireEnv) {},
			msg:   func() RetireMessage { return retireMsg("bad/uid", PurposeBanner, idBannerOld, changed) },
			want:  "dropped:invalid_message",
		},
		{
			name:  "POST is not a profile purpose",
			mode:  config.ProfileMediaRetireAll,
			setup: func(e *retireEnv) {},
			msg:   func() RetireMessage { return retireMsg(uidA, PurposePost, idBannerOld, changed) },
			want:  "dropped:invalid_message",
		},
		{
			name:  "zero changedAt",
			mode:  config.ProfileMediaRetireAll,
			setup: func(e *retireEnv) {},
			msg:   func() RetireMessage { return retireMsg(uidA, PurposeBanner, idBannerOld, time.Time{}) },
			want:  "dropped:invalid_message",
		},
		{
			name:  "no url",
			mode:  config.ProfileMediaRetireAll,
			setup: func(e *retireEnv) {},
			msg: func() RetireMessage {
				m := retireMsg(uidA, PurposeBanner, idBannerOld, changed)
				m.OldURL = ""
				return m
			},
			want: "dropped:invalid_message",
		},
		{
			name:  "oversized url",
			mode:  config.ProfileMediaRetireAll,
			setup: func(e *retireEnv) {},
			msg: func() RetireMessage {
				m := retireMsg(uidA, PurposeBanner, idBannerOld, changed)
				m.OldURL = retireBase + "/m/" + strings.Repeat("0", 600) + ".webp"
				return m
			},
			want: "dropped:invalid_message",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := newRetireEnv(tt.mode)
			tt.setup(e)
			m := tt.msg()
			docBefore := map[string]Doc{}
			for id, d := range e.repo.docs {
				docBefore[id] = *d
			}
			got, err := e.jobs.Retire(context.Background(), m)
			if err != nil {
				t.Fatalf("Retire: %v", err)
			}
			if got != tt.want {
				t.Fatalf("outcome = %q, want %q", got, tt.want)
			}
			if e.users.reads != tt.userReads || e.repo.getMany != tt.docReads {
				t.Errorf("reads: users %d (want %d), media docs %d (want %d)", e.users.reads, tt.userReads, e.repo.getMany, tt.docReads)
			}
			if len(e.tagger.calls) != tt.tagged {
				t.Errorf("customTime patches = %d, want %d", len(e.tagger.calls), tt.tagged)
			}
			if wrote := e.repo.retires > 0; wrote != tt.retired {
				t.Errorf("document written = %v, want %v", wrote, tt.retired)
			}
			if !tt.retired {
				for id, d := range e.repo.docs {
					if d.RetiredAt != docBefore[id].RetiredAt || d.ExpireAt != docBefore[id].ExpireAt {
						t.Errorf("doc %s changed on a %q outcome", id, got)
					}
				}
			}
		})
	}
}

// TestRetire_WritesWhatTheDesignSays: objects first with customTime = changedAt, then the document with retiredAt =
// changedAt and expireAt = changedAt + 72 h; the objects are the document's own two names.
func TestRetire_WritesWhatTheDesignSays(t *testing.T) {
	e := newRetireEnv(config.ProfileMediaRetireAll)
	seedProfileImage(e.repo, e.obj, idBannerOld, uidA, PurposeBanner, "webp")
	e.setCurrent(uidA, idBannerNew)
	at := retireNow.Add(-90 * time.Minute)

	got, err := e.jobs.Retire(context.Background(), retireMsg(uidA, PurposeBanner, idBannerOld, at))
	if err != nil || got != "retired" {
		t.Fatalf("Retire = %q, %v", got, err)
	}
	want := []taggedObject{{"m/" + idBannerOld + ".webp", at}, {"m/" + idBannerOld + "_t.webp", at}}
	if len(e.tagger.calls) != 2 || e.tagger.calls[0] != want[0] || e.tagger.calls[1] != want[1] {
		t.Errorf("tagged = %v, want %v", e.tagger.calls, want)
	}
	d := e.repo.docs[idBannerOld]
	if d.RetiredAt == nil || !d.RetiredAt.Equal(at) || d.ExpireAt == nil || !d.ExpireAt.Equal(at.Add(72*time.Hour)) {
		t.Errorf("doc retiredAt = %v, expireAt = %v; want %v and %v", d.RetiredAt, d.ExpireAt, at, at.Add(72*time.Hour))
	}
	if len(e.obj.deleted) != 0 || len(e.obj.public) != 2 {
		t.Errorf("the step must not delete anything itself (the bucket lifecycle rule does): deleted = %v", e.obj.deleted)
	}
	if e.repo.resolves != 0 || e.repo.claims != 0 {
		t.Errorf("only Retire writes the document")
	}
}

// TestRetire_FutureChangedAtIsClampedToNow: customTime can never be lowered, and a far-future value would outlive the
// document's TTL and escape the account eraser, so the step stamps at most "now".
func TestRetire_FutureChangedAtIsClampedToNow(t *testing.T) {
	e := newRetireEnv(config.ProfileMediaRetireAll)
	seedProfileImage(e.repo, e.obj, idBannerOld, uidA, PurposeBanner, "webp")
	got, err := e.jobs.Retire(context.Background(), retireMsg(uidA, PurposeBanner, idBannerOld, retireNow.AddDate(3, 0, 0)))
	if err != nil || got != "retired" {
		t.Fatalf("Retire = %q, %v", got, err)
	}
	for _, c := range e.tagger.calls {
		if !c.at.Equal(retireNow) {
			t.Errorf("tagged at %v, want the clamp %v", c.at, retireNow)
		}
	}
	if d := e.repo.docs[idBannerOld]; !d.RetiredAt.Equal(retireNow) || !d.ExpireAt.Equal(retireNow.Add(RetiredDocTTL)) {
		t.Errorf("doc = %v / %v", d.RetiredAt, d.ExpireAt)
	}
}

// TestRetire_RedeliveryAfterCompletionDoesNothing: the second delivery of the same message is "duplicate" with 0
// writes and no GCS call.
func TestRetire_RedeliveryAfterCompletionDoesNothing(t *testing.T) {
	e := newRetireEnv(config.ProfileMediaRetireAll)
	seedProfileImage(e.repo, e.obj, idBannerOld, uidA, PurposeBanner, "webp")
	e.setCurrent(uidA, idBannerNew)
	msg := retireMsg(uidA, PurposeBanner, idBannerOld, retireNow.Add(-time.Hour))
	if got, err := e.jobs.Retire(context.Background(), msg); err != nil || got != "retired" {
		t.Fatalf("first = %q, %v", got, err)
	}
	tagged, retires := len(e.tagger.calls), e.repo.retires
	got, err := e.jobs.Retire(context.Background(), msg)
	if err != nil || got != "duplicate" {
		t.Fatalf("second = %q, %v; want duplicate", got, err)
	}
	if len(e.tagger.calls) != tagged || e.repo.retires != retires {
		t.Errorf("a redelivery touched GCS (%d -> %d patches) or wrote the doc (%d -> %d)", tagged, len(e.tagger.calls), retires, e.repo.retires)
	}
}

// TestRetire_CrashBetweenTheTagAndTheDocumentConverges: objects are tagged, the document write never happens (a crash, a
// lost conflict, a Firestore error); the redelivery repeats the tag with the same value and writes the document.
func TestRetire_CrashBetweenTheTagAndTheDocumentConverges(t *testing.T) {
	tests := []struct {
		name    string
		break_  func(e *retireEnv)
		fix     func(e *retireEnv)
		wantErr error
	}{
		{
			name:   "document write fails",
			break_: func(e *retireEnv) { e.repo.retireErr = errors.New("firestore unavailable") },
			fix:    func(e *retireEnv) { e.repo.retireErr = nil },
		},
		{
			name:    "document moved under it (concurrent delivery or eraser)",
			break_:  func(e *retireEnv) { e.repo.retireErr = ErrConflict },
			fix:     func(e *retireEnv) { e.repo.retireErr = nil },
			wantErr: ErrConflict,
		},
		{
			name:   "the second object cannot be tagged",
			break_: func(e *retireEnv) { e.tagger.failOn = "m/" + idBannerOld + "_t.webp" },
			fix:    func(e *retireEnv) { e.tagger.failOn = "" },
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := newRetireEnv(config.ProfileMediaRetireAll)
			seedProfileImage(e.repo, e.obj, idBannerOld, uidA, PurposeBanner, "webp")
			e.setCurrent(uidA, idBannerNew)
			at := retireNow.Add(-time.Hour)
			msg := retireMsg(uidA, PurposeBanner, idBannerOld, at)

			tt.break_(e)
			out, err := e.jobs.Retire(context.Background(), msg)
			if err == nil || out != "" {
				t.Fatalf("Retire = %q, %v; want an error so the message is redelivered", out, err)
			}
			if tt.wantErr != nil && !errors.Is(err, tt.wantErr) {
				t.Errorf("err = %v, want it to wrap %v", err, tt.wantErr)
			}
			if e.repo.docs[idBannerOld].RetiredAt != nil {
				t.Fatal("the document must not be retired by a failed delivery")
			}

			tt.fix(e)
			out, err = e.jobs.Retire(context.Background(), msg)
			if err != nil || out != "retired" {
				t.Fatalf("redelivery = %q, %v; want retired", out, err)
			}
			if d := e.repo.docs[idBannerOld]; d.RetiredAt == nil || !d.RetiredAt.Equal(at) {
				t.Errorf("retiredAt = %v, want %v", d.RetiredAt, at)
			}
			for _, c := range e.tagger.calls {
				if !c.at.Equal(at) {
					t.Errorf("a repeated tag must carry the same value (customTime never moves back): %v", c.at)
				}
			}
			// And the third delivery is a no-op.
			if out, err = e.jobs.Retire(context.Background(), msg); err != nil || out != "duplicate" {
				t.Errorf("third = %q, %v", out, err)
			}
		})
	}
}

func TestRetire_InfrastructureErrorsNack(t *testing.T) {
	e := newRetireEnv(config.ProfileMediaRetireAll)
	seedProfileImage(e.repo, e.obj, idBannerOld, uidA, PurposeBanner, "webp")
	e.users.err = errors.New("users read failed")
	if out, err := e.jobs.Retire(context.Background(), retireMsg(uidA, PurposeBanner, idBannerOld, retireNow)); err == nil {
		t.Fatalf("a failed users read must nack, got %q", out)
	} else if strings.Contains(err.Error(), uidA) {
		t.Errorf("the error leaks the uid: %v", err)
	}
	if e.repo.getMany != 0 || len(e.tagger.calls) != 0 {
		t.Error("nothing may be read or tagged after a failed users read")
	}

	// A step that is not wired is a loud error, never a silent ack that would hide a misconfiguration.
	bare := NewJobs(newFakeRepo(), newFakeObjects(), fakePosts{}, nil).WithProfileRetire(RetireDeps{Mode: config.ProfileMediaRetireAll})
	if _, err := bare.Retire(context.Background(), retireMsg(uidA, PurposeBanner, idBannerOld, retireNow)); err == nil {
		t.Error("a retire step without a users reader or tagger must error")
	}
}

func TestRetireHandler_Handle(t *testing.T) {
	e := newRetireEnv(config.ProfileMediaRetireAll)
	seedProfileImage(e.repo, e.obj, idBannerOld, uidA, PurposeBanner, "webp")
	h := e.jobs.RetireHandler()

	enc := func(t *testing.T, m RetireMessage) []byte {
		t.Helper()
		b, err := json.Marshal(m)
		if err != nil {
			t.Fatal(err)
		}
		return b
	}
	good := retireMsg(uidA, PurposeBanner, idBannerOld, retireNow.Add(-time.Minute))
	wrongKind := good
	wrongKind.Kind = JobKindPostDelete

	tests := []struct {
		name string
		data []byte
		want string
	}{
		{"malformed json", []byte(`{"kind":`), "dropped:malformed_message"},
		{"not json at all", []byte("hello"), "dropped:malformed_message"},
		{"empty body", nil, "dropped:malformed_message"},
		{"another kind", enc(t, wrongKind), "dropped:invalid_message"},
		{"no kind", []byte(`{"uid":"uid-alice"}`), "dropped:invalid_message"},
		{"a good message", enc(t, good), "retired"},
		{"the same message again", enc(t, good), "duplicate"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := h.Handle(context.Background(), tt.data)
			if err != nil || got != tt.want {
				t.Fatalf("Handle = %q, %v; want %q", got, err, tt.want)
			}
		})
	}
}

// TestProfileImageReplaced_Publish: the publish side checks the switch in memory before anything else (0 messages when
// the switch does not allow the purpose), and a published message carries exactly what the handler needs.
func TestProfileImageReplaced_Publish(t *testing.T) {
	at := retireNow.Add(-time.Second)
	full, thumb := imgURLs(idBannerOld, "webp")
	tests := []struct {
		name    string
		mode    config.ProfileMediaRetire
		purpose Purpose
		want    int
	}{
		{"off publishes nothing", config.ProfileMediaRetireOff, PurposeBanner, 0},
		{"zero value publishes nothing", "", PurposeBanner, 0},
		{"banner mode, banner", config.ProfileMediaRetireBanner, PurposeBanner, 1},
		{"banner mode, avatar", config.ProfileMediaRetireBanner, PurposeAvatar, 0},
		{"all, avatar", config.ProfileMediaRetireAll, PurposeAvatar, 1},
		{"all, banner", config.ProfileMediaRetireAll, PurposeBanner, 1},
		{"all never publishes a post image", config.ProfileMediaRetireAll, PurposePost, 0},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := newRetireEnv(tt.mode)
			if err := e.jobs.ProfileImageReplaced(context.Background(), uidA, tt.purpose, full, thumb, at); err != nil {
				t.Fatalf("ProfileImageReplaced: %v", err)
			}
			if len(e.pub.msgs) != tt.want {
				t.Fatalf("messages = %d, want %d", len(e.pub.msgs), tt.want)
			}
			if tt.want == 0 {
				return
			}
			var m RetireMessage
			if err := json.Unmarshal(e.pub.msgs[0], &m); err != nil {
				t.Fatal(err)
			}
			if m.Kind != JobKindProfileMediaRetired || m.UID != uidA || m.Purpose != string(tt.purpose) || m.OldURL != full || m.OldThumbURL != thumb || !m.ChangedAt.Equal(at) {
				t.Errorf("message = %+v", m)
			}
			if bytes.Contains(e.pub.msgs[0], []byte("token")) {
				t.Error("a message carries only ids and urls")
			}
		})
	}

	t.Run("a publisher failure is returned for the caller to log", func(t *testing.T) {
		e := newRetireEnv(config.ProfileMediaRetireAll)
		e.pub.err = errors.New("pubsub down")
		if err := e.jobs.ProfileImageReplaced(context.Background(), uidA, PurposeBanner, full, thumb, at); err == nil {
			t.Fatal("want the publish error")
		}
	})
	t.Run("no publisher is an error when the switch allows it", func(t *testing.T) {
		j := NewJobs(newFakeRepo(), newFakeObjects(), fakePosts{}, nil).WithProfileRetire(RetireDeps{Mode: config.ProfileMediaRetireAll})
		if err := j.ProfileImageReplaced(context.Background(), uidA, PurposeBanner, full, thumb, at); err == nil {
			t.Fatal("want an error")
		}
		off := NewJobs(newFakeRepo(), newFakeObjects(), fakePosts{}, nil)
		if err := off.ProfileImageReplaced(context.Background(), uidA, PurposeBanner, full, thumb, at); err != nil {
			t.Fatalf("a switch that is off needs no publisher: %v", err)
		}
	})
}

// TestPurgeUser_CoversRetiredImagesInsideTheGrace: a retired AVATAR and BANNER still own their objects until the
// document's TTL, so an account deleted during the grace loses the objects and the documents at once; the export still
// lists them, with the retirement time.
func TestPurgeUser_CoversRetiredImagesInsideTheGrace(t *testing.T) {
	r, o := newFakeRepo(), newFakeObjects()
	seedProfileImage(r, o, idAvatarOld, uidA, PurposeAvatar, "webp")
	seedProfileImage(r, o, idBannerOld, uidA, PurposeBanner, "jpg")
	seedProfileImage(r, o, idBannerNew, uidA, PurposeBanner, "webp") // the current banner, not retired
	seedProfileImage(r, o, idAvatarNew, uidB, PurposeAvatar, "webp") // someone else's
	at := retireNow.Add(-2 * time.Hour)
	exp := at.Add(RetiredDocTTL)
	for _, id := range []string{idAvatarOld, idBannerOld} {
		d := r.docs[id]
		d.RetiredAt, d.ExpireAt = &at, &exp
	}

	p := NewPurger(r, o, "https://cdn.test/media")
	var out bytes.Buffer
	if err := p.WriteSection(context.Background(), uidA, &out); err != nil {
		t.Fatal(err)
	}
	var export struct {
		Media []struct {
			ID        string     `json:"id"`
			Purpose   string     `json:"purpose"`
			RetiredAt *time.Time `json:"retiredAt"`
		} `json:"media"`
	}
	if err := json.Unmarshal(out.Bytes(), &export); err != nil {
		t.Fatalf("export is not JSON: %v\n%s", err, out.String())
	}
	if len(export.Media) != 3 {
		t.Fatalf("export lists %d images, want all 3 of Alice's (retired ones included until their TTL): %s", len(export.Media), out.String())
	}
	retired := 0
	for _, m := range export.Media {
		if m.RetiredAt != nil {
			retired++
			if !m.RetiredAt.Equal(at) || (m.ID != idAvatarOld && m.ID != idBannerOld) {
				t.Errorf("retired entry %+v", m)
			}
		}
	}
	if retired != 2 {
		t.Errorf("retired entries = %d, want 2 (the current banner is not retired)", retired)
	}

	_, done, err := p.PurgeUser(context.Background(), uidA, Checkpoint{})
	if err != nil || !done {
		t.Fatalf("PurgeUser done=%v err=%v", done, err)
	}
	if len(r.docs) != 1 || r.docs[idAvatarNew] == nil {
		t.Errorf("docs left = %v: only Bob's may remain (retired documents are erased with the account)", r.docs)
	}
	if len(o.public) != 2 {
		t.Errorf("public objects left = %v: both of Alice's retired images and her current banner must be deleted at once", o.public)
	}
}

// TestRetire_ChangedAtIsStampedAtMicrosecondPrecision: Firestore timestamps carry no finer precision, so the value on the
// objects and on the document is the same microsecond-truncated time, however many nanoseconds the message carried.
func TestRetire_ChangedAtIsStampedAtMicrosecondPrecision(t *testing.T) {
	e := newRetireEnv(config.ProfileMediaRetireAll)
	seedProfileImage(e.repo, e.obj, idBannerOld, uidA, PurposeBanner, "webp")
	at := retireNow.Add(-time.Hour).Add(123456789 * time.Nanosecond)
	want := retireNow.Add(-time.Hour).Add(123456 * time.Microsecond)
	if got, err := e.jobs.Retire(context.Background(), retireMsg(uidA, PurposeBanner, idBannerOld, at)); err != nil || got != "retired" {
		t.Fatalf("Retire = %q, %v", got, err)
	}
	for _, c := range e.tagger.calls {
		if !c.at.Equal(want) {
			t.Errorf("tagged at %v, want %v", c.at, want)
		}
	}
	if d := e.repo.docs[idBannerOld]; !d.RetiredAt.Equal(want) || !d.ExpireAt.Equal(want.Add(RetiredDocTTL)) {
		t.Errorf("doc = %v / %v, want %v and +72 h", d.RetiredAt, d.ExpireAt, want)
	}
}
