package main

import (
	"context"
	"errors"
	"fmt"
	"io"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// publicIDUsage documents `opsctl public-id`.
const publicIDUsage = `  opsctl public-id --project P (--uid UID | --id PUBLIC_ID)
                          (read-only support lookup of one account's uid <-> public id pair. The public id is
                          the only id that may be shared outside the team (a ticket reply, a message to the user); the
                          uid stays internal. The pair is printed to stdout only, never logged; errors are redacted. Reads
                          users/{uid} and publicIds/{id} (at most 2 reads) and reports whether they agree: --uid prints
                          lookup=ok|missing|other-account, --id prints account_public_id=match|mismatch|none, never the uid
                          of another account. Works whatever FEATURE_PUBLIC_IDS says; a production project asks for the
                          typed project id first)
`

// publicIDStore is the identity repo's two reads (*identity.FirestoreRepo): never the flag-gated service, which answers
// empty while public_ids is globally off.
type publicIDStore interface {
	GetProfile(ctx context.Context, uid string) (identity.Profile, error)
	ResolvePublicIDs(ctx context.Context, publicIDs []string) (map[string]string, error)
}

// parsePublicIDArgs validates a public-id invocation before anything is opened or confirmed. A public id also matches
// the uid character set, so --uid tests the public-id shape first.
func parsePublicIDArgs(uid, publicID string) error {
	if (uid == "") == (publicID == "") {
		return errors.New("public-id needs exactly one of --uid or --id")
	}
	if uid != "" {
		if identity.ValidPublicID(uid) {
			return errors.New("--uid is a public id: use --id")
		}
		if !identity.ValidUserID(uid) {
			return errors.New("--uid is not a valid user id")
		}
		return nil
	}
	if !identity.ValidPublicID(publicID) {
		return errors.New("--id is not a well-formed public id (u + 26 lowercase base32 characters)")
	}
	return nil
}

// publicIDLookup is `opsctl public-id`: one pair, printed to out. Every error is redacted of both ids (Firestore's text
// names the document path) before run prints it.
func publicIDLookup(ctx context.Context, st publicIDStore, uid, publicID string, out io.Writer) error {
	cctx, cancel := context.WithTimeout(ctx, callTimeout)
	defer cancel()
	var err error
	if uid != "" {
		err = lookupByUID(cctx, st, uid, out)
	} else {
		err = lookupByPublicID(cctx, st, publicID, out)
	}
	return logger.RedactErr(err, uid, publicID)
}

func lookupByUID(ctx context.Context, st publicIDStore, uid string, out io.Writer) error {
	p, err := st.GetProfile(ctx, uid)
	if errors.Is(err, identity.ErrNotFound) {
		fmt.Fprintf(out, "uid=%s\naccount=none\n", uid)
		return nil
	}
	if err != nil {
		return fmt.Errorf("read the account: %w", err)
	}
	if p.PublicID == "" {
		fmt.Fprintf(out, "uid=%s\npublic_id=none\nstatus=%s\n", uid, statusName(p.Status))
		return nil
	}
	owners, err := st.ResolvePublicIDs(ctx, []string{p.PublicID})
	if err != nil {
		return logger.RedactErr(fmt.Errorf("read the lookup: %w", err), p.PublicID)
	}
	lookup := "ok"
	switch owner, ok := owners[p.PublicID]; {
	case !ok:
		lookup = "missing" // opsctl backfill-public-ids re-creates it
	case owner != uid:
		lookup = "other-account" // reported, never named
	}
	fmt.Fprintf(out, "uid=%s\npublic_id=%s\nlookup=%s\nstatus=%s\n", uid, p.PublicID, lookup, statusName(p.Status))
	return nil
}

func lookupByPublicID(ctx context.Context, st publicIDStore, publicID string, out io.Writer) error {
	owners, err := st.ResolvePublicIDs(ctx, []string{publicID})
	if err != nil {
		return fmt.Errorf("read the lookup: %w", err)
	}
	uid, ok := owners[publicID]
	if !ok {
		fmt.Fprintf(out, "public_id=%s\nuid=none\n", publicID)
		return nil
	}
	p, err := st.GetProfile(ctx, uid)
	if errors.Is(err, identity.ErrNotFound) {
		fmt.Fprintf(out, "public_id=%s\nuid=%s\naccount=none\n", publicID, uid)
		return nil
	}
	if err != nil {
		return logger.RedactErr(fmt.Errorf("read the account: %w", err), uid)
	}
	match := "match"
	switch {
	case p.PublicID == "":
		match = "none"
	case p.PublicID != publicID:
		match = "mismatch" // the account's own id is not printed
	}
	fmt.Fprintf(out, "public_id=%s\nuid=%s\naccount_public_id=%s\nstatus=%s\n", publicID, uid, match, statusName(p.Status))
	return nil
}
