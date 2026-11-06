import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/search/data/recent_searches_store.dart';
import 'package:dzeroth/features/search/data/search_repository.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import 'package:dzeroth/gen/dzeroth/search/v1/search.pb.dart' as pb;
import 'package:fixnum/fixnum.dart' show Int64;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

class MockSearchOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

/// An in-memory [RecentSearchesStore] (newest first, same rules as the
/// database one) for widget and cubit tests.
class FakeRecentSearchesStore implements RecentSearchesStore {
  FakeRecentSearchesStore([List<String> initial = const []])
    : items = [...initial];

  final List<String> items;

  @override
  Future<List<String>> read(String uid) async => [...items];

  @override
  Future<void> add(String uid, String query) async {
    items
      ..remove(query)
      ..insert(0, query);
    if (items.length > kRecentSearchesMax) items.removeLast();
  }

  @override
  Future<void> remove(String uid, String query) async => items.remove(query);

  @override
  Future<void> clear(String uid) async => items.clear();
}

graph.UserListItem searchPerson(String handle, {String name = ''}) =>
    graph.UserListItem(
      user: common.AuthorSnapshot(
        userId: 'u-$handle',
        handle: handle,
        displayName: name.isEmpty ? 'Name $handle' : name,
      ),
    );

pb.Trend searchTrend(String tag, int posts, int rank) =>
    pb.Trend(tag: tag, postCount: Int64(posts), rank: rank);

/// Pumps [child] with the providers [AppSearchField] reads. `search` is on
/// unless [features] says otherwise.
Future<MockSearchOnboardingBloc> pumpWithSearch(
  WidgetTester tester,
  Widget child, {
  required SearchRepository repository,
  required RecentSearchesStore store,
  Set<String> features = const {'search', 'trends'},
  Size size = const Size(400, 800),
  double textScale = 1.0,
  Brightness brightness = Brightness.light,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final onboarding = MockSearchOnboardingBloc();
  whenListen(
    onboarding,
    const Stream<OnboardingState>.empty(),
    initialState: OnboardingState(enabledFeatures: features),
  );
  await tester.pumpWidget(
    MultiRepositoryProvider(
      providers: [
        RepositoryProvider<SearchRepository>.value(value: repository),
        RepositoryProvider<RecentSearchesStore>.value(value: store),
      ],
      child: BlocProvider<OnboardingBloc>.value(
        value: onboarding,
        child: MaterialApp(
          theme: buildAppTheme(brightness: brightness),
          builder: (context, app) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: app!,
          ),
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(16),
              child: Align(alignment: Alignment.topCenter, child: child),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return onboarding;
}
