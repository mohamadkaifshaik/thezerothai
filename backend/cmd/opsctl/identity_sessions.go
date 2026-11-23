package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
)

const identitySessionsUsage = `  opsctl identity sessions clear-cut --project P --user U   (removes the account's session cut, users/{uid}.sessionsValidAfter,
                          after a lockout bug: sessions that signed in before it work again within 60 s on every server;
                          the global lever is FEATURE_DEVICE_SIGN_OUT=off)
                          WARNING: this lets EVERY session that signed in before the cut back in, the removed device's
                          (the thief's) included. Use it only for a confirmed lockout bug, and have the user redo the
                          removal afterwards. A REMOTE removal the client is still retrying may write the cut again;
                          turn device_sign_out globally off if that matters. The audit line goes to stdout only: paste
                          it into the incident record.
`

// sessionCutClearer is identity.FirestoreRepo's ClearSessionCut (the identity module owns users/{uid}; opsctl never writes
// the document itself).
type sessionCutClearer interface {
	ClearSessionCut(ctx context.Context, uid string) (time.Time, error)
}

// identityCommand is `opsctl identity sessions clear-cut --project P --user U` (removal-server design 3.4, Q12): the
// operator lever for one account locked out by a wrong session cut. It has its own flags (parsed here, before anything is
// opened or confirmed: a usage error is exit 2) and the usual typed confirmation for a -prod project. The write is
// identity's field-level delete of sessionsValidAfter in one transaction; a repeat writes nothing; a missing account is
// exit 1. The audit line is fixed-shape and NOTICE-labelled; it names the account only by the keyed uid_hash the API logs
// (CURSOR_HMAC_KEY), never the uid, and never prints the cut time. API instances keep serving the cut from their cached
// profile for up to 60 s.
func identityCommand(ctx context.Context, args []string, in io.Reader, out, errOut io.Writer, open opener, now func() time.Time) int {
	if len(args) < 2 || args[0] != "sessions" || args[1] != "clear-cut" {
		fmt.Fprintf(errOut, "usage:\n%s", identitySessionsUsage)
		return 2
	}
	fs := flag.NewFlagSet("identity sessions clear-cut", flag.ContinueOnError)
	fs.SetOutput(errOut)
	project := fs.String("project", "", "GCP project id (required)")
	user := fs.String("user", "", "the account's user id (required)")
	if err := fs.Parse(args[2:]); err != nil {
		return 2
	}
	switch {
	case fs.NArg() > 0:
		fmt.Fprintf(errOut, "unexpected argument %q\n%s", fs.Arg(0), identitySessionsUsage)
		return 2
	case *project == "":
		fmt.Fprintf(errOut, "--project is required (there is no default project)\n%s", identitySessionsUsage)
		return 2
	case !identity.ValidUserID(*user):
		fmt.Fprintf(errOut, "--user must be a valid user id\n%s", identitySessionsUsage)
		return 2
	}
	if isProd(*project) && !confirmed(in, out, *project) {
		fmt.Fprintln(errOut, "aborted: confirmation did not match")
		return 1
	}
	b, err := open(ctx, *project)
	if err != nil {
		fmt.Fprintf(errOut, "open backends: %v\n", err)
		return 1
	}
	defer b.close()
	if err := clearSessionCut(ctx, b, *project, *user, out, now); err != nil {
		fmt.Fprintln(errOut, err)
		return 1
	}
	return 0
}

func clearSessionCut(ctx context.Context, b *backends, project, uid string, out io.Writer, now func() time.Time) error {
	if b.sessionCuts == nil {
		return errors.New("identity sessions clear-cut: no session cut store configured")
	}
	cctx, cancel := context.WithTimeout(ctx, callTimeout)
	defer cancel()
	cleared, err := b.sessionCuts.ClearSessionCut(cctx, uid)
	switch {
	case errors.Is(err, identity.ErrNotFound):
		return errors.New("no such user (nothing written)")
	case err != nil:
		return err
	}
	hash := uidHashForAudit(uid)
	wrote := !cleared.IsZero()
	if wrote {
		fmt.Fprintf(out, "cleared: uid_hash=%s\nsessions that signed in before the cut work again within 60 s on every server (cached profiles expire)\n", hash)
	} else {
		fmt.Fprintf(out, "no session cut: uid_hash=%s; nothing written\n", hash)
	}
	fmt.Fprintf(out, "audit: NOTICE identity sessions clear-cut project=%s at=%s uid_hash=%s wrote=%t\n",
		project, now().UTC().Format(time.RFC3339), hash, wrote)
	return nil
}
