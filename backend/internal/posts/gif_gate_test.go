package posts

import (
	"fmt"
	"testing"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	"github.com/dzeroth/dzeroth/backend/internal/media"
)

// W6-9 (ADR-0029 D10): the second FEATURE_GIF gate and the GIF-only rules of CreatePost and SchedulePost. The decision
// itself is made inside the transaction from the media claim (repo level, emulator test gif_integration_test.go); these
// tests pin how the service maps the repo's sentinels and what the handler passes down.

func TestCreate_GifSentinelsMapToTheDocumentedErrors(t *testing.T) {
	tests := []struct {
		name        string
		err         error
		wantCode    connect.Code
		wantReason  commonv1.ErrorReason
		wantFeature string
		wantField   string
	}{
		{"gif off for the caller", fmt.Errorf("wrapped: %w", ErrGifDisabled), connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED, "gif", ""},
		{"gif next to another image", ErrGifNotAlone, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, "", "media_ids"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := newCreateEnv()
			e.repo.createErr = tt.err
			_, _, err := e.create(CreateInput{IdempotencyKey: key1, Text: "x", MediaIDs: []string{mid1}, MediaEnabled: true})
			ae := wantAPIError(t, err, tt.wantCode, tt.wantReason)
			if ae.Metadata["feature"] != tt.wantFeature || ae.Metadata["field"] != tt.wantField {
				t.Fatalf("metadata = %v", ae.Metadata)
			}
		})
	}
}

func TestCreate_GifEnabledReachesTheRepo(t *testing.T) {
	for _, on := range []bool{false, true} {
		e := newCreateEnv()
		if _, _, err := e.create(CreateInput{IdempotencyKey: key1, Text: "x", MediaIDs: []string{mid1}, MediaEnabled: true, GifEnabled: on}); err != nil {
			t.Fatal(err)
		}
		if e.repo.lastCreate.GifEnabled != on {
			t.Errorf("GifEnabled = %v, want %v", e.repo.lastCreate.GifEnabled, on)
		}
	}
}

func TestSchedule_GifIsValidation(t *testing.T) {
	e := newSchedSvcEnv()
	e.repo.createErr = ErrGifNotSchedulable
	_, c, err := e.schedule(e.validIn(func(i *ScheduleInput) { i.MediaIDs = mediaIDs(1) }))
	ae := wantAPIError(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION)
	if ae.Metadata["field"] != "media_ids" || c.Writes() != 0 {
		t.Fatalf("metadata = %v writes=%d", ae.Metadata, c.Writes())
	}
}

// TestServer_CreatePostMapsTheGifFlag: the handler sets GifEnabled from the registry for the caller (FEATURE_GIF), never
// from the request, and with the same wire name media uses.
func TestServer_CreatePostMapsTheGifFlag(t *testing.T) {
	if GifFlagName != media.GifFlagName {
		t.Fatalf("posts.GifFlagName = %q, media.GifFlagName = %q", GifFlagName, media.GifFlagName)
	}
	tests := []struct {
		name   string
		flags  namedFlags
		wantOn bool
	}{
		{"off", namedFlags{"posts": true, "media": true}, false},
		{"on", namedFlags{"posts": true, "media": true, "gif": true}, true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			svc := &pollCaptureSvc{}
			srv := NewServer(svc, tt.flags)
			if _, err := srv.CreatePost(callerCtx("u1"), connect.NewRequest(&postsv1.CreatePostRequest{IdempotencyKey: key1, Text: "hi"})); err != nil {
				t.Fatal(err)
			}
			if svc.got.GifEnabled != tt.wantOn {
				t.Errorf("GifEnabled = %v, want %v", svc.got.GifEnabled, tt.wantOn)
			}
		})
	}
}

// TestMediaRef_ContentTypeSurvivesTheStoredShapeAndTheWire: copied from the claim into the stored media doc (omitted for a
// pre-W6 ref), back to the domain, into embeds and onto MediaRef.content_type.
func TestMediaRef_ContentTypeSurvivesTheStoredShapeAndTheWire(t *testing.T) {
	gif := MediaRef{ID: mid1, URL: "u.gif", ThumbURL: "t.jpg", Width: 10, Height: 20, ContentType: media.ContentTypeGIF}
	old := MediaRef{ID: mid2, URL: "u.jpg", ThumbURL: "t.jpg", Width: 10, Height: 20}
	p := &Post{ID: "1", Media: []MediaRef{gif, old}, Embedded: &Embedded{PostID: "2", Media: []MediaRef{gif}}}

	doc := toDoc(p)
	if doc.Media[0].ContentType != media.ContentTypeGIF || doc.Media[1].ContentType != "" || doc.Embedded.Media[0].ContentType != media.ContentTypeGIF {
		t.Fatalf("stored media = %+v / embedded %+v", doc.Media, doc.Embedded.Media)
	}
	back := doc.toPost("1")
	if back.Media[0] != gif || back.Media[1] != old || back.Embedded.Media[0] != gif {
		t.Fatalf("round trip = %+v / %+v", back.Media, back.Embedded.Media)
	}
	if snap := snapshotOf(p); snap.Media[0] != gif {
		t.Fatalf("snapshotOf lost the content type: %+v", snap.Media)
	}
	wire := mediaRefsToProto(p.Media)
	if wire[0].GetContentType() != media.ContentTypeGIF || wire[1].GetContentType() != "" {
		t.Fatalf("wire = %v", wire)
	}
	sched := mediaDocsToRefs(mediaRefsToDocs([]MediaRef{gif}))
	if sched[0] != gif {
		t.Fatalf("scheduled draft round trip = %+v", sched)
	}
}
