// server.go is the thin Connect handler for MediaService: extract the caller's uid, check FEATURE_MEDIA, convert
// proto <-> domain, call Service. No business logic and no Firestore here (handlers stay thin; errors are mapped to
// Connect codes by pkg/platform/mw.ErrorMapping).
package media

import (
	"context"
	"time"

	"connectrpc.com/connect"
	"google.golang.org/protobuf/types/known/timestamppb"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	mediav1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/media/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/media/v1/mediav1connect"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

const (
	// createDeadline bounds CreateUpload (one transaction plus local signing).
	createDeadline = 8 * time.Second
	// finalizeDeadline bounds FinalizeUpload: up to 4 images, each 4 object reads, 2 Vision calls and 2 copies,
	// run concurrently; inside Cloud Run's 30 s request timeout.
	finalizeDeadline = 20 * time.Second
)

// Server adapts Service to mediav1connect.MediaServiceHandler.
type Server struct {
	svc   Service
	flags FlagChecker
}

// NewServer builds the Connect handler. Use with mediav1connect.NewMediaServiceHandler.
func NewServer(svc Service, fc FlagChecker) *Server { return &Server{svc: svc, flags: fc} }

var _ mediav1connect.MediaServiceHandler = (*Server)(nil)

// guard is the FEATURE_MEDIA check, before any other work (0 reads).
func (s *Server) guard(ctx context.Context) (string, error) {
	uid, ok := authn.UIDFromContext(ctx)
	if !ok || uid == "" {
		return "", apierr.New(connect.CodeUnauthenticated, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "unauthenticated")
	}
	var enabled func(uid, name string) bool
	if s.flags != nil {
		enabled = s.flags.Enabled
	}
	if err := flags.Guard(ctx, enabled, uid, FlagName); err != nil {
		return "", err
	}
	return uid, nil
}

// CreateUpload implements mediav1connect.MediaServiceHandler.
func (s *Server) CreateUpload(ctx context.Context, req *connect.Request[mediav1.CreateUploadRequest]) (*connect.Response[mediav1.CreateUploadResponse], error) {
	uid, err := s.guard(ctx)
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithTimeout(ctx, createDeadline)
	defer cancel()
	m := req.Msg
	in := CreateUploadInput{IdempotencyKey: m.GetIdempotencyKey(), Purpose: purposeFromProto(m.GetPurpose())}
	for _, it := range m.GetItems() {
		in.Items = append(in.Items, UploadItem{
			ContentType: it.GetContentType(), FullBytes: it.GetFullSizeBytes(), ThumbBytes: it.GetThumbSizeBytes(),
			Width: int(it.GetWidth()), Height: int(it.GetHeight()), FullMD5: it.GetFullMd5(), ThumbMD5: it.GetThumbMd5(),
		})
	}
	targets, err := s.svc.CreateUpload(ctx, uid, in)
	if err != nil {
		return nil, err
	}
	out := &mediav1.CreateUploadResponse{Targets: make([]*mediav1.UploadTarget, len(targets))}
	for i, t := range targets {
		out.Targets[i] = &mediav1.UploadTarget{MediaId: t.MediaID, Full: signedToProto(t.Full), Thumb: signedToProto(t.Thumb)}
	}
	return connect.NewResponse(out), nil
}

// FinalizeUpload implements mediav1connect.MediaServiceHandler.
func (s *Server) FinalizeUpload(ctx context.Context, req *connect.Request[mediav1.FinalizeUploadRequest]) (*connect.Response[mediav1.FinalizeUploadResponse], error) {
	uid, err := s.guard(ctx)
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithTimeout(ctx, finalizeDeadline)
	defer cancel()
	m := req.Msg
	if err := idemKeyIssue(m.GetIdempotencyKey()); err != nil {
		return nil, err
	}
	items := make([]FinalizeItem, 0, len(m.GetItems()))
	for _, it := range m.GetItems() {
		items = append(items, FinalizeItem{MediaID: it.GetMediaId(), Blurhash: it.GetBlurhash()})
	}
	results, err := s.svc.FinalizeUpload(ctx, uid, items)
	if err != nil {
		return nil, err
	}
	out := &mediav1.FinalizeUploadResponse{Results: make([]*mediav1.MediaResult, len(results))}
	for i, r := range results {
		mr := &mediav1.MediaResult{MediaId: r.MediaID, Status: statusToProto(r.Status), RejectionReason: r.RejectionReason}
		if r.Ref != nil {
			mr.Media = RefToProto(*r.Ref)
		}
		out.Results[i] = mr
	}
	return connect.NewResponse(out), nil
}

// RefToProto converts a published image to common.v1.MediaRef (alt text is the caller's to set).
func RefToProto(r Ref) *commonv1.MediaRef {
	return &commonv1.MediaRef{
		MediaId: r.ID, Url: r.URL, ThumbUrl: r.ThumbURL,
		Width: int32(r.Width), Height: int32(r.Height), Blurhash: r.Blurhash, //nolint:gosec // validated <= MaxDimension (4096) at CreateUpload
	}
}

func signedToProto(p SignedPut) *mediav1.SignedUpload {
	return &mediav1.SignedUpload{Url: p.URL, Method: "PUT", Headers: p.Headers, ExpiresAt: timestamppb.New(p.ExpiresAt)}
}

func purposeFromProto(p mediav1.MediaPurpose) Purpose {
	switch p {
	case mediav1.MediaPurpose_MEDIA_PURPOSE_POST:
		return PurposePost
	case mediav1.MediaPurpose_MEDIA_PURPOSE_AVATAR:
		return PurposeAvatar
	default:
		return ""
	}
}

func statusToProto(s Status) mediav1.MediaStatus {
	switch s {
	case StatusPending:
		return mediav1.MediaStatus_MEDIA_STATUS_PENDING
	case StatusReady:
		return mediav1.MediaStatus_MEDIA_STATUS_READY
	case StatusReadyUnscreened:
		return mediav1.MediaStatus_MEDIA_STATUS_READY_UNSCREENED
	case StatusRejected:
		return mediav1.MediaStatus_MEDIA_STATUS_REJECTED
	default:
		return mediav1.MediaStatus_MEDIA_STATUS_UNSPECIFIED
	}
}
