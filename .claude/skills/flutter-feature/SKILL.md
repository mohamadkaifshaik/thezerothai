---
name: flutter-feature
description: How to scaffold a Flutter feature (data/domain/presentation, BLoC, go_router, freezed, tests) that runs on iOS, Android and Web. Use when creating or restructuring any Flutter screen or feature.
---

# Flutter feature blueprint

```
app/lib/
  core/ (api/, auth/, theme/, router/, storage/, analytics/, widgets/, l10n/)
  features/<feature>/
    data/        <feature>_repository.dart  (connect-dart client + local cache)
    domain/      models (freezed), use-cases if logic is non-trivial
    presentation/ <feature>_screen.dart, widgets/, bloc/ (<feature>_bloc.dart, _event.dart, _state.dart)
app/test/features/<feature>/...   app/integration_test/...
```

## Pattern

```dart
class TimelineBloc extends Bloc<TimelineEvent, TimelineState> {
  String? _cursor;

  TimelineBloc() : super(const TimelineState.initial()) {
    on<TimelineLoad>(_onLoad);
    on<TimelineLoadMore>(_onLoadMore);
    on<TimelineLike>(_onLike);
  }

  Future<void> _onLoad(
    TimelineLoad event,
    Emitter<TimelineState> emit,
  ) async {
    // Load timeline
  }

  Future<void> _onLoadMore(
    TimelineLoadMore event,
    Emitter<TimelineState> emit,
  ) async {
    // Append with cursor
    // Guard concurrent loads
  }

  Future<void> _onLike(
    TimelineLike event,
    Emitter<TimelineState> emit,
  ) async {
    // Optimistic update
    // Rollback on error
  }
}
```

- State management is **BLoC only** (`flutter_bloc`). No Riverpod, `ConsumerWidget`, `AsyncNotifier` or providers.
- Screens provide their bloc with `BlocProvider` (blocs come from the existing DI/repository wiring, not created in `build` repeatedly) and render with `BlocBuilder` (UI only), `BlocListener` (side effects: snackbars, navigation) or `BlocConsumer` (both). Use `buildWhen`/`listenWhen`/`BlocSelector` to limit rebuilds.
- Handle loading/error/data from freezed bloc states with the existing shared state-view widget (check `docs/ui-catalog.md`).
- Widgets never call repositories or mutate state directly: user interactions dispatch events via `context.read<XBloc>().add(...)`; blocs call repositories and emit states.
- Responsive: `LayoutBuilder` breakpoints — mobile (<600) bottom nav, tablet (600–1200) nav rail, desktop (>1200) 3-column like X web.
- Platform: adaptive widgets where it matters (dialogs, pickers), `kIsWeb` guarded features.
- Every screen: widget test (loading/error/data), semantics, dark mode golden.
- Packages baseline: flutter_bloc, bloc, go_router, freezed, json_serializable, connectrpc, firebase_auth, firebase_app_check, firebase_messaging, firebase_crashlytics, firebase_remote_config, cached_network_image, flutter_image_compress, image_picker, drift, intl.

## Cost-aware client rules (the client is our cheapest cache)

- Clients never read Firestore/Storage directly (except public media URLs) — everything goes through the API.
- Persist timeline, profiles and own follow/like state locally (drift on mobile, drift-web/IndexedDB on web); render from cache first.
- Refresh incrementally with `since` cursors (see `timeline` skill); auto-refresh at most every 60 s while foregrounded; no background polling — use FCM for "new activity" nudges.
- Lists load `thumbUrl`; full images only on tap. Decode with `cacheWidth`.
- Compress/resize images on device before upload (see `media-pipeline`).
- Debounce search input (300 ms) and require ≥ 2 chars.
- Attach App Check token + Firebase ID token to every API call; handle `RESOURCE_EXHAUSTED` (quota) and `UNAVAILABLE` (degraded mode) with friendly UI.

## Keep the catalog current
- Add every new shared widget, cubit or helper to `docs/ui-catalog.md` in the same PR (`reuse-first` depends on it).
