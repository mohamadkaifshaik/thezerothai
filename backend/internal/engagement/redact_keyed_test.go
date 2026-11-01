package engagement

import (
	"fmt"
	"strings"
	"testing"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// assertKeyedPostRedaction fails when msg carries a plain uid, a plain post id or the unkeyed hash of a post id, or lacks the
// keyed HashPost of each post id (W6-56).
func assertKeyedPostRedaction(t *testing.T, msg, uid string, postIDs ...string) {
	t.Helper()
	if strings.Contains(msg, uid) {
		t.Errorf("plain uid in %q", msg)
	}
	for _, p := range postIDs {
		if strings.Contains(msg, p) {
			t.Errorf("plain post id %q in %q", p, msg)
		}
		if strings.Contains(msg, logger.HashUID(p)) {
			t.Errorf("unkeyed hash of post id %q in %q", p, msg)
		}
		if !strings.Contains(msg, logger.HashPost(p)) {
			t.Errorf("want keyed HashPost of %q in %q", p, msg)
		}
	}
	if !strings.Contains(msg, logger.HashUID(uid)) {
		t.Errorf("want HashUID(uid) in %q", msg)
	}
}

// The list paths (bookmarks, likes) and the bookmark write path: an error naming post ids and the uid yields the keyed post hash.
func TestListAndBookmarkErrors_RedactPostIDsKeyed(t *testing.T) {
	t.Parallel()
	cases := []struct {
		name string
		run  func(t *testing.T) ([]string, error)
	}{
		{"ListBookmarks GetMany fails", func(t *testing.T) ([]string, error) {
			e := newListEnv(t)
			e.seed(2)
			e.rd.getManyErr = fmt.Errorf("batch get posts/%s posts/%s users/%s failed", pid(1), pid(2), caller)
			_, err := e.m.ListBookmarks(e.ctx, caller, 0, "")
			return []string{pid(1), pid(2)}, err
		}},
		{"ListBookmarks query fails past page one", func(t *testing.T) ([]string, error) {
			e := newListEnv(t)
			e.seed(25)
			p1, err := e.m.ListBookmarks(e.ctx, caller, 20, "")
			if err != nil || p1.NextPageToken == "" {
				t.Fatalf("page 1: %v %q", err, p1.NextPageToken)
			}
			e.bm.listErr = fmt.Errorf("start after users/%s/bookmarks/%s: unavailable", caller, pid(6))
			_, err = e.m.ListBookmarks(e.ctx, caller, 20, p1.NextPageToken)
			return []string{pid(6)}, err
		}},
		{"ListLikedPosts GetMany fails", func(t *testing.T) ([]string, error) {
			e := newListEnv(t)
			e.seedLikes(2)
			e.rd.getManyErr = fmt.Errorf("batch get posts/%s posts/%s users/%s failed", pid(1), pid(2), caller)
			_, err := e.m.ListLikedPosts(e.ctx, caller, 0, "")
			return []string{pid(1), pid(2)}, err
		}},
		{"bookmark write error", func(t *testing.T) ([]string, error) {
			e := newListEnv(t)
			raw := fmt.Errorf("commit users/%s/bookmarks/%s", caller, pidA)
			return []string{pidA}, mapBookmarkErr(e.ctx, "add bookmark", caller, pidA, raw)
		}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			posts, err := tc.run(t)
			if err == nil {
				t.Fatal("want an error")
			}
			assertKeyedPostRedaction(t, err.Error(), caller, posts...)
		})
	}
}

// The likes/reposts purge helper: a document id <postId>_<uid> renders as HashPost(postId)_HashUID(uid).
func TestRedactLikeDocErr_Keyed(t *testing.T) {
	t.Parallel()
	const uid = "uidAbc123"
	cases := []struct {
		name  string
		posts []string
	}{
		{"one document", []string{"7300000000000000001"}},
		{"page of two", []string{"7300000000000000001", "7300000000000000002"}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			var docs []*firestore.DocumentSnapshot
			var named string
			for _, p := range tc.posts {
				docs = append(docs, &firestore.DocumentSnapshot{Ref: &firestore.DocumentRef{ID: p + "_" + uid}})
				named += " documents/likes/" + p + "_" + uid
			}
			err := redactLikeDocErr(fmt.Errorf("engagement: purge %s: rpc error:%s", logger.HashUID(uid), named), uid, docs)
			msg := err.Error()
			assertKeyedPostRedaction(t, msg, uid, tc.posts...)
			for _, p := range tc.posts {
				if !strings.Contains(msg, logger.HashPost(p)+"_"+logger.HashUID(uid)) {
					t.Errorf("want HashPost_HashUID in %q", msg)
				}
			}
		})
	}
}
