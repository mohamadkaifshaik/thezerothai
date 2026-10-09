package apiserver

// T11 (docs/plans/account-deletion-export.md): the collection-coverage guard. Every Firestore collection and GCS
// prefix ADR-0003 (and the slice ADRs after it) names must map to a registered deletion step (Eraser), a registered
// export section, or an ADR-referenced residue allowlist entry (ADR-0011 Q10). The scan reads the Go sources of
// backend/internal/* and backend/pkg/platform/* and fails, naming the constant, when a module names a collection that
// has no row. The same table and allowlist drive the emulator residue sweep (account_lifecycle_sweep_integration_test.go).
// No emulator is needed, so this runs in `make ci`.

import (
	"go/ast"
	"go/parser"
	"go/token"
	"io/fs"
	"path/filepath"
	"regexp"
	"slices"
	"sort"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
)

// disposition says what happens to a collection when its owner's account is deleted.
type disposition int

const (
	// erasedByStep: a registered deletion step (collectionRow.Step) removes the user's documents.
	erasedByStep disposition = iota + 1
	// pendingEraser: the collection belongs to a slice that has not shipped its Eraser yet (ADR-0011 Q1 order: P4
	// media, P5 engagement, P6 notifications, P7 reports). Allowed only while no code path writes it; the emulator
	// sweep fails the day one does without the Eraser.
	pendingEraser
	// notPersonal: holds no user data, or only what the Q10 allowlist accepts (platform records with a TTL).
	notPersonal
)

// collectionRow is one line of the T11 table.
type collectionRow struct {
	Name string
	// Sub marks a subcollection (users/{uid}/<Name>); it is scanned with a collection-group query.
	Sub         bool
	Disposition disposition
	// Step is the registered deletion step for erasedByStep (identity.Lifecycle.StepNames), or "identity" for the
	// built-in identity step.
	Step string
	// Section is the export section that carries the data ("" when the data is not exported, with ExportNote why).
	Section    string
	ExportNote string
	// Owner is the module (and slice for pendingEraser rows).
	Owner string
	Cite  string
}

// lifecycleCollections is the T11 table: every collection in ADR-0003 (data model) plus the ones the code names
// today. A slice that adds a collection adds its row in its own PR (plan T11).
var lifecycleCollections = []collectionRow{
	{Name: "users", Disposition: erasedByStep, Step: "users_doc", Section: "profile", Owner: "identity", Cite: "ADR-0011 Q1 step 7 (users/{uid} last)"},
	{Name: "private", Sub: true, Disposition: erasedByStep, Step: "identity", ExportNote: "reserved for PII, none at Stage 0 (ADR-0003 row users/{uid}/private)", Owner: "identity", Cite: "ADR-0011 Q1 step 5"},
	{Name: "handles", Disposition: erasedByStep, Step: "identity", Section: "profile", Owner: "identity", Cite: "ADR-0011 Q1 step 5 (only when owned by the uid)"},
	{Name: "exports", Disposition: erasedByStep, Step: "identity", ExportNote: "the export file itself", Owner: "identity", Cite: "ADR-0011 Q1 step 5 (objects first, then docs)"},
	{Name: "quotas", Disposition: erasedByStep, Step: "identity", ExportNote: "operational counters, not user content", Owner: "platform", Cite: "ADR-0011 Q1 step 5"},
	{Name: "idempotency", Disposition: notPersonal, ExportNote: "24 h TTL key records", Owner: "platform", Cite: "ADR-0011 Q10 (a): uid until the 24 h TTL"},
	{Name: "graph", Disposition: erasedByStep, Step: "graph", Section: "graph", Owner: "graph", Cite: "ADR-0011 Q1 step 3, ADR-0008 purge"},
	{Name: "follows", Disposition: erasedByStep, Step: "graph", Section: "graph", Owner: "graph", Cite: "ADR-0011 Q1 step 3, ADR-0008 purge"},
	{Name: "posts", Disposition: erasedByStep, Step: "posts", Section: "posts", Owner: "posts", Cite: "ADR-0011 Q1 step 2, ADR-0010 purge"},

	// Declared in ADR-0003, no code yet.
	{Name: "followRequests", Disposition: pendingEraser, Owner: "graph (private accounts, later ADR)", Cite: "ADR-0003 data model"},
	{Name: "likes", Disposition: pendingEraser, Owner: "engagement (P5)", Cite: "ADR-0003 data model, ADR-0011 Q1"},
	{Name: "reposts", Disposition: pendingEraser, Owner: "engagement (P5)", Cite: "ADR-0003 data model, ADR-0011 Q1"},
	{Name: "userLikes", Disposition: pendingEraser, Owner: "engagement (P5)", Cite: "ADR-0003 data model, ADR-0011 Q1"},
	{Name: "media", Disposition: pendingEraser, Owner: "media (P4)", Cite: "ADR-0003, ADR-0005, ADR-0011 Q1"},
	{Name: "reports", Disposition: pendingEraser, Owner: "moderation (P7)", Cite: "ADR-0003 data model, ADR-0011 Q1 (reporterId)"},
	{Name: "admin", Disposition: notPersonal, Owner: "admin", Cite: "ADR-0003 data model (feature flags, SafeSearch counter)"},
	// notifications is declared by identity (the unread count reads it) but nothing creates documents until P6 ships
	// the notifications slice and its Eraser.
	{Name: "notifications", Sub: true, Disposition: pendingEraser, Owner: "notifications (P6)", Cite: "ADR-0003 data model users/{uid}/notifications, ADR-0011 Q1"},
}

// gcsPrefixRow is one GCS object namespace.
type gcsPrefixRow struct {
	Bucket, Prefix string
	Disposition    disposition
	Step, Cite     string
}

var lifecycleGCSPrefixes = []gcsPrefixRow{
	{Bucket: "exports (private)", Prefix: "<exportId>.json", Disposition: erasedByStep, Step: "identity", Cite: "ADR-0011 Q1 step 5 (objects deleted before the exports docs); 7-day lifecycle rule as backstop"},
	{Bucket: "media (public-read)", Prefix: "media/{ownerId}/...", Disposition: pendingEraser, Cite: "ADR-0005, ADR-0011 Q1 (P4 registers the media Eraser)"},
}

// residueAllowance is one thing a post-deletion sweep may still find that mentions the deleted uid. Everything else
// the sweep finds is a defect (ADR-0011 Q10). A new entry needs an ADR amendment and a privacy-policy update in the
// same PR.
type residueAllowance struct {
	Collection string
	// Field is the top-level field that may hold the uid ("" = any field of that collection).
	Field string
	Cite  string
}

var residueAllowlist = []residueAllowance{
	{Collection: "idempotency", Cite: "ADR-0011 Q10 (a): idempotency/* uid until its 24 h TTL"},
	{Collection: "graph", Field: "muted", Cite: "ADR-0011 Q10 (b): other users' muted[] (lazy clean-up, ADR-0008 T27)"},
	{Collection: "graph", Field: "blocked", Cite: "ADR-0011 Q10 (b): other users' blocked[] (lazy clean-up, ADR-0008 T27)"},
	{Collection: "posts", Field: "mentionIds", Cite: "ADR-0011 Q10 (c): mentions in others' posts (runbook 3b, P6 ADR)"},
	{Collection: "posts", Field: "mentions", Cite: "ADR-0011 Q10 (c): mentions in others' posts (runbook 3b, P6 ADR)"},
}

// allowed reports whether a hit for the deleted uid in collection/field is on the Q10 allowlist.
func allowed(collection, field string) bool {
	return slices.ContainsFunc(residueAllowlist, func(a residueAllowance) bool {
		return a.Collection == collection && (a.Field == "" || a.Field == field)
	})
}

var collectionNameConst = regexp.MustCompile(`(?i)collection$`)

// collectionRef is a collection name found in non-test source.
type collectionRef struct {
	Name, Where string
}

// scanCollectionNames parses the non-test sources under roots and returns every collection the code names: string
// constants/vars whose identifier ends in "collection" (case-insensitive, so Subcollection too) and literal
// arguments of .Collection(...) / .CollectionGroup(...) calls.
func scanCollectionNames(t *testing.T, roots ...string) []collectionRef {
	t.Helper()
	var out []collectionRef
	fset := token.NewFileSet()
	for _, root := range roots {
		err := filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
			if err != nil {
				return err
			}
			if d.IsDir() {
				if d.Name() == "gen" || d.Name() == "testdata" {
					return filepath.SkipDir
				}
				return nil
			}
			if !strings.HasSuffix(path, ".go") || strings.HasSuffix(path, "_test.go") {
				return nil
			}
			f, perr := parser.ParseFile(fset, path, nil, 0)
			if perr != nil {
				return perr
			}
			ast.Inspect(f, func(n ast.Node) bool {
				switch n := n.(type) {
				case *ast.ValueSpec:
					for i, id := range n.Names {
						if i >= len(n.Values) || !collectionNameConst.MatchString(id.Name) {
							continue
						}
						if lit, ok := n.Values[i].(*ast.BasicLit); ok && lit.Kind == token.STRING {
							s, _ := strconv.Unquote(lit.Value)
							out = append(out, collectionRef{s, id.Name + " at " + fset.Position(id.Pos()).String()})
						}
					}
				case *ast.CallExpr:
					sel, ok := n.Fun.(*ast.SelectorExpr)
					if !ok || (sel.Sel.Name != "Collection" && sel.Sel.Name != "CollectionGroup") || len(n.Args) == 0 {
						return true
					}
					if lit, ok := n.Args[0].(*ast.BasicLit); ok && lit.Kind == token.STRING {
						s, _ := strconv.Unquote(lit.Value)
						out = append(out, collectionRef{s, sel.Sel.Name + "(" + lit.Value + ") at " + fset.Position(n.Pos()).String()})
					}
				}
				return true
			})
			return nil
		})
		if err != nil {
			t.Fatalf("scan %s: %v", root, err)
		}
	}
	return out
}

func rowFor(name string) (collectionRow, bool) {
	for _, r := range lifecycleCollections {
		if r.Name == name {
			return r, true
		}
	}
	return collectionRow{}, false
}

// readOnlyToday lists pendingEraser collections the code already names but never writes (so there is nothing to erase
// yet). Adding to it needs the same review as an allowlist entry.
var readOnlyToday = map[string]bool{
	"notifications": true, // identity.UnreadNotificationCount only counts; the P6 slice creates documents.
}

// coverageProblems checks refs and the table against the registered step and section names. It is a function so the
// mutation tests below can prove the guard fails on each kind of gap.
func coverageProblems(refs []collectionRef, rows []collectionRow, steps, sections []string) []string {
	var problems []string
	byName := map[string]collectionRow{}
	for _, r := range rows {
		byName[r.Name] = r
	}
	for _, ref := range refs {
		row, ok := byName[ref.Name]
		if !ok {
			problems = append(problems, "collection "+strconv.Quote(ref.Name)+" ("+ref.Where+") has no row in lifecycleCollections: register an Eraser (or a Q10 allowlist entry) and add the row")
			continue
		}
		if row.Disposition == pendingEraser && !readOnlyToday[row.Name] {
			problems = append(problems, "collection "+strconv.Quote(ref.Name)+" ("+ref.Where+") is now named in code but its row is still pendingEraser: register the Eraser and update the row")
		}
	}
	for _, r := range rows {
		if r.Cite == "" || r.Owner == "" {
			problems = append(problems, "row "+strconv.Quote(r.Name)+" has no Owner/Cite")
		}
		switch r.Disposition {
		case erasedByStep:
			if r.Step != "identity" && !slices.Contains(steps, r.Step) {
				problems = append(problems, "row "+strconv.Quote(r.Name)+": step "+strconv.Quote(r.Step)+" is not registered (steps: "+strings.Join(steps, ",")+")")
			}
			if r.Section != "" && r.Section != "profile" && r.Section != "account" && !slices.Contains(sections, r.Section) {
				problems = append(problems, "row "+strconv.Quote(r.Name)+": export section "+strconv.Quote(r.Section)+" is not registered")
			}
			if r.Section == "" && r.ExportNote == "" {
				problems = append(problems, "row "+strconv.Quote(r.Name)+": neither an export section nor an ExportNote")
			}
		case pendingEraser, notPersonal:
		default:
			problems = append(problems, "row "+strconv.Quote(r.Name)+" has no disposition")
		}
	}
	sort.Strings(problems)
	return problems
}

func registeredLifecycle(t *testing.T) (steps, sections []string) {
	t.Helper()
	l, err := identity.NewLifecycle(identity.LifecycleDeps{
		Repo: stubRepo{}, Cache: identity.NewCache(time.Minute), Publisher: stubPub{}, Auth: stubAuth{},
		ExportsPerDay: 1, ExportRetention: time.Hour, ExportURLTTL: time.Minute,
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := registerLifecycleModules(l, posts.NewFirestoreRepo(nil), graph.NewFirestoreRepo(nil)); err != nil {
		t.Fatal(err)
	}
	return l.StepNames(), l.ExportSectionNames()
}

// TestLifecycleCollections_EveryCollectionHasARow is the T11 gate: it fails `make ci` naming any collection constant
// or Collection("...") literal in backend/internal or backend/pkg/platform that has no row, any row whose Eraser or
// export section is not registered, and any pendingEraser row whose collection the code started writing.
func TestLifecycleCollections_EveryCollectionHasARow(t *testing.T) {
	refs := scanCollectionNames(t, "..", "../../pkg/platform")
	if len(refs) < 8 {
		t.Fatalf("the scan found only %d collection names (%v): the scanner or the layout changed", len(refs), refs)
	}
	steps, sections := registeredLifecycle(t)
	if problems := coverageProblems(refs, lifecycleCollections, steps, sections); len(problems) > 0 {
		t.Fatalf("collection coverage:\n  %s", strings.Join(problems, "\n  "))
	}
	got := map[string]bool{}
	for _, r := range refs {
		got[r.Name] = true
	}
	for _, want := range []string{"users", "handles", "exports", "private", "quotas", "idempotency", "graph", "follows", "posts"} {
		if !got[want] {
			t.Errorf("the scan did not find %q: the scanner missed a naming pattern", want)
		}
	}
}

// TestLifecycleCollections_GuardCatchesGaps proves the guard itself: each kind of gap produces a failure that names
// the collection.
func TestLifecycleCollections_GuardCatchesGaps(t *testing.T) {
	steps, sections := registeredLifecycle(t)
	real := scanCollectionNames(t, "..", "../../pkg/platform")
	tests := []struct {
		name string
		refs []collectionRef
		rows []collectionRow
		want string
	}{
		{"new collection constant without a row", append(slices.Clone(real), collectionRef{"bookmarks", "bookmarksCollection at x.go:1"}), lifecycleCollections, `"bookmarks"`},
		{"row names an unregistered step", nil, append(slices.Clone(lifecycleCollections), collectionRow{Name: "likes2", Disposition: erasedByStep, Step: "engagement", ExportNote: "n", Owner: "o", Cite: "c"}), `step "engagement" is not registered`},
		{"row names an unregistered section", nil, append(slices.Clone(lifecycleCollections), collectionRow{Name: "x", Disposition: erasedByStep, Step: "graph", Section: "likes", Owner: "o", Cite: "c"}), `export section "likes" is not registered`},
		{"pending row for a collection the code writes", []collectionRef{{"media", "mediaCollection at m.go:1"}}, lifecycleCollections, `still pendingEraser`},
		{"row without a citation", nil, []collectionRow{{Name: "x", Disposition: notPersonal, Owner: "o"}}, `no Owner/Cite`},
		{"row without a disposition", nil, []collectionRow{{Name: "x", Owner: "o", Cite: "c"}}, `no disposition`},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			problems := strings.Join(coverageProblems(tt.refs, tt.rows, steps, sections), "\n")
			if !strings.Contains(problems, tt.want) {
				t.Errorf("problems = %q, want one containing %q", problems, tt.want)
			}
		})
	}
	if problems := coverageProblems(nil, lifecycleCollections, steps, sections); len(problems) != 0 {
		t.Errorf("the shipped table has problems on its own: %v", problems)
	}
}

// TestLifecycleCollections_AllowlistIsCited: every residue allowance and row cites its ADR or runbook line, and the
// allowlist is exactly the Q10 set (a growth of it is a reviewed change, not a drive-by).
func TestLifecycleCollections_AllowlistIsCited(t *testing.T) {
	cite := regexp.MustCompile(`ADR-\d{4}|runbook`)
	for _, a := range residueAllowlist {
		if !cite.MatchString(a.Cite) {
			t.Errorf("allowlist entry %s.%s cites no ADR/runbook: %q", a.Collection, a.Field, a.Cite)
		}
	}
	for _, r := range lifecycleCollections {
		if !cite.MatchString(r.Cite) {
			t.Errorf("row %q cites no ADR: %q", r.Name, r.Cite)
		}
	}
	steps, _ := registeredLifecycle(t)
	for _, g := range lifecycleGCSPrefixes {
		if !cite.MatchString(g.Cite) {
			t.Errorf("GCS row %s/%s cites no ADR: %q", g.Bucket, g.Prefix, g.Cite)
		}
		if g.Disposition == erasedByStep && g.Step != "identity" && !slices.Contains(steps, g.Step) {
			t.Errorf("GCS row %s/%s: step %q is not registered", g.Bucket, g.Prefix, g.Step)
		}
	}
	// The allowlist matcher the emulator sweep uses: Q10 entries match, everything else does not.
	for _, tt := range []struct {
		collection, field string
		want              bool
	}{
		{"idempotency", "uid", true}, {"graph", "blocked", true}, {"graph", "muted", true}, {"posts", "mentionIds", true},
		{"graph", "blockedBy", false}, {"graph", "following", false}, {"posts", "authorId", false}, {"follows", "followerId", false},
		{"exports", "uid", false}, {"handles", "uid", false}, {"users", "__name__", false}, {"bookmarks", "uid", false},
	} {
		if got := allowed(tt.collection, tt.field); got != tt.want {
			t.Errorf("allowed(%q, %q) = %v, want %v", tt.collection, tt.field, got, tt.want)
		}
	}
	if row, ok := rowFor("exports"); !ok || row.Step != "identity" {
		t.Errorf("rowFor(exports) = %+v, %v", row, ok)
	}
	if _, ok := rowFor("bookmarks"); ok {
		t.Error("rowFor(bookmarks) found a row")
	}
	if got, want := len(residueAllowlist), 5; got != want {
		t.Errorf("residue allowlist has %d entries, want %d: a new entry needs an ADR amendment and a privacy-policy update (Q10)", got, want)
	}
}
