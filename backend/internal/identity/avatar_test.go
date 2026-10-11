package identity

import (
	"context"
	"errors"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
)

type fakeAvatars struct {
	ref   AvatarRef
	err   error
	calls []string
}

func (f *fakeAvatars) ResolveAvatar(_ context.Context, uid, mediaID string) (AvatarRef, error) {
	f.calls = append(f.calls, uid+"/"+mediaID)
	return f.ref, f.err
}

func TestUpdateProfile_Avatar(t *testing.T) {
	const mediaID = "0000000000000000201"
	tests := []struct {
		name      string
		avatars   *fakeAvatars // nil: no resolver wired
		wantURL   string
		wantErr   bool
		wantCalls int
	}{
		{"resolved avatar is copied into the profile", &fakeAvatars{ref: AvatarRef{URL: "https://m/a.webp", ThumbURL: "https://m/a_t.webp"}}, "https://m/a.webp", false, 1},
		{"not ready is MEDIA_NOT_READY", &fakeAvatars{err: ErrAvatarNotReady}, "", true, 1},
		{"no resolver wired is MEDIA_NOT_READY", nil, "", true, 0},
		{"infrastructure error is not an apierr", &fakeAvatars{err: errors.New("firestore down")}, "", true, 1},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			repo := newFakeRepo()
			var opts []Option
			if tt.avatars != nil {
				opts = append(opts, WithAvatarResolver(tt.avatars))
			}
			svc := New(repo, NewCache(time.Minute), 7*24*time.Hour, opts...).(*service)
			if _, err := svc.CreateProfile(context.Background(), "uid-1", validKey, "Alice", "Alice A."); err != nil {
				t.Fatal(err)
			}
			id := mediaID
			got, err := svc.UpdateProfile(context.Background(), "uid-1", UpdateProfileParams{IdempotencyKey: validKey, AvatarMediaID: &id})
			if (err != nil) != tt.wantErr {
				t.Fatalf("err = %v, wantErr %v", err, tt.wantErr)
			}
			if tt.avatars != nil && len(tt.avatars.calls) != tt.wantCalls {
				t.Fatalf("resolver calls = %v", tt.avatars.calls)
			}
			if tt.avatars != nil && len(tt.avatars.calls) == 1 && tt.avatars.calls[0] != "uid-1/"+mediaID {
				t.Fatalf("resolver asked %q: it must be asked for the caller's own uid", tt.avatars.calls[0])
			}
			if err != nil {
				var ae *apierr.Error
				if errors.As(err, &ae) {
					if ae.Code != connect.CodeFailedPrecondition || ae.Reason != commonv1.ErrorReason_ERROR_REASON_MEDIA_NOT_READY {
						t.Fatalf("code=%v reason=%v", ae.Code, ae.Reason)
					}
				}
				if repo.updateCalls != 0 {
					t.Fatalf("updateCalls = %d: a rejected avatar must write nothing", repo.updateCalls)
				}
				return
			}
			if got.AvatarURL != tt.wantURL || got.AvatarThumbURL != "https://m/a_t.webp" {
				t.Fatalf("profile avatar = %q / %q", got.AvatarURL, got.AvatarThumbURL)
			}
		})
	}
}
