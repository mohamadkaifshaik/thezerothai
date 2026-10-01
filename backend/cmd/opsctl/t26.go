package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"time"

	"cloud.google.com/go/firestore"
	firebase "firebase.google.com/go/v4"
	fbauth "firebase.google.com/go/v4/auth"
	"google.golang.org/api/iterator"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
)

const (
	// t26Timeout bounds the whole scan (Auth paging plus Firestore batches).
	t26Timeout = 10 * time.Minute
	// t26Batch is the GetAll batch size for the users/{uid} existence checks.
	t26Batch = 100
)

// authUser is the only per-user data the T26 scan keeps: the provider ids and the email-verified flag. The uid
// never reaches this type; the scan holds uids only in a batch slice, in memory, and never prints them.
type authUser struct {
	UID           string
	Providers     []string
	EmailVerified bool
}

// authLister streams every Firebase Auth user to fn (the Admin SDK ListUsers pager).
type authLister func(ctx context.Context, fn func(authUser) error) error

// usersExistFn returns how many of uids own a users/{uid} doc, reading each doc once (one GetAll batch).
type usersExistFn func(ctx context.Context, uids []string) (int, error)

// t26Result holds only aggregate counts.
type t26Result struct {
	Total, Allowed, NotAllowed, NotAllowedWithUsersDoc, FirestoreReads int
}

// pass reports the T26 verdict: no not-allowed account may own a users doc.
func (r t26Result) pass() bool { return r.NotAllowedWithUsersDoc == 0 }

// allowedAccount applies the ADR-0010 D5 A10 allowlist to an Auth user's provider list by reusing the single
// shared predicate authn.Claims.IdentityGate (anonymous is not allowed outside the emulator): any google.com or
// apple.com provider, or a password provider with a verified email.
func allowedAccount(u authUser) bool {
	for _, p := range u.Providers {
		c := authn.Claims{SignInProvider: p, EmailVerified: u.EmailVerified}
		if c.IdentityGate(false) == authn.GatePass {
			return true
		}
	}
	return false
}

// scanT26 classifies every Auth user and checks, in GetAll batches, which not-allowed ones own a users doc.
// It is read-only. Firestore reads equal the number of not-allowed users.
func scanT26(ctx context.Context, list authLister, exists usersExistFn) (t26Result, error) {
	var res t26Result
	var batch []string
	flush := func() error {
		if len(batch) == 0 {
			return nil
		}
		n, err := exists(ctx, batch)
		if err != nil {
			return err
		}
		res.NotAllowedWithUsersDoc += n
		res.FirestoreReads += len(batch)
		batch = batch[:0]
		return nil
	}
	err := list(ctx, func(u authUser) error {
		res.Total++
		if allowedAccount(u) {
			res.Allowed++
			return nil
		}
		res.NotAllowed++
		batch = append(batch, u.UID)
		if len(batch) >= t26Batch {
			return flush()
		}
		return nil
	})
	if err != nil {
		return t26Result{}, err
	}
	if err := flush(); err != nil {
		return t26Result{}, err
	}
	return res, nil
}

// checkT26 runs the scan and prints only aggregate counts and the verdict line. It returns an error on FAIL
// so the process exits non-zero.
func checkT26(ctx context.Context, b *backends, out io.Writer) error {
	ctx, cancel := context.WithTimeout(ctx, t26Timeout)
	defer cancel()
	res, err := scanT26(ctx, b.listAuthUsers, b.usersExist)
	if err != nil {
		return err
	}
	fmt.Fprintf(out, "total=%d\nallowed=%d\nnot_allowed=%d\nnot_allowed_with_users_doc=%d\nfirestore_reads=%d\n",
		res.Total, res.Allowed, res.NotAllowed, res.NotAllowedWithUsersDoc, res.FirestoreReads)
	if !res.pass() {
		fmt.Fprintln(out, "T26: FAIL")
		return errors.New("T26 precondition failed")
	}
	fmt.Fprintln(out, "T26: PASS")
	return nil
}

// newAuthLister lists Auth users through the Admin SDK (ADC, or FIREBASE_AUTH_EMULATOR_HOST); in memory only.
func newAuthLister(ctx context.Context, project string) (authLister, error) {
	app, err := firebase.NewApp(ctx, &firebase.Config{ProjectID: project})
	if err != nil {
		return nil, fmt.Errorf("init firebase app: %w", err)
	}
	client, err := app.Auth(ctx)
	if err != nil {
		return nil, fmt.Errorf("init firebase auth client: %w", err)
	}
	return func(ctx context.Context, fn func(authUser) error) error {
		it := client.Users(ctx, "")
		for {
			rec, err := it.Next()
			if errors.Is(err, iterator.Done) {
				return nil
			}
			if err != nil {
				return fmt.Errorf("list auth users: %w", err)
			}
			if err := fn(toAuthUser(rec.UserRecord)); err != nil {
				return err
			}
		}
	}, nil
}

func toAuthUser(r *fbauth.UserRecord) authUser {
	u := authUser{UID: r.UID, EmailVerified: r.EmailVerified}
	for _, p := range r.ProviderUserInfo {
		u.Providers = append(u.Providers, p.ProviderID)
	}
	return u
}

// newUsersExist counts existing users/{uid} docs with one batched GetAll per call (1 read per uid).
func newUsersExist(client *firestore.Client) usersExistFn {
	return func(ctx context.Context, uids []string) (int, error) {
		refs := make([]*firestore.DocumentRef, len(uids))
		for i, uid := range uids {
			refs[i] = client.Collection("users").Doc(uid)
		}
		snaps, err := client.GetAll(ctx, refs)
		if err != nil {
			return 0, fmt.Errorf("users existence check: %w", err)
		}
		n := 0
		for _, s := range snaps {
			if s.Exists() {
				n++
			}
		}
		return n, nil
	}
}
