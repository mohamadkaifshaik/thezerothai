package media

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"
)

func TestPurgeUser(t *testing.T) {
	r, o := newFakeRepo(), newFakeObjects()
	// 250 of Alice's images (published, pending, rejected) plus one of Bob's.
	for i := 0; i < 250; i++ {
		id := fmt.Sprintf("%019d", 7000+i)
		switch i % 3 {
		case 0:
			seedPublished(r, o, id, uidA, "")
		case 1:
			r.docs[id] = &Doc{ID: id, OwnerID: uidA, Status: string(StatusPending), UploadPath: "u/" + uidA + "/" + id + ".jpg", ThumbUploadPath: "u/" + uidA + "/" + id + "_t.jpg"}
			o.upload["u/"+uidA+"/"+id+".jpg"] = fakeObject{}
			o.upload["u/"+uidA+"/"+id+"_t.jpg"] = fakeObject{}
		default:
			r.docs[id] = &Doc{ID: id, OwnerID: uidA, Status: string(StatusRejected)}
		}
	}
	seedPublished(r, o, "0000000000000009000", uidB, "")

	p := NewPurger(r, o, "https://cdn.test/media")
	var cp Checkpoint
	var done bool
	var err error
	calls := 0
	for !done {
		calls++
		if calls > 10 {
			t.Fatal("purge does not converge")
		}
		cp, done, err = p.PurgeUser(context.Background(), uidA, cp)
		if err != nil {
			t.Fatal(err)
		}
	}
	if cp.Deleted != 250 || calls != 3 {
		t.Fatalf("deleted=%d calls=%d, want 250 in 3 pages of <= %d", cp.Deleted, calls, opsPage)
	}
	if len(r.docs) != 1 || r.docs["0000000000000009000"] == nil {
		t.Fatalf("docs left = %d: only Bob's may remain", len(r.docs))
	}
	if len(o.public) != 2 || len(o.upload) != 0 {
		t.Fatalf("objects left public=%d upload=%d: only Bob's two public objects may remain", len(o.public), len(o.upload))
	}
	// Re-running after completion is a cheap no-op.
	_, done, err = p.PurgeUser(context.Background(), uidA, cp)
	if err != nil || !done {
		t.Fatalf("rerun done=%v err=%v", done, err)
	}
}

func TestPurgeUser_ObjectsBeforeDocuments(t *testing.T) {
	r, o := newFakeRepo(), newFakeObjects()
	seedPublished(r, o, idM1, uidA, "")
	o.deletePub = fmt.Errorf("gcs 503")
	_, done, err := NewPurger(r, o, "").PurgeUser(context.Background(), uidA, Checkpoint{})
	if err == nil || done {
		t.Fatalf("done=%v err=%v: a failed object delete must fail the step", done, err)
	}
	if len(r.docs) != 1 {
		t.Fatal("the document is what finds the objects again: keep it until they are gone")
	}
}

func TestWriteSection_ExportsOnlyUserFacingFields(t *testing.T) {
	r, o := newFakeRepo(), newFakeObjects()
	seedPublished(r, o, idM1, uidA, postP)
	r.docs[idM2] = &Doc{ID: idM2, OwnerID: uidA, Purpose: string(PurposeAvatar), Status: string(StatusRejected), CreatedAt: time.Unix(1, 0),
		RejectionReason: "secret reason", FullMD5: "md5secret", UploadPath: "u/internal/path"}
	var buf bytes.Buffer
	if err := NewPurger(r, o, "https://cdn.test/media").WriteSection(context.Background(), uidA, &buf); err != nil {
		t.Fatal(err)
	}
	var out struct {
		Media []map[string]any `json:"media"`
	}
	if err := json.Unmarshal(buf.Bytes(), &out); err != nil {
		t.Fatalf("export is not valid JSON: %v\n%s", err, buf.String())
	}
	if len(out.Media) != 2 {
		t.Fatalf("media = %d", len(out.Media))
	}
	for _, s := range []string{"md5secret", "u/internal/path", "secret reason", "uploadPath", "ownerId"} {
		if strings.Contains(buf.String(), s) {
			t.Fatalf("export leaks %q: %s", s, buf.String())
		}
	}
	if !strings.Contains(buf.String(), "https://cdn.test/media/m/"+idM1+".jpg") {
		t.Fatalf("published image URL missing: %s", buf.String())
	}
	if (&Purger{}).Name() != "media" {
		t.Fatal("section name")
	}
	var empty bytes.Buffer
	if err := NewPurger(newFakeRepo(), o, "").WriteSection(context.Background(), uidB, &empty); err != nil || strings.TrimSpace(empty.String()) != `{"media":[]}` {
		t.Fatalf("empty export = %q err=%v", empty.String(), err)
	}
}
