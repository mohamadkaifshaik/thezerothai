package search

import (
	"context"
	"slices"
)

// Load is GetAll of trends/current and trends/hidden, counted as one get.
func (f *fakeTrendsStore) Load(context.Context) (*TrendsDoc, []string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.gets++
	if f.getErr != nil {
		return nil, nil, f.getErr
	}
	if f.hiddenErr != nil {
		return nil, nil, f.hiddenErr
	}
	hidden := slices.Clone(f.hidden)
	if f.doc == nil {
		return nil, hidden, nil
	}
	d := *f.doc
	return &d, hidden, nil
}

func (f *fakeTrendsStore) Hidden(context.Context) ([]string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.hiddenGets++
	if f.hiddenErr != nil {
		return nil, f.hiddenErr
	}
	return slices.Clone(f.hidden), nil
}

func (f *fakeTrendsStore) Hide(_ context.Context, tag string) (HideResult, error) {
	key, err := HideKey(tag)
	if err != nil {
		return HideResult{}, err
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	if slices.Contains(f.hidden, key) {
		return HideResult{Key: key, Count: len(f.hidden)}, nil
	}
	if len(f.hidden) >= maxHiddenTags {
		return HideResult{Key: key, Count: len(f.hidden)}, ErrHiddenFull
	}
	f.hidden = append(f.hidden, key)
	f.hideWrites++
	return HideResult{Key: key, Changed: true, Count: len(f.hidden)}, nil
}

func (f *fakeTrendsStore) Unhide(_ context.Context, tag string) (HideResult, error) {
	key, err := HideKey(tag)
	if err != nil {
		return HideResult{}, err
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	i := slices.Index(f.hidden, key)
	if i < 0 {
		return HideResult{Key: key, Count: len(f.hidden)}, nil
	}
	f.hidden = slices.Delete(f.hidden, i, i+1)
	f.hideWrites++
	return HideResult{Key: key, Changed: true, Count: len(f.hidden)}, nil
}
