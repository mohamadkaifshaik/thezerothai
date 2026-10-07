// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'app_database.dart';

// ignore_for_file: type=lint
class $ProfileCacheEntriesTable extends ProfileCacheEntries
    with TableInfo<$ProfileCacheEntriesTable, CachedProfile> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ProfileCacheEntriesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _userIdMeta = const VerificationMeta('userId');
  @override
  late final GeneratedColumn<String> userId = GeneratedColumn<String>(
    'user_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _handleMeta = const VerificationMeta('handle');
  @override
  late final GeneratedColumn<String> handle = GeneratedColumn<String>(
    'handle',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _displayNameMeta = const VerificationMeta(
    'displayName',
  );
  @override
  late final GeneratedColumn<String> displayName = GeneratedColumn<String>(
    'display_name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _bioMeta = const VerificationMeta('bio');
  @override
  late final GeneratedColumn<String> bio = GeneratedColumn<String>(
    'bio',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _avatarUrlMeta = const VerificationMeta(
    'avatarUrl',
  );
  @override
  late final GeneratedColumn<String> avatarUrl = GeneratedColumn<String>(
    'avatar_url',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _avatarThumbUrlMeta = const VerificationMeta(
    'avatarThumbUrl',
  );
  @override
  late final GeneratedColumn<String> avatarThumbUrl = GeneratedColumn<String>(
    'avatar_thumb_url',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _isPrivateMeta = const VerificationMeta(
    'isPrivate',
  );
  @override
  late final GeneratedColumn<bool> isPrivate = GeneratedColumn<bool>(
    'is_private',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("is_private" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _verifiedMeta = const VerificationMeta(
    'verified',
  );
  @override
  late final GeneratedColumn<bool> verified = GeneratedColumn<bool>(
    'verified',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("verified" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _followersCountMeta = const VerificationMeta(
    'followersCount',
  );
  @override
  late final GeneratedColumn<int> followersCount = GeneratedColumn<int>(
    'followers_count',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _followingCountMeta = const VerificationMeta(
    'followingCount',
  );
  @override
  late final GeneratedColumn<int> followingCount = GeneratedColumn<int>(
    'following_count',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _postsCountMeta = const VerificationMeta(
    'postsCount',
  );
  @override
  late final GeneratedColumn<int> postsCount = GeneratedColumn<int>(
    'posts_count',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _cachedAtMeta = const VerificationMeta(
    'cachedAt',
  );
  @override
  late final GeneratedColumn<DateTime> cachedAt = GeneratedColumn<DateTime>(
    'cached_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    userId,
    handle,
    displayName,
    bio,
    avatarUrl,
    avatarThumbUrl,
    isPrivate,
    verified,
    followersCount,
    followingCount,
    postsCount,
    cachedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'profile_cache_entries';
  @override
  VerificationContext validateIntegrity(
    Insertable<CachedProfile> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('user_id')) {
      context.handle(
        _userIdMeta,
        userId.isAcceptableOrUnknown(data['user_id']!, _userIdMeta),
      );
    } else if (isInserting) {
      context.missing(_userIdMeta);
    }
    if (data.containsKey('handle')) {
      context.handle(
        _handleMeta,
        handle.isAcceptableOrUnknown(data['handle']!, _handleMeta),
      );
    } else if (isInserting) {
      context.missing(_handleMeta);
    }
    if (data.containsKey('display_name')) {
      context.handle(
        _displayNameMeta,
        displayName.isAcceptableOrUnknown(
          data['display_name']!,
          _displayNameMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_displayNameMeta);
    }
    if (data.containsKey('bio')) {
      context.handle(
        _bioMeta,
        bio.isAcceptableOrUnknown(data['bio']!, _bioMeta),
      );
    }
    if (data.containsKey('avatar_url')) {
      context.handle(
        _avatarUrlMeta,
        avatarUrl.isAcceptableOrUnknown(data['avatar_url']!, _avatarUrlMeta),
      );
    }
    if (data.containsKey('avatar_thumb_url')) {
      context.handle(
        _avatarThumbUrlMeta,
        avatarThumbUrl.isAcceptableOrUnknown(
          data['avatar_thumb_url']!,
          _avatarThumbUrlMeta,
        ),
      );
    }
    if (data.containsKey('is_private')) {
      context.handle(
        _isPrivateMeta,
        isPrivate.isAcceptableOrUnknown(data['is_private']!, _isPrivateMeta),
      );
    }
    if (data.containsKey('verified')) {
      context.handle(
        _verifiedMeta,
        verified.isAcceptableOrUnknown(data['verified']!, _verifiedMeta),
      );
    }
    if (data.containsKey('followers_count')) {
      context.handle(
        _followersCountMeta,
        followersCount.isAcceptableOrUnknown(
          data['followers_count']!,
          _followersCountMeta,
        ),
      );
    }
    if (data.containsKey('following_count')) {
      context.handle(
        _followingCountMeta,
        followingCount.isAcceptableOrUnknown(
          data['following_count']!,
          _followingCountMeta,
        ),
      );
    }
    if (data.containsKey('posts_count')) {
      context.handle(
        _postsCountMeta,
        postsCount.isAcceptableOrUnknown(data['posts_count']!, _postsCountMeta),
      );
    }
    if (data.containsKey('cached_at')) {
      context.handle(
        _cachedAtMeta,
        cachedAt.isAcceptableOrUnknown(data['cached_at']!, _cachedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_cachedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {userId};
  @override
  CachedProfile map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return CachedProfile(
      userId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}user_id'],
      )!,
      handle: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}handle'],
      )!,
      displayName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}display_name'],
      )!,
      bio: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}bio'],
      )!,
      avatarUrl: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}avatar_url'],
      )!,
      avatarThumbUrl: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}avatar_thumb_url'],
      )!,
      isPrivate: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}is_private'],
      )!,
      verified: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}verified'],
      )!,
      followersCount: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}followers_count'],
      )!,
      followingCount: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}following_count'],
      )!,
      postsCount: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}posts_count'],
      )!,
      cachedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}cached_at'],
      )!,
    );
  }

  @override
  $ProfileCacheEntriesTable createAlias(String alias) {
    return $ProfileCacheEntriesTable(attachedDatabase, alias);
  }
}

class CachedProfile extends DataClass implements Insertable<CachedProfile> {
  /// Firebase uid. Primary key.
  final String userId;
  final String handle;
  final String displayName;
  final String bio;
  final String avatarUrl;
  final String avatarThumbUrl;
  final bool isPrivate;
  final bool verified;
  final int followersCount;
  final int followingCount;
  final int postsCount;

  /// When this row was written, so callers can decide whether it is fresh
  /// enough to render without a refresh (see the `timeline` skill).
  final DateTime cachedAt;
  const CachedProfile({
    required this.userId,
    required this.handle,
    required this.displayName,
    required this.bio,
    required this.avatarUrl,
    required this.avatarThumbUrl,
    required this.isPrivate,
    required this.verified,
    required this.followersCount,
    required this.followingCount,
    required this.postsCount,
    required this.cachedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['user_id'] = Variable<String>(userId);
    map['handle'] = Variable<String>(handle);
    map['display_name'] = Variable<String>(displayName);
    map['bio'] = Variable<String>(bio);
    map['avatar_url'] = Variable<String>(avatarUrl);
    map['avatar_thumb_url'] = Variable<String>(avatarThumbUrl);
    map['is_private'] = Variable<bool>(isPrivate);
    map['verified'] = Variable<bool>(verified);
    map['followers_count'] = Variable<int>(followersCount);
    map['following_count'] = Variable<int>(followingCount);
    map['posts_count'] = Variable<int>(postsCount);
    map['cached_at'] = Variable<DateTime>(cachedAt);
    return map;
  }

  ProfileCacheEntriesCompanion toCompanion(bool nullToAbsent) {
    return ProfileCacheEntriesCompanion(
      userId: Value(userId),
      handle: Value(handle),
      displayName: Value(displayName),
      bio: Value(bio),
      avatarUrl: Value(avatarUrl),
      avatarThumbUrl: Value(avatarThumbUrl),
      isPrivate: Value(isPrivate),
      verified: Value(verified),
      followersCount: Value(followersCount),
      followingCount: Value(followingCount),
      postsCount: Value(postsCount),
      cachedAt: Value(cachedAt),
    );
  }

  factory CachedProfile.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return CachedProfile(
      userId: serializer.fromJson<String>(json['userId']),
      handle: serializer.fromJson<String>(json['handle']),
      displayName: serializer.fromJson<String>(json['displayName']),
      bio: serializer.fromJson<String>(json['bio']),
      avatarUrl: serializer.fromJson<String>(json['avatarUrl']),
      avatarThumbUrl: serializer.fromJson<String>(json['avatarThumbUrl']),
      isPrivate: serializer.fromJson<bool>(json['isPrivate']),
      verified: serializer.fromJson<bool>(json['verified']),
      followersCount: serializer.fromJson<int>(json['followersCount']),
      followingCount: serializer.fromJson<int>(json['followingCount']),
      postsCount: serializer.fromJson<int>(json['postsCount']),
      cachedAt: serializer.fromJson<DateTime>(json['cachedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'userId': serializer.toJson<String>(userId),
      'handle': serializer.toJson<String>(handle),
      'displayName': serializer.toJson<String>(displayName),
      'bio': serializer.toJson<String>(bio),
      'avatarUrl': serializer.toJson<String>(avatarUrl),
      'avatarThumbUrl': serializer.toJson<String>(avatarThumbUrl),
      'isPrivate': serializer.toJson<bool>(isPrivate),
      'verified': serializer.toJson<bool>(verified),
      'followersCount': serializer.toJson<int>(followersCount),
      'followingCount': serializer.toJson<int>(followingCount),
      'postsCount': serializer.toJson<int>(postsCount),
      'cachedAt': serializer.toJson<DateTime>(cachedAt),
    };
  }

  CachedProfile copyWith({
    String? userId,
    String? handle,
    String? displayName,
    String? bio,
    String? avatarUrl,
    String? avatarThumbUrl,
    bool? isPrivate,
    bool? verified,
    int? followersCount,
    int? followingCount,
    int? postsCount,
    DateTime? cachedAt,
  }) => CachedProfile(
    userId: userId ?? this.userId,
    handle: handle ?? this.handle,
    displayName: displayName ?? this.displayName,
    bio: bio ?? this.bio,
    avatarUrl: avatarUrl ?? this.avatarUrl,
    avatarThumbUrl: avatarThumbUrl ?? this.avatarThumbUrl,
    isPrivate: isPrivate ?? this.isPrivate,
    verified: verified ?? this.verified,
    followersCount: followersCount ?? this.followersCount,
    followingCount: followingCount ?? this.followingCount,
    postsCount: postsCount ?? this.postsCount,
    cachedAt: cachedAt ?? this.cachedAt,
  );
  CachedProfile copyWithCompanion(ProfileCacheEntriesCompanion data) {
    return CachedProfile(
      userId: data.userId.present ? data.userId.value : this.userId,
      handle: data.handle.present ? data.handle.value : this.handle,
      displayName: data.displayName.present
          ? data.displayName.value
          : this.displayName,
      bio: data.bio.present ? data.bio.value : this.bio,
      avatarUrl: data.avatarUrl.present ? data.avatarUrl.value : this.avatarUrl,
      avatarThumbUrl: data.avatarThumbUrl.present
          ? data.avatarThumbUrl.value
          : this.avatarThumbUrl,
      isPrivate: data.isPrivate.present ? data.isPrivate.value : this.isPrivate,
      verified: data.verified.present ? data.verified.value : this.verified,
      followersCount: data.followersCount.present
          ? data.followersCount.value
          : this.followersCount,
      followingCount: data.followingCount.present
          ? data.followingCount.value
          : this.followingCount,
      postsCount: data.postsCount.present
          ? data.postsCount.value
          : this.postsCount,
      cachedAt: data.cachedAt.present ? data.cachedAt.value : this.cachedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('CachedProfile(')
          ..write('userId: $userId, ')
          ..write('handle: $handle, ')
          ..write('displayName: $displayName, ')
          ..write('bio: $bio, ')
          ..write('avatarUrl: $avatarUrl, ')
          ..write('avatarThumbUrl: $avatarThumbUrl, ')
          ..write('isPrivate: $isPrivate, ')
          ..write('verified: $verified, ')
          ..write('followersCount: $followersCount, ')
          ..write('followingCount: $followingCount, ')
          ..write('postsCount: $postsCount, ')
          ..write('cachedAt: $cachedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    userId,
    handle,
    displayName,
    bio,
    avatarUrl,
    avatarThumbUrl,
    isPrivate,
    verified,
    followersCount,
    followingCount,
    postsCount,
    cachedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is CachedProfile &&
          other.userId == this.userId &&
          other.handle == this.handle &&
          other.displayName == this.displayName &&
          other.bio == this.bio &&
          other.avatarUrl == this.avatarUrl &&
          other.avatarThumbUrl == this.avatarThumbUrl &&
          other.isPrivate == this.isPrivate &&
          other.verified == this.verified &&
          other.followersCount == this.followersCount &&
          other.followingCount == this.followingCount &&
          other.postsCount == this.postsCount &&
          other.cachedAt == this.cachedAt);
}

class ProfileCacheEntriesCompanion extends UpdateCompanion<CachedProfile> {
  final Value<String> userId;
  final Value<String> handle;
  final Value<String> displayName;
  final Value<String> bio;
  final Value<String> avatarUrl;
  final Value<String> avatarThumbUrl;
  final Value<bool> isPrivate;
  final Value<bool> verified;
  final Value<int> followersCount;
  final Value<int> followingCount;
  final Value<int> postsCount;
  final Value<DateTime> cachedAt;
  final Value<int> rowid;
  const ProfileCacheEntriesCompanion({
    this.userId = const Value.absent(),
    this.handle = const Value.absent(),
    this.displayName = const Value.absent(),
    this.bio = const Value.absent(),
    this.avatarUrl = const Value.absent(),
    this.avatarThumbUrl = const Value.absent(),
    this.isPrivate = const Value.absent(),
    this.verified = const Value.absent(),
    this.followersCount = const Value.absent(),
    this.followingCount = const Value.absent(),
    this.postsCount = const Value.absent(),
    this.cachedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ProfileCacheEntriesCompanion.insert({
    required String userId,
    required String handle,
    required String displayName,
    this.bio = const Value.absent(),
    this.avatarUrl = const Value.absent(),
    this.avatarThumbUrl = const Value.absent(),
    this.isPrivate = const Value.absent(),
    this.verified = const Value.absent(),
    this.followersCount = const Value.absent(),
    this.followingCount = const Value.absent(),
    this.postsCount = const Value.absent(),
    required DateTime cachedAt,
    this.rowid = const Value.absent(),
  }) : userId = Value(userId),
       handle = Value(handle),
       displayName = Value(displayName),
       cachedAt = Value(cachedAt);
  static Insertable<CachedProfile> custom({
    Expression<String>? userId,
    Expression<String>? handle,
    Expression<String>? displayName,
    Expression<String>? bio,
    Expression<String>? avatarUrl,
    Expression<String>? avatarThumbUrl,
    Expression<bool>? isPrivate,
    Expression<bool>? verified,
    Expression<int>? followersCount,
    Expression<int>? followingCount,
    Expression<int>? postsCount,
    Expression<DateTime>? cachedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (userId != null) 'user_id': userId,
      if (handle != null) 'handle': handle,
      if (displayName != null) 'display_name': displayName,
      if (bio != null) 'bio': bio,
      if (avatarUrl != null) 'avatar_url': avatarUrl,
      if (avatarThumbUrl != null) 'avatar_thumb_url': avatarThumbUrl,
      if (isPrivate != null) 'is_private': isPrivate,
      if (verified != null) 'verified': verified,
      if (followersCount != null) 'followers_count': followersCount,
      if (followingCount != null) 'following_count': followingCount,
      if (postsCount != null) 'posts_count': postsCount,
      if (cachedAt != null) 'cached_at': cachedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ProfileCacheEntriesCompanion copyWith({
    Value<String>? userId,
    Value<String>? handle,
    Value<String>? displayName,
    Value<String>? bio,
    Value<String>? avatarUrl,
    Value<String>? avatarThumbUrl,
    Value<bool>? isPrivate,
    Value<bool>? verified,
    Value<int>? followersCount,
    Value<int>? followingCount,
    Value<int>? postsCount,
    Value<DateTime>? cachedAt,
    Value<int>? rowid,
  }) {
    return ProfileCacheEntriesCompanion(
      userId: userId ?? this.userId,
      handle: handle ?? this.handle,
      displayName: displayName ?? this.displayName,
      bio: bio ?? this.bio,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      avatarThumbUrl: avatarThumbUrl ?? this.avatarThumbUrl,
      isPrivate: isPrivate ?? this.isPrivate,
      verified: verified ?? this.verified,
      followersCount: followersCount ?? this.followersCount,
      followingCount: followingCount ?? this.followingCount,
      postsCount: postsCount ?? this.postsCount,
      cachedAt: cachedAt ?? this.cachedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (userId.present) {
      map['user_id'] = Variable<String>(userId.value);
    }
    if (handle.present) {
      map['handle'] = Variable<String>(handle.value);
    }
    if (displayName.present) {
      map['display_name'] = Variable<String>(displayName.value);
    }
    if (bio.present) {
      map['bio'] = Variable<String>(bio.value);
    }
    if (avatarUrl.present) {
      map['avatar_url'] = Variable<String>(avatarUrl.value);
    }
    if (avatarThumbUrl.present) {
      map['avatar_thumb_url'] = Variable<String>(avatarThumbUrl.value);
    }
    if (isPrivate.present) {
      map['is_private'] = Variable<bool>(isPrivate.value);
    }
    if (verified.present) {
      map['verified'] = Variable<bool>(verified.value);
    }
    if (followersCount.present) {
      map['followers_count'] = Variable<int>(followersCount.value);
    }
    if (followingCount.present) {
      map['following_count'] = Variable<int>(followingCount.value);
    }
    if (postsCount.present) {
      map['posts_count'] = Variable<int>(postsCount.value);
    }
    if (cachedAt.present) {
      map['cached_at'] = Variable<DateTime>(cachedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ProfileCacheEntriesCompanion(')
          ..write('userId: $userId, ')
          ..write('handle: $handle, ')
          ..write('displayName: $displayName, ')
          ..write('bio: $bio, ')
          ..write('avatarUrl: $avatarUrl, ')
          ..write('avatarThumbUrl: $avatarThumbUrl, ')
          ..write('isPrivate: $isPrivate, ')
          ..write('verified: $verified, ')
          ..write('followersCount: $followersCount, ')
          ..write('followingCount: $followingCount, ')
          ..write('postsCount: $postsCount, ')
          ..write('cachedAt: $cachedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $FollowingCacheEntriesTable extends FollowingCacheEntries
    with TableInfo<$FollowingCacheEntriesTable, CachedFollowing> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $FollowingCacheEntriesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _userIdMeta = const VerificationMeta('userId');
  @override
  late final GeneratedColumn<String> userId = GeneratedColumn<String>(
    'user_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _cachedAtMeta = const VerificationMeta(
    'cachedAt',
  );
  @override
  late final GeneratedColumn<DateTime> cachedAt = GeneratedColumn<DateTime>(
    'cached_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [userId, cachedAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'following_cache_entries';
  @override
  VerificationContext validateIntegrity(
    Insertable<CachedFollowing> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('user_id')) {
      context.handle(
        _userIdMeta,
        userId.isAcceptableOrUnknown(data['user_id']!, _userIdMeta),
      );
    } else if (isInserting) {
      context.missing(_userIdMeta);
    }
    if (data.containsKey('cached_at')) {
      context.handle(
        _cachedAtMeta,
        cachedAt.isAcceptableOrUnknown(data['cached_at']!, _cachedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_cachedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {userId};
  @override
  CachedFollowing map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return CachedFollowing(
      userId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}user_id'],
      )!,
      cachedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}cached_at'],
      )!,
    );
  }

  @override
  $FollowingCacheEntriesTable createAlias(String alias) {
    return $FollowingCacheEntriesTable(attachedDatabase, alias);
  }
}

class CachedFollowing extends DataClass implements Insertable<CachedFollowing> {
  /// Uid of an account the signed-in user follows. Primary key.
  final String userId;

  /// When this row was written, so it can be pruned or judged stale later.
  final DateTime cachedAt;
  const CachedFollowing({required this.userId, required this.cachedAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['user_id'] = Variable<String>(userId);
    map['cached_at'] = Variable<DateTime>(cachedAt);
    return map;
  }

  FollowingCacheEntriesCompanion toCompanion(bool nullToAbsent) {
    return FollowingCacheEntriesCompanion(
      userId: Value(userId),
      cachedAt: Value(cachedAt),
    );
  }

  factory CachedFollowing.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return CachedFollowing(
      userId: serializer.fromJson<String>(json['userId']),
      cachedAt: serializer.fromJson<DateTime>(json['cachedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'userId': serializer.toJson<String>(userId),
      'cachedAt': serializer.toJson<DateTime>(cachedAt),
    };
  }

  CachedFollowing copyWith({String? userId, DateTime? cachedAt}) =>
      CachedFollowing(
        userId: userId ?? this.userId,
        cachedAt: cachedAt ?? this.cachedAt,
      );
  CachedFollowing copyWithCompanion(FollowingCacheEntriesCompanion data) {
    return CachedFollowing(
      userId: data.userId.present ? data.userId.value : this.userId,
      cachedAt: data.cachedAt.present ? data.cachedAt.value : this.cachedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('CachedFollowing(')
          ..write('userId: $userId, ')
          ..write('cachedAt: $cachedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(userId, cachedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is CachedFollowing &&
          other.userId == this.userId &&
          other.cachedAt == this.cachedAt);
}

class FollowingCacheEntriesCompanion extends UpdateCompanion<CachedFollowing> {
  final Value<String> userId;
  final Value<DateTime> cachedAt;
  final Value<int> rowid;
  const FollowingCacheEntriesCompanion({
    this.userId = const Value.absent(),
    this.cachedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  FollowingCacheEntriesCompanion.insert({
    required String userId,
    required DateTime cachedAt,
    this.rowid = const Value.absent(),
  }) : userId = Value(userId),
       cachedAt = Value(cachedAt);
  static Insertable<CachedFollowing> custom({
    Expression<String>? userId,
    Expression<DateTime>? cachedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (userId != null) 'user_id': userId,
      if (cachedAt != null) 'cached_at': cachedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  FollowingCacheEntriesCompanion copyWith({
    Value<String>? userId,
    Value<DateTime>? cachedAt,
    Value<int>? rowid,
  }) {
    return FollowingCacheEntriesCompanion(
      userId: userId ?? this.userId,
      cachedAt: cachedAt ?? this.cachedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (userId.present) {
      map['user_id'] = Variable<String>(userId.value);
    }
    if (cachedAt.present) {
      map['cached_at'] = Variable<DateTime>(cachedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('FollowingCacheEntriesCompanion(')
          ..write('userId: $userId, ')
          ..write('cachedAt: $cachedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $TimelineItemEntriesTable extends TimelineItemEntries
    with TableInfo<$TimelineItemEntriesTable, CachedTimelineItem> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $TimelineItemEntriesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _feedKeyMeta = const VerificationMeta(
    'feedKey',
  );
  @override
  late final GeneratedColumn<String> feedKey = GeneratedColumn<String>(
    'feed_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _itemKeyMeta = const VerificationMeta(
    'itemKey',
  );
  @override
  late final GeneratedColumn<String> itemKey = GeneratedColumn<String>(
    'item_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sortKeyMeta = const VerificationMeta(
    'sortKey',
  );
  @override
  late final GeneratedColumn<String> sortKey = GeneratedColumn<String>(
    'sort_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _payloadMeta = const VerificationMeta(
    'payload',
  );
  @override
  late final GeneratedColumn<Uint8List> payload = GeneratedColumn<Uint8List>(
    'payload',
    aliasedName,
    true,
    type: DriftSqlType.blob,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _gapTokenMeta = const VerificationMeta(
    'gapToken',
  );
  @override
  late final GeneratedColumn<String> gapToken = GeneratedColumn<String>(
    'gap_token',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _pageTokenMeta = const VerificationMeta(
    'pageToken',
  );
  @override
  late final GeneratedColumn<String> pageToken = GeneratedColumn<String>(
    'page_token',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    feedKey,
    itemKey,
    sortKey,
    payload,
    gapToken,
    pageToken,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'timeline_item_entries';
  @override
  VerificationContext validateIntegrity(
    Insertable<CachedTimelineItem> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('feed_key')) {
      context.handle(
        _feedKeyMeta,
        feedKey.isAcceptableOrUnknown(data['feed_key']!, _feedKeyMeta),
      );
    } else if (isInserting) {
      context.missing(_feedKeyMeta);
    }
    if (data.containsKey('item_key')) {
      context.handle(
        _itemKeyMeta,
        itemKey.isAcceptableOrUnknown(data['item_key']!, _itemKeyMeta),
      );
    } else if (isInserting) {
      context.missing(_itemKeyMeta);
    }
    if (data.containsKey('sort_key')) {
      context.handle(
        _sortKeyMeta,
        sortKey.isAcceptableOrUnknown(data['sort_key']!, _sortKeyMeta),
      );
    } else if (isInserting) {
      context.missing(_sortKeyMeta);
    }
    if (data.containsKey('payload')) {
      context.handle(
        _payloadMeta,
        payload.isAcceptableOrUnknown(data['payload']!, _payloadMeta),
      );
    }
    if (data.containsKey('gap_token')) {
      context.handle(
        _gapTokenMeta,
        gapToken.isAcceptableOrUnknown(data['gap_token']!, _gapTokenMeta),
      );
    }
    if (data.containsKey('page_token')) {
      context.handle(
        _pageTokenMeta,
        pageToken.isAcceptableOrUnknown(data['page_token']!, _pageTokenMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {feedKey, itemKey};
  @override
  CachedTimelineItem map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return CachedTimelineItem(
      feedKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}feed_key'],
      )!,
      itemKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}item_key'],
      )!,
      sortKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}sort_key'],
      )!,
      payload: attachedDatabase.typeMapping.read(
        DriftSqlType.blob,
        data['${effectivePrefix}payload'],
      ),
      gapToken: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}gap_token'],
      ),
      pageToken: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}page_token'],
      ),
    );
  }

  @override
  $TimelineItemEntriesTable createAlias(String alias) {
    return $TimelineItemEntriesTable(attachedDatabase, alias);
  }
}

class CachedTimelineItem extends DataClass
    implements Insertable<CachedTimelineItem> {
  /// `home` or `user:{userId}:{posts|replies}` (see `FeedKey`).
  final String feedKey;

  /// The `post_id` for a post row, `gap:{sortKey}` for a gap row. Together
  /// with [feedKey] this makes `post_id` unique per feed (dedupe on merge).
  final String itemKey;
  final String sortKey;

  /// Serialized `PostView`; null for a gap row.
  final Uint8List? payload;

  /// `gap_page_token`; null for a post row.
  final String? gapToken;

  /// For a post row that ended a fetched page: that page's
  /// `next_page_token`. Lets retention trim at a page boundary and resume
  /// scrolling from the cut.
  final String? pageToken;
  const CachedTimelineItem({
    required this.feedKey,
    required this.itemKey,
    required this.sortKey,
    this.payload,
    this.gapToken,
    this.pageToken,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['feed_key'] = Variable<String>(feedKey);
    map['item_key'] = Variable<String>(itemKey);
    map['sort_key'] = Variable<String>(sortKey);
    if (!nullToAbsent || payload != null) {
      map['payload'] = Variable<Uint8List>(payload);
    }
    if (!nullToAbsent || gapToken != null) {
      map['gap_token'] = Variable<String>(gapToken);
    }
    if (!nullToAbsent || pageToken != null) {
      map['page_token'] = Variable<String>(pageToken);
    }
    return map;
  }

  TimelineItemEntriesCompanion toCompanion(bool nullToAbsent) {
    return TimelineItemEntriesCompanion(
      feedKey: Value(feedKey),
      itemKey: Value(itemKey),
      sortKey: Value(sortKey),
      payload: payload == null && nullToAbsent
          ? const Value.absent()
          : Value(payload),
      gapToken: gapToken == null && nullToAbsent
          ? const Value.absent()
          : Value(gapToken),
      pageToken: pageToken == null && nullToAbsent
          ? const Value.absent()
          : Value(pageToken),
    );
  }

  factory CachedTimelineItem.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return CachedTimelineItem(
      feedKey: serializer.fromJson<String>(json['feedKey']),
      itemKey: serializer.fromJson<String>(json['itemKey']),
      sortKey: serializer.fromJson<String>(json['sortKey']),
      payload: serializer.fromJson<Uint8List?>(json['payload']),
      gapToken: serializer.fromJson<String?>(json['gapToken']),
      pageToken: serializer.fromJson<String?>(json['pageToken']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'feedKey': serializer.toJson<String>(feedKey),
      'itemKey': serializer.toJson<String>(itemKey),
      'sortKey': serializer.toJson<String>(sortKey),
      'payload': serializer.toJson<Uint8List?>(payload),
      'gapToken': serializer.toJson<String?>(gapToken),
      'pageToken': serializer.toJson<String?>(pageToken),
    };
  }

  CachedTimelineItem copyWith({
    String? feedKey,
    String? itemKey,
    String? sortKey,
    Value<Uint8List?> payload = const Value.absent(),
    Value<String?> gapToken = const Value.absent(),
    Value<String?> pageToken = const Value.absent(),
  }) => CachedTimelineItem(
    feedKey: feedKey ?? this.feedKey,
    itemKey: itemKey ?? this.itemKey,
    sortKey: sortKey ?? this.sortKey,
    payload: payload.present ? payload.value : this.payload,
    gapToken: gapToken.present ? gapToken.value : this.gapToken,
    pageToken: pageToken.present ? pageToken.value : this.pageToken,
  );
  CachedTimelineItem copyWithCompanion(TimelineItemEntriesCompanion data) {
    return CachedTimelineItem(
      feedKey: data.feedKey.present ? data.feedKey.value : this.feedKey,
      itemKey: data.itemKey.present ? data.itemKey.value : this.itemKey,
      sortKey: data.sortKey.present ? data.sortKey.value : this.sortKey,
      payload: data.payload.present ? data.payload.value : this.payload,
      gapToken: data.gapToken.present ? data.gapToken.value : this.gapToken,
      pageToken: data.pageToken.present ? data.pageToken.value : this.pageToken,
    );
  }

  @override
  String toString() {
    return (StringBuffer('CachedTimelineItem(')
          ..write('feedKey: $feedKey, ')
          ..write('itemKey: $itemKey, ')
          ..write('sortKey: $sortKey, ')
          ..write('payload: $payload, ')
          ..write('gapToken: $gapToken, ')
          ..write('pageToken: $pageToken')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    feedKey,
    itemKey,
    sortKey,
    $driftBlobEquality.hash(payload),
    gapToken,
    pageToken,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is CachedTimelineItem &&
          other.feedKey == this.feedKey &&
          other.itemKey == this.itemKey &&
          other.sortKey == this.sortKey &&
          $driftBlobEquality.equals(other.payload, this.payload) &&
          other.gapToken == this.gapToken &&
          other.pageToken == this.pageToken);
}

class TimelineItemEntriesCompanion extends UpdateCompanion<CachedTimelineItem> {
  final Value<String> feedKey;
  final Value<String> itemKey;
  final Value<String> sortKey;
  final Value<Uint8List?> payload;
  final Value<String?> gapToken;
  final Value<String?> pageToken;
  final Value<int> rowid;
  const TimelineItemEntriesCompanion({
    this.feedKey = const Value.absent(),
    this.itemKey = const Value.absent(),
    this.sortKey = const Value.absent(),
    this.payload = const Value.absent(),
    this.gapToken = const Value.absent(),
    this.pageToken = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  TimelineItemEntriesCompanion.insert({
    required String feedKey,
    required String itemKey,
    required String sortKey,
    this.payload = const Value.absent(),
    this.gapToken = const Value.absent(),
    this.pageToken = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : feedKey = Value(feedKey),
       itemKey = Value(itemKey),
       sortKey = Value(sortKey);
  static Insertable<CachedTimelineItem> custom({
    Expression<String>? feedKey,
    Expression<String>? itemKey,
    Expression<String>? sortKey,
    Expression<Uint8List>? payload,
    Expression<String>? gapToken,
    Expression<String>? pageToken,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (feedKey != null) 'feed_key': feedKey,
      if (itemKey != null) 'item_key': itemKey,
      if (sortKey != null) 'sort_key': sortKey,
      if (payload != null) 'payload': payload,
      if (gapToken != null) 'gap_token': gapToken,
      if (pageToken != null) 'page_token': pageToken,
      if (rowid != null) 'rowid': rowid,
    });
  }

  TimelineItemEntriesCompanion copyWith({
    Value<String>? feedKey,
    Value<String>? itemKey,
    Value<String>? sortKey,
    Value<Uint8List?>? payload,
    Value<String?>? gapToken,
    Value<String?>? pageToken,
    Value<int>? rowid,
  }) {
    return TimelineItemEntriesCompanion(
      feedKey: feedKey ?? this.feedKey,
      itemKey: itemKey ?? this.itemKey,
      sortKey: sortKey ?? this.sortKey,
      payload: payload ?? this.payload,
      gapToken: gapToken ?? this.gapToken,
      pageToken: pageToken ?? this.pageToken,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (feedKey.present) {
      map['feed_key'] = Variable<String>(feedKey.value);
    }
    if (itemKey.present) {
      map['item_key'] = Variable<String>(itemKey.value);
    }
    if (sortKey.present) {
      map['sort_key'] = Variable<String>(sortKey.value);
    }
    if (payload.present) {
      map['payload'] = Variable<Uint8List>(payload.value);
    }
    if (gapToken.present) {
      map['gap_token'] = Variable<String>(gapToken.value);
    }
    if (pageToken.present) {
      map['page_token'] = Variable<String>(pageToken.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('TimelineItemEntriesCompanion(')
          ..write('feedKey: $feedKey, ')
          ..write('itemKey: $itemKey, ')
          ..write('sortKey: $sortKey, ')
          ..write('payload: $payload, ')
          ..write('gapToken: $gapToken, ')
          ..write('pageToken: $pageToken, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $TimelineStateEntriesTable extends TimelineStateEntries
    with TableInfo<$TimelineStateEntriesTable, CachedTimelineState> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $TimelineStateEntriesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _feedKeyMeta = const VerificationMeta(
    'feedKey',
  );
  @override
  late final GeneratedColumn<String> feedKey = GeneratedColumn<String>(
    'feed_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sinceTokenMeta = const VerificationMeta(
    'sinceToken',
  );
  @override
  late final GeneratedColumn<String> sinceToken = GeneratedColumn<String>(
    'since_token',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _olderPageTokenMeta = const VerificationMeta(
    'olderPageToken',
  );
  @override
  late final GeneratedColumn<String> olderPageToken = GeneratedColumn<String>(
    'older_page_token',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    feedKey,
    sinceToken,
    olderPageToken,
    updatedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'timeline_state_entries';
  @override
  VerificationContext validateIntegrity(
    Insertable<CachedTimelineState> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('feed_key')) {
      context.handle(
        _feedKeyMeta,
        feedKey.isAcceptableOrUnknown(data['feed_key']!, _feedKeyMeta),
      );
    } else if (isInserting) {
      context.missing(_feedKeyMeta);
    }
    if (data.containsKey('since_token')) {
      context.handle(
        _sinceTokenMeta,
        sinceToken.isAcceptableOrUnknown(data['since_token']!, _sinceTokenMeta),
      );
    }
    if (data.containsKey('older_page_token')) {
      context.handle(
        _olderPageTokenMeta,
        olderPageToken.isAcceptableOrUnknown(
          data['older_page_token']!,
          _olderPageTokenMeta,
        ),
      );
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {feedKey};
  @override
  CachedTimelineState map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return CachedTimelineState(
      feedKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}feed_key'],
      )!,
      sinceToken: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}since_token'],
      )!,
      olderPageToken: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}older_page_token'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}updated_at'],
      )!,
    );
  }

  @override
  $TimelineStateEntriesTable createAlias(String alias) {
    return $TimelineStateEntriesTable(attachedDatabase, alias);
  }
}

class CachedTimelineState extends DataClass
    implements Insertable<CachedTimelineState> {
  final String feedKey;
  final String sinceToken;

  /// Token for scrolling older than the oldest cached item; '' = none/end.
  final String olderPageToken;
  final DateTime updatedAt;
  const CachedTimelineState({
    required this.feedKey,
    required this.sinceToken,
    required this.olderPageToken,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['feed_key'] = Variable<String>(feedKey);
    map['since_token'] = Variable<String>(sinceToken);
    map['older_page_token'] = Variable<String>(olderPageToken);
    map['updated_at'] = Variable<DateTime>(updatedAt);
    return map;
  }

  TimelineStateEntriesCompanion toCompanion(bool nullToAbsent) {
    return TimelineStateEntriesCompanion(
      feedKey: Value(feedKey),
      sinceToken: Value(sinceToken),
      olderPageToken: Value(olderPageToken),
      updatedAt: Value(updatedAt),
    );
  }

  factory CachedTimelineState.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return CachedTimelineState(
      feedKey: serializer.fromJson<String>(json['feedKey']),
      sinceToken: serializer.fromJson<String>(json['sinceToken']),
      olderPageToken: serializer.fromJson<String>(json['olderPageToken']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'feedKey': serializer.toJson<String>(feedKey),
      'sinceToken': serializer.toJson<String>(sinceToken),
      'olderPageToken': serializer.toJson<String>(olderPageToken),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
    };
  }

  CachedTimelineState copyWith({
    String? feedKey,
    String? sinceToken,
    String? olderPageToken,
    DateTime? updatedAt,
  }) => CachedTimelineState(
    feedKey: feedKey ?? this.feedKey,
    sinceToken: sinceToken ?? this.sinceToken,
    olderPageToken: olderPageToken ?? this.olderPageToken,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  CachedTimelineState copyWithCompanion(TimelineStateEntriesCompanion data) {
    return CachedTimelineState(
      feedKey: data.feedKey.present ? data.feedKey.value : this.feedKey,
      sinceToken: data.sinceToken.present
          ? data.sinceToken.value
          : this.sinceToken,
      olderPageToken: data.olderPageToken.present
          ? data.olderPageToken.value
          : this.olderPageToken,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('CachedTimelineState(')
          ..write('feedKey: $feedKey, ')
          ..write('sinceToken: $sinceToken, ')
          ..write('olderPageToken: $olderPageToken, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(feedKey, sinceToken, olderPageToken, updatedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is CachedTimelineState &&
          other.feedKey == this.feedKey &&
          other.sinceToken == this.sinceToken &&
          other.olderPageToken == this.olderPageToken &&
          other.updatedAt == this.updatedAt);
}

class TimelineStateEntriesCompanion
    extends UpdateCompanion<CachedTimelineState> {
  final Value<String> feedKey;
  final Value<String> sinceToken;
  final Value<String> olderPageToken;
  final Value<DateTime> updatedAt;
  final Value<int> rowid;
  const TimelineStateEntriesCompanion({
    this.feedKey = const Value.absent(),
    this.sinceToken = const Value.absent(),
    this.olderPageToken = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  TimelineStateEntriesCompanion.insert({
    required String feedKey,
    this.sinceToken = const Value.absent(),
    this.olderPageToken = const Value.absent(),
    required DateTime updatedAt,
    this.rowid = const Value.absent(),
  }) : feedKey = Value(feedKey),
       updatedAt = Value(updatedAt);
  static Insertable<CachedTimelineState> custom({
    Expression<String>? feedKey,
    Expression<String>? sinceToken,
    Expression<String>? olderPageToken,
    Expression<DateTime>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (feedKey != null) 'feed_key': feedKey,
      if (sinceToken != null) 'since_token': sinceToken,
      if (olderPageToken != null) 'older_page_token': olderPageToken,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  TimelineStateEntriesCompanion copyWith({
    Value<String>? feedKey,
    Value<String>? sinceToken,
    Value<String>? olderPageToken,
    Value<DateTime>? updatedAt,
    Value<int>? rowid,
  }) {
    return TimelineStateEntriesCompanion(
      feedKey: feedKey ?? this.feedKey,
      sinceToken: sinceToken ?? this.sinceToken,
      olderPageToken: olderPageToken ?? this.olderPageToken,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (feedKey.present) {
      map['feed_key'] = Variable<String>(feedKey.value);
    }
    if (sinceToken.present) {
      map['since_token'] = Variable<String>(sinceToken.value);
    }
    if (olderPageToken.present) {
      map['older_page_token'] = Variable<String>(olderPageToken.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('TimelineStateEntriesCompanion(')
          ..write('feedKey: $feedKey, ')
          ..write('sinceToken: $sinceToken, ')
          ..write('olderPageToken: $olderPageToken, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $AccountExportEntriesTable extends AccountExportEntries
    with TableInfo<$AccountExportEntriesTable, SavedAccountExport> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $AccountExportEntriesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _exportIdMeta = const VerificationMeta(
    'exportId',
  );
  @override
  late final GeneratedColumn<String> exportId = GeneratedColumn<String>(
    'export_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _uidMeta = const VerificationMeta('uid');
  @override
  late final GeneratedColumn<String> uid = GeneratedColumn<String>(
    'uid',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _requestedAtMeta = const VerificationMeta(
    'requestedAt',
  );
  @override
  late final GeneratedColumn<DateTime> requestedAt = GeneratedColumn<DateTime>(
    'requested_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _expiresAtMeta = const VerificationMeta(
    'expiresAt',
  );
  @override
  late final GeneratedColumn<DateTime> expiresAt = GeneratedColumn<DateTime>(
    'expires_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [exportId, uid, requestedAt, expiresAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'account_export_entries';
  @override
  VerificationContext validateIntegrity(
    Insertable<SavedAccountExport> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('export_id')) {
      context.handle(
        _exportIdMeta,
        exportId.isAcceptableOrUnknown(data['export_id']!, _exportIdMeta),
      );
    } else if (isInserting) {
      context.missing(_exportIdMeta);
    }
    if (data.containsKey('uid')) {
      context.handle(
        _uidMeta,
        uid.isAcceptableOrUnknown(data['uid']!, _uidMeta),
      );
    } else if (isInserting) {
      context.missing(_uidMeta);
    }
    if (data.containsKey('requested_at')) {
      context.handle(
        _requestedAtMeta,
        requestedAt.isAcceptableOrUnknown(
          data['requested_at']!,
          _requestedAtMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_requestedAtMeta);
    }
    if (data.containsKey('expires_at')) {
      context.handle(
        _expiresAtMeta,
        expiresAt.isAcceptableOrUnknown(data['expires_at']!, _expiresAtMeta),
      );
    } else if (isInserting) {
      context.missing(_expiresAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {exportId};
  @override
  SavedAccountExport map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SavedAccountExport(
      exportId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}export_id'],
      )!,
      uid: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}uid'],
      )!,
      requestedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}requested_at'],
      )!,
      expiresAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}expires_at'],
      )!,
    );
  }

  @override
  $AccountExportEntriesTable createAlias(String alias) {
    return $AccountExportEntriesTable(attachedDatabase, alias);
  }
}

class SavedAccountExport extends DataClass
    implements Insertable<SavedAccountExport> {
  final String exportId;

  /// Firebase uid the export belongs to; another account never sees it.
  final String uid;
  final DateTime requestedAt;

  /// Server `expireAt` (request time + 7 days); after it GetAccountExport
  /// answers NOT_FOUND (plan Q6).
  final DateTime expiresAt;
  const SavedAccountExport({
    required this.exportId,
    required this.uid,
    required this.requestedAt,
    required this.expiresAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['export_id'] = Variable<String>(exportId);
    map['uid'] = Variable<String>(uid);
    map['requested_at'] = Variable<DateTime>(requestedAt);
    map['expires_at'] = Variable<DateTime>(expiresAt);
    return map;
  }

  AccountExportEntriesCompanion toCompanion(bool nullToAbsent) {
    return AccountExportEntriesCompanion(
      exportId: Value(exportId),
      uid: Value(uid),
      requestedAt: Value(requestedAt),
      expiresAt: Value(expiresAt),
    );
  }

  factory SavedAccountExport.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SavedAccountExport(
      exportId: serializer.fromJson<String>(json['exportId']),
      uid: serializer.fromJson<String>(json['uid']),
      requestedAt: serializer.fromJson<DateTime>(json['requestedAt']),
      expiresAt: serializer.fromJson<DateTime>(json['expiresAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'exportId': serializer.toJson<String>(exportId),
      'uid': serializer.toJson<String>(uid),
      'requestedAt': serializer.toJson<DateTime>(requestedAt),
      'expiresAt': serializer.toJson<DateTime>(expiresAt),
    };
  }

  SavedAccountExport copyWith({
    String? exportId,
    String? uid,
    DateTime? requestedAt,
    DateTime? expiresAt,
  }) => SavedAccountExport(
    exportId: exportId ?? this.exportId,
    uid: uid ?? this.uid,
    requestedAt: requestedAt ?? this.requestedAt,
    expiresAt: expiresAt ?? this.expiresAt,
  );
  SavedAccountExport copyWithCompanion(AccountExportEntriesCompanion data) {
    return SavedAccountExport(
      exportId: data.exportId.present ? data.exportId.value : this.exportId,
      uid: data.uid.present ? data.uid.value : this.uid,
      requestedAt: data.requestedAt.present
          ? data.requestedAt.value
          : this.requestedAt,
      expiresAt: data.expiresAt.present ? data.expiresAt.value : this.expiresAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SavedAccountExport(')
          ..write('exportId: $exportId, ')
          ..write('uid: $uid, ')
          ..write('requestedAt: $requestedAt, ')
          ..write('expiresAt: $expiresAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(exportId, uid, requestedAt, expiresAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SavedAccountExport &&
          other.exportId == this.exportId &&
          other.uid == this.uid &&
          other.requestedAt == this.requestedAt &&
          other.expiresAt == this.expiresAt);
}

class AccountExportEntriesCompanion
    extends UpdateCompanion<SavedAccountExport> {
  final Value<String> exportId;
  final Value<String> uid;
  final Value<DateTime> requestedAt;
  final Value<DateTime> expiresAt;
  final Value<int> rowid;
  const AccountExportEntriesCompanion({
    this.exportId = const Value.absent(),
    this.uid = const Value.absent(),
    this.requestedAt = const Value.absent(),
    this.expiresAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  AccountExportEntriesCompanion.insert({
    required String exportId,
    required String uid,
    required DateTime requestedAt,
    required DateTime expiresAt,
    this.rowid = const Value.absent(),
  }) : exportId = Value(exportId),
       uid = Value(uid),
       requestedAt = Value(requestedAt),
       expiresAt = Value(expiresAt);
  static Insertable<SavedAccountExport> custom({
    Expression<String>? exportId,
    Expression<String>? uid,
    Expression<DateTime>? requestedAt,
    Expression<DateTime>? expiresAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (exportId != null) 'export_id': exportId,
      if (uid != null) 'uid': uid,
      if (requestedAt != null) 'requested_at': requestedAt,
      if (expiresAt != null) 'expires_at': expiresAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  AccountExportEntriesCompanion copyWith({
    Value<String>? exportId,
    Value<String>? uid,
    Value<DateTime>? requestedAt,
    Value<DateTime>? expiresAt,
    Value<int>? rowid,
  }) {
    return AccountExportEntriesCompanion(
      exportId: exportId ?? this.exportId,
      uid: uid ?? this.uid,
      requestedAt: requestedAt ?? this.requestedAt,
      expiresAt: expiresAt ?? this.expiresAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (exportId.present) {
      map['export_id'] = Variable<String>(exportId.value);
    }
    if (uid.present) {
      map['uid'] = Variable<String>(uid.value);
    }
    if (requestedAt.present) {
      map['requested_at'] = Variable<DateTime>(requestedAt.value);
    }
    if (expiresAt.present) {
      map['expires_at'] = Variable<DateTime>(expiresAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('AccountExportEntriesCompanion(')
          ..write('exportId: $exportId, ')
          ..write('uid: $uid, ')
          ..write('requestedAt: $requestedAt, ')
          ..write('expiresAt: $expiresAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$AppDatabase extends GeneratedDatabase {
  _$AppDatabase(QueryExecutor e) : super(e);
  $AppDatabaseManager get managers => $AppDatabaseManager(this);
  late final $ProfileCacheEntriesTable profileCacheEntries =
      $ProfileCacheEntriesTable(this);
  late final $FollowingCacheEntriesTable followingCacheEntries =
      $FollowingCacheEntriesTable(this);
  late final $TimelineItemEntriesTable timelineItemEntries =
      $TimelineItemEntriesTable(this);
  late final $TimelineStateEntriesTable timelineStateEntries =
      $TimelineStateEntriesTable(this);
  late final $AccountExportEntriesTable accountExportEntries =
      $AccountExportEntriesTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    profileCacheEntries,
    followingCacheEntries,
    timelineItemEntries,
    timelineStateEntries,
    accountExportEntries,
  ];
}

typedef $$ProfileCacheEntriesTableCreateCompanionBuilder =
    ProfileCacheEntriesCompanion Function({
      required String userId,
      required String handle,
      required String displayName,
      Value<String> bio,
      Value<String> avatarUrl,
      Value<String> avatarThumbUrl,
      Value<bool> isPrivate,
      Value<bool> verified,
      Value<int> followersCount,
      Value<int> followingCount,
      Value<int> postsCount,
      required DateTime cachedAt,
      Value<int> rowid,
    });
typedef $$ProfileCacheEntriesTableUpdateCompanionBuilder =
    ProfileCacheEntriesCompanion Function({
      Value<String> userId,
      Value<String> handle,
      Value<String> displayName,
      Value<String> bio,
      Value<String> avatarUrl,
      Value<String> avatarThumbUrl,
      Value<bool> isPrivate,
      Value<bool> verified,
      Value<int> followersCount,
      Value<int> followingCount,
      Value<int> postsCount,
      Value<DateTime> cachedAt,
      Value<int> rowid,
    });

class $$ProfileCacheEntriesTableFilterComposer
    extends Composer<_$AppDatabase, $ProfileCacheEntriesTable> {
  $$ProfileCacheEntriesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get userId => $composableBuilder(
    column: $table.userId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get handle => $composableBuilder(
    column: $table.handle,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get displayName => $composableBuilder(
    column: $table.displayName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get bio => $composableBuilder(
    column: $table.bio,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get avatarUrl => $composableBuilder(
    column: $table.avatarUrl,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get avatarThumbUrl => $composableBuilder(
    column: $table.avatarThumbUrl,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get isPrivate => $composableBuilder(
    column: $table.isPrivate,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get verified => $composableBuilder(
    column: $table.verified,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get followersCount => $composableBuilder(
    column: $table.followersCount,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get followingCount => $composableBuilder(
    column: $table.followingCount,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get postsCount => $composableBuilder(
    column: $table.postsCount,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get cachedAt => $composableBuilder(
    column: $table.cachedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$ProfileCacheEntriesTableOrderingComposer
    extends Composer<_$AppDatabase, $ProfileCacheEntriesTable> {
  $$ProfileCacheEntriesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get userId => $composableBuilder(
    column: $table.userId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get handle => $composableBuilder(
    column: $table.handle,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get displayName => $composableBuilder(
    column: $table.displayName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get bio => $composableBuilder(
    column: $table.bio,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get avatarUrl => $composableBuilder(
    column: $table.avatarUrl,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get avatarThumbUrl => $composableBuilder(
    column: $table.avatarThumbUrl,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get isPrivate => $composableBuilder(
    column: $table.isPrivate,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get verified => $composableBuilder(
    column: $table.verified,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get followersCount => $composableBuilder(
    column: $table.followersCount,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get followingCount => $composableBuilder(
    column: $table.followingCount,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get postsCount => $composableBuilder(
    column: $table.postsCount,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get cachedAt => $composableBuilder(
    column: $table.cachedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$ProfileCacheEntriesTableAnnotationComposer
    extends Composer<_$AppDatabase, $ProfileCacheEntriesTable> {
  $$ProfileCacheEntriesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get userId =>
      $composableBuilder(column: $table.userId, builder: (column) => column);

  GeneratedColumn<String> get handle =>
      $composableBuilder(column: $table.handle, builder: (column) => column);

  GeneratedColumn<String> get displayName => $composableBuilder(
    column: $table.displayName,
    builder: (column) => column,
  );

  GeneratedColumn<String> get bio =>
      $composableBuilder(column: $table.bio, builder: (column) => column);

  GeneratedColumn<String> get avatarUrl =>
      $composableBuilder(column: $table.avatarUrl, builder: (column) => column);

  GeneratedColumn<String> get avatarThumbUrl => $composableBuilder(
    column: $table.avatarThumbUrl,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get isPrivate =>
      $composableBuilder(column: $table.isPrivate, builder: (column) => column);

  GeneratedColumn<bool> get verified =>
      $composableBuilder(column: $table.verified, builder: (column) => column);

  GeneratedColumn<int> get followersCount => $composableBuilder(
    column: $table.followersCount,
    builder: (column) => column,
  );

  GeneratedColumn<int> get followingCount => $composableBuilder(
    column: $table.followingCount,
    builder: (column) => column,
  );

  GeneratedColumn<int> get postsCount => $composableBuilder(
    column: $table.postsCount,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get cachedAt =>
      $composableBuilder(column: $table.cachedAt, builder: (column) => column);
}

class $$ProfileCacheEntriesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $ProfileCacheEntriesTable,
          CachedProfile,
          $$ProfileCacheEntriesTableFilterComposer,
          $$ProfileCacheEntriesTableOrderingComposer,
          $$ProfileCacheEntriesTableAnnotationComposer,
          $$ProfileCacheEntriesTableCreateCompanionBuilder,
          $$ProfileCacheEntriesTableUpdateCompanionBuilder,
          (
            CachedProfile,
            BaseReferences<
              _$AppDatabase,
              $ProfileCacheEntriesTable,
              CachedProfile
            >,
          ),
          CachedProfile,
          PrefetchHooks Function()
        > {
  $$ProfileCacheEntriesTableTableManager(
    _$AppDatabase db,
    $ProfileCacheEntriesTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ProfileCacheEntriesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ProfileCacheEntriesTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              $$ProfileCacheEntriesTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> userId = const Value.absent(),
                Value<String> handle = const Value.absent(),
                Value<String> displayName = const Value.absent(),
                Value<String> bio = const Value.absent(),
                Value<String> avatarUrl = const Value.absent(),
                Value<String> avatarThumbUrl = const Value.absent(),
                Value<bool> isPrivate = const Value.absent(),
                Value<bool> verified = const Value.absent(),
                Value<int> followersCount = const Value.absent(),
                Value<int> followingCount = const Value.absent(),
                Value<int> postsCount = const Value.absent(),
                Value<DateTime> cachedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ProfileCacheEntriesCompanion(
                userId: userId,
                handle: handle,
                displayName: displayName,
                bio: bio,
                avatarUrl: avatarUrl,
                avatarThumbUrl: avatarThumbUrl,
                isPrivate: isPrivate,
                verified: verified,
                followersCount: followersCount,
                followingCount: followingCount,
                postsCount: postsCount,
                cachedAt: cachedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String userId,
                required String handle,
                required String displayName,
                Value<String> bio = const Value.absent(),
                Value<String> avatarUrl = const Value.absent(),
                Value<String> avatarThumbUrl = const Value.absent(),
                Value<bool> isPrivate = const Value.absent(),
                Value<bool> verified = const Value.absent(),
                Value<int> followersCount = const Value.absent(),
                Value<int> followingCount = const Value.absent(),
                Value<int> postsCount = const Value.absent(),
                required DateTime cachedAt,
                Value<int> rowid = const Value.absent(),
              }) => ProfileCacheEntriesCompanion.insert(
                userId: userId,
                handle: handle,
                displayName: displayName,
                bio: bio,
                avatarUrl: avatarUrl,
                avatarThumbUrl: avatarThumbUrl,
                isPrivate: isPrivate,
                verified: verified,
                followersCount: followersCount,
                followingCount: followingCount,
                postsCount: postsCount,
                cachedAt: cachedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$ProfileCacheEntriesTable, CachedProfile>(table),
                  BaseReferences<
                    _$AppDatabase,
                    $ProfileCacheEntriesTable,
                    CachedProfile
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$ProfileCacheEntriesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $ProfileCacheEntriesTable,
      CachedProfile,
      $$ProfileCacheEntriesTableFilterComposer,
      $$ProfileCacheEntriesTableOrderingComposer,
      $$ProfileCacheEntriesTableAnnotationComposer,
      $$ProfileCacheEntriesTableCreateCompanionBuilder,
      $$ProfileCacheEntriesTableUpdateCompanionBuilder,
      (
        CachedProfile,
        BaseReferences<_$AppDatabase, $ProfileCacheEntriesTable, CachedProfile>,
      ),
      CachedProfile,
      PrefetchHooks Function()
    >;
typedef $$FollowingCacheEntriesTableCreateCompanionBuilder =
    FollowingCacheEntriesCompanion Function({
      required String userId,
      required DateTime cachedAt,
      Value<int> rowid,
    });
typedef $$FollowingCacheEntriesTableUpdateCompanionBuilder =
    FollowingCacheEntriesCompanion Function({
      Value<String> userId,
      Value<DateTime> cachedAt,
      Value<int> rowid,
    });

class $$FollowingCacheEntriesTableFilterComposer
    extends Composer<_$AppDatabase, $FollowingCacheEntriesTable> {
  $$FollowingCacheEntriesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get userId => $composableBuilder(
    column: $table.userId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get cachedAt => $composableBuilder(
    column: $table.cachedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$FollowingCacheEntriesTableOrderingComposer
    extends Composer<_$AppDatabase, $FollowingCacheEntriesTable> {
  $$FollowingCacheEntriesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get userId => $composableBuilder(
    column: $table.userId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get cachedAt => $composableBuilder(
    column: $table.cachedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$FollowingCacheEntriesTableAnnotationComposer
    extends Composer<_$AppDatabase, $FollowingCacheEntriesTable> {
  $$FollowingCacheEntriesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get userId =>
      $composableBuilder(column: $table.userId, builder: (column) => column);

  GeneratedColumn<DateTime> get cachedAt =>
      $composableBuilder(column: $table.cachedAt, builder: (column) => column);
}

class $$FollowingCacheEntriesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $FollowingCacheEntriesTable,
          CachedFollowing,
          $$FollowingCacheEntriesTableFilterComposer,
          $$FollowingCacheEntriesTableOrderingComposer,
          $$FollowingCacheEntriesTableAnnotationComposer,
          $$FollowingCacheEntriesTableCreateCompanionBuilder,
          $$FollowingCacheEntriesTableUpdateCompanionBuilder,
          (
            CachedFollowing,
            BaseReferences<
              _$AppDatabase,
              $FollowingCacheEntriesTable,
              CachedFollowing
            >,
          ),
          CachedFollowing,
          PrefetchHooks Function()
        > {
  $$FollowingCacheEntriesTableTableManager(
    _$AppDatabase db,
    $FollowingCacheEntriesTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$FollowingCacheEntriesTableFilterComposer(
                $db: db,
                $table: table,
              ),
          createOrderingComposer: () =>
              $$FollowingCacheEntriesTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              $$FollowingCacheEntriesTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> userId = const Value.absent(),
                Value<DateTime> cachedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => FollowingCacheEntriesCompanion(
                userId: userId,
                cachedAt: cachedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String userId,
                required DateTime cachedAt,
                Value<int> rowid = const Value.absent(),
              }) => FollowingCacheEntriesCompanion.insert(
                userId: userId,
                cachedAt: cachedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$FollowingCacheEntriesTable, CachedFollowing>(
                    table,
                  ),
                  BaseReferences<
                    _$AppDatabase,
                    $FollowingCacheEntriesTable,
                    CachedFollowing
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$FollowingCacheEntriesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $FollowingCacheEntriesTable,
      CachedFollowing,
      $$FollowingCacheEntriesTableFilterComposer,
      $$FollowingCacheEntriesTableOrderingComposer,
      $$FollowingCacheEntriesTableAnnotationComposer,
      $$FollowingCacheEntriesTableCreateCompanionBuilder,
      $$FollowingCacheEntriesTableUpdateCompanionBuilder,
      (
        CachedFollowing,
        BaseReferences<
          _$AppDatabase,
          $FollowingCacheEntriesTable,
          CachedFollowing
        >,
      ),
      CachedFollowing,
      PrefetchHooks Function()
    >;
typedef $$TimelineItemEntriesTableCreateCompanionBuilder =
    TimelineItemEntriesCompanion Function({
      required String feedKey,
      required String itemKey,
      required String sortKey,
      Value<Uint8List?> payload,
      Value<String?> gapToken,
      Value<String?> pageToken,
      Value<int> rowid,
    });
typedef $$TimelineItemEntriesTableUpdateCompanionBuilder =
    TimelineItemEntriesCompanion Function({
      Value<String> feedKey,
      Value<String> itemKey,
      Value<String> sortKey,
      Value<Uint8List?> payload,
      Value<String?> gapToken,
      Value<String?> pageToken,
      Value<int> rowid,
    });

class $$TimelineItemEntriesTableFilterComposer
    extends Composer<_$AppDatabase, $TimelineItemEntriesTable> {
  $$TimelineItemEntriesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get feedKey => $composableBuilder(
    column: $table.feedKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get itemKey => $composableBuilder(
    column: $table.itemKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get sortKey => $composableBuilder(
    column: $table.sortKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<Uint8List> get payload => $composableBuilder(
    column: $table.payload,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get gapToken => $composableBuilder(
    column: $table.gapToken,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get pageToken => $composableBuilder(
    column: $table.pageToken,
    builder: (column) => ColumnFilters(column),
  );
}

class $$TimelineItemEntriesTableOrderingComposer
    extends Composer<_$AppDatabase, $TimelineItemEntriesTable> {
  $$TimelineItemEntriesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get feedKey => $composableBuilder(
    column: $table.feedKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get itemKey => $composableBuilder(
    column: $table.itemKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get sortKey => $composableBuilder(
    column: $table.sortKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<Uint8List> get payload => $composableBuilder(
    column: $table.payload,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get gapToken => $composableBuilder(
    column: $table.gapToken,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get pageToken => $composableBuilder(
    column: $table.pageToken,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$TimelineItemEntriesTableAnnotationComposer
    extends Composer<_$AppDatabase, $TimelineItemEntriesTable> {
  $$TimelineItemEntriesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get feedKey =>
      $composableBuilder(column: $table.feedKey, builder: (column) => column);

  GeneratedColumn<String> get itemKey =>
      $composableBuilder(column: $table.itemKey, builder: (column) => column);

  GeneratedColumn<String> get sortKey =>
      $composableBuilder(column: $table.sortKey, builder: (column) => column);

  GeneratedColumn<Uint8List> get payload =>
      $composableBuilder(column: $table.payload, builder: (column) => column);

  GeneratedColumn<String> get gapToken =>
      $composableBuilder(column: $table.gapToken, builder: (column) => column);

  GeneratedColumn<String> get pageToken =>
      $composableBuilder(column: $table.pageToken, builder: (column) => column);
}

class $$TimelineItemEntriesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $TimelineItemEntriesTable,
          CachedTimelineItem,
          $$TimelineItemEntriesTableFilterComposer,
          $$TimelineItemEntriesTableOrderingComposer,
          $$TimelineItemEntriesTableAnnotationComposer,
          $$TimelineItemEntriesTableCreateCompanionBuilder,
          $$TimelineItemEntriesTableUpdateCompanionBuilder,
          (
            CachedTimelineItem,
            BaseReferences<
              _$AppDatabase,
              $TimelineItemEntriesTable,
              CachedTimelineItem
            >,
          ),
          CachedTimelineItem,
          PrefetchHooks Function()
        > {
  $$TimelineItemEntriesTableTableManager(
    _$AppDatabase db,
    $TimelineItemEntriesTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$TimelineItemEntriesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$TimelineItemEntriesTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              $$TimelineItemEntriesTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> feedKey = const Value.absent(),
                Value<String> itemKey = const Value.absent(),
                Value<String> sortKey = const Value.absent(),
                Value<Uint8List?> payload = const Value.absent(),
                Value<String?> gapToken = const Value.absent(),
                Value<String?> pageToken = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => TimelineItemEntriesCompanion(
                feedKey: feedKey,
                itemKey: itemKey,
                sortKey: sortKey,
                payload: payload,
                gapToken: gapToken,
                pageToken: pageToken,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String feedKey,
                required String itemKey,
                required String sortKey,
                Value<Uint8List?> payload = const Value.absent(),
                Value<String?> gapToken = const Value.absent(),
                Value<String?> pageToken = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => TimelineItemEntriesCompanion.insert(
                feedKey: feedKey,
                itemKey: itemKey,
                sortKey: sortKey,
                payload: payload,
                gapToken: gapToken,
                pageToken: pageToken,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$TimelineItemEntriesTable, CachedTimelineItem>(
                    table,
                  ),
                  BaseReferences<
                    _$AppDatabase,
                    $TimelineItemEntriesTable,
                    CachedTimelineItem
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$TimelineItemEntriesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $TimelineItemEntriesTable,
      CachedTimelineItem,
      $$TimelineItemEntriesTableFilterComposer,
      $$TimelineItemEntriesTableOrderingComposer,
      $$TimelineItemEntriesTableAnnotationComposer,
      $$TimelineItemEntriesTableCreateCompanionBuilder,
      $$TimelineItemEntriesTableUpdateCompanionBuilder,
      (
        CachedTimelineItem,
        BaseReferences<
          _$AppDatabase,
          $TimelineItemEntriesTable,
          CachedTimelineItem
        >,
      ),
      CachedTimelineItem,
      PrefetchHooks Function()
    >;
typedef $$TimelineStateEntriesTableCreateCompanionBuilder =
    TimelineStateEntriesCompanion Function({
      required String feedKey,
      Value<String> sinceToken,
      Value<String> olderPageToken,
      required DateTime updatedAt,
      Value<int> rowid,
    });
typedef $$TimelineStateEntriesTableUpdateCompanionBuilder =
    TimelineStateEntriesCompanion Function({
      Value<String> feedKey,
      Value<String> sinceToken,
      Value<String> olderPageToken,
      Value<DateTime> updatedAt,
      Value<int> rowid,
    });

class $$TimelineStateEntriesTableFilterComposer
    extends Composer<_$AppDatabase, $TimelineStateEntriesTable> {
  $$TimelineStateEntriesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get feedKey => $composableBuilder(
    column: $table.feedKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get sinceToken => $composableBuilder(
    column: $table.sinceToken,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get olderPageToken => $composableBuilder(
    column: $table.olderPageToken,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$TimelineStateEntriesTableOrderingComposer
    extends Composer<_$AppDatabase, $TimelineStateEntriesTable> {
  $$TimelineStateEntriesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get feedKey => $composableBuilder(
    column: $table.feedKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get sinceToken => $composableBuilder(
    column: $table.sinceToken,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get olderPageToken => $composableBuilder(
    column: $table.olderPageToken,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$TimelineStateEntriesTableAnnotationComposer
    extends Composer<_$AppDatabase, $TimelineStateEntriesTable> {
  $$TimelineStateEntriesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get feedKey =>
      $composableBuilder(column: $table.feedKey, builder: (column) => column);

  GeneratedColumn<String> get sinceToken => $composableBuilder(
    column: $table.sinceToken,
    builder: (column) => column,
  );

  GeneratedColumn<String> get olderPageToken => $composableBuilder(
    column: $table.olderPageToken,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $$TimelineStateEntriesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $TimelineStateEntriesTable,
          CachedTimelineState,
          $$TimelineStateEntriesTableFilterComposer,
          $$TimelineStateEntriesTableOrderingComposer,
          $$TimelineStateEntriesTableAnnotationComposer,
          $$TimelineStateEntriesTableCreateCompanionBuilder,
          $$TimelineStateEntriesTableUpdateCompanionBuilder,
          (
            CachedTimelineState,
            BaseReferences<
              _$AppDatabase,
              $TimelineStateEntriesTable,
              CachedTimelineState
            >,
          ),
          CachedTimelineState,
          PrefetchHooks Function()
        > {
  $$TimelineStateEntriesTableTableManager(
    _$AppDatabase db,
    $TimelineStateEntriesTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$TimelineStateEntriesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$TimelineStateEntriesTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              $$TimelineStateEntriesTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> feedKey = const Value.absent(),
                Value<String> sinceToken = const Value.absent(),
                Value<String> olderPageToken = const Value.absent(),
                Value<DateTime> updatedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => TimelineStateEntriesCompanion(
                feedKey: feedKey,
                sinceToken: sinceToken,
                olderPageToken: olderPageToken,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String feedKey,
                Value<String> sinceToken = const Value.absent(),
                Value<String> olderPageToken = const Value.absent(),
                required DateTime updatedAt,
                Value<int> rowid = const Value.absent(),
              }) => TimelineStateEntriesCompanion.insert(
                feedKey: feedKey,
                sinceToken: sinceToken,
                olderPageToken: olderPageToken,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$TimelineStateEntriesTable, CachedTimelineState>(
                    table,
                  ),
                  BaseReferences<
                    _$AppDatabase,
                    $TimelineStateEntriesTable,
                    CachedTimelineState
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$TimelineStateEntriesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $TimelineStateEntriesTable,
      CachedTimelineState,
      $$TimelineStateEntriesTableFilterComposer,
      $$TimelineStateEntriesTableOrderingComposer,
      $$TimelineStateEntriesTableAnnotationComposer,
      $$TimelineStateEntriesTableCreateCompanionBuilder,
      $$TimelineStateEntriesTableUpdateCompanionBuilder,
      (
        CachedTimelineState,
        BaseReferences<
          _$AppDatabase,
          $TimelineStateEntriesTable,
          CachedTimelineState
        >,
      ),
      CachedTimelineState,
      PrefetchHooks Function()
    >;
typedef $$AccountExportEntriesTableCreateCompanionBuilder =
    AccountExportEntriesCompanion Function({
      required String exportId,
      required String uid,
      required DateTime requestedAt,
      required DateTime expiresAt,
      Value<int> rowid,
    });
typedef $$AccountExportEntriesTableUpdateCompanionBuilder =
    AccountExportEntriesCompanion Function({
      Value<String> exportId,
      Value<String> uid,
      Value<DateTime> requestedAt,
      Value<DateTime> expiresAt,
      Value<int> rowid,
    });

class $$AccountExportEntriesTableFilterComposer
    extends Composer<_$AppDatabase, $AccountExportEntriesTable> {
  $$AccountExportEntriesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get exportId => $composableBuilder(
    column: $table.exportId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get uid => $composableBuilder(
    column: $table.uid,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get requestedAt => $composableBuilder(
    column: $table.requestedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get expiresAt => $composableBuilder(
    column: $table.expiresAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$AccountExportEntriesTableOrderingComposer
    extends Composer<_$AppDatabase, $AccountExportEntriesTable> {
  $$AccountExportEntriesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get exportId => $composableBuilder(
    column: $table.exportId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get uid => $composableBuilder(
    column: $table.uid,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get requestedAt => $composableBuilder(
    column: $table.requestedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get expiresAt => $composableBuilder(
    column: $table.expiresAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$AccountExportEntriesTableAnnotationComposer
    extends Composer<_$AppDatabase, $AccountExportEntriesTable> {
  $$AccountExportEntriesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get exportId =>
      $composableBuilder(column: $table.exportId, builder: (column) => column);

  GeneratedColumn<String> get uid =>
      $composableBuilder(column: $table.uid, builder: (column) => column);

  GeneratedColumn<DateTime> get requestedAt => $composableBuilder(
    column: $table.requestedAt,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get expiresAt =>
      $composableBuilder(column: $table.expiresAt, builder: (column) => column);
}

class $$AccountExportEntriesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $AccountExportEntriesTable,
          SavedAccountExport,
          $$AccountExportEntriesTableFilterComposer,
          $$AccountExportEntriesTableOrderingComposer,
          $$AccountExportEntriesTableAnnotationComposer,
          $$AccountExportEntriesTableCreateCompanionBuilder,
          $$AccountExportEntriesTableUpdateCompanionBuilder,
          (
            SavedAccountExport,
            BaseReferences<
              _$AppDatabase,
              $AccountExportEntriesTable,
              SavedAccountExport
            >,
          ),
          SavedAccountExport,
          PrefetchHooks Function()
        > {
  $$AccountExportEntriesTableTableManager(
    _$AppDatabase db,
    $AccountExportEntriesTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$AccountExportEntriesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$AccountExportEntriesTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              $$AccountExportEntriesTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> exportId = const Value.absent(),
                Value<String> uid = const Value.absent(),
                Value<DateTime> requestedAt = const Value.absent(),
                Value<DateTime> expiresAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => AccountExportEntriesCompanion(
                exportId: exportId,
                uid: uid,
                requestedAt: requestedAt,
                expiresAt: expiresAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String exportId,
                required String uid,
                required DateTime requestedAt,
                required DateTime expiresAt,
                Value<int> rowid = const Value.absent(),
              }) => AccountExportEntriesCompanion.insert(
                exportId: exportId,
                uid: uid,
                requestedAt: requestedAt,
                expiresAt: expiresAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$AccountExportEntriesTable, SavedAccountExport>(
                    table,
                  ),
                  BaseReferences<
                    _$AppDatabase,
                    $AccountExportEntriesTable,
                    SavedAccountExport
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$AccountExportEntriesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $AccountExportEntriesTable,
      SavedAccountExport,
      $$AccountExportEntriesTableFilterComposer,
      $$AccountExportEntriesTableOrderingComposer,
      $$AccountExportEntriesTableAnnotationComposer,
      $$AccountExportEntriesTableCreateCompanionBuilder,
      $$AccountExportEntriesTableUpdateCompanionBuilder,
      (
        SavedAccountExport,
        BaseReferences<
          _$AppDatabase,
          $AccountExportEntriesTable,
          SavedAccountExport
        >,
      ),
      SavedAccountExport,
      PrefetchHooks Function()
    >;

class $AppDatabaseManager {
  final _$AppDatabase _db;
  $AppDatabaseManager(this._db);
  $$ProfileCacheEntriesTableTableManager get profileCacheEntries =>
      $$ProfileCacheEntriesTableTableManager(_db, _db.profileCacheEntries);
  $$FollowingCacheEntriesTableTableManager get followingCacheEntries =>
      $$FollowingCacheEntriesTableTableManager(_db, _db.followingCacheEntries);
  $$TimelineItemEntriesTableTableManager get timelineItemEntries =>
      $$TimelineItemEntriesTableTableManager(_db, _db.timelineItemEntries);
  $$TimelineStateEntriesTableTableManager get timelineStateEntries =>
      $$TimelineStateEntriesTableTableManager(_db, _db.timelineStateEntries);
  $$AccountExportEntriesTableTableManager get accountExportEntries =>
      $$AccountExportEntriesTableTableManager(_db, _db.accountExportEntries);
}
