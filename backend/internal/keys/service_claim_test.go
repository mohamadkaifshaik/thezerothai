package keys

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"sort"
	"strings"
	"testing"
	"time"

	"connectrpc.com/connect"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

const (
	uidBob   = "uid-bob"
	uidCarol = "uid-carol"
	uidDan   = "uid-dan"
	devB1    = "device-bob-000000001"
	devB2    = "device-bob-000000002"
)

type claimRig struct {
	svc   Service
	repo  *fakeRepo
	perm  *fakePermission
	flags fakeFlags
	clk   *fakeClock
}

// newClaimRig: alice is the caller; the flag is on for alice, bob and carol (dan has it off); nobody is refused.
func newClaimRig(t *testing.T) *claimRig {
	t.Helper()
	r := &claimRig{
		repo:  newFakeRepo(),
		perm:  &fakePermission{refuse: map[string]error{}},
		flags: fakeFlags{on: map[string]bool{uidA: true, uidBob: true, uidCarol: true}},
		clk:   &fakeClock{t: t0},
	}
	r.svc = New(Deps{Repo: r.repo, Now: r.clk.now, Permission: r.perm, Flags: r.flags})
	return r
}

// seed registers a device for uid at the rig's clock and uploads packages and an optional last resort.
func (r *claimRig) seed(t *testing.T, uid, id string, tag byte, packages [][]byte, lastResort []byte) {
	t.Helper()
	ctx := context.Background()
	if _, err := r.repo.Register(ctx, uid, Device{ID: id, SignatureKey: sigKey(tag)}, r.clk.t); err != nil {
		t.Fatal(err)
	}
	if len(packages) > 0 || lastResort != nil {
		if _, _, err := r.repo.Upload(ctx, uid, id, packages, lastResort, r.clk.t); err != nil {
			t.Fatal(err)
		}
	}
}

// wireBytes is an error as the client receives it: code, message and every attached detail, serialised.
func wireBytes(t *testing.T, err error) []byte {
	t.Helper()
	ce := apierr.ToConnect(err)
	if ce == nil {
		t.Fatal("no error")
	}
	var buf bytes.Buffer
	buf.WriteString(ce.Code().String() + "|" + ce.Message() + "|")
	for _, d := range ce.Details() {
		v, verr := d.Value()
		if verr != nil {
			t.Fatalf("detail: %v", verr)
		}
		raw, merr := proto.MarshalOptions{Deterministic: true}.Marshal(v)
		if merr != nil {
			t.Fatalf("marshal detail: %v", merr)
		}
		buf.Write(raw)
	}
	return buf.Bytes()
}

// Every refusal cause (and an unknown user, refused by the permission seam) answers byte-identical CANNOT_MESSAGE on
// both RPCs, before the target's flag or any repository read; a refused target whose flag is off or who has devices
// looks the same.
func TestRefusalsAreByteIdentical(t *testing.T) {
	r := newClaimRig(t)
	r.seed(t, uidBob, devB1, 2, pkgs(0, 3), nil)
	causes := map[string]error{
		uidBob:        fmt.Errorf("%w: blocked by target", ErrCannotMessage),
		uidCarol:      fmt.Errorf("%w: target blocked by caller", ErrCannotMessage),
		uidDan:        fmt.Errorf("%w: following only (flag off too)", ErrCannotMessage),
		"uid-unknown": fmt.Errorf("%w: no such user", ErrCannotMessage),
		"uid-gone":    fmt.Errorf("%w: not ACTIVE", ErrCannotMessage),
		"uid-plain":   ErrCannotMessage,
	}
	r.perm.refuse = causes
	var want []byte
	check := func(name string, err error) {
		t.Helper()
		wantErr(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_CANNOT_MESSAGE)
		var ae *apierr.Error
		if errors.As(err, &ae) && (len(ae.Metadata) != 0 || ae.Unwrap() != nil || ae.RetryAfter != 0) {
			t.Fatalf("%s: refusal carries metadata/cause/retry: %+v", name, ae)
		}
		got := wireBytes(t, err)
		if want == nil {
			want = got
		}
		if !bytes.Equal(got, want) {
			t.Fatalf("%s: wire form differs:\n got %q\nwant %q", name, got, want)
		}
	}
	for target := range causes {
		_, err := r.svc.GetDevices(context.Background(), uidA, []string{target})
		check("get "+target, err)
		_, err = r.svc.Claim(context.Background(), uidA, target, "")
		check("claim "+target, err)
		// A refused target among allowed ones refuses the whole lookup, wherever it sits.
		_, err = r.svc.GetDevices(context.Background(), uidA, []string{uidA, target})
		check("mixed "+target, err)
	}
	if r.repo.calls != 2 { // only the seed's register and upload
		t.Fatalf("repository touched %d times, want only the 2 seed calls", r.repo.calls)
	}
	if n := len(r.repo.pool[devKey(uidBob, devB1)]); n != 3 {
		t.Fatalf("a refused claim consumed packages: pool %d", n)
	}
}

// A permission failure that is not a refusal is not CANNOT_MESSAGE, and its text carries neither uid.
func TestPermissionFailureIsNotARefusal(t *testing.T) {
	r := newClaimRig(t)
	r.perm.err = errors.New("firestore down reading " + uidBob + " for " + uidA)
	_, err := r.svc.GetDevices(context.Background(), uidA, []string{uidBob})
	if err == nil {
		t.Fatal("want error")
	}
	var ae *apierr.Error
	if errors.As(err, &ae) {
		t.Fatalf("a failure became an API error %v", ae)
	}
	if apierr.ToConnect(err).Code() != connect.CodeInternal {
		t.Fatalf("code = %v", apierr.ToConnect(err).Code())
	}
	for _, id := range []string{uidA, uidBob} {
		if strings.Contains(err.Error(), id) {
			t.Fatalf("error text %q contains %q", err.Error(), id)
		}
	}
	_, err = r.svc.Claim(context.Background(), uidA, uidBob, "")
	if err == nil || strings.Contains(err.Error(), uidBob) || strings.Contains(err.Error(), uidA) {
		t.Fatalf("claim err = %v", err)
	}
}

// The seam's answer reaches the wire as one of three things only: the one refusal (ErrCannotMessage or any apierr with
// reason CANNOT_MESSAGE, whatever its message or metadata), a generic failure that carries nothing of the seam's error
// (whatever apierr code, reason, message, metadata or retry hint it had), or the package's class mapping for contention
// and deadlines. Checked on both RPCs.
func TestPermissionSeamErrorsAreSealed(t *testing.T) {
	ctx := context.Background()
	callBoth := func(t *testing.T, seamErr error) [2]error {
		t.Helper()
		r := newClaimRig(t)
		r.seed(t, uidBob, devB1, 2, pkgs(0, 2), nil)
		r.perm.err = seamErr
		_, gerr := r.svc.GetDevices(ctx, uidA, []string{uidBob})
		_, cerr := r.svc.Claim(ctx, uidA, uidBob, "")
		if n := len(r.repo.pool[devKey(uidBob, devB1)]); n != 2 {
			t.Fatalf("a failed permission check consumed packages: pool %d", n)
		}
		return [2]error{gerr, cerr}
	}
	refusal := wireBytes(t, callBoth(t, ErrCannotMessage)[0])
	generic := wireBytes(t, callBoth(t, errors.New("plain failure"))[0])
	if bytes.Equal(refusal, generic) {
		t.Fatal("refusal and failure have the same wire form")
	}

	sealed := map[string]error{
		"apierr NOT_FOUND for an unknown user": apierr.New(connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "user "+uidBob+" not found").
			WithMeta("why", "unknown_user"),
		"apierr with metadata and retry hint": apierr.New(connect.CodeUnavailable, commonv1.ErrorReason_ERROR_REASON_RATE_LIMITED, "slow down").
			WithMeta("limit", "messaging_send").WithRetryAfter(5 * time.Second),
		"wrapped apierr": fmt.Errorf("adapter: %w", apierr.New(connect.CodePermissionDenied, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "blocked")),
		"apierr with a cause": apierr.New(connect.CodeInternal, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "db").
			WithCause(errors.New("firestore " + uidBob)),
	}
	for name, seamErr := range sealed {
		t.Run(name, func(t *testing.T) {
			for i, err := range callBoth(t, seamErr) {
				var ae *apierr.Error
				if errors.As(err, &ae) {
					t.Fatalf("call %d: the seam's apierr is reachable: %+v", i, ae)
				}
				if got := wireBytes(t, err); !bytes.Equal(got, generic) {
					t.Fatalf("call %d: wire %q, want the generic failure %q", i, got, generic)
				}
				if strings.Contains(err.Error(), uidBob) || strings.Contains(err.Error(), uidA) {
					t.Fatalf("call %d: error text %q carries a uid", i, err.Error())
				}
			}
		})
	}

	refusals := map[string]error{
		"apierr CANNOT_MESSAGE with its own message and metadata": apierr.New(connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_CANNOT_MESSAGE, "blocked by "+uidBob).
			WithMeta("cause", "block").WithRetryAfter(time.Minute),
		"wrapped apierr CANNOT_MESSAGE with another code": fmt.Errorf("adapter: %w", apierr.New(connect.CodePermissionDenied, commonv1.ErrorReason_ERROR_REASON_CANNOT_MESSAGE, "policy")),
	}
	for name, seamErr := range refusals {
		t.Run(name, func(t *testing.T) {
			for i, err := range callBoth(t, seamErr) {
				if got := wireBytes(t, err); !bytes.Equal(got, refusal) {
					t.Fatalf("call %d: wire %q, want the standard refusal %q", i, got, refusal)
				}
			}
		})
	}

	// Classes keep the package's mapping (as for repository errors): UNAVAILABLE with a 1 s retry, nothing else.
	classes := map[string]error{
		"deadline":            fmt.Errorf("adapter: %w", context.DeadlineExceeded),
		"grpc deadline":       status.Error(codes.DeadlineExceeded, "slow "+uidBob),
		"contention":          status.Error(codes.Aborted, "lock "+uidBob),
		"apierr over a cause": apierr.New(connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "gone").WithCause(context.DeadlineExceeded),
	}
	for name, seamErr := range classes {
		t.Run(name, func(t *testing.T) {
			for i, err := range callBoth(t, seamErr) {
				wantErr(t, err, connect.CodeUnavailable, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED)
				var ae *apierr.Error
				if errors.As(err, &ae) && (ae.RetryAfter != time.Second || len(ae.Metadata) != 0 || ae.Message != "temporarily busy, please retry") {
					t.Fatalf("call %d: %+v", i, ae)
				}
			}
		})
	}
}

// Missing seams fail closed: no Permission refuses every other user, no Flags means every target's flag is off.
func TestNilSeams(t *testing.T) {
	repo := newFakeRepo()
	s := New(Deps{Repo: repo, Now: func() time.Time { return t0 }, Flags: fakeFlags{on: map[string]bool{uidBob: true}}})
	_, err := s.GetDevices(context.Background(), uidA, []string{uidBob})
	wantErr(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_CANNOT_MESSAGE)
	s = New(Deps{Repo: repo, Now: func() time.Time { return t0 }, Permission: &fakePermission{}})
	if _, err := repo.Register(context.Background(), uidBob, Device{ID: devB1, SignatureKey: sigKey(2)}, t0); err != nil {
		t.Fatal(err)
	}
	got, err := s.GetDevices(context.Background(), uidA, []string{uidBob})
	if err != nil || len(got[uidBob]) != 0 {
		t.Fatalf("got %v, %v; want an empty list", got, err)
	}
}

func TestGetDevicesValidation(t *testing.T) {
	r := newClaimRig(t)
	eleven := make([]string, 11)
	for i := range eleven {
		eleven[i] = fmt.Sprintf("uid-%02d", i)
	}
	cases := map[string][]string{
		"none":         nil,
		"empty list":   {},
		"eleven":       eleven,
		"duplicate":    {uidBob, uidCarol, uidBob},
		"self twice":   {uidA, uidA},
		"invalid":      {"bad uid!"},
		"empty string": {""},
		"too long":     {strings.Repeat("a", 129)},
	}
	for name, in := range cases {
		t.Run(name, func(t *testing.T) {
			_, err := r.svc.GetDevices(context.Background(), uidA, in)
			wantValidation(t, err, "user_ids")
		})
	}
	if r.repo.calls != 0 || len(r.perm.calls) != 0 {
		t.Fatalf("validation reached the repo (%d) or permission (%d)", r.repo.calls, len(r.perm.calls))
	}
	if _, err := r.svc.GetDevices(context.Background(), uidA, eleven[:10]); err != nil {
		t.Fatalf("ten ids: %v", err)
	}
}

// Results are keyed by every requested id (flag-off and device-less users get an empty list), only active devices are
// returned (exactly 30 days unseen is inactive), other users' pool counts are zeroed and the caller's own are kept, and
// the caller's own id skips both the permission and the flag check.
func TestGetDevicesResults(t *testing.T) {
	r := newClaimRig(t)
	r.seed(t, uidA, devID, 1, pkgs(0, 4), []byte("alice-lr"))
	r.seed(t, uidBob, devB1, 2, pkgs(10, 3), []byte("bob-lr"))
	r.seed(t, uidDan, "device-dan-00000001", 4, pkgs(20, 1), nil) // flag off for dan
	r.clk.t = t0.Add(InactiveAfter - time.Second)
	r.seed(t, uidBob, devB2, 3, pkgs(30, 2), nil) // seen 30 days after devB1
	r.clk.t = t0.Add(InactiveAfter)               // devB1 and alice's device: exactly 30 days unseen
	r.flags.on[uidA] = false                      // the handler guards the caller; the service does not ask again
	r.svc = New(Deps{Repo: r.repo, Now: r.clk.now, Permission: r.perm, Flags: r.flags})

	req := []string{uidCarol, uidBob, uidDan, uidA}
	got, err := r.svc.GetDevices(context.Background(), uidA, req)
	if err != nil {
		t.Fatal(err)
	}
	keys := make([]string, 0, len(got))
	for k := range got {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	if want := []string{uidA, uidBob, uidCarol, uidDan}; fmt.Sprint(keys) != fmt.Sprint(want) {
		t.Fatalf("result keys %v, want %v", keys, want)
	}
	if len(got[uidCarol]) != 0 || len(got[uidDan]) != 0 || len(got[uidA]) != 0 {
		t.Fatalf("carol %v dan %v alice %v: want empty (no devices / flag off / inactive)", got[uidCarol], got[uidDan], got[uidA])
	}
	bob := got[uidBob]
	if len(bob) != 1 || bob[0].ID != devB2 || bob[0].PoolCount != 0 || bob[0].HasLastResort || !bytes.Equal(bob[0].SignatureKey, sigKey(3)) {
		t.Fatalf("bob = %+v, want only the active devB2 with zeroed counts", bob)
	}
	if fmt.Sprint(r.perm.calls) != fmt.Sprint([]string{uidCarol, uidBob, uidDan}) {
		t.Fatalf("permission checked %v, want every other user in request order, never the caller", r.perm.calls)
	}

	// The caller's own active devices keep their counts.
	r.clk.t = t0.Add(time.Hour)
	got, err = r.svc.GetDevices(context.Background(), uidA, []string{uidA})
	if err != nil {
		t.Fatal(err)
	}
	if mine := got[uidA]; len(mine) != 1 || mine[0].PoolCount != 4 || !mine[0].HasLastResort {
		t.Fatalf("own devices %+v, want pool 4 and a last resort", mine)
	}
}

// Lookups and claims never refresh the target's last-seen time, and returned bytes never alias the store.
func TestLookupAndClaimDoNotTouchLastSeenOrAlias(t *testing.T) {
	r := newClaimRig(t)
	r.seed(t, uidBob, devB1, 2, pkgs(0, 2), []byte("bob-lr"))
	r.clk.t = t0.Add(10 * 24 * time.Hour)
	got, err := r.svc.GetDevices(context.Background(), uidA, []string{uidBob})
	if err != nil {
		t.Fatal(err)
	}
	got[uidBob][0].SignatureKey[0] = 0xFF
	cl, err := r.svc.Claim(context.Background(), uidA, uidBob, "")
	if err != nil || len(cl) != 1 {
		t.Fatalf("claim %v, %v", cl, err)
	}
	cl[0].SignatureKey[0], cl[0].KeyPackage[0] = 0xFF, 0xFF
	d := r.repo.devices[uidBob][0]
	if !d.LastSeenAt.Equal(t0) {
		t.Fatalf("last seen moved to %v", d.LastSeenAt)
	}
	if !bytes.Equal(d.SignatureKey, sigKey(2)) {
		t.Fatal("caller's change reached the stored signature key")
	}
	for _, p := range r.repo.pool[devKey(uidBob, devB1)] {
		if p[0] == 0xFF {
			t.Fatal("caller's change reached a stored package")
		}
	}
}

// Claim consumes one one-time package per active device, then hands out the last-resort package repeatedly (kept), and
// with neither says HasKeyPackage false. Inactive devices are left out.
func TestClaimConsumesThenLastResort(t *testing.T) {
	r := newClaimRig(t)
	r.seed(t, uidBob, devB1, 2, pkgs(0, 2), []byte("bob-lr"))
	r.seed(t, uidBob, devB2, 3, nil, nil)
	r.seed(t, uidBob, "device-bob-000000003", 4, pkgs(50, 5), []byte("old-lr"))
	r.clk.t = t0.Add(InactiveAfter - time.Hour)
	if _, err := r.repo.Register(context.Background(), uidBob, Device{ID: devB1, SignatureKey: sigKey(2)}, r.clk.t); err != nil {
		t.Fatal(err)
	}
	if _, err := r.repo.Register(context.Background(), uidBob, Device{ID: devB2, SignatureKey: sigKey(3)}, r.clk.t); err != nil {
		t.Fatal(err)
	}
	r.clk.t = t0.Add(InactiveAfter) // device 3: exactly 30 days unseen

	seen := map[string]bool{}
	for i := 0; i < 4; i++ {
		cl, err := r.svc.Claim(context.Background(), uidA, uidBob, "")
		if err != nil {
			t.Fatal(err)
		}
		if len(cl) != 2 || cl[0].DeviceID != devB1 || cl[1].DeviceID != devB2 {
			t.Fatalf("claim %d: %+v, want devB1 then devB2 (the inactive one left out)", i, cl)
		}
		b1, b2 := cl[0], cl[1]
		if !bytes.Equal(b1.SignatureKey, sigKey(2)) || b2.HasKeyPackage || b2.LastResort || len(b2.KeyPackage) != 0 {
			t.Fatalf("claim %d: %+v / %+v", i, b1, b2)
		}
		switch {
		case i < 2:
			if !b1.HasKeyPackage || b1.LastResort || seen[string(b1.KeyPackage)] {
				t.Fatalf("claim %d: want a fresh one-time package, got %+v", i, b1)
			}
			seen[string(b1.KeyPackage)] = true
		default:
			if !b1.HasKeyPackage || !b1.LastResort || string(b1.KeyPackage) != "bob-lr" {
				t.Fatalf("claim %d: want the last resort, got %+v", i, b1)
			}
		}
	}
	if n := len(r.repo.pool[devKey(uidBob, "device-bob-000000003")]); n != 5 {
		t.Fatalf("inactive device's pool = %d, want untouched 5", n)
	}
}

func TestClaimFlagOffTargetIsEmpty(t *testing.T) {
	r := newClaimRig(t)
	r.seed(t, uidDan, "device-dan-00000001", 4, pkgs(0, 3), nil)
	cl, err := r.svc.Claim(context.Background(), uidA, uidDan, "")
	if err != nil || len(cl) != 0 {
		t.Fatalf("claim %v, %v; want empty success", cl, err)
	}
	if n := len(r.repo.pool[devKey(uidDan, "device-dan-00000001")]); n != 3 {
		t.Fatalf("flag-off target's pool = %d", n)
	}
}

func TestClaimValidationAndExclude(t *testing.T) {
	r := newClaimRig(t)
	r.seed(t, uidA, devID, 1, pkgs(0, 3), nil)
	r.seed(t, uidA, devID2, 5, pkgs(10, 3), nil)
	r.seed(t, uidBob, devB1, 2, pkgs(20, 3), nil)
	r.seed(t, uidBob, devB2, 3, pkgs(30, 3), nil)
	ctx := context.Background()

	for name, target := range map[string]string{"empty": "", "invalid": "bad uid!", "too long": strings.Repeat("a", 129)} {
		_, err := r.svc.Claim(ctx, uidA, target, "")
		wantValidation(t, err, "user_id")
		_ = name
	}
	for name, ex := range map[string]string{"self, none": "", "self, bad format": "short", "self, not my device": devB1} {
		_, err := r.svc.Claim(ctx, uidA, uidA, ex)
		if err == nil {
			t.Fatalf("%s: want validation", name)
		}
		wantValidation(t, err, "exclude_device_id")
	}
	_, err := r.svc.Claim(ctx, uidA, uidBob, "bad id!")
	wantValidation(t, err, "exclude_device_id")
	if len(r.perm.calls) != 0 {
		t.Fatalf("validation reached the permission check: %v", r.perm.calls)
	}
	for _, k := range []string{devKey(uidA, devID), devKey(uidA, devID2), devKey(uidBob, devB1), devKey(uidBob, devB2)} {
		if len(r.repo.pool[k]) != 3 {
			t.Fatalf("a refused claim consumed from %s", k)
		}
	}

	// Own claim: the excluded device keeps its pool; permission is not asked.
	cl, err := r.svc.Claim(ctx, uidA, uidA, devID)
	if err != nil || len(cl) != 1 || cl[0].DeviceID != devID2 || !cl[0].HasKeyPackage {
		t.Fatalf("own claim %+v, %v", cl, err)
	}
	if len(r.repo.pool[devKey(uidA, devID)]) != 3 || len(r.repo.pool[devKey(uidA, devID2)]) != 2 {
		t.Fatal("own claim consumed from the wrong device")
	}
	if len(r.perm.calls) != 0 {
		t.Fatalf("own claim asked permission: %v", r.perm.calls)
	}
	// Own claim excluding an inactive own device is still allowed (it is one of the caller's devices).
	r.clk.t = t0.Add(InactiveAfter)
	if _, err := r.svc.Claim(ctx, uidA, uidA, devID); err != nil {
		t.Fatalf("exclude of an inactive own device: %v", err)
	}

	// Another user's claim: a well-formed exclude is accepted and does not stop any device being claimed.
	r.clk.t = t0.Add(time.Hour)
	cl, err = r.svc.Claim(ctx, uidA, uidBob, devB1)
	if err != nil || len(cl) != 2 {
		t.Fatalf("other-user claim with exclude: %+v, %v", cl, err)
	}
}

func TestClaimAndLookupLogCountsOnly(t *testing.T) {
	r := newClaimRig(t)
	r.seed(t, uidBob, devB1, 2, [][]byte{[]byte("secret-package-1")}, []byte("secret-last-resort"))
	r.seed(t, uidBob, devB2, 3, nil, []byte("secret-last-resort-2"))
	secrets := []string{uidBob, uidA, devB1, devB2, string(sigKey(2)), string(sigKey(3)), "secret-"}
	noSecrets := func(info *logger.RequestInfo) {
		t.Helper()
		for _, a := range info.Fields() {
			for _, sec := range secrets {
				if strings.Contains(a.Value.String(), sec) || strings.Contains(a.Key, sec) {
					t.Fatalf("request field %s=%q contains %q", a.Key, a.Value.String(), sec)
				}
			}
		}
	}
	want := func(info *logger.RequestInfo, kv ...any) {
		t.Helper()
		for i := 0; i+1 < len(kv); i += 2 {
			got, _ := info.Get(kv[i].(string))
			if fmt.Sprint(got) != fmt.Sprint(kv[i+1]) {
				t.Fatalf("%s = %v, want %v", kv[i], got, kv[i+1])
			}
		}
	}

	ctx, info := logger.WithRequestInfo(context.Background())
	if _, err := r.svc.GetDevices(ctx, uidA, []string{uidBob, uidCarol}); err != nil {
		t.Fatal(err)
	}
	noSecrets(info)
	want(info, "keys_op", "get_devices", "outcome", "done", "user_count", 2, "device_count", 2)

	ctx, info = logger.WithRequestInfo(context.Background())
	if _, err := r.svc.Claim(ctx, uidA, uidBob, ""); err != nil {
		t.Fatal(err)
	}
	noSecrets(info)
	want(info, "keys_op", "claim", "outcome", "done", "device_count", 2, "package_count", 1, "last_resort_count", 1)

	r.perm.refuse = map[string]error{uidBob: ErrCannotMessage}
	ctx, info = logger.WithRequestInfo(context.Background())
	_, _ = r.svc.Claim(ctx, uidA, uidBob, "")
	noSecrets(info)
	want(info, "keys_op", "claim", "outcome", "rejected:cannot_message")

	r.perm.refuse = nil
	r.repo.err = errors.New("boom " + uidBob + " " + devB1)
	ctx, info = logger.WithRequestInfo(context.Background())
	_, err := r.svc.Claim(ctx, uidA, uidBob, "")
	noSecrets(info)
	for _, sec := range []string{uidBob, uidA} {
		if err == nil || strings.Contains(err.Error(), sec) {
			t.Fatalf("claim failure err = %v (contains %q)", err, sec)
		}
	}
	ctx, info = logger.WithRequestInfo(context.Background())
	_, err = r.svc.GetDevices(ctx, uidA, []string{uidBob})
	noSecrets(info)
	if err == nil || strings.Contains(err.Error(), uidBob) {
		t.Fatalf("lookup failure err = %v", err)
	}
}

// panicLookupRepo panics in ActiveDevices, which runs on errgroup goroutines that the request's recover interceptor
// does not cover.
type panicLookupRepo struct{ *fakeRepo }

func (panicLookupRepo) ActiveDevices(context.Context, string, time.Time) ([]Device, error) {
	panic("boom " + uidBob)
}

func TestGetDevicesPanicOnWorkerFailsTheCallOnly(t *testing.T) {
	r := newClaimRig(t)
	s := New(Deps{Repo: panicLookupRepo{r.repo}, Now: r.clk.now, Permission: r.perm, Flags: r.flags})
	_, err := s.GetDevices(context.Background(), uidA, []string{uidBob, uidCarol})
	if err == nil || !strings.Contains(err.Error(), "panic of type string") || strings.Contains(err.Error(), uidBob) {
		t.Fatalf("err = %v, want the panic as this call's error without its value", err)
	}
}
