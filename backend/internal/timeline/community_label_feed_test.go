package timeline

import (
	"fmt"
	"slices"
	"testing"
	"time"

	connect "connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/internal/communities"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// labelled gives p the community label snapshot (timeline may not name posts.CommunityLabel, so the type comes from newOf).
func (c *commRig) labelled(p *posts.Post) *posts.Post {
	l := newOf(p.Community)
	l.ID, l.Name = testCID, "Go"
	p.Community = l
	return p
}

// A: a community-hidden post is dropped by the per-viewer keep rule even when a cached entry still holds it, so it never reaches the
// wire, with or without a label. The visible post keeps its label.
func TestCommunity_HiddenPostDroppedAndNeverLabelled(t *testing.T) {
	t.Parallel()
	c := newCommRig(t)
	keep := c.labelled(c.cp.add(testCID, "a1", c.ms(-10*time.Second)))
	hidden := c.labelled(c.cp.add(testCID, "a2", c.ms(-20*time.Second)))
	hidden.CommunityHidden = true
	resp, _ := c.must("", "", 20)
	if got := commIDs(resp); !slices.Equal(got, []string{keep.ID}) {
		t.Fatalf("posts = %v, want only the visible one", got)
	}
	for _, v := range resp.GetPosts() {
		if v.GetPost().GetPostId() == hidden.ID {
			t.Fatalf("hidden post on the wire: %v", v)
		}
	}
	if l := resp.GetPosts()[0].GetPost().GetCommunity(); l.GetId() != testCID || l.GetName() != "Go" {
		t.Fatalf("visible post label = %v", l)
	}
	if got, _ := c.info.Get(fieldFiltered); fmt.Sprint(got) != "1" {
		t.Fatalf("items_filtered = %v, want 1", got)
	}
}

// globalOffFlags is a checker whose Enabled stays true but whose GloballyOff(communities) is true: the one state in which the feed is served
// and the label kill switch must still apply. (With the real registry mode off, Enabled is false for everyone and the call is refused.)
type globalOffFlags struct{ posts.FlagChecker }

func (globalOffFlags) GloballyOff(name string) bool { return name == communities.FlagName }

// B: communities globally off carries no label. With the real registry the call is refused before any read, so no post and no label
// can leave; and (c) the mark reaches the ViewerSet through HydrateViewer/toViews: with Enabled true and GloballyOff true the posts come
// back without a label, while the control (not globally off) carries it.
func TestCommunity_GloballyOffCarriesNoLabel(t *testing.T) {
	t.Parallel()
	on := flags.NewRegistry(flags.Spec{Name: "posts", Mode: flags.On}, flags.Spec{Name: communities.FlagName, Mode: flags.On})

	t.Run("registry off is refused with no posts", func(t *testing.T) {
		t.Parallel()
		c := newCommRig(t)
		c.srv.deps.Flags = flags.NewRegistry(flags.Spec{Name: "posts", Mode: flags.On}, flags.Spec{Name: communities.FlagName, Mode: flags.Off})
		c.labelled(c.cp.add(testCID, "a1", c.ms(-10*time.Second)))
		resp, counter, err := c.get("me", testCID, "", "", 20)
		wantAPIErr(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED, map[string]string{"feature": "communities"})
		if resp != nil || counter.Reads() != 0 {
			t.Fatalf("resp = %v, reads = %d", resp, counter.Reads())
		}
	})
	for _, tt := range []struct {
		name  string
		fc    posts.FlagChecker
		label bool
	}{
		{"control: not globally off keeps the label", on, true},
		{"globally off mark reaches toViews", globalOffFlags{on}, false},
	} {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			c := newCommRig(t)
			c.srv.deps.Flags = tt.fc
			p := c.labelled(c.cp.add(testCID, "a1", c.ms(-10*time.Second)))
			resp, _ := c.must("", "", 20)
			if got := commIDs(resp); !slices.Equal(got, []string{p.ID}) {
				t.Fatalf("posts = %v", got)
			}
			if has := resp.GetPosts()[0].GetPost().GetCommunity() != nil; has != tt.label {
				t.Fatalf("label present = %v, want %v", has, tt.label)
			}
		})
	}
}
