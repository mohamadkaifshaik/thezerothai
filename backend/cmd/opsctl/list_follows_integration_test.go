//go:build integration

package main

import (
	"bytes"
	"context"
	"strings"
	"testing"
	"time"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/internal/lists"
)

// End-to-end emulator test of `opsctl recount-list-follows --all-missing`: the real run flag handling and output over the
// real lists.FirestoreRepo, on a mixed set of lists.
func TestRecountListFollows_Integration_AllMissing(t *testing.T) {
	client, project := backfillTestClient(t)
	ctx := context.Background()
	const (
		publicMissing  = "0000000000000000001"
		privateMissing = "0000000000000000002"
		inStep         = "0000000000000000003"
		drift          = "0000000000000000004" // stored 5, no markers: --all-missing must leave it (only --list fixes drift)
		followedMiss   = "0000000000000000005" // no field, 2 markers
	)
	seed := func(id string, private bool, count any) {
		t.Helper()
		doc := map[string]any{"ownerId": "u-owner", "name": "L" + id[len(id)-1:], "isPrivate": private, "memberIds": []string{},
			"createdAt": time.Now().UTC(), "updatedAt": time.Now().UTC()}
		if count != nil {
			doc["followerCount"] = count
		}
		if _, err := client.Collection("lists").Doc(id).Set(ctx, doc); err != nil {
			t.Fatal(err)
		}
	}
	seed(publicMissing, false, nil)
	seed(privateMissing, true, nil)
	seed(inStep, false, int64(0))
	seed(drift, false, int64(5))
	seed(followedMiss, false, nil)
	for _, uid := range []string{"u-a", "u-b"} {
		if _, err := client.Collection("listFollows").Doc(uid+"_"+followedMiss).Set(ctx, map[string]any{
			"listId": followedMiss, "uid": uid, "createdAt": time.Now().UTC(),
		}); err != nil {
			t.Fatal(err)
		}
	}

	runCLI := func(args ...string) (int, string, string) {
		open := func(context.Context, string) (*backends, error) {
			return &backends{listFollows: lists.NewFirestoreRepo(client, nil, nil), close: func() {}}, nil
		}
		var out, errOut bytes.Buffer
		code := run(ctx, append(args, "--project", project), strings.NewReader(""), &out, &errOut, open, time.Now)
		return code, out.String(), errOut.String()
	}
	stored := func(id string) any {
		t.Helper()
		snap, err := client.Collection("lists").Doc(id).Get(ctx)
		if err != nil {
			t.Fatal(err)
		}
		v, err := snap.DataAt("followerCount")
		if err != nil {
			return nil
		}
		return v
	}
	mustRun := func(name string, want []string, args ...string) {
		t.Helper()
		code, out, errOut := runCLI(args...)
		if code != 0 {
			t.Fatalf("%s: code %d stderr %q", name, code, errOut)
		}
		for _, w := range want {
			if !strings.Contains(out, w) {
				t.Errorf("%s: output lacks %q:\n%s", name, w, out)
			}
		}
	}

	mustRun("dry run", []string{"dry-run: scanned=5 missing=3 would_write=3"}, "recount-list-follows", "--all-missing")
	if v := stored(publicMissing); v != nil {
		t.Fatalf("dry run wrote followerCount=%v", v)
	}
	mustRun("dry run resumed", []string{"dry-run: scanned=3 missing=1"}, "recount-list-follows", "--all-missing", "--after", privateMissing)

	mustRun("write", []string{"complete: scanned=5 missing=3 written=3"}, "recount-list-follows", "--all-missing", "--write")
	for id, want := range map[string]int64{publicMissing: 0, privateMissing: 0, inStep: 0, drift: 5, followedMiss: 2} {
		if got := stored(id); got != want {
			t.Errorf("list %s: followerCount=%v, want %d", id, got, want)
		}
	}
	mustRun("write again", []string{"complete: scanned=5 missing=0 written=0"}, "recount-list-follows", "--all-missing", "--write")

	// The Discover query now returns every public list (the drift one included: it always had the field).
	docs, err := client.Collection("lists").Where("isPrivate", "==", false).OrderBy("followerCount", firestore.Desc).Documents(ctx).GetAll()
	if err != nil || len(docs) != 4 {
		t.Fatalf("public lists by followerCount: %d, err %v; want 4", len(docs), err)
	}

	for _, bad := range []struct {
		name string
		args []string
		want string
	}{
		{"list and all-missing", []string{"recount-list-follows", "--all-missing", "--list", inStep}, "cannot be used together"},
		{"after without all-missing", []string{"recount-list-follows", "--list", inStep, "--after", inStep}, "--after needs --all-missing"},
		{"bad after", []string{"recount-list-follows", "--all-missing", "--after", "abc"}, "19-digit list id"},
		{"all-missing elsewhere", []string{"recount-shares", "--all-missing", "--post", inStep}, "--all-missing is not supported"},
	} {
		code, out, errOut := runCLI(bad.args...)
		if code == 0 || !strings.Contains(out+errOut, bad.want) {
			t.Errorf("%s: code %d, output %q %q; want a failure mentioning %q", bad.name, code, out, errOut, bad.want)
		}
	}
}
