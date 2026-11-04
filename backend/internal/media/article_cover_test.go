package media

import (
	"testing"
	"time"
)

func TestArticleCoverRequiresOwnedReadyUnclaimedStillImage(t *testing.T) {
	base := Doc{OwnerID: "alice", Purpose: string(PurposePost), Status: string(StatusReady), ContentType: ContentTypeJPEG}
	if !usablePostCover(&base, "alice") {
		t.Fatal("owned ready still cover refused")
	}
	for _, change := range []func(*Doc){func(d *Doc) { d.OwnerID = "bob" }, func(d *Doc) { d.Purpose = string(PurposeAvatar) }, func(d *Doc) { d.Status = string(StatusPending) }, func(d *Doc) { d.PostID = "already-used" }, func(d *Doc) { d.ContentType = ContentTypeGIF }, func(d *Doc) { now := time.Now(); d.RetiredAt = &now }} {
		d := base
		change(&d)
		if usablePostCover(&d, "alice") {
			t.Fatalf("accepted unusable cover: %#v", d)
		}
	}
	if usablePostCover(nil, "alice") {
		t.Fatal("accepted absent image")
	}
}
