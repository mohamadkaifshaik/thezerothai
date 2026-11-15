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
  static const VerificationMeta _subscriptionVerifiedMeta =
      const VerificationMeta('subscriptionVerified');
  @override
  late final GeneratedColumn<bool> subscriptionVerified = GeneratedColumn<bool>(
    'subscription_verified',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("subscription_verified" IN (0, 1))',
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
    subscriptionVerified,
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
    if (data.containsKey('subscription_verified')) {
      context.handle(
        _subscriptionVerifiedMeta,
        subscriptionVerified.isAcceptableOrUnknown(
          data['subscription_verified']!,
          _subscriptionVerifiedMeta,
        ),
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
      subscriptionVerified: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}subscription_verified'],
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
  final bool subscriptionVerified;
  final int followersCount;
  final int followingCount;
  final int postsCount;

  /// When this row was written, so callers can decide whether it is fresh
  /// enough to render without a refresh.
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
    required this.subscriptionVerified,
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
    map['subscription_verified'] = Variable<bool>(subscriptionVerified);
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
      subscriptionVerified: Value(subscriptionVerified),
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
      subscriptionVerified: serializer.fromJson<bool>(
        json['subscriptionVerified'],
      ),
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
      'subscriptionVerified': serializer.toJson<bool>(subscriptionVerified),
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
    bool? subscriptionVerified,
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
    subscriptionVerified: subscriptionVerified ?? this.subscriptionVerified,
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
      subscriptionVerified: data.subscriptionVerified.present
          ? data.subscriptionVerified.value
          : this.subscriptionVerified,
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
          ..write('subscriptionVerified: $subscriptionVerified, ')
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
    subscriptionVerified,
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
          other.subscriptionVerified == this.subscriptionVerified &&
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
  final Value<bool> subscriptionVerified;
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
    this.subscriptionVerified = const Value.absent(),
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
    this.subscriptionVerified = const Value.absent(),
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
    Expression<bool>? subscriptionVerified,
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
      if (subscriptionVerified != null)
        'subscription_verified': subscriptionVerified,
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
    Value<bool>? subscriptionVerified,
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
      subscriptionVerified: subscriptionVerified ?? this.subscriptionVerified,
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
    if (subscriptionVerified.present) {
      map['subscription_verified'] = Variable<bool>(subscriptionVerified.value);
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
          ..write('subscriptionVerified: $subscriptionVerified, ')
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

class $NotificationEntriesTable extends NotificationEntries
    with TableInfo<$NotificationEntriesTable, CachedNotification> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $NotificationEntriesTable(this.attachedDatabase, [this._alias]);
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
  static const String $name = 'notification_entries';
  @override
  VerificationContext validateIntegrity(
    Insertable<CachedNotification> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
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
  Set<GeneratedColumn> get $primaryKey => {itemKey};
  @override
  CachedNotification map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return CachedNotification(
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
  $NotificationEntriesTable createAlias(String alias) {
    return $NotificationEntriesTable(attachedDatabase, alias);
  }
}

class CachedNotification extends DataClass
    implements Insertable<CachedNotification> {
  /// The notification id, or `gap:{sortKey}` for a gap row.
  final String itemKey;
  final String sortKey;

  /// Serialized `Notification`; null for a gap row.
  final Uint8List? payload;

  /// `gap_page_token`; null for a notification row.
  final String? gapToken;

  /// For a row that ended a fetched page: that page's `next_page_token`
  /// (lets retention trim at a page boundary and resume scrolling).
  final String? pageToken;
  const CachedNotification({
    required this.itemKey,
    required this.sortKey,
    this.payload,
    this.gapToken,
    this.pageToken,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
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

  NotificationEntriesCompanion toCompanion(bool nullToAbsent) {
    return NotificationEntriesCompanion(
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

  factory CachedNotification.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return CachedNotification(
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
      'itemKey': serializer.toJson<String>(itemKey),
      'sortKey': serializer.toJson<String>(sortKey),
      'payload': serializer.toJson<Uint8List?>(payload),
      'gapToken': serializer.toJson<String?>(gapToken),
      'pageToken': serializer.toJson<String?>(pageToken),
    };
  }

  CachedNotification copyWith({
    String? itemKey,
    String? sortKey,
    Value<Uint8List?> payload = const Value.absent(),
    Value<String?> gapToken = const Value.absent(),
    Value<String?> pageToken = const Value.absent(),
  }) => CachedNotification(
    itemKey: itemKey ?? this.itemKey,
    sortKey: sortKey ?? this.sortKey,
    payload: payload.present ? payload.value : this.payload,
    gapToken: gapToken.present ? gapToken.value : this.gapToken,
    pageToken: pageToken.present ? pageToken.value : this.pageToken,
  );
  CachedNotification copyWithCompanion(NotificationEntriesCompanion data) {
    return CachedNotification(
      itemKey: data.itemKey.present ? data.itemKey.value : this.itemKey,
      sortKey: data.sortKey.present ? data.sortKey.value : this.sortKey,
      payload: data.payload.present ? data.payload.value : this.payload,
      gapToken: data.gapToken.present ? data.gapToken.value : this.gapToken,
      pageToken: data.pageToken.present ? data.pageToken.value : this.pageToken,
    );
  }

  @override
  String toString() {
    return (StringBuffer('CachedNotification(')
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
    itemKey,
    sortKey,
    $driftBlobEquality.hash(payload),
    gapToken,
    pageToken,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is CachedNotification &&
          other.itemKey == this.itemKey &&
          other.sortKey == this.sortKey &&
          $driftBlobEquality.equals(other.payload, this.payload) &&
          other.gapToken == this.gapToken &&
          other.pageToken == this.pageToken);
}

class NotificationEntriesCompanion extends UpdateCompanion<CachedNotification> {
  final Value<String> itemKey;
  final Value<String> sortKey;
  final Value<Uint8List?> payload;
  final Value<String?> gapToken;
  final Value<String?> pageToken;
  final Value<int> rowid;
  const NotificationEntriesCompanion({
    this.itemKey = const Value.absent(),
    this.sortKey = const Value.absent(),
    this.payload = const Value.absent(),
    this.gapToken = const Value.absent(),
    this.pageToken = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  NotificationEntriesCompanion.insert({
    required String itemKey,
    required String sortKey,
    this.payload = const Value.absent(),
    this.gapToken = const Value.absent(),
    this.pageToken = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : itemKey = Value(itemKey),
       sortKey = Value(sortKey);
  static Insertable<CachedNotification> custom({
    Expression<String>? itemKey,
    Expression<String>? sortKey,
    Expression<Uint8List>? payload,
    Expression<String>? gapToken,
    Expression<String>? pageToken,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (itemKey != null) 'item_key': itemKey,
      if (sortKey != null) 'sort_key': sortKey,
      if (payload != null) 'payload': payload,
      if (gapToken != null) 'gap_token': gapToken,
      if (pageToken != null) 'page_token': pageToken,
      if (rowid != null) 'rowid': rowid,
    });
  }

  NotificationEntriesCompanion copyWith({
    Value<String>? itemKey,
    Value<String>? sortKey,
    Value<Uint8List?>? payload,
    Value<String?>? gapToken,
    Value<String?>? pageToken,
    Value<int>? rowid,
  }) {
    return NotificationEntriesCompanion(
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
    return (StringBuffer('NotificationEntriesCompanion(')
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

class $NotificationStateEntriesTable extends NotificationStateEntries
    with TableInfo<$NotificationStateEntriesTable, CachedNotificationState> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $NotificationStateEntriesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _stateKeyMeta = const VerificationMeta(
    'stateKey',
  );
  @override
  late final GeneratedColumn<String> stateKey = GeneratedColumn<String>(
    'state_key',
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
  static const VerificationMeta _seenAtMicrosMeta = const VerificationMeta(
    'seenAtMicros',
  );
  @override
  late final GeneratedColumn<int> seenAtMicros = GeneratedColumn<int>(
    'seen_at_micros',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _deviceIdMeta = const VerificationMeta(
    'deviceId',
  );
  @override
  late final GeneratedColumn<String> deviceId = GeneratedColumn<String>(
    'device_id',
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
    stateKey,
    sinceToken,
    olderPageToken,
    seenAtMicros,
    deviceId,
    updatedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'notification_state_entries';
  @override
  VerificationContext validateIntegrity(
    Insertable<CachedNotificationState> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('state_key')) {
      context.handle(
        _stateKeyMeta,
        stateKey.isAcceptableOrUnknown(data['state_key']!, _stateKeyMeta),
      );
    } else if (isInserting) {
      context.missing(_stateKeyMeta);
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
    if (data.containsKey('seen_at_micros')) {
      context.handle(
        _seenAtMicrosMeta,
        seenAtMicros.isAcceptableOrUnknown(
          data['seen_at_micros']!,
          _seenAtMicrosMeta,
        ),
      );
    }
    if (data.containsKey('device_id')) {
      context.handle(
        _deviceIdMeta,
        deviceId.isAcceptableOrUnknown(data['device_id']!, _deviceIdMeta),
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
  Set<GeneratedColumn> get $primaryKey => {stateKey};
  @override
  CachedNotificationState map(
    Map<String, dynamic> data, {
    String? tablePrefix,
  }) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return CachedNotificationState(
      stateKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}state_key'],
      )!,
      sinceToken: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}since_token'],
      )!,
      olderPageToken: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}older_page_token'],
      )!,
      seenAtMicros: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}seen_at_micros'],
      ),
      deviceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}device_id'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}updated_at'],
      )!,
    );
  }

  @override
  $NotificationStateEntriesTable createAlias(String alias) {
    return $NotificationStateEntriesTable(attachedDatabase, alias);
  }
}

class CachedNotificationState extends DataClass
    implements Insertable<CachedNotificationState> {
  final String stateKey;
  final String sinceToken;
  final String olderPageToken;

  /// `seen_at` in microseconds since the epoch; null = never marked seen.
  final int? seenAtMicros;

  /// This installation's random device id for RegisterDevice (stable until
  /// sign-out wipes the cache; '' = not generated yet). Never the FCM token.
  final String deviceId;
  final DateTime updatedAt;
  const CachedNotificationState({
    required this.stateKey,
    required this.sinceToken,
    required this.olderPageToken,
    this.seenAtMicros,
    required this.deviceId,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['state_key'] = Variable<String>(stateKey);
    map['since_token'] = Variable<String>(sinceToken);
    map['older_page_token'] = Variable<String>(olderPageToken);
    if (!nullToAbsent || seenAtMicros != null) {
      map['seen_at_micros'] = Variable<int>(seenAtMicros);
    }
    map['device_id'] = Variable<String>(deviceId);
    map['updated_at'] = Variable<DateTime>(updatedAt);
    return map;
  }

  NotificationStateEntriesCompanion toCompanion(bool nullToAbsent) {
    return NotificationStateEntriesCompanion(
      stateKey: Value(stateKey),
      sinceToken: Value(sinceToken),
      olderPageToken: Value(olderPageToken),
      seenAtMicros: seenAtMicros == null && nullToAbsent
          ? const Value.absent()
          : Value(seenAtMicros),
      deviceId: Value(deviceId),
      updatedAt: Value(updatedAt),
    );
  }

  factory CachedNotificationState.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return CachedNotificationState(
      stateKey: serializer.fromJson<String>(json['stateKey']),
      sinceToken: serializer.fromJson<String>(json['sinceToken']),
      olderPageToken: serializer.fromJson<String>(json['olderPageToken']),
      seenAtMicros: serializer.fromJson<int?>(json['seenAtMicros']),
      deviceId: serializer.fromJson<String>(json['deviceId']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'stateKey': serializer.toJson<String>(stateKey),
      'sinceToken': serializer.toJson<String>(sinceToken),
      'olderPageToken': serializer.toJson<String>(olderPageToken),
      'seenAtMicros': serializer.toJson<int?>(seenAtMicros),
      'deviceId': serializer.toJson<String>(deviceId),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
    };
  }

  CachedNotificationState copyWith({
    String? stateKey,
    String? sinceToken,
    String? olderPageToken,
    Value<int?> seenAtMicros = const Value.absent(),
    String? deviceId,
    DateTime? updatedAt,
  }) => CachedNotificationState(
    stateKey: stateKey ?? this.stateKey,
    sinceToken: sinceToken ?? this.sinceToken,
    olderPageToken: olderPageToken ?? this.olderPageToken,
    seenAtMicros: seenAtMicros.present ? seenAtMicros.value : this.seenAtMicros,
    deviceId: deviceId ?? this.deviceId,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  CachedNotificationState copyWithCompanion(
    NotificationStateEntriesCompanion data,
  ) {
    return CachedNotificationState(
      stateKey: data.stateKey.present ? data.stateKey.value : this.stateKey,
      sinceToken: data.sinceToken.present
          ? data.sinceToken.value
          : this.sinceToken,
      olderPageToken: data.olderPageToken.present
          ? data.olderPageToken.value
          : this.olderPageToken,
      seenAtMicros: data.seenAtMicros.present
          ? data.seenAtMicros.value
          : this.seenAtMicros,
      deviceId: data.deviceId.present ? data.deviceId.value : this.deviceId,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('CachedNotificationState(')
          ..write('stateKey: $stateKey, ')
          ..write('sinceToken: $sinceToken, ')
          ..write('olderPageToken: $olderPageToken, ')
          ..write('seenAtMicros: $seenAtMicros, ')
          ..write('deviceId: $deviceId, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    stateKey,
    sinceToken,
    olderPageToken,
    seenAtMicros,
    deviceId,
    updatedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is CachedNotificationState &&
          other.stateKey == this.stateKey &&
          other.sinceToken == this.sinceToken &&
          other.olderPageToken == this.olderPageToken &&
          other.seenAtMicros == this.seenAtMicros &&
          other.deviceId == this.deviceId &&
          other.updatedAt == this.updatedAt);
}

class NotificationStateEntriesCompanion
    extends UpdateCompanion<CachedNotificationState> {
  final Value<String> stateKey;
  final Value<String> sinceToken;
  final Value<String> olderPageToken;
  final Value<int?> seenAtMicros;
  final Value<String> deviceId;
  final Value<DateTime> updatedAt;
  final Value<int> rowid;
  const NotificationStateEntriesCompanion({
    this.stateKey = const Value.absent(),
    this.sinceToken = const Value.absent(),
    this.olderPageToken = const Value.absent(),
    this.seenAtMicros = const Value.absent(),
    this.deviceId = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  NotificationStateEntriesCompanion.insert({
    required String stateKey,
    this.sinceToken = const Value.absent(),
    this.olderPageToken = const Value.absent(),
    this.seenAtMicros = const Value.absent(),
    this.deviceId = const Value.absent(),
    required DateTime updatedAt,
    this.rowid = const Value.absent(),
  }) : stateKey = Value(stateKey),
       updatedAt = Value(updatedAt);
  static Insertable<CachedNotificationState> custom({
    Expression<String>? stateKey,
    Expression<String>? sinceToken,
    Expression<String>? olderPageToken,
    Expression<int>? seenAtMicros,
    Expression<String>? deviceId,
    Expression<DateTime>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (stateKey != null) 'state_key': stateKey,
      if (sinceToken != null) 'since_token': sinceToken,
      if (olderPageToken != null) 'older_page_token': olderPageToken,
      if (seenAtMicros != null) 'seen_at_micros': seenAtMicros,
      if (deviceId != null) 'device_id': deviceId,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  NotificationStateEntriesCompanion copyWith({
    Value<String>? stateKey,
    Value<String>? sinceToken,
    Value<String>? olderPageToken,
    Value<int?>? seenAtMicros,
    Value<String>? deviceId,
    Value<DateTime>? updatedAt,
    Value<int>? rowid,
  }) {
    return NotificationStateEntriesCompanion(
      stateKey: stateKey ?? this.stateKey,
      sinceToken: sinceToken ?? this.sinceToken,
      olderPageToken: olderPageToken ?? this.olderPageToken,
      seenAtMicros: seenAtMicros ?? this.seenAtMicros,
      deviceId: deviceId ?? this.deviceId,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (stateKey.present) {
      map['state_key'] = Variable<String>(stateKey.value);
    }
    if (sinceToken.present) {
      map['since_token'] = Variable<String>(sinceToken.value);
    }
    if (olderPageToken.present) {
      map['older_page_token'] = Variable<String>(olderPageToken.value);
    }
    if (seenAtMicros.present) {
      map['seen_at_micros'] = Variable<int>(seenAtMicros.value);
    }
    if (deviceId.present) {
      map['device_id'] = Variable<String>(deviceId.value);
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
    return (StringBuffer('NotificationStateEntriesCompanion(')
          ..write('stateKey: $stateKey, ')
          ..write('sinceToken: $sinceToken, ')
          ..write('olderPageToken: $olderPageToken, ')
          ..write('seenAtMicros: $seenAtMicros, ')
          ..write('deviceId: $deviceId, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $ConversationEntriesTable extends ConversationEntries
    with TableInfo<$ConversationEntriesTable, CachedConversation> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ConversationEntriesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _conversationIdMeta = const VerificationMeta(
    'conversationId',
  );
  @override
  late final GeneratedColumn<String> conversationId = GeneratedColumn<String>(
    'conversation_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _folderMeta = const VerificationMeta('folder');
  @override
  late final GeneratedColumn<int> folder = GeneratedColumn<int>(
    'folder',
    aliasedName,
    false,
    type: DriftSqlType.int,
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
    false,
    type: DriftSqlType.blob,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    conversationId,
    folder,
    sortKey,
    payload,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'conversation_entries';
  @override
  VerificationContext validateIntegrity(
    Insertable<CachedConversation> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('conversation_id')) {
      context.handle(
        _conversationIdMeta,
        conversationId.isAcceptableOrUnknown(
          data['conversation_id']!,
          _conversationIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_conversationIdMeta);
    }
    if (data.containsKey('folder')) {
      context.handle(
        _folderMeta,
        folder.isAcceptableOrUnknown(data['folder']!, _folderMeta),
      );
    } else if (isInserting) {
      context.missing(_folderMeta);
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
    } else if (isInserting) {
      context.missing(_payloadMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {conversationId};
  @override
  CachedConversation map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return CachedConversation(
      conversationId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}conversation_id'],
      )!,
      folder: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}folder'],
      )!,
      sortKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}sort_key'],
      )!,
      payload: attachedDatabase.typeMapping.read(
        DriftSqlType.blob,
        data['${effectivePrefix}payload'],
      )!,
    );
  }

  @override
  $ConversationEntriesTable createAlias(String alias) {
    return $ConversationEntriesTable(attachedDatabase, alias);
  }
}

class CachedConversation extends DataClass
    implements Insertable<CachedConversation> {
  /// 32-character lower-case hex id (opaque).
  final String conversationId;
  final int folder;
  final String sortKey;

  /// Serialized `Conversation`.
  final Uint8List payload;
  const CachedConversation({
    required this.conversationId,
    required this.folder,
    required this.sortKey,
    required this.payload,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['conversation_id'] = Variable<String>(conversationId);
    map['folder'] = Variable<int>(folder);
    map['sort_key'] = Variable<String>(sortKey);
    map['payload'] = Variable<Uint8List>(payload);
    return map;
  }

  ConversationEntriesCompanion toCompanion(bool nullToAbsent) {
    return ConversationEntriesCompanion(
      conversationId: Value(conversationId),
      folder: Value(folder),
      sortKey: Value(sortKey),
      payload: Value(payload),
    );
  }

  factory CachedConversation.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return CachedConversation(
      conversationId: serializer.fromJson<String>(json['conversationId']),
      folder: serializer.fromJson<int>(json['folder']),
      sortKey: serializer.fromJson<String>(json['sortKey']),
      payload: serializer.fromJson<Uint8List>(json['payload']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'conversationId': serializer.toJson<String>(conversationId),
      'folder': serializer.toJson<int>(folder),
      'sortKey': serializer.toJson<String>(sortKey),
      'payload': serializer.toJson<Uint8List>(payload),
    };
  }

  CachedConversation copyWith({
    String? conversationId,
    int? folder,
    String? sortKey,
    Uint8List? payload,
  }) => CachedConversation(
    conversationId: conversationId ?? this.conversationId,
    folder: folder ?? this.folder,
    sortKey: sortKey ?? this.sortKey,
    payload: payload ?? this.payload,
  );
  CachedConversation copyWithCompanion(ConversationEntriesCompanion data) {
    return CachedConversation(
      conversationId: data.conversationId.present
          ? data.conversationId.value
          : this.conversationId,
      folder: data.folder.present ? data.folder.value : this.folder,
      sortKey: data.sortKey.present ? data.sortKey.value : this.sortKey,
      payload: data.payload.present ? data.payload.value : this.payload,
    );
  }

  @override
  String toString() {
    return (StringBuffer('CachedConversation(')
          ..write('conversationId: $conversationId, ')
          ..write('folder: $folder, ')
          ..write('sortKey: $sortKey, ')
          ..write('payload: $payload')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    conversationId,
    folder,
    sortKey,
    $driftBlobEquality.hash(payload),
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is CachedConversation &&
          other.conversationId == this.conversationId &&
          other.folder == this.folder &&
          other.sortKey == this.sortKey &&
          $driftBlobEquality.equals(other.payload, this.payload));
}

class ConversationEntriesCompanion extends UpdateCompanion<CachedConversation> {
  final Value<String> conversationId;
  final Value<int> folder;
  final Value<String> sortKey;
  final Value<Uint8List> payload;
  final Value<int> rowid;
  const ConversationEntriesCompanion({
    this.conversationId = const Value.absent(),
    this.folder = const Value.absent(),
    this.sortKey = const Value.absent(),
    this.payload = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ConversationEntriesCompanion.insert({
    required String conversationId,
    required int folder,
    required String sortKey,
    required Uint8List payload,
    this.rowid = const Value.absent(),
  }) : conversationId = Value(conversationId),
       folder = Value(folder),
       sortKey = Value(sortKey),
       payload = Value(payload);
  static Insertable<CachedConversation> custom({
    Expression<String>? conversationId,
    Expression<int>? folder,
    Expression<String>? sortKey,
    Expression<Uint8List>? payload,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (conversationId != null) 'conversation_id': conversationId,
      if (folder != null) 'folder': folder,
      if (sortKey != null) 'sort_key': sortKey,
      if (payload != null) 'payload': payload,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ConversationEntriesCompanion copyWith({
    Value<String>? conversationId,
    Value<int>? folder,
    Value<String>? sortKey,
    Value<Uint8List>? payload,
    Value<int>? rowid,
  }) {
    return ConversationEntriesCompanion(
      conversationId: conversationId ?? this.conversationId,
      folder: folder ?? this.folder,
      sortKey: sortKey ?? this.sortKey,
      payload: payload ?? this.payload,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (conversationId.present) {
      map['conversation_id'] = Variable<String>(conversationId.value);
    }
    if (folder.present) {
      map['folder'] = Variable<int>(folder.value);
    }
    if (sortKey.present) {
      map['sort_key'] = Variable<String>(sortKey.value);
    }
    if (payload.present) {
      map['payload'] = Variable<Uint8List>(payload.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ConversationEntriesCompanion(')
          ..write('conversationId: $conversationId, ')
          ..write('folder: $folder, ')
          ..write('sortKey: $sortKey, ')
          ..write('payload: $payload, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $MessageEntriesTable extends MessageEntries
    with TableInfo<$MessageEntriesTable, CachedMessage> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $MessageEntriesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _conversationIdMeta = const VerificationMeta(
    'conversationId',
  );
  @override
  late final GeneratedColumn<String> conversationId = GeneratedColumn<String>(
    'conversation_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _messageIdMeta = const VerificationMeta(
    'messageId',
  );
  @override
  late final GeneratedColumn<String> messageId = GeneratedColumn<String>(
    'message_id',
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
    false,
    type: DriftSqlType.blob,
    requiredDuringInsert: true,
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
    conversationId,
    messageId,
    sortKey,
    payload,
    pageToken,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'message_entries';
  @override
  VerificationContext validateIntegrity(
    Insertable<CachedMessage> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('conversation_id')) {
      context.handle(
        _conversationIdMeta,
        conversationId.isAcceptableOrUnknown(
          data['conversation_id']!,
          _conversationIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_conversationIdMeta);
    }
    if (data.containsKey('message_id')) {
      context.handle(
        _messageIdMeta,
        messageId.isAcceptableOrUnknown(data['message_id']!, _messageIdMeta),
      );
    } else if (isInserting) {
      context.missing(_messageIdMeta);
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
    } else if (isInserting) {
      context.missing(_payloadMeta);
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
  Set<GeneratedColumn> get $primaryKey => {conversationId, messageId};
  @override
  CachedMessage map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return CachedMessage(
      conversationId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}conversation_id'],
      )!,
      messageId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}message_id'],
      )!,
      sortKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}sort_key'],
      )!,
      payload: attachedDatabase.typeMapping.read(
        DriftSqlType.blob,
        data['${effectivePrefix}payload'],
      )!,
      pageToken: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}page_token'],
      ),
    );
  }

  @override
  $MessageEntriesTable createAlias(String alias) {
    return $MessageEntriesTable(attachedDatabase, alias);
  }
}

class CachedMessage extends DataClass implements Insertable<CachedMessage> {
  final String conversationId;
  final String messageId;
  final String sortKey;

  /// Serialized `Message`.
  final Uint8List payload;

  /// For a row that ended a fetched page: that page's `next_page_token`
  /// (lets the 200-row trim cut at a page boundary and resume scrolling).
  final String? pageToken;
  const CachedMessage({
    required this.conversationId,
    required this.messageId,
    required this.sortKey,
    required this.payload,
    this.pageToken,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['conversation_id'] = Variable<String>(conversationId);
    map['message_id'] = Variable<String>(messageId);
    map['sort_key'] = Variable<String>(sortKey);
    map['payload'] = Variable<Uint8List>(payload);
    if (!nullToAbsent || pageToken != null) {
      map['page_token'] = Variable<String>(pageToken);
    }
    return map;
  }

  MessageEntriesCompanion toCompanion(bool nullToAbsent) {
    return MessageEntriesCompanion(
      conversationId: Value(conversationId),
      messageId: Value(messageId),
      sortKey: Value(sortKey),
      payload: Value(payload),
      pageToken: pageToken == null && nullToAbsent
          ? const Value.absent()
          : Value(pageToken),
    );
  }

  factory CachedMessage.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return CachedMessage(
      conversationId: serializer.fromJson<String>(json['conversationId']),
      messageId: serializer.fromJson<String>(json['messageId']),
      sortKey: serializer.fromJson<String>(json['sortKey']),
      payload: serializer.fromJson<Uint8List>(json['payload']),
      pageToken: serializer.fromJson<String?>(json['pageToken']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'conversationId': serializer.toJson<String>(conversationId),
      'messageId': serializer.toJson<String>(messageId),
      'sortKey': serializer.toJson<String>(sortKey),
      'payload': serializer.toJson<Uint8List>(payload),
      'pageToken': serializer.toJson<String?>(pageToken),
    };
  }

  CachedMessage copyWith({
    String? conversationId,
    String? messageId,
    String? sortKey,
    Uint8List? payload,
    Value<String?> pageToken = const Value.absent(),
  }) => CachedMessage(
    conversationId: conversationId ?? this.conversationId,
    messageId: messageId ?? this.messageId,
    sortKey: sortKey ?? this.sortKey,
    payload: payload ?? this.payload,
    pageToken: pageToken.present ? pageToken.value : this.pageToken,
  );
  CachedMessage copyWithCompanion(MessageEntriesCompanion data) {
    return CachedMessage(
      conversationId: data.conversationId.present
          ? data.conversationId.value
          : this.conversationId,
      messageId: data.messageId.present ? data.messageId.value : this.messageId,
      sortKey: data.sortKey.present ? data.sortKey.value : this.sortKey,
      payload: data.payload.present ? data.payload.value : this.payload,
      pageToken: data.pageToken.present ? data.pageToken.value : this.pageToken,
    );
  }

  @override
  String toString() {
    return (StringBuffer('CachedMessage(')
          ..write('conversationId: $conversationId, ')
          ..write('messageId: $messageId, ')
          ..write('sortKey: $sortKey, ')
          ..write('payload: $payload, ')
          ..write('pageToken: $pageToken')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    conversationId,
    messageId,
    sortKey,
    $driftBlobEquality.hash(payload),
    pageToken,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is CachedMessage &&
          other.conversationId == this.conversationId &&
          other.messageId == this.messageId &&
          other.sortKey == this.sortKey &&
          $driftBlobEquality.equals(other.payload, this.payload) &&
          other.pageToken == this.pageToken);
}

class MessageEntriesCompanion extends UpdateCompanion<CachedMessage> {
  final Value<String> conversationId;
  final Value<String> messageId;
  final Value<String> sortKey;
  final Value<Uint8List> payload;
  final Value<String?> pageToken;
  final Value<int> rowid;
  const MessageEntriesCompanion({
    this.conversationId = const Value.absent(),
    this.messageId = const Value.absent(),
    this.sortKey = const Value.absent(),
    this.payload = const Value.absent(),
    this.pageToken = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  MessageEntriesCompanion.insert({
    required String conversationId,
    required String messageId,
    required String sortKey,
    required Uint8List payload,
    this.pageToken = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : conversationId = Value(conversationId),
       messageId = Value(messageId),
       sortKey = Value(sortKey),
       payload = Value(payload);
  static Insertable<CachedMessage> custom({
    Expression<String>? conversationId,
    Expression<String>? messageId,
    Expression<String>? sortKey,
    Expression<Uint8List>? payload,
    Expression<String>? pageToken,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (conversationId != null) 'conversation_id': conversationId,
      if (messageId != null) 'message_id': messageId,
      if (sortKey != null) 'sort_key': sortKey,
      if (payload != null) 'payload': payload,
      if (pageToken != null) 'page_token': pageToken,
      if (rowid != null) 'rowid': rowid,
    });
  }

  MessageEntriesCompanion copyWith({
    Value<String>? conversationId,
    Value<String>? messageId,
    Value<String>? sortKey,
    Value<Uint8List>? payload,
    Value<String?>? pageToken,
    Value<int>? rowid,
  }) {
    return MessageEntriesCompanion(
      conversationId: conversationId ?? this.conversationId,
      messageId: messageId ?? this.messageId,
      sortKey: sortKey ?? this.sortKey,
      payload: payload ?? this.payload,
      pageToken: pageToken ?? this.pageToken,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (conversationId.present) {
      map['conversation_id'] = Variable<String>(conversationId.value);
    }
    if (messageId.present) {
      map['message_id'] = Variable<String>(messageId.value);
    }
    if (sortKey.present) {
      map['sort_key'] = Variable<String>(sortKey.value);
    }
    if (payload.present) {
      map['payload'] = Variable<Uint8List>(payload.value);
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
    return (StringBuffer('MessageEntriesCompanion(')
          ..write('conversationId: $conversationId, ')
          ..write('messageId: $messageId, ')
          ..write('sortKey: $sortKey, ')
          ..write('payload: $payload, ')
          ..write('pageToken: $pageToken, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $MessagingStateEntriesTable extends MessagingStateEntries
    with TableInfo<$MessagingStateEntriesTable, CachedMessagingState> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $MessagingStateEntriesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _stateKeyMeta = const VerificationMeta(
    'stateKey',
  );
  @override
  late final GeneratedColumn<String> stateKey = GeneratedColumn<String>(
    'state_key',
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
  static const VerificationMeta _requestCountMeta = const VerificationMeta(
    'requestCount',
  );
  @override
  late final GeneratedColumn<int> requestCount = GeneratedColumn<int>(
    'request_count',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    stateKey,
    sinceToken,
    olderPageToken,
    updatedAt,
    requestCount,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'messaging_state_entries';
  @override
  VerificationContext validateIntegrity(
    Insertable<CachedMessagingState> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('state_key')) {
      context.handle(
        _stateKeyMeta,
        stateKey.isAcceptableOrUnknown(data['state_key']!, _stateKeyMeta),
      );
    } else if (isInserting) {
      context.missing(_stateKeyMeta);
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
    if (data.containsKey('request_count')) {
      context.handle(
        _requestCountMeta,
        requestCount.isAcceptableOrUnknown(
          data['request_count']!,
          _requestCountMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {stateKey};
  @override
  CachedMessagingState map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return CachedMessagingState(
      stateKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}state_key'],
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
      requestCount: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}request_count'],
      ),
    );
  }

  @override
  $MessagingStateEntriesTable createAlias(String alias) {
    return $MessagingStateEntriesTable(attachedDatabase, alias);
  }
}

class CachedMessagingState extends DataClass
    implements Insertable<CachedMessagingState> {
  final String stateKey;
  final String sinceToken;

  /// Token for scrolling older than the oldest cached row; '' = none/end.
  final String olderPageToken;
  final DateTime updatedAt;

  /// Last known pending message-request count, on the `inbox` row only (v8).
  /// Null = never received (unknown), which is not the same as 0.
  final int? requestCount;
  const CachedMessagingState({
    required this.stateKey,
    required this.sinceToken,
    required this.olderPageToken,
    required this.updatedAt,
    this.requestCount,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['state_key'] = Variable<String>(stateKey);
    map['since_token'] = Variable<String>(sinceToken);
    map['older_page_token'] = Variable<String>(olderPageToken);
    map['updated_at'] = Variable<DateTime>(updatedAt);
    if (!nullToAbsent || requestCount != null) {
      map['request_count'] = Variable<int>(requestCount);
    }
    return map;
  }

  MessagingStateEntriesCompanion toCompanion(bool nullToAbsent) {
    return MessagingStateEntriesCompanion(
      stateKey: Value(stateKey),
      sinceToken: Value(sinceToken),
      olderPageToken: Value(olderPageToken),
      updatedAt: Value(updatedAt),
      requestCount: requestCount == null && nullToAbsent
          ? const Value.absent()
          : Value(requestCount),
    );
  }

  factory CachedMessagingState.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return CachedMessagingState(
      stateKey: serializer.fromJson<String>(json['stateKey']),
      sinceToken: serializer.fromJson<String>(json['sinceToken']),
      olderPageToken: serializer.fromJson<String>(json['olderPageToken']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
      requestCount: serializer.fromJson<int?>(json['requestCount']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'stateKey': serializer.toJson<String>(stateKey),
      'sinceToken': serializer.toJson<String>(sinceToken),
      'olderPageToken': serializer.toJson<String>(olderPageToken),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
      'requestCount': serializer.toJson<int?>(requestCount),
    };
  }

  CachedMessagingState copyWith({
    String? stateKey,
    String? sinceToken,
    String? olderPageToken,
    DateTime? updatedAt,
    Value<int?> requestCount = const Value.absent(),
  }) => CachedMessagingState(
    stateKey: stateKey ?? this.stateKey,
    sinceToken: sinceToken ?? this.sinceToken,
    olderPageToken: olderPageToken ?? this.olderPageToken,
    updatedAt: updatedAt ?? this.updatedAt,
    requestCount: requestCount.present ? requestCount.value : this.requestCount,
  );
  CachedMessagingState copyWithCompanion(MessagingStateEntriesCompanion data) {
    return CachedMessagingState(
      stateKey: data.stateKey.present ? data.stateKey.value : this.stateKey,
      sinceToken: data.sinceToken.present
          ? data.sinceToken.value
          : this.sinceToken,
      olderPageToken: data.olderPageToken.present
          ? data.olderPageToken.value
          : this.olderPageToken,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
      requestCount: data.requestCount.present
          ? data.requestCount.value
          : this.requestCount,
    );
  }

  @override
  String toString() {
    return (StringBuffer('CachedMessagingState(')
          ..write('stateKey: $stateKey, ')
          ..write('sinceToken: $sinceToken, ')
          ..write('olderPageToken: $olderPageToken, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('requestCount: $requestCount')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    stateKey,
    sinceToken,
    olderPageToken,
    updatedAt,
    requestCount,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is CachedMessagingState &&
          other.stateKey == this.stateKey &&
          other.sinceToken == this.sinceToken &&
          other.olderPageToken == this.olderPageToken &&
          other.updatedAt == this.updatedAt &&
          other.requestCount == this.requestCount);
}

class MessagingStateEntriesCompanion
    extends UpdateCompanion<CachedMessagingState> {
  final Value<String> stateKey;
  final Value<String> sinceToken;
  final Value<String> olderPageToken;
  final Value<DateTime> updatedAt;
  final Value<int?> requestCount;
  final Value<int> rowid;
  const MessagingStateEntriesCompanion({
    this.stateKey = const Value.absent(),
    this.sinceToken = const Value.absent(),
    this.olderPageToken = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.requestCount = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  MessagingStateEntriesCompanion.insert({
    required String stateKey,
    this.sinceToken = const Value.absent(),
    this.olderPageToken = const Value.absent(),
    required DateTime updatedAt,
    this.requestCount = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : stateKey = Value(stateKey),
       updatedAt = Value(updatedAt);
  static Insertable<CachedMessagingState> custom({
    Expression<String>? stateKey,
    Expression<String>? sinceToken,
    Expression<String>? olderPageToken,
    Expression<DateTime>? updatedAt,
    Expression<int>? requestCount,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (stateKey != null) 'state_key': stateKey,
      if (sinceToken != null) 'since_token': sinceToken,
      if (olderPageToken != null) 'older_page_token': olderPageToken,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (requestCount != null) 'request_count': requestCount,
      if (rowid != null) 'rowid': rowid,
    });
  }

  MessagingStateEntriesCompanion copyWith({
    Value<String>? stateKey,
    Value<String>? sinceToken,
    Value<String>? olderPageToken,
    Value<DateTime>? updatedAt,
    Value<int?>? requestCount,
    Value<int>? rowid,
  }) {
    return MessagingStateEntriesCompanion(
      stateKey: stateKey ?? this.stateKey,
      sinceToken: sinceToken ?? this.sinceToken,
      olderPageToken: olderPageToken ?? this.olderPageToken,
      updatedAt: updatedAt ?? this.updatedAt,
      requestCount: requestCount ?? this.requestCount,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (stateKey.present) {
      map['state_key'] = Variable<String>(stateKey.value);
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
    if (requestCount.present) {
      map['request_count'] = Variable<int>(requestCount.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('MessagingStateEntriesCompanion(')
          ..write('stateKey: $stateKey, ')
          ..write('sinceToken: $sinceToken, ')
          ..write('olderPageToken: $olderPageToken, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('requestCount: $requestCount, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $AppSettingEntriesTable extends AppSettingEntries
    with TableInfo<$AppSettingEntriesTable, DeviceSetting> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $AppSettingEntriesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _settingKeyMeta = const VerificationMeta(
    'settingKey',
  );
  @override
  late final GeneratedColumn<String> settingKey = GeneratedColumn<String>(
    'setting_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _settingValueMeta = const VerificationMeta(
    'settingValue',
  );
  @override
  late final GeneratedColumn<String> settingValue = GeneratedColumn<String>(
    'setting_value',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [settingKey, settingValue];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'app_setting_entries';
  @override
  VerificationContext validateIntegrity(
    Insertable<DeviceSetting> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('setting_key')) {
      context.handle(
        _settingKeyMeta,
        settingKey.isAcceptableOrUnknown(data['setting_key']!, _settingKeyMeta),
      );
    } else if (isInserting) {
      context.missing(_settingKeyMeta);
    }
    if (data.containsKey('setting_value')) {
      context.handle(
        _settingValueMeta,
        settingValue.isAcceptableOrUnknown(
          data['setting_value']!,
          _settingValueMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_settingValueMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {settingKey};
  @override
  DeviceSetting map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return DeviceSetting(
      settingKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}setting_key'],
      )!,
      settingValue: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}setting_value'],
      )!,
    );
  }

  @override
  $AppSettingEntriesTable createAlias(String alias) {
    return $AppSettingEntriesTable(attachedDatabase, alias);
  }
}

class DeviceSetting extends DataClass implements Insertable<DeviceSetting> {
  final String settingKey;
  final String settingValue;
  const DeviceSetting({required this.settingKey, required this.settingValue});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['setting_key'] = Variable<String>(settingKey);
    map['setting_value'] = Variable<String>(settingValue);
    return map;
  }

  AppSettingEntriesCompanion toCompanion(bool nullToAbsent) {
    return AppSettingEntriesCompanion(
      settingKey: Value(settingKey),
      settingValue: Value(settingValue),
    );
  }

  factory DeviceSetting.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return DeviceSetting(
      settingKey: serializer.fromJson<String>(json['settingKey']),
      settingValue: serializer.fromJson<String>(json['settingValue']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'settingKey': serializer.toJson<String>(settingKey),
      'settingValue': serializer.toJson<String>(settingValue),
    };
  }

  DeviceSetting copyWith({String? settingKey, String? settingValue}) =>
      DeviceSetting(
        settingKey: settingKey ?? this.settingKey,
        settingValue: settingValue ?? this.settingValue,
      );
  DeviceSetting copyWithCompanion(AppSettingEntriesCompanion data) {
    return DeviceSetting(
      settingKey: data.settingKey.present
          ? data.settingKey.value
          : this.settingKey,
      settingValue: data.settingValue.present
          ? data.settingValue.value
          : this.settingValue,
    );
  }

  @override
  String toString() {
    return (StringBuffer('DeviceSetting(')
          ..write('settingKey: $settingKey, ')
          ..write('settingValue: $settingValue')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(settingKey, settingValue);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is DeviceSetting &&
          other.settingKey == this.settingKey &&
          other.settingValue == this.settingValue);
}

class AppSettingEntriesCompanion extends UpdateCompanion<DeviceSetting> {
  final Value<String> settingKey;
  final Value<String> settingValue;
  final Value<int> rowid;
  const AppSettingEntriesCompanion({
    this.settingKey = const Value.absent(),
    this.settingValue = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  AppSettingEntriesCompanion.insert({
    required String settingKey,
    required String settingValue,
    this.rowid = const Value.absent(),
  }) : settingKey = Value(settingKey),
       settingValue = Value(settingValue);
  static Insertable<DeviceSetting> custom({
    Expression<String>? settingKey,
    Expression<String>? settingValue,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (settingKey != null) 'setting_key': settingKey,
      if (settingValue != null) 'setting_value': settingValue,
      if (rowid != null) 'rowid': rowid,
    });
  }

  AppSettingEntriesCompanion copyWith({
    Value<String>? settingKey,
    Value<String>? settingValue,
    Value<int>? rowid,
  }) {
    return AppSettingEntriesCompanion(
      settingKey: settingKey ?? this.settingKey,
      settingValue: settingValue ?? this.settingValue,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (settingKey.present) {
      map['setting_key'] = Variable<String>(settingKey.value);
    }
    if (settingValue.present) {
      map['setting_value'] = Variable<String>(settingValue.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('AppSettingEntriesCompanion(')
          ..write('settingKey: $settingKey, ')
          ..write('settingValue: $settingValue, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $ComposerDraftEntriesTable extends ComposerDraftEntries
    with TableInfo<$ComposerDraftEntriesTable, ComposerDraftRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ComposerDraftEntriesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _draftIdMeta = const VerificationMeta(
    'draftId',
  );
  @override
  late final GeneratedColumn<String> draftId = GeneratedColumn<String>(
    'draft_id',
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
  static const VerificationMeta _draftTextMeta = const VerificationMeta(
    'draftText',
  );
  @override
  late final GeneratedColumn<String> draftText = GeneratedColumn<String>(
    'draft_text',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _pollJsonMeta = const VerificationMeta(
    'pollJson',
  );
  @override
  late final GeneratedColumn<String> pollJson = GeneratedColumn<String>(
    'poll_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _replyPolicyMeta = const VerificationMeta(
    'replyPolicy',
  );
  @override
  late final GeneratedColumn<String> replyPolicy = GeneratedColumn<String>(
    'reply_policy',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('everyone'),
  );
  static const VerificationMeta _paidPartnershipMeta = const VerificationMeta(
    'paidPartnership',
  );
  @override
  late final GeneratedColumn<bool> paidPartnership = GeneratedColumn<bool>(
    'paid_partnership',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("paid_partnership" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _madeWithAiMeta = const VerificationMeta(
    'madeWithAi',
  );
  @override
  late final GeneratedColumn<bool> madeWithAi = GeneratedColumn<bool>(
    'made_with_ai',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("made_with_ai" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _communityIdMeta = const VerificationMeta(
    'communityId',
  );
  @override
  late final GeneratedColumn<String> communityId = GeneratedColumn<String>(
    'community_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
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
  static const VerificationMeta _sendKeyMeta = const VerificationMeta(
    'sendKey',
  );
  @override
  late final GeneratedColumn<String> sendKey = GeneratedColumn<String>(
    'send_key',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _sendKindMeta = const VerificationMeta(
    'sendKind',
  );
  @override
  late final GeneratedColumn<String> sendKind = GeneratedColumn<String>(
    'send_kind',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _sendPublishAtMeta = const VerificationMeta(
    'sendPublishAt',
  );
  @override
  late final GeneratedColumn<DateTime> sendPublishAt =
      GeneratedColumn<DateTime>(
        'send_publish_at',
        aliasedName,
        true,
        type: DriftSqlType.dateTime,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _sendStartedAtMeta = const VerificationMeta(
    'sendStartedAt',
  );
  @override
  late final GeneratedColumn<DateTime> sendStartedAt =
      GeneratedColumn<DateTime>(
        'send_started_at',
        aliasedName,
        true,
        type: DriftSqlType.dateTime,
        requiredDuringInsert: false,
      );
  @override
  List<GeneratedColumn> get $columns => [
    draftId,
    uid,
    draftText,
    pollJson,
    replyPolicy,
    paidPartnership,
    madeWithAi,
    communityId,
    createdAt,
    updatedAt,
    sendKey,
    sendKind,
    sendPublishAt,
    sendStartedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'composer_draft_entries';
  @override
  VerificationContext validateIntegrity(
    Insertable<ComposerDraftRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('draft_id')) {
      context.handle(
        _draftIdMeta,
        draftId.isAcceptableOrUnknown(data['draft_id']!, _draftIdMeta),
      );
    } else if (isInserting) {
      context.missing(_draftIdMeta);
    }
    if (data.containsKey('uid')) {
      context.handle(
        _uidMeta,
        uid.isAcceptableOrUnknown(data['uid']!, _uidMeta),
      );
    } else if (isInserting) {
      context.missing(_uidMeta);
    }
    if (data.containsKey('draft_text')) {
      context.handle(
        _draftTextMeta,
        draftText.isAcceptableOrUnknown(data['draft_text']!, _draftTextMeta),
      );
    } else if (isInserting) {
      context.missing(_draftTextMeta);
    }
    if (data.containsKey('poll_json')) {
      context.handle(
        _pollJsonMeta,
        pollJson.isAcceptableOrUnknown(data['poll_json']!, _pollJsonMeta),
      );
    }
    if (data.containsKey('reply_policy')) {
      context.handle(
        _replyPolicyMeta,
        replyPolicy.isAcceptableOrUnknown(
          data['reply_policy']!,
          _replyPolicyMeta,
        ),
      );
    }
    if (data.containsKey('paid_partnership')) {
      context.handle(
        _paidPartnershipMeta,
        paidPartnership.isAcceptableOrUnknown(
          data['paid_partnership']!,
          _paidPartnershipMeta,
        ),
      );
    }
    if (data.containsKey('made_with_ai')) {
      context.handle(
        _madeWithAiMeta,
        madeWithAi.isAcceptableOrUnknown(
          data['made_with_ai']!,
          _madeWithAiMeta,
        ),
      );
    }
    if (data.containsKey('community_id')) {
      context.handle(
        _communityIdMeta,
        communityId.isAcceptableOrUnknown(
          data['community_id']!,
          _communityIdMeta,
        ),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    if (data.containsKey('send_key')) {
      context.handle(
        _sendKeyMeta,
        sendKey.isAcceptableOrUnknown(data['send_key']!, _sendKeyMeta),
      );
    }
    if (data.containsKey('send_kind')) {
      context.handle(
        _sendKindMeta,
        sendKind.isAcceptableOrUnknown(data['send_kind']!, _sendKindMeta),
      );
    }
    if (data.containsKey('send_publish_at')) {
      context.handle(
        _sendPublishAtMeta,
        sendPublishAt.isAcceptableOrUnknown(
          data['send_publish_at']!,
          _sendPublishAtMeta,
        ),
      );
    }
    if (data.containsKey('send_started_at')) {
      context.handle(
        _sendStartedAtMeta,
        sendStartedAt.isAcceptableOrUnknown(
          data['send_started_at']!,
          _sendStartedAtMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {uid, draftId};
  @override
  ComposerDraftRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ComposerDraftRow(
      draftId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}draft_id'],
      )!,
      uid: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}uid'],
      )!,
      draftText: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}draft_text'],
      )!,
      pollJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}poll_json'],
      )!,
      replyPolicy: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}reply_policy'],
      )!,
      paidPartnership: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}paid_partnership'],
      )!,
      madeWithAi: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}made_with_ai'],
      )!,
      communityId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}community_id'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}created_at'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}updated_at'],
      )!,
      sendKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}send_key'],
      ),
      sendKind: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}send_kind'],
      ),
      sendPublishAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}send_publish_at'],
      ),
      sendStartedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}send_started_at'],
      ),
    );
  }

  @override
  $ComposerDraftEntriesTable createAlias(String alias) {
    return $ComposerDraftEntriesTable(attachedDatabase, alias);
  }
}

class ComposerDraftRow extends DataClass
    implements Insertable<ComposerDraftRow> {
  /// Opaque random id, unique per account on the device (the key is
  /// `{uid, draftId}`).
  final String draftId;

  /// Firebase uid of the author.
  final String uid;

  /// The post text (named so it does not shadow drift's `text()`).
  final String draftText;

  /// JSON `{"c": [choices], "d": minutes}`; '' = no poll.
  final String pollJson;

  /// `ReplyAudience.name`.
  final String replyPolicy;
  final bool paidPartnership;
  final bool madeWithAi;

  /// The community the post was going into; '' = Everyone.
  final String communityId;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// The send in flight or lost: the
  /// idempotency key claimed for the last send of this draft, null when no
  /// send is pending. Written only by `DraftsRepository.claimSend` and cleared
  /// by `clearSend`; never touches [updatedAt]. Not personal data and
  /// never logged.
  final String? sendKey;

  /// `post` or `schedule`: which RPC [sendKey] belongs to (the two have
  /// separate key spaces on the server).
  final String? sendKind;

  /// The publish time of a pending `schedule` send, UTC.
  final DateTime? sendPublishAt;

  /// When [sendKey] was first minted; the 23 h window runs from here and is
  /// never refreshed by a reuse.
  final DateTime? sendStartedAt;
  const ComposerDraftRow({
    required this.draftId,
    required this.uid,
    required this.draftText,
    required this.pollJson,
    required this.replyPolicy,
    required this.paidPartnership,
    required this.madeWithAi,
    required this.communityId,
    required this.createdAt,
    required this.updatedAt,
    this.sendKey,
    this.sendKind,
    this.sendPublishAt,
    this.sendStartedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['draft_id'] = Variable<String>(draftId);
    map['uid'] = Variable<String>(uid);
    map['draft_text'] = Variable<String>(draftText);
    map['poll_json'] = Variable<String>(pollJson);
    map['reply_policy'] = Variable<String>(replyPolicy);
    map['paid_partnership'] = Variable<bool>(paidPartnership);
    map['made_with_ai'] = Variable<bool>(madeWithAi);
    map['community_id'] = Variable<String>(communityId);
    map['created_at'] = Variable<DateTime>(createdAt);
    map['updated_at'] = Variable<DateTime>(updatedAt);
    if (!nullToAbsent || sendKey != null) {
      map['send_key'] = Variable<String>(sendKey);
    }
    if (!nullToAbsent || sendKind != null) {
      map['send_kind'] = Variable<String>(sendKind);
    }
    if (!nullToAbsent || sendPublishAt != null) {
      map['send_publish_at'] = Variable<DateTime>(sendPublishAt);
    }
    if (!nullToAbsent || sendStartedAt != null) {
      map['send_started_at'] = Variable<DateTime>(sendStartedAt);
    }
    return map;
  }

  ComposerDraftEntriesCompanion toCompanion(bool nullToAbsent) {
    return ComposerDraftEntriesCompanion(
      draftId: Value(draftId),
      uid: Value(uid),
      draftText: Value(draftText),
      pollJson: Value(pollJson),
      replyPolicy: Value(replyPolicy),
      paidPartnership: Value(paidPartnership),
      madeWithAi: Value(madeWithAi),
      communityId: Value(communityId),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
      sendKey: sendKey == null && nullToAbsent
          ? const Value.absent()
          : Value(sendKey),
      sendKind: sendKind == null && nullToAbsent
          ? const Value.absent()
          : Value(sendKind),
      sendPublishAt: sendPublishAt == null && nullToAbsent
          ? const Value.absent()
          : Value(sendPublishAt),
      sendStartedAt: sendStartedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(sendStartedAt),
    );
  }

  factory ComposerDraftRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ComposerDraftRow(
      draftId: serializer.fromJson<String>(json['draftId']),
      uid: serializer.fromJson<String>(json['uid']),
      draftText: serializer.fromJson<String>(json['draftText']),
      pollJson: serializer.fromJson<String>(json['pollJson']),
      replyPolicy: serializer.fromJson<String>(json['replyPolicy']),
      paidPartnership: serializer.fromJson<bool>(json['paidPartnership']),
      madeWithAi: serializer.fromJson<bool>(json['madeWithAi']),
      communityId: serializer.fromJson<String>(json['communityId']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
      sendKey: serializer.fromJson<String?>(json['sendKey']),
      sendKind: serializer.fromJson<String?>(json['sendKind']),
      sendPublishAt: serializer.fromJson<DateTime?>(json['sendPublishAt']),
      sendStartedAt: serializer.fromJson<DateTime?>(json['sendStartedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'draftId': serializer.toJson<String>(draftId),
      'uid': serializer.toJson<String>(uid),
      'draftText': serializer.toJson<String>(draftText),
      'pollJson': serializer.toJson<String>(pollJson),
      'replyPolicy': serializer.toJson<String>(replyPolicy),
      'paidPartnership': serializer.toJson<bool>(paidPartnership),
      'madeWithAi': serializer.toJson<bool>(madeWithAi),
      'communityId': serializer.toJson<String>(communityId),
      'createdAt': serializer.toJson<DateTime>(createdAt),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
      'sendKey': serializer.toJson<String?>(sendKey),
      'sendKind': serializer.toJson<String?>(sendKind),
      'sendPublishAt': serializer.toJson<DateTime?>(sendPublishAt),
      'sendStartedAt': serializer.toJson<DateTime?>(sendStartedAt),
    };
  }

  ComposerDraftRow copyWith({
    String? draftId,
    String? uid,
    String? draftText,
    String? pollJson,
    String? replyPolicy,
    bool? paidPartnership,
    bool? madeWithAi,
    String? communityId,
    DateTime? createdAt,
    DateTime? updatedAt,
    Value<String?> sendKey = const Value.absent(),
    Value<String?> sendKind = const Value.absent(),
    Value<DateTime?> sendPublishAt = const Value.absent(),
    Value<DateTime?> sendStartedAt = const Value.absent(),
  }) => ComposerDraftRow(
    draftId: draftId ?? this.draftId,
    uid: uid ?? this.uid,
    draftText: draftText ?? this.draftText,
    pollJson: pollJson ?? this.pollJson,
    replyPolicy: replyPolicy ?? this.replyPolicy,
    paidPartnership: paidPartnership ?? this.paidPartnership,
    madeWithAi: madeWithAi ?? this.madeWithAi,
    communityId: communityId ?? this.communityId,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    sendKey: sendKey.present ? sendKey.value : this.sendKey,
    sendKind: sendKind.present ? sendKind.value : this.sendKind,
    sendPublishAt: sendPublishAt.present
        ? sendPublishAt.value
        : this.sendPublishAt,
    sendStartedAt: sendStartedAt.present
        ? sendStartedAt.value
        : this.sendStartedAt,
  );
  ComposerDraftRow copyWithCompanion(ComposerDraftEntriesCompanion data) {
    return ComposerDraftRow(
      draftId: data.draftId.present ? data.draftId.value : this.draftId,
      uid: data.uid.present ? data.uid.value : this.uid,
      draftText: data.draftText.present ? data.draftText.value : this.draftText,
      pollJson: data.pollJson.present ? data.pollJson.value : this.pollJson,
      replyPolicy: data.replyPolicy.present
          ? data.replyPolicy.value
          : this.replyPolicy,
      paidPartnership: data.paidPartnership.present
          ? data.paidPartnership.value
          : this.paidPartnership,
      madeWithAi: data.madeWithAi.present
          ? data.madeWithAi.value
          : this.madeWithAi,
      communityId: data.communityId.present
          ? data.communityId.value
          : this.communityId,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
      sendKey: data.sendKey.present ? data.sendKey.value : this.sendKey,
      sendKind: data.sendKind.present ? data.sendKind.value : this.sendKind,
      sendPublishAt: data.sendPublishAt.present
          ? data.sendPublishAt.value
          : this.sendPublishAt,
      sendStartedAt: data.sendStartedAt.present
          ? data.sendStartedAt.value
          : this.sendStartedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ComposerDraftRow(')
          ..write('draftId: $draftId, ')
          ..write('uid: $uid, ')
          ..write('draftText: $draftText, ')
          ..write('pollJson: $pollJson, ')
          ..write('replyPolicy: $replyPolicy, ')
          ..write('paidPartnership: $paidPartnership, ')
          ..write('madeWithAi: $madeWithAi, ')
          ..write('communityId: $communityId, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('sendKey: $sendKey, ')
          ..write('sendKind: $sendKind, ')
          ..write('sendPublishAt: $sendPublishAt, ')
          ..write('sendStartedAt: $sendStartedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    draftId,
    uid,
    draftText,
    pollJson,
    replyPolicy,
    paidPartnership,
    madeWithAi,
    communityId,
    createdAt,
    updatedAt,
    sendKey,
    sendKind,
    sendPublishAt,
    sendStartedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ComposerDraftRow &&
          other.draftId == this.draftId &&
          other.uid == this.uid &&
          other.draftText == this.draftText &&
          other.pollJson == this.pollJson &&
          other.replyPolicy == this.replyPolicy &&
          other.paidPartnership == this.paidPartnership &&
          other.madeWithAi == this.madeWithAi &&
          other.communityId == this.communityId &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt &&
          other.sendKey == this.sendKey &&
          other.sendKind == this.sendKind &&
          other.sendPublishAt == this.sendPublishAt &&
          other.sendStartedAt == this.sendStartedAt);
}

class ComposerDraftEntriesCompanion extends UpdateCompanion<ComposerDraftRow> {
  final Value<String> draftId;
  final Value<String> uid;
  final Value<String> draftText;
  final Value<String> pollJson;
  final Value<String> replyPolicy;
  final Value<bool> paidPartnership;
  final Value<bool> madeWithAi;
  final Value<String> communityId;
  final Value<DateTime> createdAt;
  final Value<DateTime> updatedAt;
  final Value<String?> sendKey;
  final Value<String?> sendKind;
  final Value<DateTime?> sendPublishAt;
  final Value<DateTime?> sendStartedAt;
  final Value<int> rowid;
  const ComposerDraftEntriesCompanion({
    this.draftId = const Value.absent(),
    this.uid = const Value.absent(),
    this.draftText = const Value.absent(),
    this.pollJson = const Value.absent(),
    this.replyPolicy = const Value.absent(),
    this.paidPartnership = const Value.absent(),
    this.madeWithAi = const Value.absent(),
    this.communityId = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.sendKey = const Value.absent(),
    this.sendKind = const Value.absent(),
    this.sendPublishAt = const Value.absent(),
    this.sendStartedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ComposerDraftEntriesCompanion.insert({
    required String draftId,
    required String uid,
    required String draftText,
    this.pollJson = const Value.absent(),
    this.replyPolicy = const Value.absent(),
    this.paidPartnership = const Value.absent(),
    this.madeWithAi = const Value.absent(),
    this.communityId = const Value.absent(),
    required DateTime createdAt,
    required DateTime updatedAt,
    this.sendKey = const Value.absent(),
    this.sendKind = const Value.absent(),
    this.sendPublishAt = const Value.absent(),
    this.sendStartedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : draftId = Value(draftId),
       uid = Value(uid),
       draftText = Value(draftText),
       createdAt = Value(createdAt),
       updatedAt = Value(updatedAt);
  static Insertable<ComposerDraftRow> custom({
    Expression<String>? draftId,
    Expression<String>? uid,
    Expression<String>? draftText,
    Expression<String>? pollJson,
    Expression<String>? replyPolicy,
    Expression<bool>? paidPartnership,
    Expression<bool>? madeWithAi,
    Expression<String>? communityId,
    Expression<DateTime>? createdAt,
    Expression<DateTime>? updatedAt,
    Expression<String>? sendKey,
    Expression<String>? sendKind,
    Expression<DateTime>? sendPublishAt,
    Expression<DateTime>? sendStartedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (draftId != null) 'draft_id': draftId,
      if (uid != null) 'uid': uid,
      if (draftText != null) 'draft_text': draftText,
      if (pollJson != null) 'poll_json': pollJson,
      if (replyPolicy != null) 'reply_policy': replyPolicy,
      if (paidPartnership != null) 'paid_partnership': paidPartnership,
      if (madeWithAi != null) 'made_with_ai': madeWithAi,
      if (communityId != null) 'community_id': communityId,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (sendKey != null) 'send_key': sendKey,
      if (sendKind != null) 'send_kind': sendKind,
      if (sendPublishAt != null) 'send_publish_at': sendPublishAt,
      if (sendStartedAt != null) 'send_started_at': sendStartedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ComposerDraftEntriesCompanion copyWith({
    Value<String>? draftId,
    Value<String>? uid,
    Value<String>? draftText,
    Value<String>? pollJson,
    Value<String>? replyPolicy,
    Value<bool>? paidPartnership,
    Value<bool>? madeWithAi,
    Value<String>? communityId,
    Value<DateTime>? createdAt,
    Value<DateTime>? updatedAt,
    Value<String?>? sendKey,
    Value<String?>? sendKind,
    Value<DateTime?>? sendPublishAt,
    Value<DateTime?>? sendStartedAt,
    Value<int>? rowid,
  }) {
    return ComposerDraftEntriesCompanion(
      draftId: draftId ?? this.draftId,
      uid: uid ?? this.uid,
      draftText: draftText ?? this.draftText,
      pollJson: pollJson ?? this.pollJson,
      replyPolicy: replyPolicy ?? this.replyPolicy,
      paidPartnership: paidPartnership ?? this.paidPartnership,
      madeWithAi: madeWithAi ?? this.madeWithAi,
      communityId: communityId ?? this.communityId,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      sendKey: sendKey ?? this.sendKey,
      sendKind: sendKind ?? this.sendKind,
      sendPublishAt: sendPublishAt ?? this.sendPublishAt,
      sendStartedAt: sendStartedAt ?? this.sendStartedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (draftId.present) {
      map['draft_id'] = Variable<String>(draftId.value);
    }
    if (uid.present) {
      map['uid'] = Variable<String>(uid.value);
    }
    if (draftText.present) {
      map['draft_text'] = Variable<String>(draftText.value);
    }
    if (pollJson.present) {
      map['poll_json'] = Variable<String>(pollJson.value);
    }
    if (replyPolicy.present) {
      map['reply_policy'] = Variable<String>(replyPolicy.value);
    }
    if (paidPartnership.present) {
      map['paid_partnership'] = Variable<bool>(paidPartnership.value);
    }
    if (madeWithAi.present) {
      map['made_with_ai'] = Variable<bool>(madeWithAi.value);
    }
    if (communityId.present) {
      map['community_id'] = Variable<String>(communityId.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    if (sendKey.present) {
      map['send_key'] = Variable<String>(sendKey.value);
    }
    if (sendKind.present) {
      map['send_kind'] = Variable<String>(sendKind.value);
    }
    if (sendPublishAt.present) {
      map['send_publish_at'] = Variable<DateTime>(sendPublishAt.value);
    }
    if (sendStartedAt.present) {
      map['send_started_at'] = Variable<DateTime>(sendStartedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ComposerDraftEntriesCompanion(')
          ..write('draftId: $draftId, ')
          ..write('uid: $uid, ')
          ..write('draftText: $draftText, ')
          ..write('pollJson: $pollJson, ')
          ..write('replyPolicy: $replyPolicy, ')
          ..write('paidPartnership: $paidPartnership, ')
          ..write('madeWithAi: $madeWithAi, ')
          ..write('communityId: $communityId, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('sendKey: $sendKey, ')
          ..write('sendKind: $sendKind, ')
          ..write('sendPublishAt: $sendPublishAt, ')
          ..write('sendStartedAt: $sendStartedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $PostHistoryEntriesTable extends PostHistoryEntries
    with TableInfo<$PostHistoryEntriesTable, PostHistoryRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $PostHistoryEntriesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _uidMeta = const VerificationMeta('uid');
  @override
  late final GeneratedColumn<String> uid = GeneratedColumn<String>(
    'uid',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _postIdMeta = const VerificationMeta('postId');
  @override
  late final GeneratedColumn<String> postId = GeneratedColumn<String>(
    'post_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _openedAtMsMeta = const VerificationMeta(
    'openedAtMs',
  );
  @override
  late final GeneratedColumn<int> openedAtMs = GeneratedColumn<int>(
    'opened_at_ms',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [uid, postId, openedAtMs];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'post_history_entries';
  @override
  VerificationContext validateIntegrity(
    Insertable<PostHistoryRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('uid')) {
      context.handle(
        _uidMeta,
        uid.isAcceptableOrUnknown(data['uid']!, _uidMeta),
      );
    } else if (isInserting) {
      context.missing(_uidMeta);
    }
    if (data.containsKey('post_id')) {
      context.handle(
        _postIdMeta,
        postId.isAcceptableOrUnknown(data['post_id']!, _postIdMeta),
      );
    } else if (isInserting) {
      context.missing(_postIdMeta);
    }
    if (data.containsKey('opened_at_ms')) {
      context.handle(
        _openedAtMsMeta,
        openedAtMs.isAcceptableOrUnknown(
          data['opened_at_ms']!,
          _openedAtMsMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_openedAtMsMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {uid, postId};
  @override
  PostHistoryRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return PostHistoryRow(
      uid: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}uid'],
      )!,
      postId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}post_id'],
      )!,
      openedAtMs: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}opened_at_ms'],
      )!,
    );
  }

  @override
  $PostHistoryEntriesTable createAlias(String alias) {
    return $PostHistoryEntriesTable(attachedDatabase, alias);
  }
}

class PostHistoryRow extends DataClass implements Insertable<PostHistoryRow> {
  final String uid;
  final String postId;

  /// Milliseconds since the epoch, UTC. Integer on purpose: two opens in the
  /// same second keep their order.
  final int openedAtMs;
  const PostHistoryRow({
    required this.uid,
    required this.postId,
    required this.openedAtMs,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['uid'] = Variable<String>(uid);
    map['post_id'] = Variable<String>(postId);
    map['opened_at_ms'] = Variable<int>(openedAtMs);
    return map;
  }

  PostHistoryEntriesCompanion toCompanion(bool nullToAbsent) {
    return PostHistoryEntriesCompanion(
      uid: Value(uid),
      postId: Value(postId),
      openedAtMs: Value(openedAtMs),
    );
  }

  factory PostHistoryRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return PostHistoryRow(
      uid: serializer.fromJson<String>(json['uid']),
      postId: serializer.fromJson<String>(json['postId']),
      openedAtMs: serializer.fromJson<int>(json['openedAtMs']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'uid': serializer.toJson<String>(uid),
      'postId': serializer.toJson<String>(postId),
      'openedAtMs': serializer.toJson<int>(openedAtMs),
    };
  }

  PostHistoryRow copyWith({String? uid, String? postId, int? openedAtMs}) =>
      PostHistoryRow(
        uid: uid ?? this.uid,
        postId: postId ?? this.postId,
        openedAtMs: openedAtMs ?? this.openedAtMs,
      );
  PostHistoryRow copyWithCompanion(PostHistoryEntriesCompanion data) {
    return PostHistoryRow(
      uid: data.uid.present ? data.uid.value : this.uid,
      postId: data.postId.present ? data.postId.value : this.postId,
      openedAtMs: data.openedAtMs.present
          ? data.openedAtMs.value
          : this.openedAtMs,
    );
  }

  @override
  String toString() {
    return (StringBuffer('PostHistoryRow(')
          ..write('uid: $uid, ')
          ..write('postId: $postId, ')
          ..write('openedAtMs: $openedAtMs')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(uid, postId, openedAtMs);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PostHistoryRow &&
          other.uid == this.uid &&
          other.postId == this.postId &&
          other.openedAtMs == this.openedAtMs);
}

class PostHistoryEntriesCompanion extends UpdateCompanion<PostHistoryRow> {
  final Value<String> uid;
  final Value<String> postId;
  final Value<int> openedAtMs;
  final Value<int> rowid;
  const PostHistoryEntriesCompanion({
    this.uid = const Value.absent(),
    this.postId = const Value.absent(),
    this.openedAtMs = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  PostHistoryEntriesCompanion.insert({
    required String uid,
    required String postId,
    required int openedAtMs,
    this.rowid = const Value.absent(),
  }) : uid = Value(uid),
       postId = Value(postId),
       openedAtMs = Value(openedAtMs);
  static Insertable<PostHistoryRow> custom({
    Expression<String>? uid,
    Expression<String>? postId,
    Expression<int>? openedAtMs,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (uid != null) 'uid': uid,
      if (postId != null) 'post_id': postId,
      if (openedAtMs != null) 'opened_at_ms': openedAtMs,
      if (rowid != null) 'rowid': rowid,
    });
  }

  PostHistoryEntriesCompanion copyWith({
    Value<String>? uid,
    Value<String>? postId,
    Value<int>? openedAtMs,
    Value<int>? rowid,
  }) {
    return PostHistoryEntriesCompanion(
      uid: uid ?? this.uid,
      postId: postId ?? this.postId,
      openedAtMs: openedAtMs ?? this.openedAtMs,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (uid.present) {
      map['uid'] = Variable<String>(uid.value);
    }
    if (postId.present) {
      map['post_id'] = Variable<String>(postId.value);
    }
    if (openedAtMs.present) {
      map['opened_at_ms'] = Variable<int>(openedAtMs.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('PostHistoryEntriesCompanion(')
          ..write('uid: $uid, ')
          ..write('postId: $postId, ')
          ..write('openedAtMs: $openedAtMs, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $UnsentPostEntriesTable extends UnsentPostEntries
    with TableInfo<$UnsentPostEntriesTable, UnsentPostRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $UnsentPostEntriesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _uidMeta = const VerificationMeta('uid');
  @override
  late final GeneratedColumn<String> uid = GeneratedColumn<String>(
    'uid',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _postIdMeta = const VerificationMeta('postId');
  @override
  late final GeneratedColumn<String> postId = GeneratedColumn<String>(
    'post_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _postTextMeta = const VerificationMeta(
    'postText',
  );
  @override
  late final GeneratedColumn<String> postText = GeneratedColumn<String>(
    'post_text',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _pollJsonMeta = const VerificationMeta(
    'pollJson',
  );
  @override
  late final GeneratedColumn<String> pollJson = GeneratedColumn<String>(
    'poll_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _replyAudienceMeta = const VerificationMeta(
    'replyAudience',
  );
  @override
  late final GeneratedColumn<String> replyAudience = GeneratedColumn<String>(
    'reply_audience',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('everyone'),
  );
  static const VerificationMeta _policyValueMeta = const VerificationMeta(
    'policyValue',
  );
  @override
  late final GeneratedColumn<int> policyValue = GeneratedColumn<int>(
    'policy_value',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _communityIdMeta = const VerificationMeta(
    'communityId',
  );
  @override
  late final GeneratedColumn<String> communityId = GeneratedColumn<String>(
    'community_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _beaconIdMeta = const VerificationMeta(
    'beaconId',
  );
  @override
  late final GeneratedColumn<String> beaconId = GeneratedColumn<String>(
    'beacon_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _isGifMeta = const VerificationMeta('isGif');
  @override
  late final GeneratedColumn<bool> isGif = GeneratedColumn<bool>(
    'is_gif',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("is_gif" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _draftIdMeta = const VerificationMeta(
    'draftId',
  );
  @override
  late final GeneratedColumn<String> draftId = GeneratedColumn<String>(
    'draft_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _deleteDraftIdMeta = const VerificationMeta(
    'deleteDraftId',
  );
  @override
  late final GeneratedColumn<String> deleteDraftId = GeneratedColumn<String>(
    'delete_draft_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _authorBytesMeta = const VerificationMeta(
    'authorBytes',
  );
  @override
  late final GeneratedColumn<Uint8List> authorBytes =
      GeneratedColumn<Uint8List>(
        'author_bytes',
        aliasedName,
        false,
        type: DriftSqlType.blob,
        requiredDuringInsert: true,
      );
  static const VerificationMeta _sendKeyMeta = const VerificationMeta(
    'sendKey',
  );
  @override
  late final GeneratedColumn<String> sendKey = GeneratedColumn<String>(
    'send_key',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _keyStartedAtMeta = const VerificationMeta(
    'keyStartedAt',
  );
  @override
  late final GeneratedColumn<DateTime> keyStartedAt = GeneratedColumn<DateTime>(
    'key_started_at',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _keyUsedMeta = const VerificationMeta(
    'keyUsed',
  );
  @override
  late final GeneratedColumn<bool> keyUsed = GeneratedColumn<bool>(
    'key_used',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("key_used" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _keyAmbiguousMeta = const VerificationMeta(
    'keyAmbiguous',
  );
  @override
  late final GeneratedColumn<bool> keyAmbiguous = GeneratedColumn<bool>(
    'key_ambiguous',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("key_ambiguous" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _claimReusedMeta = const VerificationMeta(
    'claimReused',
  );
  @override
  late final GeneratedColumn<bool> claimReused = GeneratedColumn<bool>(
    'claim_reused',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("claim_reused" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _photosKeptMeta = const VerificationMeta(
    'photosKept',
  );
  @override
  late final GeneratedColumn<bool> photosKept = GeneratedColumn<bool>(
    'photos_kept',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("photos_kept" IN (0, 1))',
    ),
    defaultValue: const Constant(true),
  );
  static const VerificationMeta _photoCountMeta = const VerificationMeta(
    'photoCount',
  );
  @override
  late final GeneratedColumn<int> photoCount = GeneratedColumn<int>(
    'photo_count',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    uid,
    postId,
    postText,
    pollJson,
    replyAudience,
    policyValue,
    communityId,
    beaconId,
    isGif,
    draftId,
    deleteDraftId,
    authorBytes,
    sendKey,
    keyStartedAt,
    keyUsed,
    keyAmbiguous,
    claimReused,
    photosKept,
    photoCount,
    createdAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'unsent_post_entries';
  @override
  VerificationContext validateIntegrity(
    Insertable<UnsentPostRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('uid')) {
      context.handle(
        _uidMeta,
        uid.isAcceptableOrUnknown(data['uid']!, _uidMeta),
      );
    } else if (isInserting) {
      context.missing(_uidMeta);
    }
    if (data.containsKey('post_id')) {
      context.handle(
        _postIdMeta,
        postId.isAcceptableOrUnknown(data['post_id']!, _postIdMeta),
      );
    } else if (isInserting) {
      context.missing(_postIdMeta);
    }
    if (data.containsKey('post_text')) {
      context.handle(
        _postTextMeta,
        postText.isAcceptableOrUnknown(data['post_text']!, _postTextMeta),
      );
    }
    if (data.containsKey('poll_json')) {
      context.handle(
        _pollJsonMeta,
        pollJson.isAcceptableOrUnknown(data['poll_json']!, _pollJsonMeta),
      );
    }
    if (data.containsKey('reply_audience')) {
      context.handle(
        _replyAudienceMeta,
        replyAudience.isAcceptableOrUnknown(
          data['reply_audience']!,
          _replyAudienceMeta,
        ),
      );
    }
    if (data.containsKey('policy_value')) {
      context.handle(
        _policyValueMeta,
        policyValue.isAcceptableOrUnknown(
          data['policy_value']!,
          _policyValueMeta,
        ),
      );
    }
    if (data.containsKey('community_id')) {
      context.handle(
        _communityIdMeta,
        communityId.isAcceptableOrUnknown(
          data['community_id']!,
          _communityIdMeta,
        ),
      );
    }
    if (data.containsKey('beacon_id')) {
      context.handle(
        _beaconIdMeta,
        beaconId.isAcceptableOrUnknown(data['beacon_id']!, _beaconIdMeta),
      );
    }
    if (data.containsKey('is_gif')) {
      context.handle(
        _isGifMeta,
        isGif.isAcceptableOrUnknown(data['is_gif']!, _isGifMeta),
      );
    }
    if (data.containsKey('draft_id')) {
      context.handle(
        _draftIdMeta,
        draftId.isAcceptableOrUnknown(data['draft_id']!, _draftIdMeta),
      );
    }
    if (data.containsKey('delete_draft_id')) {
      context.handle(
        _deleteDraftIdMeta,
        deleteDraftId.isAcceptableOrUnknown(
          data['delete_draft_id']!,
          _deleteDraftIdMeta,
        ),
      );
    }
    if (data.containsKey('author_bytes')) {
      context.handle(
        _authorBytesMeta,
        authorBytes.isAcceptableOrUnknown(
          data['author_bytes']!,
          _authorBytesMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_authorBytesMeta);
    }
    if (data.containsKey('send_key')) {
      context.handle(
        _sendKeyMeta,
        sendKey.isAcceptableOrUnknown(data['send_key']!, _sendKeyMeta),
      );
    }
    if (data.containsKey('key_started_at')) {
      context.handle(
        _keyStartedAtMeta,
        keyStartedAt.isAcceptableOrUnknown(
          data['key_started_at']!,
          _keyStartedAtMeta,
        ),
      );
    }
    if (data.containsKey('key_used')) {
      context.handle(
        _keyUsedMeta,
        keyUsed.isAcceptableOrUnknown(data['key_used']!, _keyUsedMeta),
      );
    }
    if (data.containsKey('key_ambiguous')) {
      context.handle(
        _keyAmbiguousMeta,
        keyAmbiguous.isAcceptableOrUnknown(
          data['key_ambiguous']!,
          _keyAmbiguousMeta,
        ),
      );
    }
    if (data.containsKey('claim_reused')) {
      context.handle(
        _claimReusedMeta,
        claimReused.isAcceptableOrUnknown(
          data['claim_reused']!,
          _claimReusedMeta,
        ),
      );
    }
    if (data.containsKey('photos_kept')) {
      context.handle(
        _photosKeptMeta,
        photosKept.isAcceptableOrUnknown(data['photos_kept']!, _photosKeptMeta),
      );
    }
    if (data.containsKey('photo_count')) {
      context.handle(
        _photoCountMeta,
        photoCount.isAcceptableOrUnknown(data['photo_count']!, _photoCountMeta),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {uid, postId};
  @override
  UnsentPostRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return UnsentPostRow(
      uid: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}uid'],
      )!,
      postId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}post_id'],
      )!,
      postText: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}post_text'],
      )!,
      pollJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}poll_json'],
      )!,
      replyAudience: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}reply_audience'],
      )!,
      policyValue: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}policy_value'],
      )!,
      communityId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}community_id'],
      )!,
      beaconId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}beacon_id'],
      )!,
      isGif: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}is_gif'],
      )!,
      draftId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}draft_id'],
      ),
      deleteDraftId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}delete_draft_id'],
      ),
      authorBytes: attachedDatabase.typeMapping.read(
        DriftSqlType.blob,
        data['${effectivePrefix}author_bytes'],
      )!,
      sendKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}send_key'],
      ),
      keyStartedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}key_started_at'],
      ),
      keyUsed: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}key_used'],
      )!,
      keyAmbiguous: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}key_ambiguous'],
      )!,
      claimReused: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}claim_reused'],
      )!,
      photosKept: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}photos_kept'],
      )!,
      photoCount: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}photo_count'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}created_at'],
      )!,
    );
  }

  @override
  $UnsentPostEntriesTable createAlias(String alias) {
    return $UnsentPostEntriesTable(attachedDatabase, alias);
  }
}

class UnsentPostRow extends DataClass implements Insertable<UnsentPostRow> {
  final String uid;

  /// Opaque id of the post (the sender's id for it), unique per account.
  final String postId;

  /// The post text.
  final String postText;

  /// JSON `{"c": [choices], "d": minutes}`; '' = no poll.
  final String pollJson;

  /// `ReplyAudience.name`.
  final String replyAudience;

  /// The wire value of the reply policy the send uses.
  final int policyValue;
  final String communityId;
  final String beaconId;
  final bool isGif;

  /// The unsent-post (draft) row this send belongs to, when it has one.
  final String? draftId;
  final String? deleteDraftId;

  /// The viewer's own author snapshot (serialized), for the row's avatar.
  final Uint8List authorBytes;

  /// The idempotency key of the send, with its first use and flags, so a
  /// restored post sends under the same key (never twice).
  final String? sendKey;
  final DateTime? keyStartedAt;
  final bool keyUsed;
  final bool keyAmbiguous;
  final bool claimReused;

  /// False when the photos were not kept (over the size cap, or the web):
  /// the restored post then has its text only.
  final bool photosKept;
  final int photoCount;
  final DateTime createdAt;
  const UnsentPostRow({
    required this.uid,
    required this.postId,
    required this.postText,
    required this.pollJson,
    required this.replyAudience,
    required this.policyValue,
    required this.communityId,
    required this.beaconId,
    required this.isGif,
    this.draftId,
    this.deleteDraftId,
    required this.authorBytes,
    this.sendKey,
    this.keyStartedAt,
    required this.keyUsed,
    required this.keyAmbiguous,
    required this.claimReused,
    required this.photosKept,
    required this.photoCount,
    required this.createdAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['uid'] = Variable<String>(uid);
    map['post_id'] = Variable<String>(postId);
    map['post_text'] = Variable<String>(postText);
    map['poll_json'] = Variable<String>(pollJson);
    map['reply_audience'] = Variable<String>(replyAudience);
    map['policy_value'] = Variable<int>(policyValue);
    map['community_id'] = Variable<String>(communityId);
    map['beacon_id'] = Variable<String>(beaconId);
    map['is_gif'] = Variable<bool>(isGif);
    if (!nullToAbsent || draftId != null) {
      map['draft_id'] = Variable<String>(draftId);
    }
    if (!nullToAbsent || deleteDraftId != null) {
      map['delete_draft_id'] = Variable<String>(deleteDraftId);
    }
    map['author_bytes'] = Variable<Uint8List>(authorBytes);
    if (!nullToAbsent || sendKey != null) {
      map['send_key'] = Variable<String>(sendKey);
    }
    if (!nullToAbsent || keyStartedAt != null) {
      map['key_started_at'] = Variable<DateTime>(keyStartedAt);
    }
    map['key_used'] = Variable<bool>(keyUsed);
    map['key_ambiguous'] = Variable<bool>(keyAmbiguous);
    map['claim_reused'] = Variable<bool>(claimReused);
    map['photos_kept'] = Variable<bool>(photosKept);
    map['photo_count'] = Variable<int>(photoCount);
    map['created_at'] = Variable<DateTime>(createdAt);
    return map;
  }

  UnsentPostEntriesCompanion toCompanion(bool nullToAbsent) {
    return UnsentPostEntriesCompanion(
      uid: Value(uid),
      postId: Value(postId),
      postText: Value(postText),
      pollJson: Value(pollJson),
      replyAudience: Value(replyAudience),
      policyValue: Value(policyValue),
      communityId: Value(communityId),
      beaconId: Value(beaconId),
      isGif: Value(isGif),
      draftId: draftId == null && nullToAbsent
          ? const Value.absent()
          : Value(draftId),
      deleteDraftId: deleteDraftId == null && nullToAbsent
          ? const Value.absent()
          : Value(deleteDraftId),
      authorBytes: Value(authorBytes),
      sendKey: sendKey == null && nullToAbsent
          ? const Value.absent()
          : Value(sendKey),
      keyStartedAt: keyStartedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(keyStartedAt),
      keyUsed: Value(keyUsed),
      keyAmbiguous: Value(keyAmbiguous),
      claimReused: Value(claimReused),
      photosKept: Value(photosKept),
      photoCount: Value(photoCount),
      createdAt: Value(createdAt),
    );
  }

  factory UnsentPostRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return UnsentPostRow(
      uid: serializer.fromJson<String>(json['uid']),
      postId: serializer.fromJson<String>(json['postId']),
      postText: serializer.fromJson<String>(json['postText']),
      pollJson: serializer.fromJson<String>(json['pollJson']),
      replyAudience: serializer.fromJson<String>(json['replyAudience']),
      policyValue: serializer.fromJson<int>(json['policyValue']),
      communityId: serializer.fromJson<String>(json['communityId']),
      beaconId: serializer.fromJson<String>(json['beaconId']),
      isGif: serializer.fromJson<bool>(json['isGif']),
      draftId: serializer.fromJson<String?>(json['draftId']),
      deleteDraftId: serializer.fromJson<String?>(json['deleteDraftId']),
      authorBytes: serializer.fromJson<Uint8List>(json['authorBytes']),
      sendKey: serializer.fromJson<String?>(json['sendKey']),
      keyStartedAt: serializer.fromJson<DateTime?>(json['keyStartedAt']),
      keyUsed: serializer.fromJson<bool>(json['keyUsed']),
      keyAmbiguous: serializer.fromJson<bool>(json['keyAmbiguous']),
      claimReused: serializer.fromJson<bool>(json['claimReused']),
      photosKept: serializer.fromJson<bool>(json['photosKept']),
      photoCount: serializer.fromJson<int>(json['photoCount']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'uid': serializer.toJson<String>(uid),
      'postId': serializer.toJson<String>(postId),
      'postText': serializer.toJson<String>(postText),
      'pollJson': serializer.toJson<String>(pollJson),
      'replyAudience': serializer.toJson<String>(replyAudience),
      'policyValue': serializer.toJson<int>(policyValue),
      'communityId': serializer.toJson<String>(communityId),
      'beaconId': serializer.toJson<String>(beaconId),
      'isGif': serializer.toJson<bool>(isGif),
      'draftId': serializer.toJson<String?>(draftId),
      'deleteDraftId': serializer.toJson<String?>(deleteDraftId),
      'authorBytes': serializer.toJson<Uint8List>(authorBytes),
      'sendKey': serializer.toJson<String?>(sendKey),
      'keyStartedAt': serializer.toJson<DateTime?>(keyStartedAt),
      'keyUsed': serializer.toJson<bool>(keyUsed),
      'keyAmbiguous': serializer.toJson<bool>(keyAmbiguous),
      'claimReused': serializer.toJson<bool>(claimReused),
      'photosKept': serializer.toJson<bool>(photosKept),
      'photoCount': serializer.toJson<int>(photoCount),
      'createdAt': serializer.toJson<DateTime>(createdAt),
    };
  }

  UnsentPostRow copyWith({
    String? uid,
    String? postId,
    String? postText,
    String? pollJson,
    String? replyAudience,
    int? policyValue,
    String? communityId,
    String? beaconId,
    bool? isGif,
    Value<String?> draftId = const Value.absent(),
    Value<String?> deleteDraftId = const Value.absent(),
    Uint8List? authorBytes,
    Value<String?> sendKey = const Value.absent(),
    Value<DateTime?> keyStartedAt = const Value.absent(),
    bool? keyUsed,
    bool? keyAmbiguous,
    bool? claimReused,
    bool? photosKept,
    int? photoCount,
    DateTime? createdAt,
  }) => UnsentPostRow(
    uid: uid ?? this.uid,
    postId: postId ?? this.postId,
    postText: postText ?? this.postText,
    pollJson: pollJson ?? this.pollJson,
    replyAudience: replyAudience ?? this.replyAudience,
    policyValue: policyValue ?? this.policyValue,
    communityId: communityId ?? this.communityId,
    beaconId: beaconId ?? this.beaconId,
    isGif: isGif ?? this.isGif,
    draftId: draftId.present ? draftId.value : this.draftId,
    deleteDraftId: deleteDraftId.present
        ? deleteDraftId.value
        : this.deleteDraftId,
    authorBytes: authorBytes ?? this.authorBytes,
    sendKey: sendKey.present ? sendKey.value : this.sendKey,
    keyStartedAt: keyStartedAt.present ? keyStartedAt.value : this.keyStartedAt,
    keyUsed: keyUsed ?? this.keyUsed,
    keyAmbiguous: keyAmbiguous ?? this.keyAmbiguous,
    claimReused: claimReused ?? this.claimReused,
    photosKept: photosKept ?? this.photosKept,
    photoCount: photoCount ?? this.photoCount,
    createdAt: createdAt ?? this.createdAt,
  );
  UnsentPostRow copyWithCompanion(UnsentPostEntriesCompanion data) {
    return UnsentPostRow(
      uid: data.uid.present ? data.uid.value : this.uid,
      postId: data.postId.present ? data.postId.value : this.postId,
      postText: data.postText.present ? data.postText.value : this.postText,
      pollJson: data.pollJson.present ? data.pollJson.value : this.pollJson,
      replyAudience: data.replyAudience.present
          ? data.replyAudience.value
          : this.replyAudience,
      policyValue: data.policyValue.present
          ? data.policyValue.value
          : this.policyValue,
      communityId: data.communityId.present
          ? data.communityId.value
          : this.communityId,
      beaconId: data.beaconId.present ? data.beaconId.value : this.beaconId,
      isGif: data.isGif.present ? data.isGif.value : this.isGif,
      draftId: data.draftId.present ? data.draftId.value : this.draftId,
      deleteDraftId: data.deleteDraftId.present
          ? data.deleteDraftId.value
          : this.deleteDraftId,
      authorBytes: data.authorBytes.present
          ? data.authorBytes.value
          : this.authorBytes,
      sendKey: data.sendKey.present ? data.sendKey.value : this.sendKey,
      keyStartedAt: data.keyStartedAt.present
          ? data.keyStartedAt.value
          : this.keyStartedAt,
      keyUsed: data.keyUsed.present ? data.keyUsed.value : this.keyUsed,
      keyAmbiguous: data.keyAmbiguous.present
          ? data.keyAmbiguous.value
          : this.keyAmbiguous,
      claimReused: data.claimReused.present
          ? data.claimReused.value
          : this.claimReused,
      photosKept: data.photosKept.present
          ? data.photosKept.value
          : this.photosKept,
      photoCount: data.photoCount.present
          ? data.photoCount.value
          : this.photoCount,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('UnsentPostRow(')
          ..write('uid: $uid, ')
          ..write('postId: $postId, ')
          ..write('postText: $postText, ')
          ..write('pollJson: $pollJson, ')
          ..write('replyAudience: $replyAudience, ')
          ..write('policyValue: $policyValue, ')
          ..write('communityId: $communityId, ')
          ..write('beaconId: $beaconId, ')
          ..write('isGif: $isGif, ')
          ..write('draftId: $draftId, ')
          ..write('deleteDraftId: $deleteDraftId, ')
          ..write('authorBytes: $authorBytes, ')
          ..write('sendKey: $sendKey, ')
          ..write('keyStartedAt: $keyStartedAt, ')
          ..write('keyUsed: $keyUsed, ')
          ..write('keyAmbiguous: $keyAmbiguous, ')
          ..write('claimReused: $claimReused, ')
          ..write('photosKept: $photosKept, ')
          ..write('photoCount: $photoCount, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    uid,
    postId,
    postText,
    pollJson,
    replyAudience,
    policyValue,
    communityId,
    beaconId,
    isGif,
    draftId,
    deleteDraftId,
    $driftBlobEquality.hash(authorBytes),
    sendKey,
    keyStartedAt,
    keyUsed,
    keyAmbiguous,
    claimReused,
    photosKept,
    photoCount,
    createdAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is UnsentPostRow &&
          other.uid == this.uid &&
          other.postId == this.postId &&
          other.postText == this.postText &&
          other.pollJson == this.pollJson &&
          other.replyAudience == this.replyAudience &&
          other.policyValue == this.policyValue &&
          other.communityId == this.communityId &&
          other.beaconId == this.beaconId &&
          other.isGif == this.isGif &&
          other.draftId == this.draftId &&
          other.deleteDraftId == this.deleteDraftId &&
          $driftBlobEquality.equals(other.authorBytes, this.authorBytes) &&
          other.sendKey == this.sendKey &&
          other.keyStartedAt == this.keyStartedAt &&
          other.keyUsed == this.keyUsed &&
          other.keyAmbiguous == this.keyAmbiguous &&
          other.claimReused == this.claimReused &&
          other.photosKept == this.photosKept &&
          other.photoCount == this.photoCount &&
          other.createdAt == this.createdAt);
}

class UnsentPostEntriesCompanion extends UpdateCompanion<UnsentPostRow> {
  final Value<String> uid;
  final Value<String> postId;
  final Value<String> postText;
  final Value<String> pollJson;
  final Value<String> replyAudience;
  final Value<int> policyValue;
  final Value<String> communityId;
  final Value<String> beaconId;
  final Value<bool> isGif;
  final Value<String?> draftId;
  final Value<String?> deleteDraftId;
  final Value<Uint8List> authorBytes;
  final Value<String?> sendKey;
  final Value<DateTime?> keyStartedAt;
  final Value<bool> keyUsed;
  final Value<bool> keyAmbiguous;
  final Value<bool> claimReused;
  final Value<bool> photosKept;
  final Value<int> photoCount;
  final Value<DateTime> createdAt;
  final Value<int> rowid;
  const UnsentPostEntriesCompanion({
    this.uid = const Value.absent(),
    this.postId = const Value.absent(),
    this.postText = const Value.absent(),
    this.pollJson = const Value.absent(),
    this.replyAudience = const Value.absent(),
    this.policyValue = const Value.absent(),
    this.communityId = const Value.absent(),
    this.beaconId = const Value.absent(),
    this.isGif = const Value.absent(),
    this.draftId = const Value.absent(),
    this.deleteDraftId = const Value.absent(),
    this.authorBytes = const Value.absent(),
    this.sendKey = const Value.absent(),
    this.keyStartedAt = const Value.absent(),
    this.keyUsed = const Value.absent(),
    this.keyAmbiguous = const Value.absent(),
    this.claimReused = const Value.absent(),
    this.photosKept = const Value.absent(),
    this.photoCount = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  UnsentPostEntriesCompanion.insert({
    required String uid,
    required String postId,
    this.postText = const Value.absent(),
    this.pollJson = const Value.absent(),
    this.replyAudience = const Value.absent(),
    this.policyValue = const Value.absent(),
    this.communityId = const Value.absent(),
    this.beaconId = const Value.absent(),
    this.isGif = const Value.absent(),
    this.draftId = const Value.absent(),
    this.deleteDraftId = const Value.absent(),
    required Uint8List authorBytes,
    this.sendKey = const Value.absent(),
    this.keyStartedAt = const Value.absent(),
    this.keyUsed = const Value.absent(),
    this.keyAmbiguous = const Value.absent(),
    this.claimReused = const Value.absent(),
    this.photosKept = const Value.absent(),
    this.photoCount = const Value.absent(),
    required DateTime createdAt,
    this.rowid = const Value.absent(),
  }) : uid = Value(uid),
       postId = Value(postId),
       authorBytes = Value(authorBytes),
       createdAt = Value(createdAt);
  static Insertable<UnsentPostRow> custom({
    Expression<String>? uid,
    Expression<String>? postId,
    Expression<String>? postText,
    Expression<String>? pollJson,
    Expression<String>? replyAudience,
    Expression<int>? policyValue,
    Expression<String>? communityId,
    Expression<String>? beaconId,
    Expression<bool>? isGif,
    Expression<String>? draftId,
    Expression<String>? deleteDraftId,
    Expression<Uint8List>? authorBytes,
    Expression<String>? sendKey,
    Expression<DateTime>? keyStartedAt,
    Expression<bool>? keyUsed,
    Expression<bool>? keyAmbiguous,
    Expression<bool>? claimReused,
    Expression<bool>? photosKept,
    Expression<int>? photoCount,
    Expression<DateTime>? createdAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (uid != null) 'uid': uid,
      if (postId != null) 'post_id': postId,
      if (postText != null) 'post_text': postText,
      if (pollJson != null) 'poll_json': pollJson,
      if (replyAudience != null) 'reply_audience': replyAudience,
      if (policyValue != null) 'policy_value': policyValue,
      if (communityId != null) 'community_id': communityId,
      if (beaconId != null) 'beacon_id': beaconId,
      if (isGif != null) 'is_gif': isGif,
      if (draftId != null) 'draft_id': draftId,
      if (deleteDraftId != null) 'delete_draft_id': deleteDraftId,
      if (authorBytes != null) 'author_bytes': authorBytes,
      if (sendKey != null) 'send_key': sendKey,
      if (keyStartedAt != null) 'key_started_at': keyStartedAt,
      if (keyUsed != null) 'key_used': keyUsed,
      if (keyAmbiguous != null) 'key_ambiguous': keyAmbiguous,
      if (claimReused != null) 'claim_reused': claimReused,
      if (photosKept != null) 'photos_kept': photosKept,
      if (photoCount != null) 'photo_count': photoCount,
      if (createdAt != null) 'created_at': createdAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  UnsentPostEntriesCompanion copyWith({
    Value<String>? uid,
    Value<String>? postId,
    Value<String>? postText,
    Value<String>? pollJson,
    Value<String>? replyAudience,
    Value<int>? policyValue,
    Value<String>? communityId,
    Value<String>? beaconId,
    Value<bool>? isGif,
    Value<String?>? draftId,
    Value<String?>? deleteDraftId,
    Value<Uint8List>? authorBytes,
    Value<String?>? sendKey,
    Value<DateTime?>? keyStartedAt,
    Value<bool>? keyUsed,
    Value<bool>? keyAmbiguous,
    Value<bool>? claimReused,
    Value<bool>? photosKept,
    Value<int>? photoCount,
    Value<DateTime>? createdAt,
    Value<int>? rowid,
  }) {
    return UnsentPostEntriesCompanion(
      uid: uid ?? this.uid,
      postId: postId ?? this.postId,
      postText: postText ?? this.postText,
      pollJson: pollJson ?? this.pollJson,
      replyAudience: replyAudience ?? this.replyAudience,
      policyValue: policyValue ?? this.policyValue,
      communityId: communityId ?? this.communityId,
      beaconId: beaconId ?? this.beaconId,
      isGif: isGif ?? this.isGif,
      draftId: draftId ?? this.draftId,
      deleteDraftId: deleteDraftId ?? this.deleteDraftId,
      authorBytes: authorBytes ?? this.authorBytes,
      sendKey: sendKey ?? this.sendKey,
      keyStartedAt: keyStartedAt ?? this.keyStartedAt,
      keyUsed: keyUsed ?? this.keyUsed,
      keyAmbiguous: keyAmbiguous ?? this.keyAmbiguous,
      claimReused: claimReused ?? this.claimReused,
      photosKept: photosKept ?? this.photosKept,
      photoCount: photoCount ?? this.photoCount,
      createdAt: createdAt ?? this.createdAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (uid.present) {
      map['uid'] = Variable<String>(uid.value);
    }
    if (postId.present) {
      map['post_id'] = Variable<String>(postId.value);
    }
    if (postText.present) {
      map['post_text'] = Variable<String>(postText.value);
    }
    if (pollJson.present) {
      map['poll_json'] = Variable<String>(pollJson.value);
    }
    if (replyAudience.present) {
      map['reply_audience'] = Variable<String>(replyAudience.value);
    }
    if (policyValue.present) {
      map['policy_value'] = Variable<int>(policyValue.value);
    }
    if (communityId.present) {
      map['community_id'] = Variable<String>(communityId.value);
    }
    if (beaconId.present) {
      map['beacon_id'] = Variable<String>(beaconId.value);
    }
    if (isGif.present) {
      map['is_gif'] = Variable<bool>(isGif.value);
    }
    if (draftId.present) {
      map['draft_id'] = Variable<String>(draftId.value);
    }
    if (deleteDraftId.present) {
      map['delete_draft_id'] = Variable<String>(deleteDraftId.value);
    }
    if (authorBytes.present) {
      map['author_bytes'] = Variable<Uint8List>(authorBytes.value);
    }
    if (sendKey.present) {
      map['send_key'] = Variable<String>(sendKey.value);
    }
    if (keyStartedAt.present) {
      map['key_started_at'] = Variable<DateTime>(keyStartedAt.value);
    }
    if (keyUsed.present) {
      map['key_used'] = Variable<bool>(keyUsed.value);
    }
    if (keyAmbiguous.present) {
      map['key_ambiguous'] = Variable<bool>(keyAmbiguous.value);
    }
    if (claimReused.present) {
      map['claim_reused'] = Variable<bool>(claimReused.value);
    }
    if (photosKept.present) {
      map['photos_kept'] = Variable<bool>(photosKept.value);
    }
    if (photoCount.present) {
      map['photo_count'] = Variable<int>(photoCount.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('UnsentPostEntriesCompanion(')
          ..write('uid: $uid, ')
          ..write('postId: $postId, ')
          ..write('postText: $postText, ')
          ..write('pollJson: $pollJson, ')
          ..write('replyAudience: $replyAudience, ')
          ..write('policyValue: $policyValue, ')
          ..write('communityId: $communityId, ')
          ..write('beaconId: $beaconId, ')
          ..write('isGif: $isGif, ')
          ..write('draftId: $draftId, ')
          ..write('deleteDraftId: $deleteDraftId, ')
          ..write('authorBytes: $authorBytes, ')
          ..write('sendKey: $sendKey, ')
          ..write('keyStartedAt: $keyStartedAt, ')
          ..write('keyUsed: $keyUsed, ')
          ..write('keyAmbiguous: $keyAmbiguous, ')
          ..write('claimReused: $claimReused, ')
          ..write('photosKept: $photosKept, ')
          ..write('photoCount: $photoCount, ')
          ..write('createdAt: $createdAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $UnsentPostPhotoEntriesTable extends UnsentPostPhotoEntries
    with TableInfo<$UnsentPostPhotoEntriesTable, UnsentPostPhotoRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $UnsentPostPhotoEntriesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _uidMeta = const VerificationMeta('uid');
  @override
  late final GeneratedColumn<String> uid = GeneratedColumn<String>(
    'uid',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _postIdMeta = const VerificationMeta('postId');
  @override
  late final GeneratedColumn<String> postId = GeneratedColumn<String>(
    'post_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _positionMeta = const VerificationMeta(
    'position',
  );
  @override
  late final GeneratedColumn<int> position = GeneratedColumn<int>(
    'position',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _fullBytesMeta = const VerificationMeta(
    'fullBytes',
  );
  @override
  late final GeneratedColumn<Uint8List> fullBytes = GeneratedColumn<Uint8List>(
    'full_bytes',
    aliasedName,
    false,
    type: DriftSqlType.blob,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _thumbBytesMeta = const VerificationMeta(
    'thumbBytes',
  );
  @override
  late final GeneratedColumn<Uint8List> thumbBytes = GeneratedColumn<Uint8List>(
    'thumb_bytes',
    aliasedName,
    false,
    type: DriftSqlType.blob,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _widthMeta = const VerificationMeta('width');
  @override
  late final GeneratedColumn<int> width = GeneratedColumn<int>(
    'width',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _heightMeta = const VerificationMeta('height');
  @override
  late final GeneratedColumn<int> height = GeneratedColumn<int>(
    'height',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _fullMd5Meta = const VerificationMeta(
    'fullMd5',
  );
  @override
  late final GeneratedColumn<String> fullMd5 = GeneratedColumn<String>(
    'full_md5',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _thumbMd5Meta = const VerificationMeta(
    'thumbMd5',
  );
  @override
  late final GeneratedColumn<String> thumbMd5 = GeneratedColumn<String>(
    'thumb_md5',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _blurhashMeta = const VerificationMeta(
    'blurhash',
  );
  @override
  late final GeneratedColumn<String> blurhash = GeneratedColumn<String>(
    'blurhash',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _contentTypeMeta = const VerificationMeta(
    'contentType',
  );
  @override
  late final GeneratedColumn<String> contentType = GeneratedColumn<String>(
    'content_type',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _thumbContentTypeMeta = const VerificationMeta(
    'thumbContentType',
  );
  @override
  late final GeneratedColumn<String> thumbContentType = GeneratedColumn<String>(
    'thumb_content_type',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _altTextMeta = const VerificationMeta(
    'altText',
  );
  @override
  late final GeneratedColumn<String> altText = GeneratedColumn<String>(
    'alt_text',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  @override
  List<GeneratedColumn> get $columns => [
    uid,
    postId,
    position,
    fullBytes,
    thumbBytes,
    width,
    height,
    fullMd5,
    thumbMd5,
    blurhash,
    contentType,
    thumbContentType,
    altText,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'unsent_post_photo_entries';
  @override
  VerificationContext validateIntegrity(
    Insertable<UnsentPostPhotoRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('uid')) {
      context.handle(
        _uidMeta,
        uid.isAcceptableOrUnknown(data['uid']!, _uidMeta),
      );
    } else if (isInserting) {
      context.missing(_uidMeta);
    }
    if (data.containsKey('post_id')) {
      context.handle(
        _postIdMeta,
        postId.isAcceptableOrUnknown(data['post_id']!, _postIdMeta),
      );
    } else if (isInserting) {
      context.missing(_postIdMeta);
    }
    if (data.containsKey('position')) {
      context.handle(
        _positionMeta,
        position.isAcceptableOrUnknown(data['position']!, _positionMeta),
      );
    } else if (isInserting) {
      context.missing(_positionMeta);
    }
    if (data.containsKey('full_bytes')) {
      context.handle(
        _fullBytesMeta,
        fullBytes.isAcceptableOrUnknown(data['full_bytes']!, _fullBytesMeta),
      );
    } else if (isInserting) {
      context.missing(_fullBytesMeta);
    }
    if (data.containsKey('thumb_bytes')) {
      context.handle(
        _thumbBytesMeta,
        thumbBytes.isAcceptableOrUnknown(data['thumb_bytes']!, _thumbBytesMeta),
      );
    } else if (isInserting) {
      context.missing(_thumbBytesMeta);
    }
    if (data.containsKey('width')) {
      context.handle(
        _widthMeta,
        width.isAcceptableOrUnknown(data['width']!, _widthMeta),
      );
    } else if (isInserting) {
      context.missing(_widthMeta);
    }
    if (data.containsKey('height')) {
      context.handle(
        _heightMeta,
        height.isAcceptableOrUnknown(data['height']!, _heightMeta),
      );
    } else if (isInserting) {
      context.missing(_heightMeta);
    }
    if (data.containsKey('full_md5')) {
      context.handle(
        _fullMd5Meta,
        fullMd5.isAcceptableOrUnknown(data['full_md5']!, _fullMd5Meta),
      );
    } else if (isInserting) {
      context.missing(_fullMd5Meta);
    }
    if (data.containsKey('thumb_md5')) {
      context.handle(
        _thumbMd5Meta,
        thumbMd5.isAcceptableOrUnknown(data['thumb_md5']!, _thumbMd5Meta),
      );
    } else if (isInserting) {
      context.missing(_thumbMd5Meta);
    }
    if (data.containsKey('blurhash')) {
      context.handle(
        _blurhashMeta,
        blurhash.isAcceptableOrUnknown(data['blurhash']!, _blurhashMeta),
      );
    } else if (isInserting) {
      context.missing(_blurhashMeta);
    }
    if (data.containsKey('content_type')) {
      context.handle(
        _contentTypeMeta,
        contentType.isAcceptableOrUnknown(
          data['content_type']!,
          _contentTypeMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_contentTypeMeta);
    }
    if (data.containsKey('thumb_content_type')) {
      context.handle(
        _thumbContentTypeMeta,
        thumbContentType.isAcceptableOrUnknown(
          data['thumb_content_type']!,
          _thumbContentTypeMeta,
        ),
      );
    }
    if (data.containsKey('alt_text')) {
      context.handle(
        _altTextMeta,
        altText.isAcceptableOrUnknown(data['alt_text']!, _altTextMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {uid, postId, position};
  @override
  UnsentPostPhotoRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return UnsentPostPhotoRow(
      uid: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}uid'],
      )!,
      postId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}post_id'],
      )!,
      position: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}position'],
      )!,
      fullBytes: attachedDatabase.typeMapping.read(
        DriftSqlType.blob,
        data['${effectivePrefix}full_bytes'],
      )!,
      thumbBytes: attachedDatabase.typeMapping.read(
        DriftSqlType.blob,
        data['${effectivePrefix}thumb_bytes'],
      )!,
      width: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}width'],
      )!,
      height: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}height'],
      )!,
      fullMd5: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}full_md5'],
      )!,
      thumbMd5: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}thumb_md5'],
      )!,
      blurhash: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}blurhash'],
      )!,
      contentType: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}content_type'],
      )!,
      thumbContentType: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}thumb_content_type'],
      )!,
      altText: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}alt_text'],
      )!,
    );
  }

  @override
  $UnsentPostPhotoEntriesTable createAlias(String alias) {
    return $UnsentPostPhotoEntriesTable(attachedDatabase, alias);
  }
}

class UnsentPostPhotoRow extends DataClass
    implements Insertable<UnsentPostPhotoRow> {
  final String uid;
  final String postId;
  final int position;
  final Uint8List fullBytes;
  final Uint8List thumbBytes;
  final int width;
  final int height;
  final String fullMd5;
  final String thumbMd5;
  final String blurhash;
  final String contentType;
  final String thumbContentType;
  final String altText;
  const UnsentPostPhotoRow({
    required this.uid,
    required this.postId,
    required this.position,
    required this.fullBytes,
    required this.thumbBytes,
    required this.width,
    required this.height,
    required this.fullMd5,
    required this.thumbMd5,
    required this.blurhash,
    required this.contentType,
    required this.thumbContentType,
    required this.altText,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['uid'] = Variable<String>(uid);
    map['post_id'] = Variable<String>(postId);
    map['position'] = Variable<int>(position);
    map['full_bytes'] = Variable<Uint8List>(fullBytes);
    map['thumb_bytes'] = Variable<Uint8List>(thumbBytes);
    map['width'] = Variable<int>(width);
    map['height'] = Variable<int>(height);
    map['full_md5'] = Variable<String>(fullMd5);
    map['thumb_md5'] = Variable<String>(thumbMd5);
    map['blurhash'] = Variable<String>(blurhash);
    map['content_type'] = Variable<String>(contentType);
    map['thumb_content_type'] = Variable<String>(thumbContentType);
    map['alt_text'] = Variable<String>(altText);
    return map;
  }

  UnsentPostPhotoEntriesCompanion toCompanion(bool nullToAbsent) {
    return UnsentPostPhotoEntriesCompanion(
      uid: Value(uid),
      postId: Value(postId),
      position: Value(position),
      fullBytes: Value(fullBytes),
      thumbBytes: Value(thumbBytes),
      width: Value(width),
      height: Value(height),
      fullMd5: Value(fullMd5),
      thumbMd5: Value(thumbMd5),
      blurhash: Value(blurhash),
      contentType: Value(contentType),
      thumbContentType: Value(thumbContentType),
      altText: Value(altText),
    );
  }

  factory UnsentPostPhotoRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return UnsentPostPhotoRow(
      uid: serializer.fromJson<String>(json['uid']),
      postId: serializer.fromJson<String>(json['postId']),
      position: serializer.fromJson<int>(json['position']),
      fullBytes: serializer.fromJson<Uint8List>(json['fullBytes']),
      thumbBytes: serializer.fromJson<Uint8List>(json['thumbBytes']),
      width: serializer.fromJson<int>(json['width']),
      height: serializer.fromJson<int>(json['height']),
      fullMd5: serializer.fromJson<String>(json['fullMd5']),
      thumbMd5: serializer.fromJson<String>(json['thumbMd5']),
      blurhash: serializer.fromJson<String>(json['blurhash']),
      contentType: serializer.fromJson<String>(json['contentType']),
      thumbContentType: serializer.fromJson<String>(json['thumbContentType']),
      altText: serializer.fromJson<String>(json['altText']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'uid': serializer.toJson<String>(uid),
      'postId': serializer.toJson<String>(postId),
      'position': serializer.toJson<int>(position),
      'fullBytes': serializer.toJson<Uint8List>(fullBytes),
      'thumbBytes': serializer.toJson<Uint8List>(thumbBytes),
      'width': serializer.toJson<int>(width),
      'height': serializer.toJson<int>(height),
      'fullMd5': serializer.toJson<String>(fullMd5),
      'thumbMd5': serializer.toJson<String>(thumbMd5),
      'blurhash': serializer.toJson<String>(blurhash),
      'contentType': serializer.toJson<String>(contentType),
      'thumbContentType': serializer.toJson<String>(thumbContentType),
      'altText': serializer.toJson<String>(altText),
    };
  }

  UnsentPostPhotoRow copyWith({
    String? uid,
    String? postId,
    int? position,
    Uint8List? fullBytes,
    Uint8List? thumbBytes,
    int? width,
    int? height,
    String? fullMd5,
    String? thumbMd5,
    String? blurhash,
    String? contentType,
    String? thumbContentType,
    String? altText,
  }) => UnsentPostPhotoRow(
    uid: uid ?? this.uid,
    postId: postId ?? this.postId,
    position: position ?? this.position,
    fullBytes: fullBytes ?? this.fullBytes,
    thumbBytes: thumbBytes ?? this.thumbBytes,
    width: width ?? this.width,
    height: height ?? this.height,
    fullMd5: fullMd5 ?? this.fullMd5,
    thumbMd5: thumbMd5 ?? this.thumbMd5,
    blurhash: blurhash ?? this.blurhash,
    contentType: contentType ?? this.contentType,
    thumbContentType: thumbContentType ?? this.thumbContentType,
    altText: altText ?? this.altText,
  );
  UnsentPostPhotoRow copyWithCompanion(UnsentPostPhotoEntriesCompanion data) {
    return UnsentPostPhotoRow(
      uid: data.uid.present ? data.uid.value : this.uid,
      postId: data.postId.present ? data.postId.value : this.postId,
      position: data.position.present ? data.position.value : this.position,
      fullBytes: data.fullBytes.present ? data.fullBytes.value : this.fullBytes,
      thumbBytes: data.thumbBytes.present
          ? data.thumbBytes.value
          : this.thumbBytes,
      width: data.width.present ? data.width.value : this.width,
      height: data.height.present ? data.height.value : this.height,
      fullMd5: data.fullMd5.present ? data.fullMd5.value : this.fullMd5,
      thumbMd5: data.thumbMd5.present ? data.thumbMd5.value : this.thumbMd5,
      blurhash: data.blurhash.present ? data.blurhash.value : this.blurhash,
      contentType: data.contentType.present
          ? data.contentType.value
          : this.contentType,
      thumbContentType: data.thumbContentType.present
          ? data.thumbContentType.value
          : this.thumbContentType,
      altText: data.altText.present ? data.altText.value : this.altText,
    );
  }

  @override
  String toString() {
    return (StringBuffer('UnsentPostPhotoRow(')
          ..write('uid: $uid, ')
          ..write('postId: $postId, ')
          ..write('position: $position, ')
          ..write('fullBytes: $fullBytes, ')
          ..write('thumbBytes: $thumbBytes, ')
          ..write('width: $width, ')
          ..write('height: $height, ')
          ..write('fullMd5: $fullMd5, ')
          ..write('thumbMd5: $thumbMd5, ')
          ..write('blurhash: $blurhash, ')
          ..write('contentType: $contentType, ')
          ..write('thumbContentType: $thumbContentType, ')
          ..write('altText: $altText')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    uid,
    postId,
    position,
    $driftBlobEquality.hash(fullBytes),
    $driftBlobEquality.hash(thumbBytes),
    width,
    height,
    fullMd5,
    thumbMd5,
    blurhash,
    contentType,
    thumbContentType,
    altText,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is UnsentPostPhotoRow &&
          other.uid == this.uid &&
          other.postId == this.postId &&
          other.position == this.position &&
          $driftBlobEquality.equals(other.fullBytes, this.fullBytes) &&
          $driftBlobEquality.equals(other.thumbBytes, this.thumbBytes) &&
          other.width == this.width &&
          other.height == this.height &&
          other.fullMd5 == this.fullMd5 &&
          other.thumbMd5 == this.thumbMd5 &&
          other.blurhash == this.blurhash &&
          other.contentType == this.contentType &&
          other.thumbContentType == this.thumbContentType &&
          other.altText == this.altText);
}

class UnsentPostPhotoEntriesCompanion
    extends UpdateCompanion<UnsentPostPhotoRow> {
  final Value<String> uid;
  final Value<String> postId;
  final Value<int> position;
  final Value<Uint8List> fullBytes;
  final Value<Uint8List> thumbBytes;
  final Value<int> width;
  final Value<int> height;
  final Value<String> fullMd5;
  final Value<String> thumbMd5;
  final Value<String> blurhash;
  final Value<String> contentType;
  final Value<String> thumbContentType;
  final Value<String> altText;
  final Value<int> rowid;
  const UnsentPostPhotoEntriesCompanion({
    this.uid = const Value.absent(),
    this.postId = const Value.absent(),
    this.position = const Value.absent(),
    this.fullBytes = const Value.absent(),
    this.thumbBytes = const Value.absent(),
    this.width = const Value.absent(),
    this.height = const Value.absent(),
    this.fullMd5 = const Value.absent(),
    this.thumbMd5 = const Value.absent(),
    this.blurhash = const Value.absent(),
    this.contentType = const Value.absent(),
    this.thumbContentType = const Value.absent(),
    this.altText = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  UnsentPostPhotoEntriesCompanion.insert({
    required String uid,
    required String postId,
    required int position,
    required Uint8List fullBytes,
    required Uint8List thumbBytes,
    required int width,
    required int height,
    required String fullMd5,
    required String thumbMd5,
    required String blurhash,
    required String contentType,
    this.thumbContentType = const Value.absent(),
    this.altText = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : uid = Value(uid),
       postId = Value(postId),
       position = Value(position),
       fullBytes = Value(fullBytes),
       thumbBytes = Value(thumbBytes),
       width = Value(width),
       height = Value(height),
       fullMd5 = Value(fullMd5),
       thumbMd5 = Value(thumbMd5),
       blurhash = Value(blurhash),
       contentType = Value(contentType);
  static Insertable<UnsentPostPhotoRow> custom({
    Expression<String>? uid,
    Expression<String>? postId,
    Expression<int>? position,
    Expression<Uint8List>? fullBytes,
    Expression<Uint8List>? thumbBytes,
    Expression<int>? width,
    Expression<int>? height,
    Expression<String>? fullMd5,
    Expression<String>? thumbMd5,
    Expression<String>? blurhash,
    Expression<String>? contentType,
    Expression<String>? thumbContentType,
    Expression<String>? altText,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (uid != null) 'uid': uid,
      if (postId != null) 'post_id': postId,
      if (position != null) 'position': position,
      if (fullBytes != null) 'full_bytes': fullBytes,
      if (thumbBytes != null) 'thumb_bytes': thumbBytes,
      if (width != null) 'width': width,
      if (height != null) 'height': height,
      if (fullMd5 != null) 'full_md5': fullMd5,
      if (thumbMd5 != null) 'thumb_md5': thumbMd5,
      if (blurhash != null) 'blurhash': blurhash,
      if (contentType != null) 'content_type': contentType,
      if (thumbContentType != null) 'thumb_content_type': thumbContentType,
      if (altText != null) 'alt_text': altText,
      if (rowid != null) 'rowid': rowid,
    });
  }

  UnsentPostPhotoEntriesCompanion copyWith({
    Value<String>? uid,
    Value<String>? postId,
    Value<int>? position,
    Value<Uint8List>? fullBytes,
    Value<Uint8List>? thumbBytes,
    Value<int>? width,
    Value<int>? height,
    Value<String>? fullMd5,
    Value<String>? thumbMd5,
    Value<String>? blurhash,
    Value<String>? contentType,
    Value<String>? thumbContentType,
    Value<String>? altText,
    Value<int>? rowid,
  }) {
    return UnsentPostPhotoEntriesCompanion(
      uid: uid ?? this.uid,
      postId: postId ?? this.postId,
      position: position ?? this.position,
      fullBytes: fullBytes ?? this.fullBytes,
      thumbBytes: thumbBytes ?? this.thumbBytes,
      width: width ?? this.width,
      height: height ?? this.height,
      fullMd5: fullMd5 ?? this.fullMd5,
      thumbMd5: thumbMd5 ?? this.thumbMd5,
      blurhash: blurhash ?? this.blurhash,
      contentType: contentType ?? this.contentType,
      thumbContentType: thumbContentType ?? this.thumbContentType,
      altText: altText ?? this.altText,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (uid.present) {
      map['uid'] = Variable<String>(uid.value);
    }
    if (postId.present) {
      map['post_id'] = Variable<String>(postId.value);
    }
    if (position.present) {
      map['position'] = Variable<int>(position.value);
    }
    if (fullBytes.present) {
      map['full_bytes'] = Variable<Uint8List>(fullBytes.value);
    }
    if (thumbBytes.present) {
      map['thumb_bytes'] = Variable<Uint8List>(thumbBytes.value);
    }
    if (width.present) {
      map['width'] = Variable<int>(width.value);
    }
    if (height.present) {
      map['height'] = Variable<int>(height.value);
    }
    if (fullMd5.present) {
      map['full_md5'] = Variable<String>(fullMd5.value);
    }
    if (thumbMd5.present) {
      map['thumb_md5'] = Variable<String>(thumbMd5.value);
    }
    if (blurhash.present) {
      map['blurhash'] = Variable<String>(blurhash.value);
    }
    if (contentType.present) {
      map['content_type'] = Variable<String>(contentType.value);
    }
    if (thumbContentType.present) {
      map['thumb_content_type'] = Variable<String>(thumbContentType.value);
    }
    if (altText.present) {
      map['alt_text'] = Variable<String>(altText.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('UnsentPostPhotoEntriesCompanion(')
          ..write('uid: $uid, ')
          ..write('postId: $postId, ')
          ..write('position: $position, ')
          ..write('fullBytes: $fullBytes, ')
          ..write('thumbBytes: $thumbBytes, ')
          ..write('width: $width, ')
          ..write('height: $height, ')
          ..write('fullMd5: $fullMd5, ')
          ..write('thumbMd5: $thumbMd5, ')
          ..write('blurhash: $blurhash, ')
          ..write('contentType: $contentType, ')
          ..write('thumbContentType: $thumbContentType, ')
          ..write('altText: $altText, ')
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
  late final $NotificationEntriesTable notificationEntries =
      $NotificationEntriesTable(this);
  late final $NotificationStateEntriesTable notificationStateEntries =
      $NotificationStateEntriesTable(this);
  late final $ConversationEntriesTable conversationEntries =
      $ConversationEntriesTable(this);
  late final $MessageEntriesTable messageEntries = $MessageEntriesTable(this);
  late final $MessagingStateEntriesTable messagingStateEntries =
      $MessagingStateEntriesTable(this);
  late final $AppSettingEntriesTable appSettingEntries =
      $AppSettingEntriesTable(this);
  late final $ComposerDraftEntriesTable composerDraftEntries =
      $ComposerDraftEntriesTable(this);
  late final $PostHistoryEntriesTable postHistoryEntries =
      $PostHistoryEntriesTable(this);
  late final $UnsentPostEntriesTable unsentPostEntries =
      $UnsentPostEntriesTable(this);
  late final $UnsentPostPhotoEntriesTable unsentPostPhotoEntries =
      $UnsentPostPhotoEntriesTable(this);
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
    notificationEntries,
    notificationStateEntries,
    conversationEntries,
    messageEntries,
    messagingStateEntries,
    appSettingEntries,
    composerDraftEntries,
    postHistoryEntries,
    unsentPostEntries,
    unsentPostPhotoEntries,
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
      Value<bool> subscriptionVerified,
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
      Value<bool> subscriptionVerified,
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

  ColumnFilters<bool> get subscriptionVerified => $composableBuilder(
    column: $table.subscriptionVerified,
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

  ColumnOrderings<bool> get subscriptionVerified => $composableBuilder(
    column: $table.subscriptionVerified,
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

  GeneratedColumn<bool> get subscriptionVerified => $composableBuilder(
    column: $table.subscriptionVerified,
    builder: (column) => column,
  );

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
                Value<bool> subscriptionVerified = const Value.absent(),
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
                subscriptionVerified: subscriptionVerified,
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
                Value<bool> subscriptionVerified = const Value.absent(),
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
                subscriptionVerified: subscriptionVerified,
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
typedef $$NotificationEntriesTableCreateCompanionBuilder =
    NotificationEntriesCompanion Function({
      required String itemKey,
      required String sortKey,
      Value<Uint8List?> payload,
      Value<String?> gapToken,
      Value<String?> pageToken,
      Value<int> rowid,
    });
typedef $$NotificationEntriesTableUpdateCompanionBuilder =
    NotificationEntriesCompanion Function({
      Value<String> itemKey,
      Value<String> sortKey,
      Value<Uint8List?> payload,
      Value<String?> gapToken,
      Value<String?> pageToken,
      Value<int> rowid,
    });

class $$NotificationEntriesTableFilterComposer
    extends Composer<_$AppDatabase, $NotificationEntriesTable> {
  $$NotificationEntriesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
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

class $$NotificationEntriesTableOrderingComposer
    extends Composer<_$AppDatabase, $NotificationEntriesTable> {
  $$NotificationEntriesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
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

class $$NotificationEntriesTableAnnotationComposer
    extends Composer<_$AppDatabase, $NotificationEntriesTable> {
  $$NotificationEntriesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
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

class $$NotificationEntriesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $NotificationEntriesTable,
          CachedNotification,
          $$NotificationEntriesTableFilterComposer,
          $$NotificationEntriesTableOrderingComposer,
          $$NotificationEntriesTableAnnotationComposer,
          $$NotificationEntriesTableCreateCompanionBuilder,
          $$NotificationEntriesTableUpdateCompanionBuilder,
          (
            CachedNotification,
            BaseReferences<
              _$AppDatabase,
              $NotificationEntriesTable,
              CachedNotification
            >,
          ),
          CachedNotification,
          PrefetchHooks Function()
        > {
  $$NotificationEntriesTableTableManager(
    _$AppDatabase db,
    $NotificationEntriesTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$NotificationEntriesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$NotificationEntriesTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              $$NotificationEntriesTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> itemKey = const Value.absent(),
                Value<String> sortKey = const Value.absent(),
                Value<Uint8List?> payload = const Value.absent(),
                Value<String?> gapToken = const Value.absent(),
                Value<String?> pageToken = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => NotificationEntriesCompanion(
                itemKey: itemKey,
                sortKey: sortKey,
                payload: payload,
                gapToken: gapToken,
                pageToken: pageToken,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String itemKey,
                required String sortKey,
                Value<Uint8List?> payload = const Value.absent(),
                Value<String?> gapToken = const Value.absent(),
                Value<String?> pageToken = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => NotificationEntriesCompanion.insert(
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
                  e.readTable<$NotificationEntriesTable, CachedNotification>(
                    table,
                  ),
                  BaseReferences<
                    _$AppDatabase,
                    $NotificationEntriesTable,
                    CachedNotification
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$NotificationEntriesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $NotificationEntriesTable,
      CachedNotification,
      $$NotificationEntriesTableFilterComposer,
      $$NotificationEntriesTableOrderingComposer,
      $$NotificationEntriesTableAnnotationComposer,
      $$NotificationEntriesTableCreateCompanionBuilder,
      $$NotificationEntriesTableUpdateCompanionBuilder,
      (
        CachedNotification,
        BaseReferences<
          _$AppDatabase,
          $NotificationEntriesTable,
          CachedNotification
        >,
      ),
      CachedNotification,
      PrefetchHooks Function()
    >;
typedef $$NotificationStateEntriesTableCreateCompanionBuilder =
    NotificationStateEntriesCompanion Function({
      required String stateKey,
      Value<String> sinceToken,
      Value<String> olderPageToken,
      Value<int?> seenAtMicros,
      Value<String> deviceId,
      required DateTime updatedAt,
      Value<int> rowid,
    });
typedef $$NotificationStateEntriesTableUpdateCompanionBuilder =
    NotificationStateEntriesCompanion Function({
      Value<String> stateKey,
      Value<String> sinceToken,
      Value<String> olderPageToken,
      Value<int?> seenAtMicros,
      Value<String> deviceId,
      Value<DateTime> updatedAt,
      Value<int> rowid,
    });

class $$NotificationStateEntriesTableFilterComposer
    extends Composer<_$AppDatabase, $NotificationStateEntriesTable> {
  $$NotificationStateEntriesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get stateKey => $composableBuilder(
    column: $table.stateKey,
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

  ColumnFilters<int> get seenAtMicros => $composableBuilder(
    column: $table.seenAtMicros,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get deviceId => $composableBuilder(
    column: $table.deviceId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$NotificationStateEntriesTableOrderingComposer
    extends Composer<_$AppDatabase, $NotificationStateEntriesTable> {
  $$NotificationStateEntriesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get stateKey => $composableBuilder(
    column: $table.stateKey,
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

  ColumnOrderings<int> get seenAtMicros => $composableBuilder(
    column: $table.seenAtMicros,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get deviceId => $composableBuilder(
    column: $table.deviceId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$NotificationStateEntriesTableAnnotationComposer
    extends Composer<_$AppDatabase, $NotificationStateEntriesTable> {
  $$NotificationStateEntriesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get stateKey =>
      $composableBuilder(column: $table.stateKey, builder: (column) => column);

  GeneratedColumn<String> get sinceToken => $composableBuilder(
    column: $table.sinceToken,
    builder: (column) => column,
  );

  GeneratedColumn<String> get olderPageToken => $composableBuilder(
    column: $table.olderPageToken,
    builder: (column) => column,
  );

  GeneratedColumn<int> get seenAtMicros => $composableBuilder(
    column: $table.seenAtMicros,
    builder: (column) => column,
  );

  GeneratedColumn<String> get deviceId =>
      $composableBuilder(column: $table.deviceId, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $$NotificationStateEntriesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $NotificationStateEntriesTable,
          CachedNotificationState,
          $$NotificationStateEntriesTableFilterComposer,
          $$NotificationStateEntriesTableOrderingComposer,
          $$NotificationStateEntriesTableAnnotationComposer,
          $$NotificationStateEntriesTableCreateCompanionBuilder,
          $$NotificationStateEntriesTableUpdateCompanionBuilder,
          (
            CachedNotificationState,
            BaseReferences<
              _$AppDatabase,
              $NotificationStateEntriesTable,
              CachedNotificationState
            >,
          ),
          CachedNotificationState,
          PrefetchHooks Function()
        > {
  $$NotificationStateEntriesTableTableManager(
    _$AppDatabase db,
    $NotificationStateEntriesTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$NotificationStateEntriesTableFilterComposer(
                $db: db,
                $table: table,
              ),
          createOrderingComposer: () =>
              $$NotificationStateEntriesTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              $$NotificationStateEntriesTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> stateKey = const Value.absent(),
                Value<String> sinceToken = const Value.absent(),
                Value<String> olderPageToken = const Value.absent(),
                Value<int?> seenAtMicros = const Value.absent(),
                Value<String> deviceId = const Value.absent(),
                Value<DateTime> updatedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => NotificationStateEntriesCompanion(
                stateKey: stateKey,
                sinceToken: sinceToken,
                olderPageToken: olderPageToken,
                seenAtMicros: seenAtMicros,
                deviceId: deviceId,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String stateKey,
                Value<String> sinceToken = const Value.absent(),
                Value<String> olderPageToken = const Value.absent(),
                Value<int?> seenAtMicros = const Value.absent(),
                Value<String> deviceId = const Value.absent(),
                required DateTime updatedAt,
                Value<int> rowid = const Value.absent(),
              }) => NotificationStateEntriesCompanion.insert(
                stateKey: stateKey,
                sinceToken: sinceToken,
                olderPageToken: olderPageToken,
                seenAtMicros: seenAtMicros,
                deviceId: deviceId,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<
                    $NotificationStateEntriesTable,
                    CachedNotificationState
                  >(table),
                  BaseReferences<
                    _$AppDatabase,
                    $NotificationStateEntriesTable,
                    CachedNotificationState
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$NotificationStateEntriesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $NotificationStateEntriesTable,
      CachedNotificationState,
      $$NotificationStateEntriesTableFilterComposer,
      $$NotificationStateEntriesTableOrderingComposer,
      $$NotificationStateEntriesTableAnnotationComposer,
      $$NotificationStateEntriesTableCreateCompanionBuilder,
      $$NotificationStateEntriesTableUpdateCompanionBuilder,
      (
        CachedNotificationState,
        BaseReferences<
          _$AppDatabase,
          $NotificationStateEntriesTable,
          CachedNotificationState
        >,
      ),
      CachedNotificationState,
      PrefetchHooks Function()
    >;
typedef $$ConversationEntriesTableCreateCompanionBuilder =
    ConversationEntriesCompanion Function({
      required String conversationId,
      required int folder,
      required String sortKey,
      required Uint8List payload,
      Value<int> rowid,
    });
typedef $$ConversationEntriesTableUpdateCompanionBuilder =
    ConversationEntriesCompanion Function({
      Value<String> conversationId,
      Value<int> folder,
      Value<String> sortKey,
      Value<Uint8List> payload,
      Value<int> rowid,
    });

class $$ConversationEntriesTableFilterComposer
    extends Composer<_$AppDatabase, $ConversationEntriesTable> {
  $$ConversationEntriesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get conversationId => $composableBuilder(
    column: $table.conversationId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get folder => $composableBuilder(
    column: $table.folder,
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
}

class $$ConversationEntriesTableOrderingComposer
    extends Composer<_$AppDatabase, $ConversationEntriesTable> {
  $$ConversationEntriesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get conversationId => $composableBuilder(
    column: $table.conversationId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get folder => $composableBuilder(
    column: $table.folder,
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
}

class $$ConversationEntriesTableAnnotationComposer
    extends Composer<_$AppDatabase, $ConversationEntriesTable> {
  $$ConversationEntriesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get conversationId => $composableBuilder(
    column: $table.conversationId,
    builder: (column) => column,
  );

  GeneratedColumn<int> get folder =>
      $composableBuilder(column: $table.folder, builder: (column) => column);

  GeneratedColumn<String> get sortKey =>
      $composableBuilder(column: $table.sortKey, builder: (column) => column);

  GeneratedColumn<Uint8List> get payload =>
      $composableBuilder(column: $table.payload, builder: (column) => column);
}

class $$ConversationEntriesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $ConversationEntriesTable,
          CachedConversation,
          $$ConversationEntriesTableFilterComposer,
          $$ConversationEntriesTableOrderingComposer,
          $$ConversationEntriesTableAnnotationComposer,
          $$ConversationEntriesTableCreateCompanionBuilder,
          $$ConversationEntriesTableUpdateCompanionBuilder,
          (
            CachedConversation,
            BaseReferences<
              _$AppDatabase,
              $ConversationEntriesTable,
              CachedConversation
            >,
          ),
          CachedConversation,
          PrefetchHooks Function()
        > {
  $$ConversationEntriesTableTableManager(
    _$AppDatabase db,
    $ConversationEntriesTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ConversationEntriesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ConversationEntriesTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              $$ConversationEntriesTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> conversationId = const Value.absent(),
                Value<int> folder = const Value.absent(),
                Value<String> sortKey = const Value.absent(),
                Value<Uint8List> payload = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ConversationEntriesCompanion(
                conversationId: conversationId,
                folder: folder,
                sortKey: sortKey,
                payload: payload,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String conversationId,
                required int folder,
                required String sortKey,
                required Uint8List payload,
                Value<int> rowid = const Value.absent(),
              }) => ConversationEntriesCompanion.insert(
                conversationId: conversationId,
                folder: folder,
                sortKey: sortKey,
                payload: payload,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$ConversationEntriesTable, CachedConversation>(
                    table,
                  ),
                  BaseReferences<
                    _$AppDatabase,
                    $ConversationEntriesTable,
                    CachedConversation
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$ConversationEntriesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $ConversationEntriesTable,
      CachedConversation,
      $$ConversationEntriesTableFilterComposer,
      $$ConversationEntriesTableOrderingComposer,
      $$ConversationEntriesTableAnnotationComposer,
      $$ConversationEntriesTableCreateCompanionBuilder,
      $$ConversationEntriesTableUpdateCompanionBuilder,
      (
        CachedConversation,
        BaseReferences<
          _$AppDatabase,
          $ConversationEntriesTable,
          CachedConversation
        >,
      ),
      CachedConversation,
      PrefetchHooks Function()
    >;
typedef $$MessageEntriesTableCreateCompanionBuilder =
    MessageEntriesCompanion Function({
      required String conversationId,
      required String messageId,
      required String sortKey,
      required Uint8List payload,
      Value<String?> pageToken,
      Value<int> rowid,
    });
typedef $$MessageEntriesTableUpdateCompanionBuilder =
    MessageEntriesCompanion Function({
      Value<String> conversationId,
      Value<String> messageId,
      Value<String> sortKey,
      Value<Uint8List> payload,
      Value<String?> pageToken,
      Value<int> rowid,
    });

class $$MessageEntriesTableFilterComposer
    extends Composer<_$AppDatabase, $MessageEntriesTable> {
  $$MessageEntriesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get conversationId => $composableBuilder(
    column: $table.conversationId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get messageId => $composableBuilder(
    column: $table.messageId,
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

  ColumnFilters<String> get pageToken => $composableBuilder(
    column: $table.pageToken,
    builder: (column) => ColumnFilters(column),
  );
}

class $$MessageEntriesTableOrderingComposer
    extends Composer<_$AppDatabase, $MessageEntriesTable> {
  $$MessageEntriesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get conversationId => $composableBuilder(
    column: $table.conversationId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get messageId => $composableBuilder(
    column: $table.messageId,
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

  ColumnOrderings<String> get pageToken => $composableBuilder(
    column: $table.pageToken,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$MessageEntriesTableAnnotationComposer
    extends Composer<_$AppDatabase, $MessageEntriesTable> {
  $$MessageEntriesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get conversationId => $composableBuilder(
    column: $table.conversationId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get messageId =>
      $composableBuilder(column: $table.messageId, builder: (column) => column);

  GeneratedColumn<String> get sortKey =>
      $composableBuilder(column: $table.sortKey, builder: (column) => column);

  GeneratedColumn<Uint8List> get payload =>
      $composableBuilder(column: $table.payload, builder: (column) => column);

  GeneratedColumn<String> get pageToken =>
      $composableBuilder(column: $table.pageToken, builder: (column) => column);
}

class $$MessageEntriesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $MessageEntriesTable,
          CachedMessage,
          $$MessageEntriesTableFilterComposer,
          $$MessageEntriesTableOrderingComposer,
          $$MessageEntriesTableAnnotationComposer,
          $$MessageEntriesTableCreateCompanionBuilder,
          $$MessageEntriesTableUpdateCompanionBuilder,
          (
            CachedMessage,
            BaseReferences<_$AppDatabase, $MessageEntriesTable, CachedMessage>,
          ),
          CachedMessage,
          PrefetchHooks Function()
        > {
  $$MessageEntriesTableTableManager(
    _$AppDatabase db,
    $MessageEntriesTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$MessageEntriesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$MessageEntriesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$MessageEntriesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> conversationId = const Value.absent(),
                Value<String> messageId = const Value.absent(),
                Value<String> sortKey = const Value.absent(),
                Value<Uint8List> payload = const Value.absent(),
                Value<String?> pageToken = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => MessageEntriesCompanion(
                conversationId: conversationId,
                messageId: messageId,
                sortKey: sortKey,
                payload: payload,
                pageToken: pageToken,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String conversationId,
                required String messageId,
                required String sortKey,
                required Uint8List payload,
                Value<String?> pageToken = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => MessageEntriesCompanion.insert(
                conversationId: conversationId,
                messageId: messageId,
                sortKey: sortKey,
                payload: payload,
                pageToken: pageToken,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$MessageEntriesTable, CachedMessage>(table),
                  BaseReferences<
                    _$AppDatabase,
                    $MessageEntriesTable,
                    CachedMessage
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$MessageEntriesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $MessageEntriesTable,
      CachedMessage,
      $$MessageEntriesTableFilterComposer,
      $$MessageEntriesTableOrderingComposer,
      $$MessageEntriesTableAnnotationComposer,
      $$MessageEntriesTableCreateCompanionBuilder,
      $$MessageEntriesTableUpdateCompanionBuilder,
      (
        CachedMessage,
        BaseReferences<_$AppDatabase, $MessageEntriesTable, CachedMessage>,
      ),
      CachedMessage,
      PrefetchHooks Function()
    >;
typedef $$MessagingStateEntriesTableCreateCompanionBuilder =
    MessagingStateEntriesCompanion Function({
      required String stateKey,
      Value<String> sinceToken,
      Value<String> olderPageToken,
      required DateTime updatedAt,
      Value<int?> requestCount,
      Value<int> rowid,
    });
typedef $$MessagingStateEntriesTableUpdateCompanionBuilder =
    MessagingStateEntriesCompanion Function({
      Value<String> stateKey,
      Value<String> sinceToken,
      Value<String> olderPageToken,
      Value<DateTime> updatedAt,
      Value<int?> requestCount,
      Value<int> rowid,
    });

class $$MessagingStateEntriesTableFilterComposer
    extends Composer<_$AppDatabase, $MessagingStateEntriesTable> {
  $$MessagingStateEntriesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get stateKey => $composableBuilder(
    column: $table.stateKey,
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

  ColumnFilters<int> get requestCount => $composableBuilder(
    column: $table.requestCount,
    builder: (column) => ColumnFilters(column),
  );
}

class $$MessagingStateEntriesTableOrderingComposer
    extends Composer<_$AppDatabase, $MessagingStateEntriesTable> {
  $$MessagingStateEntriesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get stateKey => $composableBuilder(
    column: $table.stateKey,
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

  ColumnOrderings<int> get requestCount => $composableBuilder(
    column: $table.requestCount,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$MessagingStateEntriesTableAnnotationComposer
    extends Composer<_$AppDatabase, $MessagingStateEntriesTable> {
  $$MessagingStateEntriesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get stateKey =>
      $composableBuilder(column: $table.stateKey, builder: (column) => column);

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

  GeneratedColumn<int> get requestCount => $composableBuilder(
    column: $table.requestCount,
    builder: (column) => column,
  );
}

class $$MessagingStateEntriesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $MessagingStateEntriesTable,
          CachedMessagingState,
          $$MessagingStateEntriesTableFilterComposer,
          $$MessagingStateEntriesTableOrderingComposer,
          $$MessagingStateEntriesTableAnnotationComposer,
          $$MessagingStateEntriesTableCreateCompanionBuilder,
          $$MessagingStateEntriesTableUpdateCompanionBuilder,
          (
            CachedMessagingState,
            BaseReferences<
              _$AppDatabase,
              $MessagingStateEntriesTable,
              CachedMessagingState
            >,
          ),
          CachedMessagingState,
          PrefetchHooks Function()
        > {
  $$MessagingStateEntriesTableTableManager(
    _$AppDatabase db,
    $MessagingStateEntriesTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$MessagingStateEntriesTableFilterComposer(
                $db: db,
                $table: table,
              ),
          createOrderingComposer: () =>
              $$MessagingStateEntriesTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              $$MessagingStateEntriesTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> stateKey = const Value.absent(),
                Value<String> sinceToken = const Value.absent(),
                Value<String> olderPageToken = const Value.absent(),
                Value<DateTime> updatedAt = const Value.absent(),
                Value<int?> requestCount = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => MessagingStateEntriesCompanion(
                stateKey: stateKey,
                sinceToken: sinceToken,
                olderPageToken: olderPageToken,
                updatedAt: updatedAt,
                requestCount: requestCount,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String stateKey,
                Value<String> sinceToken = const Value.absent(),
                Value<String> olderPageToken = const Value.absent(),
                required DateTime updatedAt,
                Value<int?> requestCount = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => MessagingStateEntriesCompanion.insert(
                stateKey: stateKey,
                sinceToken: sinceToken,
                olderPageToken: olderPageToken,
                updatedAt: updatedAt,
                requestCount: requestCount,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<
                    $MessagingStateEntriesTable,
                    CachedMessagingState
                  >(table),
                  BaseReferences<
                    _$AppDatabase,
                    $MessagingStateEntriesTable,
                    CachedMessagingState
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$MessagingStateEntriesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $MessagingStateEntriesTable,
      CachedMessagingState,
      $$MessagingStateEntriesTableFilterComposer,
      $$MessagingStateEntriesTableOrderingComposer,
      $$MessagingStateEntriesTableAnnotationComposer,
      $$MessagingStateEntriesTableCreateCompanionBuilder,
      $$MessagingStateEntriesTableUpdateCompanionBuilder,
      (
        CachedMessagingState,
        BaseReferences<
          _$AppDatabase,
          $MessagingStateEntriesTable,
          CachedMessagingState
        >,
      ),
      CachedMessagingState,
      PrefetchHooks Function()
    >;
typedef $$AppSettingEntriesTableCreateCompanionBuilder =
    AppSettingEntriesCompanion Function({
      required String settingKey,
      required String settingValue,
      Value<int> rowid,
    });
typedef $$AppSettingEntriesTableUpdateCompanionBuilder =
    AppSettingEntriesCompanion Function({
      Value<String> settingKey,
      Value<String> settingValue,
      Value<int> rowid,
    });

class $$AppSettingEntriesTableFilterComposer
    extends Composer<_$AppDatabase, $AppSettingEntriesTable> {
  $$AppSettingEntriesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get settingKey => $composableBuilder(
    column: $table.settingKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get settingValue => $composableBuilder(
    column: $table.settingValue,
    builder: (column) => ColumnFilters(column),
  );
}

class $$AppSettingEntriesTableOrderingComposer
    extends Composer<_$AppDatabase, $AppSettingEntriesTable> {
  $$AppSettingEntriesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get settingKey => $composableBuilder(
    column: $table.settingKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get settingValue => $composableBuilder(
    column: $table.settingValue,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$AppSettingEntriesTableAnnotationComposer
    extends Composer<_$AppDatabase, $AppSettingEntriesTable> {
  $$AppSettingEntriesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get settingKey => $composableBuilder(
    column: $table.settingKey,
    builder: (column) => column,
  );

  GeneratedColumn<String> get settingValue => $composableBuilder(
    column: $table.settingValue,
    builder: (column) => column,
  );
}

class $$AppSettingEntriesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $AppSettingEntriesTable,
          DeviceSetting,
          $$AppSettingEntriesTableFilterComposer,
          $$AppSettingEntriesTableOrderingComposer,
          $$AppSettingEntriesTableAnnotationComposer,
          $$AppSettingEntriesTableCreateCompanionBuilder,
          $$AppSettingEntriesTableUpdateCompanionBuilder,
          (
            DeviceSetting,
            BaseReferences<
              _$AppDatabase,
              $AppSettingEntriesTable,
              DeviceSetting
            >,
          ),
          DeviceSetting,
          PrefetchHooks Function()
        > {
  $$AppSettingEntriesTableTableManager(
    _$AppDatabase db,
    $AppSettingEntriesTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$AppSettingEntriesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$AppSettingEntriesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$AppSettingEntriesTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> settingKey = const Value.absent(),
                Value<String> settingValue = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => AppSettingEntriesCompanion(
                settingKey: settingKey,
                settingValue: settingValue,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String settingKey,
                required String settingValue,
                Value<int> rowid = const Value.absent(),
              }) => AppSettingEntriesCompanion.insert(
                settingKey: settingKey,
                settingValue: settingValue,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$AppSettingEntriesTable, DeviceSetting>(table),
                  BaseReferences<
                    _$AppDatabase,
                    $AppSettingEntriesTable,
                    DeviceSetting
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$AppSettingEntriesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $AppSettingEntriesTable,
      DeviceSetting,
      $$AppSettingEntriesTableFilterComposer,
      $$AppSettingEntriesTableOrderingComposer,
      $$AppSettingEntriesTableAnnotationComposer,
      $$AppSettingEntriesTableCreateCompanionBuilder,
      $$AppSettingEntriesTableUpdateCompanionBuilder,
      (
        DeviceSetting,
        BaseReferences<_$AppDatabase, $AppSettingEntriesTable, DeviceSetting>,
      ),
      DeviceSetting,
      PrefetchHooks Function()
    >;
typedef $$ComposerDraftEntriesTableCreateCompanionBuilder =
    ComposerDraftEntriesCompanion Function({
      required String draftId,
      required String uid,
      required String draftText,
      Value<String> pollJson,
      Value<String> replyPolicy,
      Value<bool> paidPartnership,
      Value<bool> madeWithAi,
      Value<String> communityId,
      required DateTime createdAt,
      required DateTime updatedAt,
      Value<String?> sendKey,
      Value<String?> sendKind,
      Value<DateTime?> sendPublishAt,
      Value<DateTime?> sendStartedAt,
      Value<int> rowid,
    });
typedef $$ComposerDraftEntriesTableUpdateCompanionBuilder =
    ComposerDraftEntriesCompanion Function({
      Value<String> draftId,
      Value<String> uid,
      Value<String> draftText,
      Value<String> pollJson,
      Value<String> replyPolicy,
      Value<bool> paidPartnership,
      Value<bool> madeWithAi,
      Value<String> communityId,
      Value<DateTime> createdAt,
      Value<DateTime> updatedAt,
      Value<String?> sendKey,
      Value<String?> sendKind,
      Value<DateTime?> sendPublishAt,
      Value<DateTime?> sendStartedAt,
      Value<int> rowid,
    });

class $$ComposerDraftEntriesTableFilterComposer
    extends Composer<_$AppDatabase, $ComposerDraftEntriesTable> {
  $$ComposerDraftEntriesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get draftId => $composableBuilder(
    column: $table.draftId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get uid => $composableBuilder(
    column: $table.uid,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get draftText => $composableBuilder(
    column: $table.draftText,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get pollJson => $composableBuilder(
    column: $table.pollJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get replyPolicy => $composableBuilder(
    column: $table.replyPolicy,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get paidPartnership => $composableBuilder(
    column: $table.paidPartnership,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get madeWithAi => $composableBuilder(
    column: $table.madeWithAi,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get communityId => $composableBuilder(
    column: $table.communityId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get sendKey => $composableBuilder(
    column: $table.sendKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get sendKind => $composableBuilder(
    column: $table.sendKind,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get sendPublishAt => $composableBuilder(
    column: $table.sendPublishAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get sendStartedAt => $composableBuilder(
    column: $table.sendStartedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$ComposerDraftEntriesTableOrderingComposer
    extends Composer<_$AppDatabase, $ComposerDraftEntriesTable> {
  $$ComposerDraftEntriesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get draftId => $composableBuilder(
    column: $table.draftId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get uid => $composableBuilder(
    column: $table.uid,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get draftText => $composableBuilder(
    column: $table.draftText,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get pollJson => $composableBuilder(
    column: $table.pollJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get replyPolicy => $composableBuilder(
    column: $table.replyPolicy,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get paidPartnership => $composableBuilder(
    column: $table.paidPartnership,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get madeWithAi => $composableBuilder(
    column: $table.madeWithAi,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get communityId => $composableBuilder(
    column: $table.communityId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get sendKey => $composableBuilder(
    column: $table.sendKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get sendKind => $composableBuilder(
    column: $table.sendKind,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get sendPublishAt => $composableBuilder(
    column: $table.sendPublishAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get sendStartedAt => $composableBuilder(
    column: $table.sendStartedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$ComposerDraftEntriesTableAnnotationComposer
    extends Composer<_$AppDatabase, $ComposerDraftEntriesTable> {
  $$ComposerDraftEntriesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get draftId =>
      $composableBuilder(column: $table.draftId, builder: (column) => column);

  GeneratedColumn<String> get uid =>
      $composableBuilder(column: $table.uid, builder: (column) => column);

  GeneratedColumn<String> get draftText =>
      $composableBuilder(column: $table.draftText, builder: (column) => column);

  GeneratedColumn<String> get pollJson =>
      $composableBuilder(column: $table.pollJson, builder: (column) => column);

  GeneratedColumn<String> get replyPolicy => $composableBuilder(
    column: $table.replyPolicy,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get paidPartnership => $composableBuilder(
    column: $table.paidPartnership,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get madeWithAi => $composableBuilder(
    column: $table.madeWithAi,
    builder: (column) => column,
  );

  GeneratedColumn<String> get communityId => $composableBuilder(
    column: $table.communityId,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  GeneratedColumn<String> get sendKey =>
      $composableBuilder(column: $table.sendKey, builder: (column) => column);

  GeneratedColumn<String> get sendKind =>
      $composableBuilder(column: $table.sendKind, builder: (column) => column);

  GeneratedColumn<DateTime> get sendPublishAt => $composableBuilder(
    column: $table.sendPublishAt,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get sendStartedAt => $composableBuilder(
    column: $table.sendStartedAt,
    builder: (column) => column,
  );
}

class $$ComposerDraftEntriesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $ComposerDraftEntriesTable,
          ComposerDraftRow,
          $$ComposerDraftEntriesTableFilterComposer,
          $$ComposerDraftEntriesTableOrderingComposer,
          $$ComposerDraftEntriesTableAnnotationComposer,
          $$ComposerDraftEntriesTableCreateCompanionBuilder,
          $$ComposerDraftEntriesTableUpdateCompanionBuilder,
          (
            ComposerDraftRow,
            BaseReferences<
              _$AppDatabase,
              $ComposerDraftEntriesTable,
              ComposerDraftRow
            >,
          ),
          ComposerDraftRow,
          PrefetchHooks Function()
        > {
  $$ComposerDraftEntriesTableTableManager(
    _$AppDatabase db,
    $ComposerDraftEntriesTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ComposerDraftEntriesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ComposerDraftEntriesTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              $$ComposerDraftEntriesTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> draftId = const Value.absent(),
                Value<String> uid = const Value.absent(),
                Value<String> draftText = const Value.absent(),
                Value<String> pollJson = const Value.absent(),
                Value<String> replyPolicy = const Value.absent(),
                Value<bool> paidPartnership = const Value.absent(),
                Value<bool> madeWithAi = const Value.absent(),
                Value<String> communityId = const Value.absent(),
                Value<DateTime> createdAt = const Value.absent(),
                Value<DateTime> updatedAt = const Value.absent(),
                Value<String?> sendKey = const Value.absent(),
                Value<String?> sendKind = const Value.absent(),
                Value<DateTime?> sendPublishAt = const Value.absent(),
                Value<DateTime?> sendStartedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ComposerDraftEntriesCompanion(
                draftId: draftId,
                uid: uid,
                draftText: draftText,
                pollJson: pollJson,
                replyPolicy: replyPolicy,
                paidPartnership: paidPartnership,
                madeWithAi: madeWithAi,
                communityId: communityId,
                createdAt: createdAt,
                updatedAt: updatedAt,
                sendKey: sendKey,
                sendKind: sendKind,
                sendPublishAt: sendPublishAt,
                sendStartedAt: sendStartedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String draftId,
                required String uid,
                required String draftText,
                Value<String> pollJson = const Value.absent(),
                Value<String> replyPolicy = const Value.absent(),
                Value<bool> paidPartnership = const Value.absent(),
                Value<bool> madeWithAi = const Value.absent(),
                Value<String> communityId = const Value.absent(),
                required DateTime createdAt,
                required DateTime updatedAt,
                Value<String?> sendKey = const Value.absent(),
                Value<String?> sendKind = const Value.absent(),
                Value<DateTime?> sendPublishAt = const Value.absent(),
                Value<DateTime?> sendStartedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ComposerDraftEntriesCompanion.insert(
                draftId: draftId,
                uid: uid,
                draftText: draftText,
                pollJson: pollJson,
                replyPolicy: replyPolicy,
                paidPartnership: paidPartnership,
                madeWithAi: madeWithAi,
                communityId: communityId,
                createdAt: createdAt,
                updatedAt: updatedAt,
                sendKey: sendKey,
                sendKind: sendKind,
                sendPublishAt: sendPublishAt,
                sendStartedAt: sendStartedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$ComposerDraftEntriesTable, ComposerDraftRow>(
                    table,
                  ),
                  BaseReferences<
                    _$AppDatabase,
                    $ComposerDraftEntriesTable,
                    ComposerDraftRow
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$ComposerDraftEntriesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $ComposerDraftEntriesTable,
      ComposerDraftRow,
      $$ComposerDraftEntriesTableFilterComposer,
      $$ComposerDraftEntriesTableOrderingComposer,
      $$ComposerDraftEntriesTableAnnotationComposer,
      $$ComposerDraftEntriesTableCreateCompanionBuilder,
      $$ComposerDraftEntriesTableUpdateCompanionBuilder,
      (
        ComposerDraftRow,
        BaseReferences<
          _$AppDatabase,
          $ComposerDraftEntriesTable,
          ComposerDraftRow
        >,
      ),
      ComposerDraftRow,
      PrefetchHooks Function()
    >;
typedef $$PostHistoryEntriesTableCreateCompanionBuilder =
    PostHistoryEntriesCompanion Function({
      required String uid,
      required String postId,
      required int openedAtMs,
      Value<int> rowid,
    });
typedef $$PostHistoryEntriesTableUpdateCompanionBuilder =
    PostHistoryEntriesCompanion Function({
      Value<String> uid,
      Value<String> postId,
      Value<int> openedAtMs,
      Value<int> rowid,
    });

class $$PostHistoryEntriesTableFilterComposer
    extends Composer<_$AppDatabase, $PostHistoryEntriesTable> {
  $$PostHistoryEntriesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get uid => $composableBuilder(
    column: $table.uid,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get postId => $composableBuilder(
    column: $table.postId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get openedAtMs => $composableBuilder(
    column: $table.openedAtMs,
    builder: (column) => ColumnFilters(column),
  );
}

class $$PostHistoryEntriesTableOrderingComposer
    extends Composer<_$AppDatabase, $PostHistoryEntriesTable> {
  $$PostHistoryEntriesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get uid => $composableBuilder(
    column: $table.uid,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get postId => $composableBuilder(
    column: $table.postId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get openedAtMs => $composableBuilder(
    column: $table.openedAtMs,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$PostHistoryEntriesTableAnnotationComposer
    extends Composer<_$AppDatabase, $PostHistoryEntriesTable> {
  $$PostHistoryEntriesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get uid =>
      $composableBuilder(column: $table.uid, builder: (column) => column);

  GeneratedColumn<String> get postId =>
      $composableBuilder(column: $table.postId, builder: (column) => column);

  GeneratedColumn<int> get openedAtMs => $composableBuilder(
    column: $table.openedAtMs,
    builder: (column) => column,
  );
}

class $$PostHistoryEntriesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $PostHistoryEntriesTable,
          PostHistoryRow,
          $$PostHistoryEntriesTableFilterComposer,
          $$PostHistoryEntriesTableOrderingComposer,
          $$PostHistoryEntriesTableAnnotationComposer,
          $$PostHistoryEntriesTableCreateCompanionBuilder,
          $$PostHistoryEntriesTableUpdateCompanionBuilder,
          (
            PostHistoryRow,
            BaseReferences<
              _$AppDatabase,
              $PostHistoryEntriesTable,
              PostHistoryRow
            >,
          ),
          PostHistoryRow,
          PrefetchHooks Function()
        > {
  $$PostHistoryEntriesTableTableManager(
    _$AppDatabase db,
    $PostHistoryEntriesTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$PostHistoryEntriesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$PostHistoryEntriesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$PostHistoryEntriesTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> uid = const Value.absent(),
                Value<String> postId = const Value.absent(),
                Value<int> openedAtMs = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => PostHistoryEntriesCompanion(
                uid: uid,
                postId: postId,
                openedAtMs: openedAtMs,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String uid,
                required String postId,
                required int openedAtMs,
                Value<int> rowid = const Value.absent(),
              }) => PostHistoryEntriesCompanion.insert(
                uid: uid,
                postId: postId,
                openedAtMs: openedAtMs,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$PostHistoryEntriesTable, PostHistoryRow>(table),
                  BaseReferences<
                    _$AppDatabase,
                    $PostHistoryEntriesTable,
                    PostHistoryRow
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$PostHistoryEntriesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $PostHistoryEntriesTable,
      PostHistoryRow,
      $$PostHistoryEntriesTableFilterComposer,
      $$PostHistoryEntriesTableOrderingComposer,
      $$PostHistoryEntriesTableAnnotationComposer,
      $$PostHistoryEntriesTableCreateCompanionBuilder,
      $$PostHistoryEntriesTableUpdateCompanionBuilder,
      (
        PostHistoryRow,
        BaseReferences<_$AppDatabase, $PostHistoryEntriesTable, PostHistoryRow>,
      ),
      PostHistoryRow,
      PrefetchHooks Function()
    >;
typedef $$UnsentPostEntriesTableCreateCompanionBuilder =
    UnsentPostEntriesCompanion Function({
      required String uid,
      required String postId,
      Value<String> postText,
      Value<String> pollJson,
      Value<String> replyAudience,
      Value<int> policyValue,
      Value<String> communityId,
      Value<String> beaconId,
      Value<bool> isGif,
      Value<String?> draftId,
      Value<String?> deleteDraftId,
      required Uint8List authorBytes,
      Value<String?> sendKey,
      Value<DateTime?> keyStartedAt,
      Value<bool> keyUsed,
      Value<bool> keyAmbiguous,
      Value<bool> claimReused,
      Value<bool> photosKept,
      Value<int> photoCount,
      required DateTime createdAt,
      Value<int> rowid,
    });
typedef $$UnsentPostEntriesTableUpdateCompanionBuilder =
    UnsentPostEntriesCompanion Function({
      Value<String> uid,
      Value<String> postId,
      Value<String> postText,
      Value<String> pollJson,
      Value<String> replyAudience,
      Value<int> policyValue,
      Value<String> communityId,
      Value<String> beaconId,
      Value<bool> isGif,
      Value<String?> draftId,
      Value<String?> deleteDraftId,
      Value<Uint8List> authorBytes,
      Value<String?> sendKey,
      Value<DateTime?> keyStartedAt,
      Value<bool> keyUsed,
      Value<bool> keyAmbiguous,
      Value<bool> claimReused,
      Value<bool> photosKept,
      Value<int> photoCount,
      Value<DateTime> createdAt,
      Value<int> rowid,
    });

class $$UnsentPostEntriesTableFilterComposer
    extends Composer<_$AppDatabase, $UnsentPostEntriesTable> {
  $$UnsentPostEntriesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get uid => $composableBuilder(
    column: $table.uid,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get postId => $composableBuilder(
    column: $table.postId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get postText => $composableBuilder(
    column: $table.postText,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get pollJson => $composableBuilder(
    column: $table.pollJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get replyAudience => $composableBuilder(
    column: $table.replyAudience,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get policyValue => $composableBuilder(
    column: $table.policyValue,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get communityId => $composableBuilder(
    column: $table.communityId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get beaconId => $composableBuilder(
    column: $table.beaconId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get isGif => $composableBuilder(
    column: $table.isGif,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get draftId => $composableBuilder(
    column: $table.draftId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get deleteDraftId => $composableBuilder(
    column: $table.deleteDraftId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<Uint8List> get authorBytes => $composableBuilder(
    column: $table.authorBytes,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get sendKey => $composableBuilder(
    column: $table.sendKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get keyStartedAt => $composableBuilder(
    column: $table.keyStartedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get keyUsed => $composableBuilder(
    column: $table.keyUsed,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get keyAmbiguous => $composableBuilder(
    column: $table.keyAmbiguous,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get claimReused => $composableBuilder(
    column: $table.claimReused,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get photosKept => $composableBuilder(
    column: $table.photosKept,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get photoCount => $composableBuilder(
    column: $table.photoCount,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$UnsentPostEntriesTableOrderingComposer
    extends Composer<_$AppDatabase, $UnsentPostEntriesTable> {
  $$UnsentPostEntriesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get uid => $composableBuilder(
    column: $table.uid,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get postId => $composableBuilder(
    column: $table.postId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get postText => $composableBuilder(
    column: $table.postText,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get pollJson => $composableBuilder(
    column: $table.pollJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get replyAudience => $composableBuilder(
    column: $table.replyAudience,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get policyValue => $composableBuilder(
    column: $table.policyValue,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get communityId => $composableBuilder(
    column: $table.communityId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get beaconId => $composableBuilder(
    column: $table.beaconId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get isGif => $composableBuilder(
    column: $table.isGif,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get draftId => $composableBuilder(
    column: $table.draftId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get deleteDraftId => $composableBuilder(
    column: $table.deleteDraftId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<Uint8List> get authorBytes => $composableBuilder(
    column: $table.authorBytes,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get sendKey => $composableBuilder(
    column: $table.sendKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get keyStartedAt => $composableBuilder(
    column: $table.keyStartedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get keyUsed => $composableBuilder(
    column: $table.keyUsed,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get keyAmbiguous => $composableBuilder(
    column: $table.keyAmbiguous,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get claimReused => $composableBuilder(
    column: $table.claimReused,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get photosKept => $composableBuilder(
    column: $table.photosKept,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get photoCount => $composableBuilder(
    column: $table.photoCount,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$UnsentPostEntriesTableAnnotationComposer
    extends Composer<_$AppDatabase, $UnsentPostEntriesTable> {
  $$UnsentPostEntriesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get uid =>
      $composableBuilder(column: $table.uid, builder: (column) => column);

  GeneratedColumn<String> get postId =>
      $composableBuilder(column: $table.postId, builder: (column) => column);

  GeneratedColumn<String> get postText =>
      $composableBuilder(column: $table.postText, builder: (column) => column);

  GeneratedColumn<String> get pollJson =>
      $composableBuilder(column: $table.pollJson, builder: (column) => column);

  GeneratedColumn<String> get replyAudience => $composableBuilder(
    column: $table.replyAudience,
    builder: (column) => column,
  );

  GeneratedColumn<int> get policyValue => $composableBuilder(
    column: $table.policyValue,
    builder: (column) => column,
  );

  GeneratedColumn<String> get communityId => $composableBuilder(
    column: $table.communityId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get beaconId =>
      $composableBuilder(column: $table.beaconId, builder: (column) => column);

  GeneratedColumn<bool> get isGif =>
      $composableBuilder(column: $table.isGif, builder: (column) => column);

  GeneratedColumn<String> get draftId =>
      $composableBuilder(column: $table.draftId, builder: (column) => column);

  GeneratedColumn<String> get deleteDraftId => $composableBuilder(
    column: $table.deleteDraftId,
    builder: (column) => column,
  );

  GeneratedColumn<Uint8List> get authorBytes => $composableBuilder(
    column: $table.authorBytes,
    builder: (column) => column,
  );

  GeneratedColumn<String> get sendKey =>
      $composableBuilder(column: $table.sendKey, builder: (column) => column);

  GeneratedColumn<DateTime> get keyStartedAt => $composableBuilder(
    column: $table.keyStartedAt,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get keyUsed =>
      $composableBuilder(column: $table.keyUsed, builder: (column) => column);

  GeneratedColumn<bool> get keyAmbiguous => $composableBuilder(
    column: $table.keyAmbiguous,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get claimReused => $composableBuilder(
    column: $table.claimReused,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get photosKept => $composableBuilder(
    column: $table.photosKept,
    builder: (column) => column,
  );

  GeneratedColumn<int> get photoCount => $composableBuilder(
    column: $table.photoCount,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);
}

class $$UnsentPostEntriesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $UnsentPostEntriesTable,
          UnsentPostRow,
          $$UnsentPostEntriesTableFilterComposer,
          $$UnsentPostEntriesTableOrderingComposer,
          $$UnsentPostEntriesTableAnnotationComposer,
          $$UnsentPostEntriesTableCreateCompanionBuilder,
          $$UnsentPostEntriesTableUpdateCompanionBuilder,
          (
            UnsentPostRow,
            BaseReferences<
              _$AppDatabase,
              $UnsentPostEntriesTable,
              UnsentPostRow
            >,
          ),
          UnsentPostRow,
          PrefetchHooks Function()
        > {
  $$UnsentPostEntriesTableTableManager(
    _$AppDatabase db,
    $UnsentPostEntriesTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$UnsentPostEntriesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$UnsentPostEntriesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$UnsentPostEntriesTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> uid = const Value.absent(),
                Value<String> postId = const Value.absent(),
                Value<String> postText = const Value.absent(),
                Value<String> pollJson = const Value.absent(),
                Value<String> replyAudience = const Value.absent(),
                Value<int> policyValue = const Value.absent(),
                Value<String> communityId = const Value.absent(),
                Value<String> beaconId = const Value.absent(),
                Value<bool> isGif = const Value.absent(),
                Value<String?> draftId = const Value.absent(),
                Value<String?> deleteDraftId = const Value.absent(),
                Value<Uint8List> authorBytes = const Value.absent(),
                Value<String?> sendKey = const Value.absent(),
                Value<DateTime?> keyStartedAt = const Value.absent(),
                Value<bool> keyUsed = const Value.absent(),
                Value<bool> keyAmbiguous = const Value.absent(),
                Value<bool> claimReused = const Value.absent(),
                Value<bool> photosKept = const Value.absent(),
                Value<int> photoCount = const Value.absent(),
                Value<DateTime> createdAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => UnsentPostEntriesCompanion(
                uid: uid,
                postId: postId,
                postText: postText,
                pollJson: pollJson,
                replyAudience: replyAudience,
                policyValue: policyValue,
                communityId: communityId,
                beaconId: beaconId,
                isGif: isGif,
                draftId: draftId,
                deleteDraftId: deleteDraftId,
                authorBytes: authorBytes,
                sendKey: sendKey,
                keyStartedAt: keyStartedAt,
                keyUsed: keyUsed,
                keyAmbiguous: keyAmbiguous,
                claimReused: claimReused,
                photosKept: photosKept,
                photoCount: photoCount,
                createdAt: createdAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String uid,
                required String postId,
                Value<String> postText = const Value.absent(),
                Value<String> pollJson = const Value.absent(),
                Value<String> replyAudience = const Value.absent(),
                Value<int> policyValue = const Value.absent(),
                Value<String> communityId = const Value.absent(),
                Value<String> beaconId = const Value.absent(),
                Value<bool> isGif = const Value.absent(),
                Value<String?> draftId = const Value.absent(),
                Value<String?> deleteDraftId = const Value.absent(),
                required Uint8List authorBytes,
                Value<String?> sendKey = const Value.absent(),
                Value<DateTime?> keyStartedAt = const Value.absent(),
                Value<bool> keyUsed = const Value.absent(),
                Value<bool> keyAmbiguous = const Value.absent(),
                Value<bool> claimReused = const Value.absent(),
                Value<bool> photosKept = const Value.absent(),
                Value<int> photoCount = const Value.absent(),
                required DateTime createdAt,
                Value<int> rowid = const Value.absent(),
              }) => UnsentPostEntriesCompanion.insert(
                uid: uid,
                postId: postId,
                postText: postText,
                pollJson: pollJson,
                replyAudience: replyAudience,
                policyValue: policyValue,
                communityId: communityId,
                beaconId: beaconId,
                isGif: isGif,
                draftId: draftId,
                deleteDraftId: deleteDraftId,
                authorBytes: authorBytes,
                sendKey: sendKey,
                keyStartedAt: keyStartedAt,
                keyUsed: keyUsed,
                keyAmbiguous: keyAmbiguous,
                claimReused: claimReused,
                photosKept: photosKept,
                photoCount: photoCount,
                createdAt: createdAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$UnsentPostEntriesTable, UnsentPostRow>(table),
                  BaseReferences<
                    _$AppDatabase,
                    $UnsentPostEntriesTable,
                    UnsentPostRow
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$UnsentPostEntriesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $UnsentPostEntriesTable,
      UnsentPostRow,
      $$UnsentPostEntriesTableFilterComposer,
      $$UnsentPostEntriesTableOrderingComposer,
      $$UnsentPostEntriesTableAnnotationComposer,
      $$UnsentPostEntriesTableCreateCompanionBuilder,
      $$UnsentPostEntriesTableUpdateCompanionBuilder,
      (
        UnsentPostRow,
        BaseReferences<_$AppDatabase, $UnsentPostEntriesTable, UnsentPostRow>,
      ),
      UnsentPostRow,
      PrefetchHooks Function()
    >;
typedef $$UnsentPostPhotoEntriesTableCreateCompanionBuilder =
    UnsentPostPhotoEntriesCompanion Function({
      required String uid,
      required String postId,
      required int position,
      required Uint8List fullBytes,
      required Uint8List thumbBytes,
      required int width,
      required int height,
      required String fullMd5,
      required String thumbMd5,
      required String blurhash,
      required String contentType,
      Value<String> thumbContentType,
      Value<String> altText,
      Value<int> rowid,
    });
typedef $$UnsentPostPhotoEntriesTableUpdateCompanionBuilder =
    UnsentPostPhotoEntriesCompanion Function({
      Value<String> uid,
      Value<String> postId,
      Value<int> position,
      Value<Uint8List> fullBytes,
      Value<Uint8List> thumbBytes,
      Value<int> width,
      Value<int> height,
      Value<String> fullMd5,
      Value<String> thumbMd5,
      Value<String> blurhash,
      Value<String> contentType,
      Value<String> thumbContentType,
      Value<String> altText,
      Value<int> rowid,
    });

class $$UnsentPostPhotoEntriesTableFilterComposer
    extends Composer<_$AppDatabase, $UnsentPostPhotoEntriesTable> {
  $$UnsentPostPhotoEntriesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get uid => $composableBuilder(
    column: $table.uid,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get postId => $composableBuilder(
    column: $table.postId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get position => $composableBuilder(
    column: $table.position,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<Uint8List> get fullBytes => $composableBuilder(
    column: $table.fullBytes,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<Uint8List> get thumbBytes => $composableBuilder(
    column: $table.thumbBytes,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get width => $composableBuilder(
    column: $table.width,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get height => $composableBuilder(
    column: $table.height,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get fullMd5 => $composableBuilder(
    column: $table.fullMd5,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get thumbMd5 => $composableBuilder(
    column: $table.thumbMd5,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get blurhash => $composableBuilder(
    column: $table.blurhash,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get contentType => $composableBuilder(
    column: $table.contentType,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get thumbContentType => $composableBuilder(
    column: $table.thumbContentType,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get altText => $composableBuilder(
    column: $table.altText,
    builder: (column) => ColumnFilters(column),
  );
}

class $$UnsentPostPhotoEntriesTableOrderingComposer
    extends Composer<_$AppDatabase, $UnsentPostPhotoEntriesTable> {
  $$UnsentPostPhotoEntriesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get uid => $composableBuilder(
    column: $table.uid,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get postId => $composableBuilder(
    column: $table.postId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get position => $composableBuilder(
    column: $table.position,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<Uint8List> get fullBytes => $composableBuilder(
    column: $table.fullBytes,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<Uint8List> get thumbBytes => $composableBuilder(
    column: $table.thumbBytes,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get width => $composableBuilder(
    column: $table.width,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get height => $composableBuilder(
    column: $table.height,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get fullMd5 => $composableBuilder(
    column: $table.fullMd5,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get thumbMd5 => $composableBuilder(
    column: $table.thumbMd5,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get blurhash => $composableBuilder(
    column: $table.blurhash,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get contentType => $composableBuilder(
    column: $table.contentType,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get thumbContentType => $composableBuilder(
    column: $table.thumbContentType,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get altText => $composableBuilder(
    column: $table.altText,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$UnsentPostPhotoEntriesTableAnnotationComposer
    extends Composer<_$AppDatabase, $UnsentPostPhotoEntriesTable> {
  $$UnsentPostPhotoEntriesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get uid =>
      $composableBuilder(column: $table.uid, builder: (column) => column);

  GeneratedColumn<String> get postId =>
      $composableBuilder(column: $table.postId, builder: (column) => column);

  GeneratedColumn<int> get position =>
      $composableBuilder(column: $table.position, builder: (column) => column);

  GeneratedColumn<Uint8List> get fullBytes =>
      $composableBuilder(column: $table.fullBytes, builder: (column) => column);

  GeneratedColumn<Uint8List> get thumbBytes => $composableBuilder(
    column: $table.thumbBytes,
    builder: (column) => column,
  );

  GeneratedColumn<int> get width =>
      $composableBuilder(column: $table.width, builder: (column) => column);

  GeneratedColumn<int> get height =>
      $composableBuilder(column: $table.height, builder: (column) => column);

  GeneratedColumn<String> get fullMd5 =>
      $composableBuilder(column: $table.fullMd5, builder: (column) => column);

  GeneratedColumn<String> get thumbMd5 =>
      $composableBuilder(column: $table.thumbMd5, builder: (column) => column);

  GeneratedColumn<String> get blurhash =>
      $composableBuilder(column: $table.blurhash, builder: (column) => column);

  GeneratedColumn<String> get contentType => $composableBuilder(
    column: $table.contentType,
    builder: (column) => column,
  );

  GeneratedColumn<String> get thumbContentType => $composableBuilder(
    column: $table.thumbContentType,
    builder: (column) => column,
  );

  GeneratedColumn<String> get altText =>
      $composableBuilder(column: $table.altText, builder: (column) => column);
}

class $$UnsentPostPhotoEntriesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $UnsentPostPhotoEntriesTable,
          UnsentPostPhotoRow,
          $$UnsentPostPhotoEntriesTableFilterComposer,
          $$UnsentPostPhotoEntriesTableOrderingComposer,
          $$UnsentPostPhotoEntriesTableAnnotationComposer,
          $$UnsentPostPhotoEntriesTableCreateCompanionBuilder,
          $$UnsentPostPhotoEntriesTableUpdateCompanionBuilder,
          (
            UnsentPostPhotoRow,
            BaseReferences<
              _$AppDatabase,
              $UnsentPostPhotoEntriesTable,
              UnsentPostPhotoRow
            >,
          ),
          UnsentPostPhotoRow,
          PrefetchHooks Function()
        > {
  $$UnsentPostPhotoEntriesTableTableManager(
    _$AppDatabase db,
    $UnsentPostPhotoEntriesTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$UnsentPostPhotoEntriesTableFilterComposer(
                $db: db,
                $table: table,
              ),
          createOrderingComposer: () =>
              $$UnsentPostPhotoEntriesTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              $$UnsentPostPhotoEntriesTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> uid = const Value.absent(),
                Value<String> postId = const Value.absent(),
                Value<int> position = const Value.absent(),
                Value<Uint8List> fullBytes = const Value.absent(),
                Value<Uint8List> thumbBytes = const Value.absent(),
                Value<int> width = const Value.absent(),
                Value<int> height = const Value.absent(),
                Value<String> fullMd5 = const Value.absent(),
                Value<String> thumbMd5 = const Value.absent(),
                Value<String> blurhash = const Value.absent(),
                Value<String> contentType = const Value.absent(),
                Value<String> thumbContentType = const Value.absent(),
                Value<String> altText = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => UnsentPostPhotoEntriesCompanion(
                uid: uid,
                postId: postId,
                position: position,
                fullBytes: fullBytes,
                thumbBytes: thumbBytes,
                width: width,
                height: height,
                fullMd5: fullMd5,
                thumbMd5: thumbMd5,
                blurhash: blurhash,
                contentType: contentType,
                thumbContentType: thumbContentType,
                altText: altText,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String uid,
                required String postId,
                required int position,
                required Uint8List fullBytes,
                required Uint8List thumbBytes,
                required int width,
                required int height,
                required String fullMd5,
                required String thumbMd5,
                required String blurhash,
                required String contentType,
                Value<String> thumbContentType = const Value.absent(),
                Value<String> altText = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => UnsentPostPhotoEntriesCompanion.insert(
                uid: uid,
                postId: postId,
                position: position,
                fullBytes: fullBytes,
                thumbBytes: thumbBytes,
                width: width,
                height: height,
                fullMd5: fullMd5,
                thumbMd5: thumbMd5,
                blurhash: blurhash,
                contentType: contentType,
                thumbContentType: thumbContentType,
                altText: altText,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$UnsentPostPhotoEntriesTable, UnsentPostPhotoRow>(
                    table,
                  ),
                  BaseReferences<
                    _$AppDatabase,
                    $UnsentPostPhotoEntriesTable,
                    UnsentPostPhotoRow
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$UnsentPostPhotoEntriesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $UnsentPostPhotoEntriesTable,
      UnsentPostPhotoRow,
      $$UnsentPostPhotoEntriesTableFilterComposer,
      $$UnsentPostPhotoEntriesTableOrderingComposer,
      $$UnsentPostPhotoEntriesTableAnnotationComposer,
      $$UnsentPostPhotoEntriesTableCreateCompanionBuilder,
      $$UnsentPostPhotoEntriesTableUpdateCompanionBuilder,
      (
        UnsentPostPhotoRow,
        BaseReferences<
          _$AppDatabase,
          $UnsentPostPhotoEntriesTable,
          UnsentPostPhotoRow
        >,
      ),
      UnsentPostPhotoRow,
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
  $$NotificationEntriesTableTableManager get notificationEntries =>
      $$NotificationEntriesTableTableManager(_db, _db.notificationEntries);
  $$NotificationStateEntriesTableTableManager get notificationStateEntries =>
      $$NotificationStateEntriesTableTableManager(
        _db,
        _db.notificationStateEntries,
      );
  $$ConversationEntriesTableTableManager get conversationEntries =>
      $$ConversationEntriesTableTableManager(_db, _db.conversationEntries);
  $$MessageEntriesTableTableManager get messageEntries =>
      $$MessageEntriesTableTableManager(_db, _db.messageEntries);
  $$MessagingStateEntriesTableTableManager get messagingStateEntries =>
      $$MessagingStateEntriesTableTableManager(_db, _db.messagingStateEntries);
  $$AppSettingEntriesTableTableManager get appSettingEntries =>
      $$AppSettingEntriesTableTableManager(_db, _db.appSettingEntries);
  $$ComposerDraftEntriesTableTableManager get composerDraftEntries =>
      $$ComposerDraftEntriesTableTableManager(_db, _db.composerDraftEntries);
  $$PostHistoryEntriesTableTableManager get postHistoryEntries =>
      $$PostHistoryEntriesTableTableManager(_db, _db.postHistoryEntries);
  $$UnsentPostEntriesTableTableManager get unsentPostEntries =>
      $$UnsentPostEntriesTableTableManager(_db, _db.unsentPostEntries);
  $$UnsentPostPhotoEntriesTableTableManager get unsentPostPhotoEntries =>
      $$UnsentPostPhotoEntriesTableTableManager(
        _db,
        _db.unsentPostPhotoEntries,
      );
}
