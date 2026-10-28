package posts

import (
	"errors"
	"reflect"
	"testing"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
)

// W3-29b: GetThread through posts.Audience (ADR-0025 D4). Thread of newThreadEnv: root rRoot by uZed; replies rReply1
// (uCarol), rReply2 (blocked), rReply3 (muted), rReply4 (the caller), rReply5/6 (uDave).

func TestGetThread_ProtectedFocalIsTheDeletedFocalAnswer(t *testing.T) {
	e := newThreadEnv()
	e.protect(uCarol)
	_, _, errProt := e.thread(ThreadInput{PostID: rReply1})
	e2 := newThreadEnv()
	delete(e2.repo.docs, rReply1)
	_, _, errGone := e2.thread(ThreadInput{PostID: rReply1})
	a, b := wantAPIError(t, errProt, connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED), wantAPIError(t, errGone, connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED)
	if a.Message != b.Message || a.Code != b.Code || !reflect.DeepEqual(a.Metadata, b.Metadata) {
		t.Fatalf("protected focal %+v differs from a deleted focal %+v", a, b)
	}
}

func TestGetThread_ProtectedRepliesAreDroppedAndCounted(t *testing.T) {
	tests := []struct {
		name      string
		follow    []string
		want      []string
		protected int
	}{
		{"stranger", nil, []string{rReply4, rReply5, rReply6}, 1},
		{"follower of the protected author", []string{uCarol}, []string{rReply1, rReply4, rReply5, rReply6}, 0},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := newThreadEnv()
			e.protect(uCarol)
			e.graph.snap.Following = following(tt.follow...).Following
			th, c, err := e.thread(ThreadInput{PostID: rRoot})
			if err != nil {
				t.Fatal(err)
			}
			if got := idsOf(th.Replies); !reflect.DeepEqual(got, tt.want) {
				t.Fatalf("replies = %v, want %v", got, tt.want)
			}
			if c.Reads() > 38 || c.Writes() != 0 {
				t.Fatalf("reads=%d writes=%d", c.Reads(), c.Writes())
			}
		})
	}
}

func TestGetThread_ProtectedContextIsATombstone(t *testing.T) {
	// The parent (rReply1, carol) protected: the focal reply by the caller stays, the parent is a tombstone.
	e := newThreadEnv()
	e.protect(uCarol)
	th, _, err := e.thread(ThreadInput{PostID: rReply4})
	if err != nil {
		t.Fatal(err)
	}
	if th.Focal.ID != rReply4 || th.Parent != nil || !th.ParentUnavailable || th.Root == nil || th.RootUnavailable {
		t.Fatalf("parent tombstone only: %+v", th)
	}
	// The root (zed) protected: both are tombstones for a reply whose parent is the root; the focal's text is shown.
	e = newThreadEnv()
	e.protect(uZed)
	th, _, err = e.thread(ThreadInput{PostID: rReply1})
	if err != nil {
		t.Fatal(err)
	}
	if th.Focal == nil || th.Parent != nil || !th.ParentUnavailable || th.Root != nil || !th.RootUnavailable {
		t.Fatalf("want parent_unavailable and root_unavailable: %+v", th)
	}
	// A follower of the root author gets both back.
	e = newThreadEnv()
	e.protect(uZed)
	e.graph.snap.Following = following(uZed).Following
	th, _, err = e.thread(ThreadInput{PostID: rReply1})
	if err != nil || th.Parent == nil || th.Root == nil {
		t.Fatalf("a follower sees the context: %+v %v", th, err)
	}
}

func TestGetThread_ProtectedRepostContextIsATombstoneButQuoteIsKept(t *testing.T) {
	// The root is by uZed; make it a QUOTE of uDave's post (embedded author protected).
	e := newThreadEnv()
	e.protect(uDave)
	root := e.repo.docs[rRoot]
	root.Kind, root.EmbeddedAuthorID = KindQuote, uDave
	th, _, err := e.thread(ThreadInput{PostID: rReply1})
	if err != nil || th.Root == nil || th.RootUnavailable {
		t.Fatalf("a quote of a protected post stays (it renders stripped): %+v %v", th, err)
	}
	root.Kind = KindRepost
	th, _, err = e.thread(ThreadInput{PostID: rReply2})
	if err != nil {
		t.Fatal(err)
	}
	if th.Root != nil || !th.RootUnavailable {
		t.Fatalf("a repost of a protected post is a tombstone: %+v", th)
	}
}

func TestGetThread_UnknownProtectedSetIsUnavailable(t *testing.T) {
	e := newThreadEnv()
	f := e.protect(uCarol)
	f.err = errors.New("firestore down")
	_, _, err := e.thread(ThreadInput{PostID: rRoot})
	var ae *apierr.Error
	if !errors.As(err, &ae) || ae.Code != connect.CodeUnavailable {
		t.Fatalf("err = %v, want UNAVAILABLE (fail closed)", err)
	}
}

func TestGetThread_WithoutALoaderNobodyIsProtected(t *testing.T) {
	e := newThreadEnv()
	th, _, err := e.thread(ThreadInput{PostID: rRoot})
	if err != nil || len(th.Replies) != 4 {
		t.Fatalf("replies = %d err = %v", len(th.Replies), err)
	}
}
