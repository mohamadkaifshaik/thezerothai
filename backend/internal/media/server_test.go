package media

import (
	"context"
	"testing"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	mediav1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/media/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
)

func authedCtx(uid string) context.Context {
	return authn.WithClaims(context.Background(), authn.Claims{UID: uid, SignInProvider: authn.SignInProviderGoogle})
}

func TestServer_FlagOffIsFeatureDisabledBeforeAnyWork(t *testing.T) {
	for _, flags := range []FlagChecker{nil, fakeFlags{FlagName: false}} {
		e := newEnv(t, envOpts{})
		s := NewServer(e.svc, flags)
		_, err := s.CreateUpload(authedCtx(uidA), connect.NewRequest(&mediav1.CreateUploadRequest{IdempotencyKey: key1}))
		_ = wantAPI(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED)
		_, err = s.FinalizeUpload(authedCtx(uidA), connect.NewRequest(&mediav1.FinalizeUploadRequest{IdempotencyKey: key1}))
		_ = wantAPI(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED)
		if len(e.repo.docs) != 0 || e.sign.calls != 0 {
			t.Fatal("a disabled flag must do no work")
		}
	}
}

func TestServer_NoCallerIsUnauthenticated(t *testing.T) {
	e := newEnv(t, envOpts{})
	s := NewServer(e.svc, fakeFlags{FlagName: true})
	_, err := s.CreateUpload(context.Background(), connect.NewRequest(&mediav1.CreateUploadRequest{}))
	_ = wantAPI(t, err, connect.CodeUnauthenticated, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED)
}

func TestServer_EndToEndConversion(t *testing.T) {
	e := newEnv(t, envOpts{})
	s := NewServer(e.svc, fakeFlags{FlagName: true})
	full, thumb := jpegBytes("F"), jpegBytes("T")
	resp, err := s.CreateUpload(authedCtx(uidA), connect.NewRequest(&mediav1.CreateUploadRequest{
		IdempotencyKey: key1, Purpose: mediav1.MediaPurpose_MEDIA_PURPOSE_AVATAR,
		Items: []*mediav1.UploadItem{{
			ContentType: "image/jpeg", FullSizeBytes: int64(len(full)), ThumbSizeBytes: int64(len(thumb)), Width: 400, Height: 400,
			FullMd5: md5b64(full), ThumbMd5: md5b64(thumb),
		}},
	}))
	if err != nil {
		t.Fatal(err)
	}
	tg := resp.Msg.GetTargets()[0]
	if tg.GetFull().GetMethod() != "PUT" || tg.GetFull().GetHeaders()["Content-MD5"] != md5b64(full) || tg.GetThumb().GetExpiresAt() == nil {
		t.Fatalf("target = %v", tg)
	}
	if e.repo.docs[tg.GetMediaId()].Purpose != string(PurposeAvatar) {
		t.Fatal("purpose not converted")
	}
	e.put(uidA, UploadTarget{MediaID: tg.GetMediaId()}, full, thumb, "image/jpeg")
	fin, err := s.FinalizeUpload(authedCtx(uidA), connect.NewRequest(&mediav1.FinalizeUploadRequest{
		IdempotencyKey: key2, Items: []*mediav1.FinalizeItem{{MediaId: tg.GetMediaId(), Blurhash: "LEHV6n"}},
	}))
	if err != nil {
		t.Fatal(err)
	}
	r := fin.Msg.GetResults()[0]
	if r.GetStatus() != mediav1.MediaStatus_MEDIA_STATUS_READY || r.GetMedia().GetThumbUrl() == "" || r.GetMedia().GetBlurhash() != "LEHV6n" {
		t.Fatalf("result = %v", r)
	}
	// Finalize needs a valid idempotency key shape like every mutation.
	_, err = s.FinalizeUpload(authedCtx(uidA), connect.NewRequest(&mediav1.FinalizeUploadRequest{IdempotencyKey: "x", Items: []*mediav1.FinalizeItem{{MediaId: tg.GetMediaId()}}}))
	_ = wantAPI(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION)
}
