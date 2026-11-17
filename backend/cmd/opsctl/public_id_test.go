package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
)

const (
	lookupUID   = "LookupUidAbCdEfGhIjKlMnOp1234"
	lookupOther = "OtherUidAbCdEfGhIjKlMnOp12345"
	lookupPub   = "u0123456789abcdefghjkmnpqrs"
	lookupPub2  = "u1aaaaaaaaaaaaaaaaaaaaaaaaa"
)

// fakePublicIDStore is users/{uid} (profiles) and publicIds/{id} (lookups); it counts reads and can fail.
type fakePublicIDStore struct {
	profiles map[string]identity.Profile
	lookups  map[string]string
	// failProfile and failLookup fail that read with an error naming its document path, like Firestore's text.
	failProfile, failLookup bool
	reads                   int
}

func (s *fakePublicIDStore) GetProfile(_ context.Context, uid string) (identity.Profile, error) {
	s.reads++
	if s.failProfile {
		return identity.Profile{}, fmt.Errorf("rpc error: projects/p/databases/(default)/documents/users/%s: %w", uid, errors.New("unavailable"))
	}
	p, ok := s.profiles[uid]
	if !ok {
		return identity.Profile{}, identity.ErrNotFound
	}
	return p, nil
}

func (s *fakePublicIDStore) ResolvePublicIDs(_ context.Context, ids []string) (map[string]string, error) {
	s.reads += len(ids)
	if s.failLookup {
		return nil, fmt.Errorf("rpc error: projects/p/databases/(default)/documents/publicIds/%s: %w", ids[0], errors.New("unavailable"))
	}
	out := map[string]string{}
	for _, id := range ids {
		if uid, ok := s.lookups[id]; ok {
			out[id] = uid
		}
	}
	return out, nil
}

func runPublicID(t *testing.T, st *fakePublicIDStore, stdin string, args ...string) (code int, stdout, stderr string, opened bool) {
	t.Helper()
	var out, errOut bytes.Buffer
	open := func(context.Context, string) (*backends, error) {
		opened = true
		return &backends{publicIDLookup: st, close: func() {}}, nil
	}
	code = run(context.Background(), append([]string{"public-id"}, args...), strings.NewReader(stdin), &out, &errOut, open, nil)
	return code, out.String(), errOut.String(), opened
}

func TestPublicIDLookup(t *testing.T) {
	active := identity.Profile{UserID: lookupUID, PublicID: lookupPub, Status: identity.AccountStatusActive}
	tests := []struct {
		name      string
		profiles  map[string]identity.Profile
		lookups   map[string]string
		args      []string
		want      string
		wantReads int
	}{
		{"uid with a consistent pair", map[string]identity.Profile{lookupUID: active}, map[string]string{lookupPub: lookupUID},
			[]string{"--uid", lookupUID}, "uid=" + lookupUID + "\npublic_id=" + lookupPub + "\nlookup=ok\nstatus=ACTIVE\n", 2},
		{"uid without a public id: no lookup read", map[string]identity.Profile{lookupUID: {UserID: lookupUID, Status: identity.AccountStatusSuspended}}, nil,
			[]string{"--uid", lookupUID}, "uid=" + lookupUID + "\npublic_id=none\nstatus=SUSPENDED\n", 1},
		{"uid whose lookup document is missing", map[string]identity.Profile{lookupUID: active}, nil,
			[]string{"--uid", lookupUID}, "uid=" + lookupUID + "\npublic_id=" + lookupPub + "\nlookup=missing\nstatus=ACTIVE\n", 2},
		{"uid whose lookup names another account (that uid is not printed)", map[string]identity.Profile{lookupUID: active}, map[string]string{lookupPub: lookupOther},
			[]string{"--uid", lookupUID}, "uid=" + lookupUID + "\npublic_id=" + lookupPub + "\nlookup=other-account\nstatus=ACTIVE\n", 2},
		{"unknown uid", nil, nil,
			[]string{"--uid", lookupUID}, "uid=" + lookupUID + "\naccount=none\n", 1},
		{"id with a consistent pair", map[string]identity.Profile{lookupUID: active}, map[string]string{lookupPub: lookupUID},
			[]string{"--id", lookupPub}, "public_id=" + lookupPub + "\nuid=" + lookupUID + "\naccount_public_id=match\nstatus=ACTIVE\n", 2},
		{"unknown id: no account read", nil, nil,
			[]string{"--id", lookupPub}, "public_id=" + lookupPub + "\nuid=none\n", 1},
		{"id whose account stores another id", map[string]identity.Profile{lookupUID: {UserID: lookupUID, PublicID: lookupPub2, Status: identity.AccountStatusActive}}, map[string]string{lookupPub: lookupUID},
			[]string{"--id", lookupPub}, "public_id=" + lookupPub + "\nuid=" + lookupUID + "\naccount_public_id=mismatch\nstatus=ACTIVE\n", 2},
		{"id whose account has none", map[string]identity.Profile{lookupUID: {UserID: lookupUID, Status: identity.AccountStatusDeleting}}, map[string]string{lookupPub: lookupUID},
			[]string{"--id", lookupPub}, "public_id=" + lookupPub + "\nuid=" + lookupUID + "\naccount_public_id=none\nstatus=DELETING\n", 2},
		{"id whose account is gone", nil, map[string]string{lookupPub: lookupUID},
			[]string{"--id", lookupPub}, "public_id=" + lookupPub + "\nuid=" + lookupUID + "\naccount=none\n", 2},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			st := &fakePublicIDStore{profiles: tt.profiles, lookups: tt.lookups}
			code, stdout, stderr, _ := runPublicID(t, st, "", append([]string{"--project", "dzeroth-dev"}, tt.args...)...)
			if code != 0 {
				t.Fatalf("code = %d, stderr = %q", code, stderr)
			}
			if stdout != tt.want {
				t.Errorf("stdout = %q, want %q", stdout, tt.want)
			}
			if stderr != "" {
				t.Errorf("stderr = %q, want nothing (the mapping goes to stdout only)", stderr)
			}
			if st.reads != tt.wantReads {
				t.Errorf("reads = %d, want %d", st.reads, tt.wantReads)
			}
		})
	}
}

func TestPublicIDLookup_UsageErrors(t *testing.T) {
	tests := []struct {
		name string
		args []string
		want string
	}{
		{"neither", []string{"--project", "dzeroth-dev"}, "exactly one of --uid or --id"},
		{"both", []string{"--project", "dzeroth-dev", "--uid", lookupUID, "--id", lookupPub}, "exactly one of --uid or --id"},
		{"a public id passed as --uid", []string{"--project", "dzeroth-dev", "--uid", lookupPub}, "--uid is a public id"},
		{"malformed uid", []string{"--project", "dzeroth-dev", "--uid", "bad/uid"}, "--uid is not a valid user id"},
		{"malformed id", []string{"--project", "dzeroth-dev", "--id", "U0123456789ABCDEFGHJKMNPQRS"}, "--id is not a well-formed public id"},
		{"a uid passed as --id", []string{"--project", "dzeroth-dev", "--id", lookupUID}, "--id is not a well-formed public id"},
		{"no project", []string{"--uid", lookupUID}, "--project is required"},
		{"dry-run is meaningless", []string{"--project", "dzeroth-dev", "--uid", lookupUID, "--dry-run"}, "--dry-run is not supported"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			code, _, stderr, opened := runPublicID(t, &fakePublicIDStore{}, "", tt.args...)
			if code != 2 || !strings.Contains(stderr, tt.want) {
				t.Errorf("code = %d, stderr = %q, want 2 and %q", code, stderr, tt.want)
			}
			if opened {
				t.Error("Firestore was opened for a usage error")
			}
		})
	}
}

// A production project asks for the typed project id first, like every opsctl command; a wrong answer reads nothing.
func TestPublicIDLookup_ProdConfirmation(t *testing.T) {
	st := &fakePublicIDStore{profiles: map[string]identity.Profile{lookupUID: {UserID: lookupUID, PublicID: lookupPub}}, lookups: map[string]string{lookupPub: lookupUID}}
	code, _, _, opened := runPublicID(t, st, "nope\n", "--project", "dzeroth-prod", "--uid", lookupUID)
	if code != 1 || opened {
		t.Fatalf("wrong confirmation: code = %d, opened = %v", code, opened)
	}
	code, stdout, _, _ := runPublicID(t, st, "dzeroth-prod\n", "--project", "dzeroth-prod", "--uid", lookupUID)
	if code != 0 || !strings.Contains(stdout, "public_id="+lookupPub) {
		t.Fatalf("confirmed: code = %d, stdout = %q", code, stdout)
	}
}

// A Firestore error names the document path (the uid or the public id), including the id found by the first read when
// the second fails: none reaches stderr or stdout.
func TestPublicIDLookup_ErrorsAreRedacted(t *testing.T) {
	pair := func() (map[string]identity.Profile, map[string]string) {
		return map[string]identity.Profile{lookupUID: {UserID: lookupUID, PublicID: lookupPub}}, map[string]string{lookupPub: lookupUID}
	}
	tests := []struct {
		name                    string
		args                    []string
		failProfile, failLookup bool
	}{
		{"--uid, the account read fails", []string{"--uid", lookupUID}, true, false},
		{"--uid, the lookup read of the found id fails", []string{"--uid", lookupUID}, false, true},
		{"--id, the lookup read fails", []string{"--id", lookupPub}, false, true},
		{"--id, the account read of the found uid fails", []string{"--id", lookupPub}, true, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			profiles, lookups := pair()
			st := &fakePublicIDStore{profiles: profiles, lookups: lookups, failProfile: tt.failProfile, failLookup: tt.failLookup}
			code, stdout, stderr, _ := runPublicID(t, st, "", append([]string{"--project", "dzeroth-dev"}, tt.args...)...)
			if code != 1 || !strings.Contains(stderr, "unavailable") {
				t.Fatalf("code = %d, stderr = %q", code, stderr)
			}
			if strings.Contains(stderr, lookupUID) || strings.Contains(stderr, lookupPub) || stdout != "" {
				t.Errorf("an id leaked: stdout %q stderr %q", stdout, stderr)
			}
		})
	}
}

func TestUsageListsPublicID(t *testing.T) {
	if !strings.Contains(usage, "opsctl public-id --project P (--uid UID | --id PUBLIC_ID)") || !strings.Contains(usage, "only id that may be shared") {
		t.Errorf("usage does not document public-id:\n%s", usage)
	}
}
