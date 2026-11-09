package articles

import (
	"context"
	"errors"
	"strings"
	"testing"
	"unicode/utf8"
)

type failingGetRepo struct{ *memoryRepo }

func (failingGetRepo) get(context.Context, string) (*record, error) {
	return nil, errors.New("unavailable")
}

func TestReportEvidence(t *testing.T) {
	const postID = "1000000000000000001"
	big := strings.Repeat("é", MaxEvidenceBodyBytes) // 2 bytes each: twice the bound
	rows := map[string]*record{
		testID:                 {ID: testID, AuthorID: "alice", Revision: 3, Title: "Title", Body: testBody, PostID: postID, Published: true},
		"draftdraftdraft00001": {ID: "draftdraftdraft00001", AuthorID: "alice", Title: "Draft", Body: testBody},
		"bigbigbigbigbig00001": {ID: "bigbigbigbigbig00001", AuthorID: "alice", Revision: 1, Title: "Big", PostID: postID, Published: true,
			Body: `[{"kind":"paragraph","runs":[{"text":"x` + big + `","marks":[]}]}]`},
	}
	tests := []struct {
		name      string
		repo      repository
		articleID string
		postID    string
		want      Evidence
		wantErr   error
		anyErr    bool
	}{
		{name: "published root", articleID: testID, postID: postID, want: Evidence{ArticleID: testID, Title: "Title", Revision: 3, Body: "Hello world"}},
		{name: "another post", articleID: testID, postID: "1000000000000000002", wantErr: ErrNotFound},
		{name: "draft", articleID: "draftdraftdraft00001", postID: postID, wantErr: ErrNotFound},
		{name: "missing", articleID: "missingmissing00001", postID: postID, wantErr: ErrNotFound},
		{name: "invalid id", articleID: "../x", postID: postID, wantErr: ErrNotFound},
		{name: "read fails", repo: failingGetRepo{}, articleID: testID, postID: postID, anyErr: true},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			repo := tc.repo
			if repo == nil {
				repo = &memoryRepo{rows: rows}
			}
			got, err := evidenceReader{repo: repo}.ReportEvidence(context.Background(), tc.articleID, tc.postID)
			switch {
			case tc.anyErr:
				if err == nil || errors.Is(err, ErrNotFound) {
					t.Fatalf("err = %v, want a transient error", err)
				}
			case tc.wantErr != nil:
				if !errors.Is(err, tc.wantErr) {
					t.Fatalf("err = %v, want %v", err, tc.wantErr)
				}
			default:
				if err != nil || got != tc.want {
					t.Fatalf("got %#v, %v; want %#v", got, err, tc.want)
				}
			}
		})
	}
	t.Run("body bounded on a code point", func(t *testing.T) {
		got, err := evidenceReader{repo: &memoryRepo{rows: rows}}.ReportEvidence(context.Background(), "bigbigbigbigbig00001", postID)
		if err != nil {
			t.Fatal(err)
		}
		if len(got.Body) > MaxEvidenceBodyBytes || len(got.Body) < MaxEvidenceBodyBytes-1 || !utf8.ValidString(got.Body) || !got.Truncated {
			t.Fatalf("body %d bytes, valid %v, truncated %v", len(got.Body), utf8.ValidString(got.Body), got.Truncated)
		}
	})
}
