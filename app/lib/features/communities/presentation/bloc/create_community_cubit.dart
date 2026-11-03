import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:uuid/uuid.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../gen/dzeroth/communities/v1/communities.pb.dart' as pb;
import '../../data/communities_repository.dart';
import '../communities_error_messages.dart';

@immutable
class CreateCommunityState {
  const CreateCommunityState({this.busy = false, this.error, this.created});

  /// A create is in flight (inputs and buttons are disabled).
  final bool busy;

  /// Friendly text of the last failure; the form stays open for a retry.
  final String? error;

  /// Set once when the call succeeded: the screen opens its page.
  final pb.Community? created;
}

/// Create community: one CreateCommunity per submit.
///
/// One idempotency key per user action, reused when the same action is retried
/// after a failure (rule 4). The key is tied to the exact payload it was first
/// sent with: after an edit the next submit is a new action with a new key.
class CreateCommunityCubit extends Cubit<CreateCommunityState> {
  CreateCommunityCubit({required CommunitiesRepository repository})
    : _repository = repository,
      super(const CreateCommunityState());

  static const _uuid = Uuid();

  final CommunitiesRepository _repository;
  String? _key;
  String? _payload;

  Future<void> create({
    required String name,
    required String description,
    required List<pb.CommunityRule> rules,
  }) async {
    if (state.busy) return;
    final payload = [
      name,
      description,
      for (final r in rules) '${r.title}\u0001${r.text}',
    ].join('\u0000');
    if (_payload != payload) {
      _key = _uuid.v4();
      _payload = payload;
    }
    emit(const CreateCommunityState(busy: true));
    try {
      final r = await _repository.createCommunity(
        idempotencyKey: _key!,
        name: name,
        description: description,
        rules: rules,
      );
      if (isClosed) return;
      emit(CreateCommunityState(created: r.community));
    } on AppException catch (error) {
      if (isClosed) return;
      emit(CreateCommunityState(error: communitiesErrorMessage(error)));
    }
  }
}
