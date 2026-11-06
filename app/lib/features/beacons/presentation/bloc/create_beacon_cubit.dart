import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:uuid/uuid.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../gen/dzeroth/beacons/v1/beacons.pb.dart' as pb;
import '../../data/beacons_repository.dart';
import '../beacons_error_messages.dart';

@immutable
class CreateBeaconState {
  const CreateBeaconState({this.busy = false, this.error, this.created});

  /// A create is in flight (inputs and the button are disabled).
  final bool busy;

  /// Friendly text of the last failure; the form stays open for a retry.
  final String? error;

  /// Set once when the call succeeded: the screen opens the plan.
  final pb.BeaconView? created;
}

/// `/plans/new`: one CreateBeacon per submit (R31).
///
/// One idempotency key per user action, reused when the same action is
/// retried after a failure (rule 4). The key is tied to the exact payload it
/// was first sent with (the request's bytes): after an edit the next submit is
/// a new action with a new key.
class CreateBeaconCubit extends Cubit<CreateBeaconState> {
  CreateBeaconCubit({required BeaconsRepository repository})
    : _repository = repository,
      super(const CreateBeaconState());

  static const _uuid = Uuid();

  final BeaconsRepository _repository;
  String? _key;
  List<int>? _payload;

  Future<void> create(pb.CreateBeaconRequest request) async {
    if (state.busy) return;
    final payload = request.writeToBuffer();
    if (_payload == null || !listEquals(_payload, payload)) {
      _key = _uuid.v4();
      _payload = payload;
    }
    emit(const CreateBeaconState(busy: true));
    try {
      final view = await _repository.createBeacon(
        idempotencyKey: _key!,
        request: request,
      );
      if (isClosed) return;
      emit(CreateBeaconState(created: view));
    } on AppException catch (error) {
      if (isClosed) return;
      emit(CreateBeaconState(error: beaconsErrorMessage(error)));
    }
  }
}
