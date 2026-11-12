package main

import (
	"context"
	"errors"
	"fmt"
	"io"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/internal/media"
)

const (
	// purgeBannersPage is one page of either phase (media documents of purpose BANNER, users documents by id).
	purgeBannersPage = 100
	// purgeBannersMaxPages bounds one phase of one run; a run that reaches it says so and a rerun continues (both phases
	// are idempotent: erased documents are not found again).
	purgeBannersMaxPages = 1000
)

// legacyBannerMedia is *media.LegacyBannerPurger.
type legacyBannerMedia interface {
	PurgeLegacyBanners(ctx context.Context, after string, limit int, dryRun bool) (media.LegacyBannerPage, error)
}

// legacyBannerProfiles is *identity.FirestoreRepo's ClearLegacyBannerFields.
type legacyBannerProfiles interface {
	ClearLegacyBannerFields(ctx context.Context, after string, limit int, dryRun bool) (identity.LegacyBannerFieldsPage, error)
}

// purgeBanners is `opsctl purge-banners`: the one-off clean-up of the removed profile banner in a project. It is a dry
// run unless --apply is given. Phase 1 erases every media document of the stored purpose BANNER (any status) with every
// object it may own (objects first, then the document). Phase 2 deletes bannerUrl and bannerThumbUrl from every users
// document that still holds them (a field-level update; nothing else on the document moves). Run it after the API
// revision without banners serves all traffic in the project, so no new banner can appear behind it. Both phases are
// idempotent: a rerun finds nothing it already erased, so an interrupted or failed run is simply run again.
//
// Until it has run, account deletion still erases a legacy banner: the media eraser deletes every document of the owner
// whatever its purpose, and users/{uid} is deleted whole. Remove the command once it has run in every environment.
func purgeBanners(ctx context.Context, b *backends, project string, apply bool, out io.Writer) error {
	if b.bannerMedia == nil || b.bannerProfiles == nil {
		return errors.New("purge-banners: no media or identity repo configured")
	}
	dryRun := !apply
	fmt.Fprintf(out, "purge-banners: project=%s dry-run=%t\n", project, dryRun)

	var found, deleted int
	after := ""
	for pages := 0; ; pages++ {
		if pages == purgeBannersMaxPages {
			fmt.Fprintf(out, "media: page limit of %d reached: rerun to continue\n", purgeBannersMaxPages)
			break
		}
		if err := ctx.Err(); err != nil {
			return fmt.Errorf("media phase interrupted (rerun; nothing is lost): %w", err)
		}
		pctx, cancel := context.WithTimeout(ctx, callTimeout)
		p, err := b.bannerMedia.PurgeLegacyBanners(pctx, after, purgeBannersPage, dryRun)
		cancel()
		found, deleted = found+p.Found, deleted+p.Deleted
		if err != nil {
			return fmt.Errorf("media phase: %w (rerun; erased documents are not found again)", err)
		}
		fmt.Fprintf(out, "media: page found=%d deleted=%d\n", p.Found, p.Deleted)
		if p.Found < purgeBannersPage {
			break
		}
		if dryRun {
			after = p.Last // nothing was deleted: page past what was listed
		}
	}

	var scanned, holding, cleared, gone int
	after = ""
	for pages := 0; ; pages++ {
		if pages == purgeBannersMaxPages {
			fmt.Fprintf(out, "users: page limit of %d reached: rerun to continue\n", purgeBannersMaxPages)
			break
		}
		if err := ctx.Err(); err != nil {
			return fmt.Errorf("users phase interrupted (rerun; nothing is lost): %w", err)
		}
		pctx, cancel := context.WithTimeout(ctx, callTimeout)
		p, err := b.bannerProfiles.ClearLegacyBannerFields(pctx, after, purgeBannersPage, dryRun)
		cancel()
		scanned, holding, cleared, gone = scanned+p.Scanned, holding+p.Found, cleared+p.Cleared, gone+p.Gone
		if err != nil {
			return fmt.Errorf("users phase: %w (rerun; cleared documents are skipped)", err)
		}
		if p.Scanned < purgeBannersPage {
			break
		}
		after = p.Last
	}

	if dryRun {
		fmt.Fprintf(out, "dry-run: media documents to erase=%d, users documents to clear=%d of %d scanned (nothing written; pass --apply)\n",
			found, holding, scanned)
		return nil
	}
	fmt.Fprintf(out, "purge-banners: complete: media documents erased=%d (objects first), users documents cleared=%d of %d scanned (%d gone meanwhile)\n",
		deleted, cleared, scanned, gone)
	return nil
}
