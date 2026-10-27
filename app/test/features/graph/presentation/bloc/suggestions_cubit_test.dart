import 'dart:async';

import 'package:dzeroth/features/graph/presentation/bloc/suggestions_cubit.dart';
import 'package:dzeroth/gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import 'package:flutter_test/flutter_test.dart';

import '../../../../support/suggestions_fixtures.dart';

List<String> _ids(SuggestionsCubit cubit) => [
  for (final item in cubit.state.items) item.user.userId,
];

void main() {
  late SuggestionsRig rig;
  late SuggestionsCubit cubit;

  setUp(() {
    rig = SuggestionsRig();
    cubit = SuggestionsCubit(repository: rig.repository);
  });

  tearDown(() async {
    await cubit.close();
    await rig.database.close();
  });

  test('starts empty and shows the rows once loaded', () async {
    expect(cubit.state.items, isEmpty);

    await cubit.ensureLoaded('me');

    expect(_ids(cubit), ['u1', 'u2', 'u3', 'u4', 'u5']);
    expect(rig.suggestionCalls, 1);
  });

  test('two surfaces asking at once make one call', () async {
    await Future.wait([cubit.ensureLoaded('me'), cubit.ensureLoaded('me')]);
    await cubit.ensureLoaded('me');

    expect(rig.suggestionCalls, 1);
    expect(cubit.state.items.length, 5);
  });

  test('hide removes the row from the state and the repository', () async {
    await cubit.ensureLoaded('me');

    cubit.hide('u2');

    expect(_ids(cubit), ['u1', 'u3', 'u4', 'u5']);
    await cubit.ensureLoaded('me');
    expect(_ids(cubit), ['u1', 'u3', 'u4', 'u5']);
    expect(rig.suggestionCalls, 1);
  });

  test('hide before anything is loaded does nothing', () {
    cubit.hide('u2');

    expect(cubit.state.items, isEmpty);
  });

  test('reset empties the state and forgets the session', () async {
    await cubit.ensureLoaded('me');
    cubit.hide('u2');

    cubit.reset();

    expect(cubit.state.items, isEmpty);
    expect(rig.repository.current('me'), isEmpty);
    await cubit.ensureLoaded('me');
    expect(_ids(cubit), ['u1', 'u2', 'u3', 'u4', 'u5']);
  });

  test('a list for another account replaces the first at once', () async {
    await cubit.ensureLoaded('alice');
    rig.users = [suggestedUser(7)];

    final bob = cubit.ensureLoaded('bob');
    expect(cubit.state.items, isEmpty);
    await bob;

    expect(_ids(cubit), ['u7']);
  });

  test('a late answer for the previous account is ignored', () async {
    final gate = Completer<graph.ListSuggestedUsersResponse>();
    rig.onSuggestions = () => gate.future;
    final late = cubit.ensureLoaded('alice');
    await Future<void>.delayed(Duration.zero);

    rig
      ..onSuggestions = null
      ..users = [suggestedUser(7)];
    await cubit.ensureLoaded('bob');
    gate.complete(graph.ListSuggestedUsersResponse(users: [suggestedUser(1)]));
    await late;

    expect(_ids(cubit), ['u7']);
  });

  test('a failure leaves the list empty and does not throw', () async {
    rig.onSuggestions = () async => throw StateError('boom');

    await cubit.ensureLoaded('me');

    expect(cubit.state.items, isEmpty);
  });

  test('reset after close does not throw', () async {
    await cubit.close();

    expect(cubit.reset, returnsNormally);
  });
}
