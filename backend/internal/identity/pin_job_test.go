package identity

import (
	"context"
	"errors"
	"strings"
	"testing"
)

type fakePinsRepo struct {
	cleared bool
	err     error
	calls   []string
}

func (f *fakePinsRepo) ClearIfPinned(_ context.Context, uid, postID string) (bool, error) {
	f.calls = append(f.calls, uid+"/"+postID)
	return f.cleared, f.err
}

type fakeGone struct {
	gone  bool
	err   error
	calls []string
}

func (f *fakeGone) PostGone(_ context.Context, postID string) (bool, error) {
	f.calls = append(f.calls, postID)
	return f.gone, f.err
}

func TestPinJobs_Handle(t *testing.T) {
	const good = `{"kind":"post_delete","uid":"uid-1","postId":"0000000000000000301","mediaIds":["1"]}`
	tests := []struct {
		name         string
		data         string
		gone         fakeGone
		repo         fakePinsRepo
		wantOutcome  string
		wantErr      bool
		wantGoneCall bool
		wantClear    bool
	}{
		{"pinned post deleted: pin cleared", good, fakeGone{gone: true}, fakePinsRepo{cleared: true}, "pin_cleared", false, true, true},
		{"deleted post was not the pin: noop", good, fakeGone{gone: true}, fakePinsRepo{cleared: false}, "noop", false, true, true},
		{"the post still exists: refused, nothing unpinned", good, fakeGone{gone: false}, fakePinsRepo{cleared: true}, "refused", false, true, false},
		{"existence check fails: nack", good, fakeGone{err: errors.New("firestore down uid-1")}, fakePinsRepo{}, "", true, true, false},
		{"clear fails: nack", good, fakeGone{gone: true}, fakePinsRepo{err: errors.New("aborted uid-1")}, "", true, true, true},
		{"malformed JSON is acknowledged and dropped", `{not json`, fakeGone{gone: true}, fakePinsRepo{}, "dropped:malformed_message", false, false, false},
		{"wrong kind", `{"kind":"account_delete","uid":"uid-1","postId":"0000000000000000301"}`, fakeGone{gone: true}, fakePinsRepo{}, "dropped:invalid_message", false, false, false},
		{"bad uid (composite-key separator)", `{"kind":"post_delete","uid":"a_b","postId":"0000000000000000301"}`, fakeGone{gone: true}, fakePinsRepo{}, "dropped:invalid_message", false, false, false},
		{"empty uid", `{"kind":"post_delete","uid":"","postId":"0000000000000000301"}`, fakeGone{gone: true}, fakePinsRepo{}, "dropped:invalid_message", false, false, false},
		{"bad post id", `{"kind":"post_delete","uid":"uid-1","postId":"12"}`, fakeGone{gone: true}, fakePinsRepo{}, "dropped:invalid_message", false, false, false},
		{"empty message", ``, fakeGone{gone: true}, fakePinsRepo{}, "dropped:malformed_message", false, false, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			gone, repo := tt.gone, tt.repo
			out, err := NewPinJobs(&repo, &gone, nil).Handle(context.Background(), []byte(tt.data))
			if (err != nil) != tt.wantErr {
				t.Fatalf("err = %v, wantErr %v", err, tt.wantErr)
			}
			if err != nil && strings.Contains(err.Error(), "uid-1") {
				t.Fatalf("the error leaks the uid: %v", err)
			}
			if out != tt.wantOutcome {
				t.Fatalf("outcome = %q, want %q", out, tt.wantOutcome)
			}
			if (len(gone.calls) == 1) != tt.wantGoneCall || (len(repo.calls) == 1) != tt.wantClear {
				t.Fatalf("existence checks %v, clear calls %v", gone.calls, repo.calls)
			}
			if tt.wantClear && repo.calls[0] != "uid-1/0000000000000000301" {
				t.Fatalf("cleared %q", repo.calls[0])
			}
		})
	}
}

func TestPinJobs_RedeliveryConverges(t *testing.T) {
	repo := &fakePinsRepo{cleared: true}
	j := NewPinJobs(repo, &fakeGone{gone: true}, nil)
	data := []byte(`{"kind":"post_delete","uid":"uid-1","postId":"0000000000000000301"}`)
	if out, err := j.Handle(context.Background(), data); err != nil || out != "pin_cleared" {
		t.Fatalf("first delivery = %q, %v", out, err)
	}
	repo.cleared = false // the pin is gone now
	if out, err := j.Handle(context.Background(), data); err != nil || out != "noop" {
		t.Fatalf("redelivery = %q, %v", out, err)
	}
}

func TestPinJobs_ForgetsTheCachedProfileOnlyWhenAPinWasCleared(t *testing.T) {
	data := []byte(`{"kind":"post_delete","uid":"uid-1","postId":"0000000000000000301"}`)
	for _, tt := range []struct {
		name    string
		cleared bool
		want    []string
	}{{"cleared", true, []string{"uid-1"}}, {"nothing to clear", false, nil}} {
		t.Run(tt.name, func(t *testing.T) {
			var forgotten []string
			j := NewPinJobs(&fakePinsRepo{cleared: tt.cleared}, &fakeGone{gone: true}, func(uids ...string) { forgotten = append(forgotten, uids...) })
			if _, err := j.Handle(context.Background(), data); err != nil {
				t.Fatal(err)
			}
			if strings.Join(forgotten, ",") != strings.Join(tt.want, ",") {
				t.Fatalf("forgotten = %v, want %v", forgotten, tt.want)
			}
		})
	}
}
