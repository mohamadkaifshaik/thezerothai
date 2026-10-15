import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/media/data/media_uploader.dart';
import 'package:dzeroth/features/onboarding/data/identity_repository.dart';
import 'package:dzeroth/features/media/domain/image_processor.dart';
import 'package:dzeroth/features/profile/presentation/bloc/edit_profile_cubit.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:dzeroth/gen/dzeroth/media/v1/media.pb.dart' as pb;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../../support/media_fixtures.dart';

class MockIdentityRepository extends Mock implements IdentityRepository {}

void main() {
  setUpAll(registerMediaFallbacks);

  late MockIdentityRepository identityRepo;
  late MockMediaRepository media;
  late FakeImagePicker picker;
  late FakeImageProcessor processor;
  late EditProfileCubit cubit;
  late List<Object> reported;
  late List<String?> sentAvatarIds;
  late List<String> sentKeys;

  setUp(() {
    identityRepo = MockIdentityRepository();
    media = MockMediaRepository();
    picker = FakeImagePicker();
    processor = FakeImageProcessor();
    reported = [];
    sentAvatarIds = [];
    sentKeys = [];
    cubit = EditProfileCubit(
      identityRepository: identityRepo,
      initial: identity.Profile(
        userId: 'me',
        handle: 'kaif',
        displayName: 'Kaif',
        bio: 'hello',
      ),
      picker: picker,
      processor: processor,
      uploader: MediaUploader(repository: media),
      onUnexpectedError: (error, _) => reported.add(error),
    );
    when(
      () => identityRepo.updateProfile(
        idempotencyKey: any(named: 'idempotencyKey'),
        displayName: any(named: 'displayName'),
        bio: any(named: 'bio'),
        avatarMediaId: any(named: 'avatarMediaId'),
      ),
    ).thenAnswer((invocation) async {
      sentAvatarIds.add(invocation.namedArguments[#avatarMediaId] as String?);
      sentKeys.add(invocation.namedArguments[#idempotencyKey] as String);
      return identity.Profile(userId: 'me', handle: 'kaif', avatarUrl: 'new');
    });
  });

  tearDown(() => cubit.close());

  test('is available only when the media pieces are wired', () {
    final plain = EditProfileCubit(
      identityRepository: identityRepo,
      initial: identity.Profile(userId: 'me'),
    );
    expect(plain.canChangeAvatar, isFalse);
    expect(cubit.canChangeAvatar, isTrue);
    plain.close();
  });

  test('picking prepares a preview and makes Save available', () async {
    picker.nextAvatar = imageBytes('a');

    await cubit.pickAvatar();

    expect(processor.purposes, [ImagePurpose.avatar]);
    expect(cubit.state.avatarPreview, isNotNull);
    expect(cubit.state.isPreparingAvatar, isFalse);
    expect(cubit.hasChanges, isTrue);
    expect(cubit.canSave, isTrue);
  });

  test('cancelling the picker changes nothing', () async {
    await cubit.pickAvatar();

    expect(cubit.hasChanges, isFalse);
    expect(cubit.state.avatarPreview, isNull);
  });

  test(
    'a file that is not an image shows a photo error and no preview',
    () async {
      picker.nextAvatar = badBytes;

      await cubit.pickAvatar();

      expect(cubit.state.avatarPreview, isNull);
      expect(cubit.state.avatarFailed, isTrue);
      expect(cubit.state.error, isA<ValidationException>());
      expect(cubit.canSave, isFalse);
    },
  );

  test('a picker failure is reported as a photo error', () async {
    picker.failWith = StateError('denied');

    await cubit.pickAvatar();

    expect(cubit.state.avatarFailed, isTrue);
    expect(cubit.state.error, isNotNull);
    expect(cubit.hasChanges, isFalse);
  });

  test(
    'MEDIA_NOT_READY on save drops the avatar so it is picked again',
    () async {
      stubHappyUpload(media);
      when(
        () => identityRepo.updateProfile(
          idempotencyKey: any(named: 'idempotencyKey'),
          displayName: any(named: 'displayName'),
          bio: any(named: 'bio'),
          avatarMediaId: any(named: 'avatarMediaId'),
        ),
      ).thenThrow(const MediaNotReadyException('gone'));
      picker.nextAvatar = imageBytes('a');
      await cubit.pickAvatar();

      await cubit.save();

      expect(cubit.state.avatarFailed, isTrue);
      expect(cubit.isAvatarChanged, isFalse);
      expect(cubit.state.avatarPreview, isNull);
    },
  );

  test('save uploads the avatar then sends only its media id', () async {
    stubHappyUpload(media);
    picker.nextAvatar = imageBytes('a');
    await cubit.pickAvatar();

    await cubit.save();

    expect(cubit.state.status, EditProfileStatus.saved);
    expect(sentAvatarIds, ['m1']);
    final createdFor =
        verify(
              () => media.createUpload(
                idempotencyKey: any(named: 'idempotencyKey'),
                purpose: captureAny(named: 'purpose'),
                images: any(named: 'images'),
              ),
            ).captured.single
            as pb.MediaPurpose;
    expect(createdFor, pb.MediaPurpose.MEDIA_PURPOSE_AVATAR);
  });

  test('retry after a failed UpdateProfile reuses the uploaded media id and '
      'the same key (no second upload)', () async {
    stubHappyUpload(media);
    var fail = true;
    when(
      () => identityRepo.updateProfile(
        idempotencyKey: any(named: 'idempotencyKey'),
        displayName: any(named: 'displayName'),
        bio: any(named: 'bio'),
        avatarMediaId: any(named: 'avatarMediaId'),
      ),
    ).thenAnswer((invocation) async {
      sentAvatarIds.add(invocation.namedArguments[#avatarMediaId] as String?);
      sentKeys.add(invocation.namedArguments[#idempotencyKey] as String);
      if (fail) throw const NetworkException('offline');
      return identity.Profile(userId: 'me', handle: 'kaif');
    });
    picker.nextAvatar = imageBytes('a');
    await cubit.pickAvatar();

    await cubit.save();
    expect(cubit.state.error, isA<NetworkException>());
    expect(cubit.state.avatarFailed, isFalse);
    fail = false;
    await cubit.save();

    expect(cubit.state.status, EditProfileStatus.saved);
    expect(sentAvatarIds, ['m1', 'm1']);
    expect(sentKeys.toSet(), hasLength(1));
    verify(
      () => media.createUpload(
        idempotencyKey: any(named: 'idempotencyKey'),
        purpose: any(named: 'purpose'),
        images: any(named: 'images'),
      ),
    ).called(1);
  });

  test('a rejected avatar is dropped with its reason; UpdateProfile is '
      'never sent', () async {
    stubHappyUpload(media, result: (id) => rejectedResult(id, 'Not allowed'));
    picker.nextAvatar = imageBytes('a');
    await cubit.pickAvatar();

    await cubit.save();

    expect(cubit.state.error, isA<ValidationException>());
    expect(cubit.state.error!.message, 'Not allowed');
    expect(cubit.state.avatarFailed, isTrue);
    expect(cubit.state.avatarPreview, isNull);
    expect(cubit.hasChanges, isFalse);
    verifyNever(
      () => identityRepo.updateProfile(
        idempotencyKey: any(named: 'idempotencyKey'),
        displayName: any(named: 'displayName'),
        bio: any(named: 'bio'),
        avatarMediaId: any(named: 'avatarMediaId'),
      ),
    );
  });

  test(
    'an upload network failure is a photo error and keeps the photo',
    () async {
      stubHappyUpload(
        media,
        onPut: (_) async => throw const NetworkException('offline'),
      );
      picker.nextAvatar = imageBytes('a');
      await cubit.pickAvatar();

      await cubit.save();

      expect(cubit.state.error, isA<NetworkException>());
      expect(cubit.state.avatarFailed, isTrue);
      expect(cubit.state.avatarPreview, isNotNull);
      expect(cubit.canSave, isTrue);
    },
  );

  test('name and avatar together go in one UpdateProfile', () async {
    stubHappyUpload(media);
    picker.nextAvatar = imageBytes('a');
    await cubit.pickAvatar();
    cubit.displayNameChanged('Kaif S');

    await cubit.save();

    verify(
      () => identityRepo.updateProfile(
        idempotencyKey: any(named: 'idempotencyKey'),
        displayName: 'Kaif S',
        bio: null,
        avatarMediaId: 'm1',
      ),
    ).called(1);
  });
}
