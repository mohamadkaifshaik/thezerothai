package billing

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"
)

type memoryBindings struct {
	mu   sync.Mutex
	rows map[string]Binding
}

func (m *memoryBindings) EnsureBinding(_ context.Context, b Binding) (Binding, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if prior, ok := m.rows[b.UID]; ok {
		return prior, nil
	}
	m.rows[b.UID] = b
	return b, nil
}

type bindingStoreFunc func(context.Context, Binding) (Binding, error)

func (f bindingStoreFunc) EnsureBinding(ctx context.Context, b Binding) (Binding, error) {
	return f(ctx, b)
}

func TestIdentityReplayAndConcurrentDevices(t *testing.T) {
	store := &memoryBindings{rows: make(map[string]Binding)}
	now := testBinding().CreatedAt
	svc, err := NewIdentityService(store, Sandbox, func() time.Time { return now })
	if err != nil {
		t.Fatal(err)
	}
	const devices = 20
	results := make(chan Binding, devices)
	errorsOut := make(chan error, devices)
	var wg sync.WaitGroup
	for range devices {
		wg.Go(func() {
			b, err := svc.Ensure(context.Background(), "account-a")
			results <- b
			errorsOut <- err
		})
	}
	wg.Wait()
	close(results)
	close(errorsOut)
	for err := range errorsOut {
		if err != nil {
			t.Fatal(err)
		}
	}
	want := store.rows["account-a"]
	for b := range results {
		if b != want || !validBinding(b) {
			t.Fatal("concurrent devices did not converge on one private binding")
		}
	}
	other, err := svc.Ensure(context.Background(), "account-b")
	if err != nil || other.CustomerID == want.CustomerID || other.CustomerID == other.UID {
		t.Fatal("different accounts must have independent opaque identities")
	}
}

func TestIdentityRejectsBadInputsBeforeStorage(t *testing.T) {
	store := bindingStoreFunc(func(context.Context, Binding) (Binding, error) {
		t.Fatal("invalid request reached storage")
		return Binding{}, nil
	})
	if _, err := NewIdentityService(nil, Sandbox, nil); !errors.Is(err, ErrInvalidInput) {
		t.Fatal(err)
	}
	if _, err := NewIdentityService(store, "", nil); !errors.Is(err, ErrInvalidInput) {
		t.Fatal(err)
	}
	svc, err := NewIdentityService(store, Production, nil)
	if err != nil {
		t.Fatal(err)
	}
	for _, uid := range []string{"", "..", ".", "a/b", "a\x00b", "a\nb"} {
		if _, err := svc.Ensure(context.Background(), uid); !errors.Is(err, ErrInvalidInput) {
			t.Fatalf("invalid uid accepted: %v", err)
		}
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := svc.Ensure(ctx, "account-a"); !errors.Is(err, context.Canceled) {
		t.Fatal(err)
	}
}

func TestIdentityValidatesStoredOwnerAndEnvironment(t *testing.T) {
	for _, mutate := range []func(*Binding){
		func(b *Binding) { b.UID = "account-b" },
		func(b *Binding) { b.Environment = Production },
		func(b *Binding) { b.CustomerID = "account-a" },
		func(b *Binding) { b.CreatedAt = time.Time{} },
	} {
		store := bindingStoreFunc(func(_ context.Context, b Binding) (Binding, error) { mutate(&b); return b, nil })
		svc, err := NewIdentityService(store, Sandbox, nil)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := svc.Ensure(context.Background(), "account-a"); !errors.Is(err, ErrOwnership) {
			t.Fatalf("bad stored binding accepted: %v", err)
		}
	}
}

func TestIdentityStorageFailureIsNotAFreeBinding(t *testing.T) {
	store := bindingStoreFunc(func(context.Context, Binding) (Binding, error) { return Binding{}, ErrUnavailable })
	svc, err := NewIdentityService(store, Sandbox, nil)
	if err != nil {
		t.Fatal(err)
	}
	if got, err := svc.Ensure(context.Background(), "account-a"); !errors.Is(err, ErrUnavailable) || got != (Binding{}) {
		t.Fatal("storage failure returned a usable binding")
	}
}
