package media

import (
	"context"
	"errors"
	"slices"
	"sort"
	"testing"
)

// legacyBannerFake lists the fakeRepo's BANNER documents in id order, like the Firestore query.
type legacyBannerFake struct {
	*fakeRepo
	listErr error
}

func (f legacyBannerFake) ListLegacyBanners(_ context.Context, after string, limit int) ([]*Doc, error) {
	if f.listErr != nil {
		return nil, f.listErr
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	var ids []string
	for id, d := range f.docs {
		if d.Purpose == LegacyBannerPurpose && id > after {
			ids = append(ids, id)
		}
	}
	sort.Strings(ids)
	if len(ids) > limit {
		ids = ids[:limit]
	}
	out := make([]*Doc, 0, len(ids))
	for _, id := range ids {
		out = append(out, f.docs[id])
	}
	return out, nil
}

func TestPurgeLegacyBanners(t *testing.T) {
	newEnvLB := func() (*LegacyBannerPurger, *fakeRepo, *fakeObjects) {
		r, o := newFakeRepo(), newFakeObjects()
		seedProfileImage(r, o, "0000000000000000801", uidA, LegacyBannerPurpose, "webp")
		seedProfileImage(r, o, "0000000000000000802", uidB, LegacyBannerPurpose, "jpg")
		seedProfileImage(r, o, "0000000000000000803", uidA, LegacyBannerPurpose, "webp")
		// A PENDING one: no public objects yet, only the private upload leftovers.
		r.docs["0000000000000000803"].Status = string(StatusPending)
		r.docs["0000000000000000803"].UploadPath = "u/" + uidA + "/0000000000000000803.webp"
		r.docs["0000000000000000803"].ThumbUploadPath = "u/" + uidA + "/0000000000000000803_t.webp"
		// Not banners: never touched.
		seedProfileImage(r, o, "0000000000000000804", uidA, PurposeAvatar, "webp")
		seedProfileImage(r, o, "0000000000000000805", uidA, PurposePost, "webp")
		return &LegacyBannerPurger{repo: legacyBannerFake{fakeRepo: r}, objects: o}, r, o
	}

	t.Run("dry run lists and writes nothing", func(t *testing.T) {
		p, r, o := newEnvLB()
		page, err := p.PurgeLegacyBanners(context.Background(), "", 2, true)
		if err != nil || page.Found != 2 || page.Deleted != 0 || page.Last != "0000000000000000802" {
			t.Fatalf("page = %+v, %v", page, err)
		}
		if len(r.docs) != 5 || len(o.deleted) != 0 {
			t.Fatalf("a dry run wrote: docs=%d deleted=%v", len(r.docs), o.deleted)
		}
		page, err = p.PurgeLegacyBanners(context.Background(), page.Last, 2, true)
		if err != nil || page.Found != 1 || page.Last != "0000000000000000803" {
			t.Fatalf("second dry page = %+v, %v", page, err)
		}
	})

	t.Run("apply erases objects then documents, only banners, and a rerun finds nothing", func(t *testing.T) {
		p, r, o := newEnvLB()
		page, err := p.PurgeLegacyBanners(context.Background(), "", 100, false)
		if err != nil || page.Found != 3 || page.Deleted != 3 {
			t.Fatalf("page = %+v, %v", page, err)
		}
		for _, id := range []string{"0000000000000000801", "0000000000000000802", "0000000000000000803"} {
			if r.docs[id] != nil {
				t.Errorf("media/%s survived", id)
			}
		}
		if r.docs["0000000000000000804"] == nil || r.docs["0000000000000000805"] == nil {
			t.Fatal("a document of another purpose was erased")
		}
		for _, name := range []string{"m/0000000000000000801.webp", "m/0000000000000000801_t.webp", "m/0000000000000000802.jpg", "m/0000000000000000802_t.jpg"} {
			if _, ok := o.public[name]; ok {
				t.Errorf("public object %s survived", name)
			}
		}
		for _, name := range []string{"u:u/" + uidA + "/0000000000000000803.webp", "u:u/" + uidA + "/0000000000000000803_t.webp"} {
			if !slices.Contains(o.deleted, name) {
				t.Errorf("upload leftover %s was not deleted: %v", name, o.deleted)
			}
		}
		if _, ok := o.public["m/0000000000000000804.webp"]; !ok {
			t.Error("the avatar's object was deleted")
		}
		again, err := p.PurgeLegacyBanners(context.Background(), "", 100, false)
		if err != nil || again.Found != 0 || again.Deleted != 0 {
			t.Fatalf("rerun = %+v, %v; want nothing found", again, err)
		}
	})

	t.Run("an object delete failure keeps the documents for the next run", func(t *testing.T) {
		p, r, o := newEnvLB()
		o.deletePub = errors.New("gcs unavailable")
		if _, err := p.PurgeLegacyBanners(context.Background(), "", 100, false); err == nil {
			t.Fatal("want the GCS error")
		}
		if r.docs["0000000000000000801"] == nil {
			t.Fatal("a document was deleted before its objects (objects first, document last)")
		}
	})

	t.Run("a list failure is returned", func(t *testing.T) {
		r, o := newFakeRepo(), newFakeObjects()
		p := &LegacyBannerPurger{repo: legacyBannerFake{fakeRepo: r, listErr: errors.New("firestore down")}, objects: o}
		if _, err := p.PurgeLegacyBanners(context.Background(), "", 100, false); err == nil {
			t.Fatal("want the list error")
		}
	})
}
