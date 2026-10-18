package main

import (
	"context"
	"fmt"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
)

// profileDirectory is the one identity.Directory method the notification actor sweep uses: GetProfiles, to repoint a
// collapsed row ("X and 3 others liked ...") at its newest remaining actor instead of deleting the whole row. The
// identity repo serves it; the embedded nil Directory makes any other method fail loudly (nil dereference in a
// command that never calls one) rather than silently doing nothing.
type profileDirectory struct {
	identity.Directory
	repo *identity.FirestoreRepo
}

func newProfileDirectory(repo *identity.FirestoreRepo) profileDirectory {
	return profileDirectory{repo: repo}
}

// GetProfiles implements identity.Directory for the sweep: one read per uid (no instance cache in opsctl).
func (d profileDirectory) GetProfiles(ctx context.Context, uids []string) (map[string]identity.Profile, error) {
	out, err := d.repo.GetProfiles(ctx, uids)
	if err != nil {
		return nil, fmt.Errorf("opsctl: profiles for the notification sweep: %w", err)
	}
	return out, nil
}
