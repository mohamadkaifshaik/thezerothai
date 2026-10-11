// media_wiring.go composes the media module (P4, ADR-0005): the Connect server, the post_delete job, the account
// Eraser/exporter and the library posts and identity consume. Consumer-side adapters live here (the BlockChecker
// pattern, ADR-0002): media does not import identity or posts.
package apiserver

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"time"

	"cloud.google.com/go/firestore"

	mediav1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/media/v1/mediav1connect"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/internal/media"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/degraded"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/quota"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/snowflake"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// mediaModule is everything Build needs from the media composition.
type mediaModule struct {
	server  *media.Server
	library *media.Library
	purger  *media.Purger
	jobs    *media.Jobs
}

// mediaProcedures is the DEGRADED_MODE=nomedia block list: every procedure that creates or publishes media.
func mediaProcedures() degraded.ProcedureSet {
	return degraded.NewProcedureSet(
		mediav1connect.MediaServiceCreateUploadProcedure,
		mediav1connect.MediaServiceFinalizeUploadProcedure,
	)
}

// lateAccountDirectory is identity.Directory bound after identity is built: media is constructed first (identity and
// posts consume its library), and media needs the directory only per request. Set once at startup, before
// ListenAndServe, and never again.
type lateAccountDirectory struct{ d identity.Directory }

// directoryAge adapts identity.Directory to media.Directory.
type directoryAge struct{ d *lateAccountDirectory }

func (a directoryAge) AccountCreatedAt(ctx context.Context, uid string) (time.Time, error) {
	if a.d.d == nil {
		return time.Time{}, errors.New("account directory is not wired")
	}
	profiles, err := a.d.d.GetProfiles(ctx, []string{uid})
	if err != nil {
		return time.Time{}, err
	}
	p, ok := profiles[uid]
	if !ok {
		return time.Time{}, errors.New("account has no active profile")
	}
	return p.CreatedAt, nil
}

// postGone adapts the posts repo to media.PostGone: a fresh read that bypasses every cache (1 read).
type postGone struct{ repo *posts.FirestoreRepo }

func (p postGone) PostGone(ctx context.Context, postID string) (bool, error) {
	got, err := p.repo.GetAll(ctx, []string{postID})
	if err != nil {
		return false, err
	}
	_, exists := got[postID]
	return !exists, nil
}

// wireMedia builds the media module. Nothing here does I/O: the GCS, Vision and Pub/Sub clients are lazy.
func wireMedia(cfg config.Config, log *slog.Logger, fs *firestore.Client, featureFlags *flags.Registry,
	dir *lateAccountDirectory, postsRepo *posts.FirestoreRepo, node *snowflake.Node, publisher media.JobPublisher) (*mediaModule, error) {
	buckets, err := media.NewBuckets(cfg.MediaUploadBucket, cfg.MediaBucket)
	if err != nil {
		return nil, fmt.Errorf("media buckets: %w", err)
	}
	var moderator media.Moderator = media.AllowAll{}
	if cfg.Env != "local" {
		moderator, err = media.NewVision(cfg.MediaUploadBucket)
		if err != nil {
			return nil, fmt.Errorf("media moderator: %w", err)
		}
	}
	repo := media.NewFirestoreRepo(fs, media.WriteDeps{Idempotency: idempotency.New(fs), Quotas: quota.New(fs)})
	svc, err := media.New(media.Deps{
		Repo: repo, Signer: buckets, Objects: buckets, Moderator: moderator,
		Directory: directoryAge{dir}, IDs: node, PublicBaseURL: cfg.MediaPublicBaseURL,
		MediaPerDay: int64(cfg.Quota.MediaPerDay), NewAccountMediaPerDay: int64(cfg.Quota.NewAccountMediaPerDay),
		NewAccountWindow: cfg.Quota.NewAccountWindow,
		VisionMonthlyCap: int64(cfg.VisionMonthlyCap), Policy: cfg.VisionExhaustedPolicy, ScreenThumb: cfg.VisionScreenThumb,
		Log: log,
	})
	if err != nil {
		return nil, fmt.Errorf("media service: %w", err)
	}
	return &mediaModule{
		server:  media.NewServer(svc, featureFlags),
		library: media.NewLibrary(repo, cfg.MediaPublicBaseURL),
		purger:  media.NewPurger(repo, buckets, cfg.MediaPublicBaseURL),
		jobs:    media.NewJobs(repo, buckets, postGone{postsRepo}, publisher),
	}, nil
}

// avatarResolver adapts media.Reader to identity.AvatarResolver and applies FEATURE_MEDIA: with the flag off an
// avatar id is "not ready" like any other unusable id (one answer).
type avatarResolver struct {
	lib   media.Reader
	flags *flags.Registry
}

func (a avatarResolver) ResolveAvatar(ctx context.Context, uid, mediaID string) (identity.AvatarRef, error) {
	if !a.flags.Enabled(uid, media.FlagName) {
		return identity.AvatarRef{}, identity.ErrAvatarNotReady
	}
	ref, err := a.lib.ResolveAvatar(ctx, uid, mediaID)
	switch {
	case media.IsNotReady(err):
		return identity.AvatarRef{}, identity.ErrAvatarNotReady
	case err != nil:
		return identity.AvatarRef{}, err
	}
	return identity.AvatarRef{URL: ref.URL, ThumbURL: ref.ThumbURL}, nil
}

// postsMediaAttacher adapts media.Attacher to posts.MediaAttacher.
type postsMediaAttacher struct{ lib media.Attacher }

func (a postsMediaAttacher) LoadForPost(ctx context.Context, tx *firestore.Transaction, uid string, ids []string) (posts.MediaClaim, error) {
	c, err := a.lib.LoadForPost(ctx, tx, uid, ids)
	switch {
	case media.IsNotReady(err):
		return nil, posts.ErrMediaNotReady
	case err != nil:
		return nil, err
	}
	return postsMediaClaim{c}, nil
}

type postsMediaClaim struct{ c *media.Claim }

func (m postsMediaClaim) Refs() []posts.MediaRef {
	out := make([]posts.MediaRef, len(m.c.Refs))
	for i, r := range m.c.Refs {
		out[i] = posts.MediaRef{ID: r.ID, URL: r.URL, ThumbURL: r.ThumbURL, Width: r.Width, Height: r.Height, Blurhash: r.Blurhash}
	}
	return out
}

func (m postsMediaClaim) Attach(b store.Batch, postID string) { m.c.Attach(b, postID) }
