package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"
)

func TestAllowedAccount(t *testing.T) {
	tests := []struct {
		name string
		u    authUser
		want bool
	}{
		{"google", authUser{Providers: []string{"google.com"}}, true},
		{"apple unverified flag", authUser{Providers: []string{"apple.com"}}, true},
		{"password verified", authUser{Providers: []string{"password"}, EmailVerified: true}, true},
		{"password unverified", authUser{Providers: []string{"password"}}, false},
		{"phone", authUser{Providers: []string{"phone"}, EmailVerified: true}, false},
		{"anonymous (no providers)", authUser{}, false},
		{"saml", authUser{Providers: []string{"saml.corp"}, EmailVerified: true}, false},
		{"unverified password plus google", authUser{Providers: []string{"password", "google.com"}}, true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := allowedAccount(tt.u); got != tt.want {
				t.Errorf("allowedAccount = %v, want %v", got, tt.want)
			}
		})
	}
}

func fakeList(users []authUser, err error) authLister {
	return func(_ context.Context, fn func(authUser) error) error {
		for _, u := range users {
			if e := fn(u); e != nil {
				return e
			}
		}
		return err
	}
}

// fakeExists reports docs for the given uid set and records batch sizes.
func fakeExists(docs map[string]bool, batches *[]int) usersExistFn {
	return func(_ context.Context, uids []string) (int, error) {
		*batches = append(*batches, len(uids))
		n := 0
		for _, u := range uids {
			if docs[u] {
				n++
			}
		}
		return n, nil
	}
}

func TestScanT26(t *testing.T) {
	bad := func(n int) []authUser {
		var us []authUser
		for i := range n {
			us = append(us, authUser{UID: fmt.Sprintf("bad%d", i), Providers: []string{"phone"}})
		}
		return us
	}
	good := authUser{UID: "g", Providers: []string{"google.com"}}

	tests := []struct {
		name        string
		users       []authUser
		docs        map[string]bool
		want        t26Result
		wantBatches []int
		wantPass    bool
	}{
		{"empty", nil, nil, t26Result{}, nil, true},
		{"all allowed: no firestore reads", []authUser{good, good}, nil, t26Result{Total: 2, Allowed: 2}, nil, true},
		{"not allowed without doc", append(bad(2), good), nil,
			t26Result{Total: 3, Allowed: 1, NotAllowed: 2, FirestoreReads: 2}, []int{2}, true},
		{"not allowed with doc", append(bad(3), good), map[string]bool{"bad1": true},
			t26Result{Total: 4, Allowed: 1, NotAllowed: 3, NotAllowedWithUsersDoc: 1, FirestoreReads: 3}, []int{3}, false},
		{"batching at 100", bad(250), map[string]bool{"bad249": true},
			t26Result{Total: 250, NotAllowed: 250, NotAllowedWithUsersDoc: 1, FirestoreReads: 250}, []int{100, 100, 50}, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var batches []int
			got, err := scanT26(context.Background(), fakeList(tt.users, nil), fakeExists(tt.docs, &batches))
			if err != nil {
				t.Fatal(err)
			}
			if got != tt.want {
				t.Errorf("result = %+v, want %+v", got, tt.want)
			}
			if fmt.Sprint(batches) != fmt.Sprint(tt.wantBatches) {
				t.Errorf("batches = %v, want %v", batches, tt.wantBatches)
			}
			if got.pass() != tt.wantPass {
				t.Errorf("pass = %v, want %v", got.pass(), tt.wantPass)
			}
		})
	}
}

func TestScanT26_Errors(t *testing.T) {
	boom := errors.New("boom")
	var batches []int
	if _, err := scanT26(context.Background(), fakeList(nil, boom), fakeExists(nil, &batches)); !errors.Is(err, boom) {
		t.Errorf("list error = %v, want boom", err)
	}
	failing := func(context.Context, []string) (int, error) { return 0, boom }
	users := []authUser{{UID: "x", Providers: []string{"phone"}}}
	if _, err := scanT26(context.Background(), fakeList(users, nil), failing); !errors.Is(err, boom) {
		t.Errorf("exists error = %v, want boom", err)
	}
}

func TestRun_CheckT26_OutputIsAggregateOnly(t *testing.T) {
	const secretUID, secretProv = "SECRETUID123", "saml.secretcorp"
	users := []authUser{
		{UID: "ok1", Providers: []string{"google.com"}},
		{UID: secretUID, Providers: []string{secretProv}},
	}
	for _, tt := range []struct {
		name     string
		docs     map[string]bool
		wantCode int
		wantLast string
	}{
		{"pass", nil, 0, "T26: PASS"},
		{"fail", map[string]bool{secretUID: true}, 1, "T26: FAIL"},
	} {
		t.Run(tt.name, func(t *testing.T) {
			var batches []int
			fb := &fakeBackend{eraser: &fakeEraser{}}
			open := func(ctx context.Context, p string) (*backends, error) {
				b, _ := fb.open(ctx, p)
				b.listAuthUsers = fakeList(users, nil)
				b.usersExist = fakeExists(tt.docs, &batches)
				return b, nil
			}
			var out, errOut bytes.Buffer
			code := run(context.Background(), []string{"check-t26", "--project", "dzeroth-dev"},
				strings.NewReader(""), &out, &errOut, open, time.Now)
			if code != tt.wantCode {
				t.Fatalf("code = %d, want %d (stderr %q)", code, tt.wantCode, errOut.String())
			}
			lines := strings.Split(strings.TrimSpace(out.String()), "\n")
			if lines[len(lines)-1] != tt.wantLast {
				t.Errorf("last line = %q, want %q", lines[len(lines)-1], tt.wantLast)
			}
			for _, want := range []string{"total=2", "allowed=1", "not_allowed=1", "firestore_reads=1"} {
				if !strings.Contains(out.String(), want) {
					t.Errorf("output missing %q: %q", want, out.String())
				}
			}
			all := out.String() + errOut.String()
			for _, leak := range []string{secretUID, secretProv, "ok1"} {
				if strings.Contains(all, leak) {
					t.Errorf("output leaks %q", leak)
				}
			}
		})
	}
}

func TestRun_CheckT26_RequiresProject(t *testing.T) {
	fb := &fakeBackend{eraser: &fakeEraser{}}
	code, _, stderr := do(t, fb, "", "check-t26")
	if code != 2 || !strings.Contains(stderr, "--project is required") || fb.opened != 0 {
		t.Errorf("code=%d stderr=%q opened=%d", code, stderr, fb.opened)
	}
}
