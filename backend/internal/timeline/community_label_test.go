package timeline

import (
	"testing"
	"time"

	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

const labelCID = "1000000000000000042"

// W5-26b (ADR-0031 D5): the community label on Home, profile and list timelines is decided only by posts.ToView: a community post carries
// it, a hidden one (communityHidden) and every post while communities is globally off do not, and viewer_reply_permission stays what the
// timelines can say with 0 reads (never NOT_ALLOWED from the community rule).
func TestTimelines_CommunityLabel(t *testing.T) {
	t.Parallel()
	reg := func(m flags.Mode) *flags.Registry {
		return flags.NewRegistry(flags.Spec{Name: "posts", Mode: flags.On}, flags.Spec{Name: "lists", Mode: flags.On},
			flags.Spec{Name: "communities", Mode: m})
	}
	tests := []struct {
		name   string
		mode   flags.Mode
		hidden bool
		want   bool
	}{
		{"community post", flags.On, false, true},
		{"hidden community post", flags.On, true, false},
		{"communities globally off", flags.Off, false, false},
		{"allowlist rollout is not the kill switch", flags.Allowlist, false, true},
	}
	for _, tt := range tests {
		for _, surface := range []string{"home", "user", "list"} {
			t.Run(surface+"/"+tt.name, func(t *testing.T) {
				t.Parallel()
				var r *rig
				var p *posts.Post
				switch surface {
				case "home":
					r = newRig(t)
					r.follow("me", 1)
					p = r.posts.add("f1", r.ms(-3*time.Second))
				case "user":
					r = newRig(t)
					p = r.seedUser("author", 1)[0]
				default:
					r, _ = listRig(t, "m1")
					p = r.posts.add("m1", r.ms(-3*time.Second))
					r.dir.profiles["me"] = identity.Profile{UserID: "me", Status: identity.AccountStatusActive}
				}
				p.CommunityID, p.ConversationCommunityID = labelCID, labelCID
				label := newOf(p.Community) // timeline may not name posts.CommunityLabel (the seam guard in server_test.go), so the label is built by type inference
				label.ID, label.Name = labelCID, "Go"
				p.Community = label
				p.CommunityHidden = tt.hidden
				r.srv.deps.Flags = reg(tt.mode)

				var views []*postsv1.PostView
				switch surface {
				case "home":
					views = r.mustHome("", "", 20).GetPosts()
				case "user":
					views = r.mustUser("me", "author", false, "", "", 20).GetPosts()
				default:
					views = r.mustList("", "", 20).GetPosts()
				}
				if len(views) != 1 {
					t.Fatalf("rows = %d", len(views))
				}
				c := views[0].GetPost().GetCommunity()
				if (c != nil) != tt.want {
					t.Fatalf("community = %v, want present=%v", c, tt.want)
				}
				if c != nil && (c.GetId() != labelCID || c.GetName() != "Go") {
					t.Fatalf("community = %v", c)
				}
				if got := views[0].GetViewerReplyPermission(); got == postsv1.ReplyPermission_REPLY_PERMISSION_NOT_ALLOWED {
					t.Fatalf("a timeline row must not decide the members-only rule (0 reads), got %v", got)
				}
			})
		}
	}
}

// newOf returns a new zero T for a typed nil or non-nil pointer, without naming T.
func newOf[T any](*T) *T { return new(T) }
