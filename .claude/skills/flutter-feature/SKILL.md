---
name: flutter-feature
description: How to scaffold a Flutter feature (data/domain/presentation, Riverpod, go_router, freezed, tests) that runs on iOS, Android and Web. Use when creating or restructuring any Flutter screen or feature.
---

# Flutter feature blueprint

```
app/lib/
  core/ (api/, auth/, theme/, router/, storage/, analytics/, widgets/, l10n/)
  features/<feature>/
    data/        <feature>_repository.dart  (connect-dart client + local cache)
    domain/      models (freezed), use-cases if logic is non-trivial
    presentation/ <feature>_screen.dart, widgets/, <feature>_controller.dart (@riverpod AsyncNotifier)
app/test/features/<feature>/...   app/integration_test/...
```

## Pattern
```dart
@riverpod
class TimelineController extends _$TimelineController {
  String? _cursor;
  @override
  Future<List<Post>> build() async => _load(refresh: true);
  Future<void> loadMore() async { /* append with cursor, guard concurrent loads */ }
  Future<void> like(PostId id) async { /* optimistic update, rollback on error */ }
}
```
- Screens are `ConsumerWidget`, handle `AsyncValue` loading/error/data with shared `AsyncView` widget.
- Responsive: `LayoutBuilder` breakpoints — mobile (<600) bottom nav, tablet (600–1200) nav rail, desktop (>1200) 3-column like X web.
- Platform: adaptive widgets where it matters (dialogs, pickers), `kIsWeb` guarded features.
- Every screen: widget test (loading/error/data), semantics, dark mode golden.
- Packages baseline: flutter_riverpod, riverpod_annotation, go_router, freezed, json_serializable, connectrpc, firebase_auth, firebase_app_check, firebase_messaging, firebase_crashlytics, firebase_remote_config, cached_network_image, flutter_image_compress, image_picker, drift, intl.

## Cost-aware client rules (the client is our cheapest cache)
- Clients never read Firestore/Storage directly (except public media URLs) — everything goes through the API.
- Persist timeline, profiles and own follow/like state locally (drift on mobile, drift-web/IndexedDB on web); render from cache first.
- Refresh incrementally with `since` cursors (see `timeline` skill); auto-refresh at most every 60 s while foregrounded; no background polling — use FCM for "new activity" nudges.
- Lists load `thumbUrl`; full images only on tap. Decode with `cacheWidth`.
- Compress/resize images on device before upload (see `media-pipeline`).
- Debounce search input (300 ms) and require ≥ 2 chars.
- Attach App Check token + Firebase ID token to every API call; handle `RESOURCE_EXHAUSTED` (quota) and `UNAVAILABLE` (degraded mode) with friendly UI.
