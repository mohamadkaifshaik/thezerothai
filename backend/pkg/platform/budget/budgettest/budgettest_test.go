package budgettest

import (
	"fmt"
	"strings"
	"testing"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
)

// recorder is a testing.TB that records Errorf calls instead of failing the real test, so Assert's failure
// path can itself be asserted (testing-strategy: a budget regression must fail; here we prove it does).
type recorder struct {
	testing.TB
	errs []string
}

func (r *recorder) Helper() {}
func (r *recorder) Errorf(format string, args ...any) {
	r.errs = append(r.errs, fmt.Sprintf(format, args...))
}

func counter(reads, writes, deletes int64) *budget.Counter {
	c := &budget.Counter{}
	c.AddReads(reads)
	c.AddWrites(writes)
	c.AddDeletes(deletes)
	return c
}

func TestAssert(t *testing.T) {
	tests := []struct {
		name     string
		c        *budget.Counter
		b        Budget
		wantErrs []string // substrings, one per expected error, in order
	}{
		{"at budget records nothing", counter(3, 2, 1), Budget{Reads: 3, Writes: 2, Deletes: 1}, nil},
		{"under budget records nothing", counter(0, 0, 0), Budget{Reads: 3, Writes: 2, Deletes: 1}, nil},
		{"reads over", counter(5, 0, 0), Budget{Reads: 4, Writes: 2, Deletes: 1}, []string{"rpc: Reads() = 5, want <= 4"}},
		{"writes over", counter(0, 3, 0), Budget{Reads: 4, Writes: 2, Deletes: 1}, []string{"rpc: Writes() = 3, want <= 2"}},
		{"deletes over", counter(0, 0, 2), Budget{Reads: 4, Writes: 2, Deletes: 1}, []string{"rpc: Deletes() = 2, want <= 1"}},
		{"all over records three", counter(9, 8, 7), Budget{}, []string{"Reads() = 9, want <= 0", "Writes() = 8, want <= 0", "Deletes() = 7, want <= 0"}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			rec := &recorder{TB: t}
			Assert(rec, "rpc", tt.c, tt.b)
			if len(rec.errs) != len(tt.wantErrs) {
				t.Fatalf("recorded %d errors %q, want %d", len(rec.errs), rec.errs, len(tt.wantErrs))
			}
			for i, want := range tt.wantErrs {
				if !strings.Contains(rec.errs[i], want) {
					t.Errorf("error %d = %q, want it to contain %q", i, rec.errs[i], want)
				}
			}
		})
	}
}
