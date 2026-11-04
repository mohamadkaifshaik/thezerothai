//go:build integration

package posts

import (
	"context"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
)

// TestGIF_Integration_CreatePostGates: the content type rides on the media claim, so the gif gate
// writes nothing; an allowed single GIF is stored with its content type and copies it to the
// wire; a GIF next to a photo is VALIDATION.
func TestGIF_Integration_CreatePostGates(t *testing.T) {
	client := newTestClient(t)
	in := newCreateInstance(t, client, time.Nanosecond)
	in.repo.w.Media = &sweepMedia{client: client}
	in.signUp(t, "uid-alice", "alice")
	ctx0 := context.Background()
	if _, err := in.svc.directory.GetProfiles(ctx0, []string{"uid-alice"}); err != nil {
		t.Fatal(err)
	}
	seed := func(n int, contentType string) string {
		id := sweepMediaID(n)
		if _, err := client.Collection("media").Doc(id).Set(ctx0, map[string]any{
			"ownerId": "uid-alice", "status": "READY", "contentType": contentType,
		}); err != nil {
			t.Fatal(err)
		}
		return id
	}
	gif1, gif2, photo := seed(1, "image/gif"), seed(2, "image/gif"), seed(3, "image/jpeg")

	create := func(n int, ids []string, gifOn bool) (*Post, error) {
		return in.svc.Create(googleCtx(ctx0, "uid-alice"), "uid-alice", CreateInput{
			IdempotencyKey: key(n), Text: "gif", MediaIDs: ids, MediaEnabled: true, GifEnabled: gifOn,
		})
	}

	t.Run("gif off: FEATURE_DISABLED and nothing written", func(t *testing.T) {
		_, err := create(1, []string{gif1}, false)
		ae := wantAPIError(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED)
		if ae.Metadata["feature"] != "gif" || countDocs(t, client, postsCollection) != 0 {
			t.Fatalf("feature=%q posts=%d, want gif and no post written", ae.Metadata["feature"], countDocs(t, client, postsCollection))
		}
	})
	t.Run("gif next to a photo: VALIDATION media_ids and nothing written", func(t *testing.T) {
		_, err := create(2, []string{gif2, photo}, true)
		ae := wantAPIError(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION)
		if ae.Metadata["field"] != "media_ids" || countDocs(t, client, postsCollection) != 0 {
			t.Fatalf("field=%q posts=%d, want media_ids and no post written", ae.Metadata["field"], countDocs(t, client, postsCollection))
		}
	})
	t.Run("a single gif with the flag on is stored with its content type", func(t *testing.T) {
		p, err := create(3, []string{gif1}, true)
		if err != nil {
			t.Fatal(err)
		}
		if len(p.Media) != 1 || p.Media[0].ContentType != "image/gif" {
			t.Fatalf("returned media = %+v", p.Media)
		}
		got, err := in.repo.GetAll(ctx0, []string{p.ID})
		if err != nil || got[p.ID] == nil || len(got[p.ID].Media) != 1 || got[p.ID].Media[0].ContentType != "image/gif" {
			t.Fatalf("stored media = %+v err=%v", got[p.ID], err)
		}
		if w := ToProto(got[p.ID]).GetMedia()[0].GetContentType(); w != "image/gif" {
			t.Fatalf("wire content_type = %q", w)
		}
	})
	t.Run("a photo stays valid with the flag off", func(t *testing.T) {
		if _, err := create(4, []string{photo}, false); err != nil {
			t.Fatal(err)
		}
	})
}
