package articles

import (
	"context"
	"errors"
	"fmt"
	"reflect"
	"strings"
	"testing"

	"connectrpc.com/connect"

	av "github.com/dzeroth/dzeroth/backend/gen/dzeroth/articles/v1"
	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
)

const (
	imgA = "100000000000000001"
	imgB = "100000000000000002"
)

func imageBlock(id, alt, caption string) string {
	return fmt.Sprintf(`{"kind":"image","runs":[],"mediaId":%q,"altText":%q,"caption":%q}`, id, alt, caption)
}

func body(blocks ...string) string { return "[" + strings.Join(blocks, ",") + "]" }

func TestInspectContentImageBlocks(t *testing.T) {
	long := strings.Repeat("a", maxImageAltRunes+1)
	var tooMany []string
	for i := 0; i <= maxArticleImages; i++ {
		tooMany = append(tooMany, imageBlock(fmt.Sprintf("1000000000000%06d", i), "", ""))
	}
	tests := []struct {
		name       string
		body       string
		publishing bool
		wantIDs    []string
		wantErr    bool
	}{
		{name: "image with alt and caption", body: body(imageBlock(imgA, "a cat", "Sunday")), wantIDs: []string{imgA}},
		{name: "alt and caption optional", body: body(imageBlock(imgA, "", "")), wantIDs: []string{imgA}},
		{name: "ids keep body order", body: body(imageBlock(imgB, "", ""), `{"kind":"paragraph","runs":[{"text":"x","marks":[]}]}`, imageBlock(imgA, "", "")), wantIDs: []string{imgB, imgA}},
		{name: "image-only article may publish", body: body(imageBlock(imgA, "", "")), publishing: true, wantIDs: []string{imgA}},
		{name: "empty article cannot publish", body: body(), publishing: true, wantErr: true},
		{name: "missing media id", body: body(`{"kind":"image","runs":[]}`), wantErr: true},
		{name: "malformed media id", body: body(imageBlock("../etc", "", "")), wantErr: true},
		{name: "image with runs", body: body(`{"kind":"image","runs":[{"text":"x","marks":[]}],"mediaId":"` + imgA + `"}`), wantErr: true},
		{name: "alt text too long", body: body(imageBlock(imgA, long, "")), wantErr: true},
		{name: "caption too long", body: body(imageBlock(imgA, "", strings.Repeat("c", maxImageCaptionRunes+1))), wantErr: true},
		{name: "caption with control character", body: body(imageBlock(imgA, "", "a\x01b")), wantErr: true},
		{name: "same image twice", body: body(imageBlock(imgA, "", ""), imageBlock(imgA, "", "")), wantErr: true},
		{name: "too many images", body: body(tooMany...), wantErr: true},
		{name: "caption on a paragraph", body: body(`{"kind":"paragraph","runs":[],"caption":"x"}`), wantErr: true},
		{name: "caption on a divider", body: body(`{"kind":"divider","runs":[],"caption":"x"}`), wantErr: true},
		{name: "unknown field on an image", body: body(`{"kind":"image","runs":[],"mediaId":"` + imgA + `","src":"https://x"}`), wantErr: true},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			info, err := inspectContent("Title", tc.body, tc.publishing)
			if tc.wantErr {
				if err == nil {
					t.Fatalf("want an error, got %#v", info)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if !reflect.DeepEqual(info.ImageIDs, tc.wantIDs) {
				t.Fatalf("ImageIDs = %v, want %v", info.ImageIDs, tc.wantIDs)
			}
		})
	}
}

func TestImageIDsOfIsLenientAndOrdered(t *testing.T) {
	tests := []struct {
		name string
		body string
		want []string
	}{
		{name: "order kept", body: body(imageBlock(imgB, "", ""), imageBlock(imgA, "", "")), want: []string{imgB, imgA}},
		{name: "no images", body: body(`{"kind":"paragraph","runs":[]}`), want: nil},
		{name: "undecodable body has none", body: "not json", want: nil},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := imageIDsOf(tc.body); !reflect.DeepEqual(got, tc.want) {
				t.Fatalf("imageIDsOf = %v, want %v", got, tc.want)
			}
		})
	}
}

// fakeImages answers ResolveArticleImages from a fixed set of usable ids and records each call.
type fakeImages struct {
	usable map[string]bool
	err    error
	calls  [][]string
}

func (f *fakeImages) ResolveArticleImages(_ context.Context, _ string, _ string, ids []string) (map[string]*commonv1.MediaRef, error) {
	f.calls = append(f.calls, ids)
	if f.err != nil {
		return nil, f.err
	}
	out := map[string]*commonv1.MediaRef{}
	for _, id := range ids {
		if f.usable[id] {
			out[id] = &commonv1.MediaRef{MediaId: id, Url: "https://cdn.example/" + id}
		}
	}
	return out, nil
}

func TestCheckNewImagesRules(t *testing.T) {
	stored := body(imageBlock(imgA, "", ""))
	tests := []struct {
		name      string
		flag      bool
		images    *fakeImages
		existing  string // stored draft body, "" for none
		saveIDs   []string
		wantErr   bool
		wantNotOK bool // ErrImageNotReady specifically
		wantCalls int  // ownership reads
	}{
		{name: "flag off, new image refused", flag: false, images: &fakeImages{usable: map[string]bool{imgA: true}}, saveIDs: []string{imgA}, wantErr: true},
		{name: "flag off, stored image kept", flag: false, images: &fakeImages{}, existing: stored, saveIDs: []string{imgA}},
		{name: "flag on, usable new image", flag: true, images: &fakeImages{usable: map[string]bool{imgA: true}}, saveIDs: []string{imgA}, wantCalls: 1},
		{name: "flag on, unusable new image", flag: true, images: &fakeImages{usable: map[string]bool{}}, saveIDs: []string{imgA}, wantErr: true, wantNotOK: true, wantCalls: 1},
		{name: "flag on, stored image needs no read", flag: true, images: &fakeImages{}, existing: stored, saveIDs: []string{imgA}},
		{name: "flag on, resolver outage propagates", flag: true, images: &fakeImages{err: errors.New("boom")}, saveIDs: []string{imgA}, wantErr: true, wantCalls: 1},
		{name: "no images in the save", flag: true, images: &fakeImages{}, saveIDs: nil},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			s, r, _, ctx := setup()
			s.flags = testFlags(tc.flag)
			s.images = tc.images
			if tc.existing != "" {
				r.rows[testID] = &record{ID: testID, AuthorID: "alice", Revision: 1, Body: tc.existing}
			}
			err := s.checkNewImages(ctx, "alice", testID, tc.saveIDs)
			if tc.wantErr != (err != nil) {
				t.Fatalf("err = %v, wantErr %v", err, tc.wantErr)
			}
			if tc.wantNotOK && !errors.Is(err, ErrImageNotReady) {
				t.Fatalf("err = %v, want ErrImageNotReady", err)
			}
			if len(tc.images.calls) != tc.wantCalls {
				t.Fatalf("ownership reads = %d, want %d", len(tc.images.calls), tc.wantCalls)
			}
		})
	}
}

func TestWithImagesOrderOmissionAndOutage(t *testing.T) {
	a := &record{ID: testID, AuthorID: "alice", Body: body(imageBlock(imgB, "", ""), imageBlock(imgA, "", ""))}
	t.Run("body order, unusable images absent", func(t *testing.T) {
		s := &Server{images: &fakeImages{usable: map[string]bool{imgA: true}}}
		out := &av.Article{}
		s.withImages(context.Background(), out, a, "")
		if len(out.Images) != 1 || out.Images[0].GetMediaId() != imgA {
			t.Fatalf("images = %v, want only %s", out.Images, imgA)
		}
	})
	t.Run("outage leaves images out, never fails", func(t *testing.T) {
		s := &Server{images: &fakeImages{err: errors.New("down")}}
		out := &av.Article{}
		s.withImages(context.Background(), out, a, "")
		if len(out.Images) != 0 {
			t.Fatalf("images = %v, want none", out.Images)
		}
	})
	t.Run("nil resolver", func(t *testing.T) {
		out := &av.Article{}
		(&Server{}).withImages(context.Background(), out, a, "")
		if len(out.Images) != 0 {
			t.Fatal("images without a resolver")
		}
	})
}

func TestSaveImageCoverCannotAlsoBeInline(t *testing.T) {
	s, _, _, ctx := setup()
	s.flags = testFlags(true)
	s.images = &fakeImages{usable: map[string]bool{imgA: true}}
	_, err := s.SaveArticle(ctx, connect.NewRequest(&av.SaveArticleRequest{Article: &av.Article{ArticleId: testID, Title: "T", BodyJson: body(imageBlock(imgA, "", "")), CoverMediaId: imgA}}))
	if err == nil {
		t.Fatal("a cover that is also an inline image was accepted")
	}
}
