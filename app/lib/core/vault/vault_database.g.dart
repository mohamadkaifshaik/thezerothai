// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'vault_database.dart';

// ignore_for_file: type=lint
class $VaultMetaTable extends VaultMeta
    with TableInfo<$VaultMetaTable, VaultMetaRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $VaultMetaTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _metaKeyMeta = const VerificationMeta(
    'metaKey',
  );
  @override
  late final GeneratedColumn<String> metaKey = GeneratedColumn<String>(
    'meta_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _ownerUidMeta = const VerificationMeta(
    'ownerUid',
  );
  @override
  late final GeneratedColumn<String> ownerUid = GeneratedColumn<String>(
    'owner_uid',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _schemaVersionMeta = const VerificationMeta(
    'schemaVersion',
  );
  @override
  late final GeneratedColumn<int> schemaVersion = GeneratedColumn<int>(
    'schema_version',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sentinelMeta = const VerificationMeta(
    'sentinel',
  );
  @override
  late final GeneratedColumn<Uint8List> sentinel = GeneratedColumn<Uint8List>(
    'sentinel',
    aliasedName,
    false,
    type: DriftSqlType.blob,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    metaKey,
    ownerUid,
    schemaVersion,
    sentinel,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'vault_meta';
  @override
  VerificationContext validateIntegrity(
    Insertable<VaultMetaRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('meta_key')) {
      context.handle(
        _metaKeyMeta,
        metaKey.isAcceptableOrUnknown(data['meta_key']!, _metaKeyMeta),
      );
    } else if (isInserting) {
      context.missing(_metaKeyMeta);
    }
    if (data.containsKey('owner_uid')) {
      context.handle(
        _ownerUidMeta,
        ownerUid.isAcceptableOrUnknown(data['owner_uid']!, _ownerUidMeta),
      );
    } else if (isInserting) {
      context.missing(_ownerUidMeta);
    }
    if (data.containsKey('schema_version')) {
      context.handle(
        _schemaVersionMeta,
        schemaVersion.isAcceptableOrUnknown(
          data['schema_version']!,
          _schemaVersionMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_schemaVersionMeta);
    }
    if (data.containsKey('sentinel')) {
      context.handle(
        _sentinelMeta,
        sentinel.isAcceptableOrUnknown(data['sentinel']!, _sentinelMeta),
      );
    } else if (isInserting) {
      context.missing(_sentinelMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {metaKey};
  @override
  VaultMetaRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return VaultMetaRow(
      metaKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}meta_key'],
      )!,
      ownerUid: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}owner_uid'],
      )!,
      schemaVersion: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}schema_version'],
      )!,
      sentinel: attachedDatabase.typeMapping.read(
        DriftSqlType.blob,
        data['${effectivePrefix}sentinel'],
      )!,
    );
  }

  @override
  $VaultMetaTable createAlias(String alias) {
    return $VaultMetaTable(attachedDatabase, alias);
  }
}

class VaultMetaRow extends DataClass implements Insertable<VaultMetaRow> {
  final String metaKey;

  /// Clear: the uid that owns this file.
  final String ownerUid;

  /// Clear: the schema version the vault was stamped with.
  final int schemaVersion;

  /// Sealed: [kVaultSentinel].
  final Uint8List sentinel;
  const VaultMetaRow({
    required this.metaKey,
    required this.ownerUid,
    required this.schemaVersion,
    required this.sentinel,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['meta_key'] = Variable<String>(metaKey);
    map['owner_uid'] = Variable<String>(ownerUid);
    map['schema_version'] = Variable<int>(schemaVersion);
    map['sentinel'] = Variable<Uint8List>(sentinel);
    return map;
  }

  VaultMetaCompanion toCompanion(bool nullToAbsent) {
    return VaultMetaCompanion(
      metaKey: Value(metaKey),
      ownerUid: Value(ownerUid),
      schemaVersion: Value(schemaVersion),
      sentinel: Value(sentinel),
    );
  }

  factory VaultMetaRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return VaultMetaRow(
      metaKey: serializer.fromJson<String>(json['metaKey']),
      ownerUid: serializer.fromJson<String>(json['ownerUid']),
      schemaVersion: serializer.fromJson<int>(json['schemaVersion']),
      sentinel: serializer.fromJson<Uint8List>(json['sentinel']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'metaKey': serializer.toJson<String>(metaKey),
      'ownerUid': serializer.toJson<String>(ownerUid),
      'schemaVersion': serializer.toJson<int>(schemaVersion),
      'sentinel': serializer.toJson<Uint8List>(sentinel),
    };
  }

  VaultMetaRow copyWith({
    String? metaKey,
    String? ownerUid,
    int? schemaVersion,
    Uint8List? sentinel,
  }) => VaultMetaRow(
    metaKey: metaKey ?? this.metaKey,
    ownerUid: ownerUid ?? this.ownerUid,
    schemaVersion: schemaVersion ?? this.schemaVersion,
    sentinel: sentinel ?? this.sentinel,
  );
  VaultMetaRow copyWithCompanion(VaultMetaCompanion data) {
    return VaultMetaRow(
      metaKey: data.metaKey.present ? data.metaKey.value : this.metaKey,
      ownerUid: data.ownerUid.present ? data.ownerUid.value : this.ownerUid,
      schemaVersion: data.schemaVersion.present
          ? data.schemaVersion.value
          : this.schemaVersion,
      sentinel: data.sentinel.present ? data.sentinel.value : this.sentinel,
    );
  }

  @override
  String toString() {
    return (StringBuffer('VaultMetaRow(')
          ..write('metaKey: $metaKey, ')
          ..write('ownerUid: $ownerUid, ')
          ..write('schemaVersion: $schemaVersion, ')
          ..write('sentinel: $sentinel')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    metaKey,
    ownerUid,
    schemaVersion,
    $driftBlobEquality.hash(sentinel),
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is VaultMetaRow &&
          other.metaKey == this.metaKey &&
          other.ownerUid == this.ownerUid &&
          other.schemaVersion == this.schemaVersion &&
          $driftBlobEquality.equals(other.sentinel, this.sentinel));
}

class VaultMetaCompanion extends UpdateCompanion<VaultMetaRow> {
  final Value<String> metaKey;
  final Value<String> ownerUid;
  final Value<int> schemaVersion;
  final Value<Uint8List> sentinel;
  final Value<int> rowid;
  const VaultMetaCompanion({
    this.metaKey = const Value.absent(),
    this.ownerUid = const Value.absent(),
    this.schemaVersion = const Value.absent(),
    this.sentinel = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  VaultMetaCompanion.insert({
    required String metaKey,
    required String ownerUid,
    required int schemaVersion,
    required Uint8List sentinel,
    this.rowid = const Value.absent(),
  }) : metaKey = Value(metaKey),
       ownerUid = Value(ownerUid),
       schemaVersion = Value(schemaVersion),
       sentinel = Value(sentinel);
  static Insertable<VaultMetaRow> custom({
    Expression<String>? metaKey,
    Expression<String>? ownerUid,
    Expression<int>? schemaVersion,
    Expression<Uint8List>? sentinel,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (metaKey != null) 'meta_key': metaKey,
      if (ownerUid != null) 'owner_uid': ownerUid,
      if (schemaVersion != null) 'schema_version': schemaVersion,
      if (sentinel != null) 'sentinel': sentinel,
      if (rowid != null) 'rowid': rowid,
    });
  }

  VaultMetaCompanion copyWith({
    Value<String>? metaKey,
    Value<String>? ownerUid,
    Value<int>? schemaVersion,
    Value<Uint8List>? sentinel,
    Value<int>? rowid,
  }) {
    return VaultMetaCompanion(
      metaKey: metaKey ?? this.metaKey,
      ownerUid: ownerUid ?? this.ownerUid,
      schemaVersion: schemaVersion ?? this.schemaVersion,
      sentinel: sentinel ?? this.sentinel,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (metaKey.present) {
      map['meta_key'] = Variable<String>(metaKey.value);
    }
    if (ownerUid.present) {
      map['owner_uid'] = Variable<String>(ownerUid.value);
    }
    if (schemaVersion.present) {
      map['schema_version'] = Variable<int>(schemaVersion.value);
    }
    if (sentinel.present) {
      map['sentinel'] = Variable<Uint8List>(sentinel.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('VaultMetaCompanion(')
          ..write('metaKey: $metaKey, ')
          ..write('ownerUid: $ownerUid, ')
          ..write('schemaVersion: $schemaVersion, ')
          ..write('sentinel: $sentinel, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $VaultDeviceTable extends VaultDevice
    with TableInfo<$VaultDeviceTable, VaultDeviceRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $VaultDeviceTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _slotMeta = const VerificationMeta('slot');
  @override
  late final GeneratedColumn<String> slot = GeneratedColumn<String>(
    'slot',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _deviceIdMeta = const VerificationMeta(
    'deviceId',
  );
  @override
  late final GeneratedColumn<Uint8List> deviceId = GeneratedColumn<Uint8List>(
    'device_id',
    aliasedName,
    false,
    type: DriftSqlType.blob,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _deviceStateMeta = const VerificationMeta(
    'deviceState',
  );
  @override
  late final GeneratedColumn<Uint8List> deviceState =
      GeneratedColumn<Uint8List>(
        'device_state',
        aliasedName,
        false,
        type: DriftSqlType.blob,
        requiredDuringInsert: true,
      );
  @override
  List<GeneratedColumn> get $columns => [slot, deviceId, deviceState];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'vault_device';
  @override
  VerificationContext validateIntegrity(
    Insertable<VaultDeviceRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('slot')) {
      context.handle(
        _slotMeta,
        slot.isAcceptableOrUnknown(data['slot']!, _slotMeta),
      );
    } else if (isInserting) {
      context.missing(_slotMeta);
    }
    if (data.containsKey('device_id')) {
      context.handle(
        _deviceIdMeta,
        deviceId.isAcceptableOrUnknown(data['device_id']!, _deviceIdMeta),
      );
    } else if (isInserting) {
      context.missing(_deviceIdMeta);
    }
    if (data.containsKey('device_state')) {
      context.handle(
        _deviceStateMeta,
        deviceState.isAcceptableOrUnknown(
          data['device_state']!,
          _deviceStateMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_deviceStateMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {slot};
  @override
  VaultDeviceRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return VaultDeviceRow(
      slot: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}slot'],
      )!,
      deviceId: attachedDatabase.typeMapping.read(
        DriftSqlType.blob,
        data['${effectivePrefix}device_id'],
      )!,
      deviceState: attachedDatabase.typeMapping.read(
        DriftSqlType.blob,
        data['${effectivePrefix}device_state'],
      )!,
    );
  }

  @override
  $VaultDeviceTable createAlias(String alias) {
    return $VaultDeviceTable(attachedDatabase, alias);
  }
}

class VaultDeviceRow extends DataClass implements Insertable<VaultDeviceRow> {
  final String slot;

  /// Sealed.
  final Uint8List deviceId;

  /// Sealed.
  final Uint8List deviceState;
  const VaultDeviceRow({
    required this.slot,
    required this.deviceId,
    required this.deviceState,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['slot'] = Variable<String>(slot);
    map['device_id'] = Variable<Uint8List>(deviceId);
    map['device_state'] = Variable<Uint8List>(deviceState);
    return map;
  }

  VaultDeviceCompanion toCompanion(bool nullToAbsent) {
    return VaultDeviceCompanion(
      slot: Value(slot),
      deviceId: Value(deviceId),
      deviceState: Value(deviceState),
    );
  }

  factory VaultDeviceRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return VaultDeviceRow(
      slot: serializer.fromJson<String>(json['slot']),
      deviceId: serializer.fromJson<Uint8List>(json['deviceId']),
      deviceState: serializer.fromJson<Uint8List>(json['deviceState']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'slot': serializer.toJson<String>(slot),
      'deviceId': serializer.toJson<Uint8List>(deviceId),
      'deviceState': serializer.toJson<Uint8List>(deviceState),
    };
  }

  VaultDeviceRow copyWith({
    String? slot,
    Uint8List? deviceId,
    Uint8List? deviceState,
  }) => VaultDeviceRow(
    slot: slot ?? this.slot,
    deviceId: deviceId ?? this.deviceId,
    deviceState: deviceState ?? this.deviceState,
  );
  VaultDeviceRow copyWithCompanion(VaultDeviceCompanion data) {
    return VaultDeviceRow(
      slot: data.slot.present ? data.slot.value : this.slot,
      deviceId: data.deviceId.present ? data.deviceId.value : this.deviceId,
      deviceState: data.deviceState.present
          ? data.deviceState.value
          : this.deviceState,
    );
  }

  @override
  String toString() {
    return (StringBuffer('VaultDeviceRow(')
          ..write('slot: $slot, ')
          ..write('deviceId: $deviceId, ')
          ..write('deviceState: $deviceState')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    slot,
    $driftBlobEquality.hash(deviceId),
    $driftBlobEquality.hash(deviceState),
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is VaultDeviceRow &&
          other.slot == this.slot &&
          $driftBlobEquality.equals(other.deviceId, this.deviceId) &&
          $driftBlobEquality.equals(other.deviceState, this.deviceState));
}

class VaultDeviceCompanion extends UpdateCompanion<VaultDeviceRow> {
  final Value<String> slot;
  final Value<Uint8List> deviceId;
  final Value<Uint8List> deviceState;
  final Value<int> rowid;
  const VaultDeviceCompanion({
    this.slot = const Value.absent(),
    this.deviceId = const Value.absent(),
    this.deviceState = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  VaultDeviceCompanion.insert({
    required String slot,
    required Uint8List deviceId,
    required Uint8List deviceState,
    this.rowid = const Value.absent(),
  }) : slot = Value(slot),
       deviceId = Value(deviceId),
       deviceState = Value(deviceState);
  static Insertable<VaultDeviceRow> custom({
    Expression<String>? slot,
    Expression<Uint8List>? deviceId,
    Expression<Uint8List>? deviceState,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (slot != null) 'slot': slot,
      if (deviceId != null) 'device_id': deviceId,
      if (deviceState != null) 'device_state': deviceState,
      if (rowid != null) 'rowid': rowid,
    });
  }

  VaultDeviceCompanion copyWith({
    Value<String>? slot,
    Value<Uint8List>? deviceId,
    Value<Uint8List>? deviceState,
    Value<int>? rowid,
  }) {
    return VaultDeviceCompanion(
      slot: slot ?? this.slot,
      deviceId: deviceId ?? this.deviceId,
      deviceState: deviceState ?? this.deviceState,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (slot.present) {
      map['slot'] = Variable<String>(slot.value);
    }
    if (deviceId.present) {
      map['device_id'] = Variable<Uint8List>(deviceId.value);
    }
    if (deviceState.present) {
      map['device_state'] = Variable<Uint8List>(deviceState.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('VaultDeviceCompanion(')
          ..write('slot: $slot, ')
          ..write('deviceId: $deviceId, ')
          ..write('deviceState: $deviceState, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $VaultGroupsTable extends VaultGroups
    with TableInfo<$VaultGroupsTable, VaultGroupRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $VaultGroupsTable(this.attachedDatabase, [this._alias]);
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
  static const VerificationMeta _generationMeta = const VerificationMeta(
    'generation',
  );
  @override
  late final GeneratedColumn<int> generation = GeneratedColumn<int>(
    'generation',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _epochMeta = const VerificationMeta('epoch');
  @override
  late final GeneratedColumn<int> epoch = GeneratedColumn<int>(
    'epoch',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _stateMeta = const VerificationMeta('state');
  @override
  late final GeneratedColumn<Uint8List> state = GeneratedColumn<Uint8List>(
    'state',
    aliasedName,
    false,
    type: DriftSqlType.blob,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _pendingCommitMeta = const VerificationMeta(
    'pendingCommit',
  );
  @override
  late final GeneratedColumn<Uint8List> pendingCommit =
      GeneratedColumn<Uint8List>(
        'pending_commit',
        aliasedName,
        false,
        type: DriftSqlType.blob,
        requiredDuringInsert: true,
      );
  @override
  List<GeneratedColumn> get $columns => [
    conversationId,
    generation,
    epoch,
    state,
    pendingCommit,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'vault_groups';
  @override
  VerificationContext validateIntegrity(
    Insertable<VaultGroupRow> instance, {
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
    if (data.containsKey('generation')) {
      context.handle(
        _generationMeta,
        generation.isAcceptableOrUnknown(data['generation']!, _generationMeta),
      );
    } else if (isInserting) {
      context.missing(_generationMeta);
    }
    if (data.containsKey('epoch')) {
      context.handle(
        _epochMeta,
        epoch.isAcceptableOrUnknown(data['epoch']!, _epochMeta),
      );
    } else if (isInserting) {
      context.missing(_epochMeta);
    }
    if (data.containsKey('state')) {
      context.handle(
        _stateMeta,
        state.isAcceptableOrUnknown(data['state']!, _stateMeta),
      );
    } else if (isInserting) {
      context.missing(_stateMeta);
    }
    if (data.containsKey('pending_commit')) {
      context.handle(
        _pendingCommitMeta,
        pendingCommit.isAcceptableOrUnknown(
          data['pending_commit']!,
          _pendingCommitMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_pendingCommitMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {conversationId};
  @override
  VaultGroupRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return VaultGroupRow(
      conversationId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}conversation_id'],
      )!,
      generation: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}generation'],
      )!,
      epoch: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}epoch'],
      )!,
      state: attachedDatabase.typeMapping.read(
        DriftSqlType.blob,
        data['${effectivePrefix}state'],
      )!,
      pendingCommit: attachedDatabase.typeMapping.read(
        DriftSqlType.blob,
        data['${effectivePrefix}pending_commit'],
      )!,
    );
  }

  @override
  $VaultGroupsTable createAlias(String alias) {
    return $VaultGroupsTable(attachedDatabase, alias);
  }
}

class VaultGroupRow extends DataClass implements Insertable<VaultGroupRow> {
  final String conversationId;
  final int generation;
  final int epoch;

  /// Sealed.
  final Uint8List state;

  /// Sealed: one byte, 1 when a commit is pending.
  final Uint8List pendingCommit;
  const VaultGroupRow({
    required this.conversationId,
    required this.generation,
    required this.epoch,
    required this.state,
    required this.pendingCommit,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['conversation_id'] = Variable<String>(conversationId);
    map['generation'] = Variable<int>(generation);
    map['epoch'] = Variable<int>(epoch);
    map['state'] = Variable<Uint8List>(state);
    map['pending_commit'] = Variable<Uint8List>(pendingCommit);
    return map;
  }

  VaultGroupsCompanion toCompanion(bool nullToAbsent) {
    return VaultGroupsCompanion(
      conversationId: Value(conversationId),
      generation: Value(generation),
      epoch: Value(epoch),
      state: Value(state),
      pendingCommit: Value(pendingCommit),
    );
  }

  factory VaultGroupRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return VaultGroupRow(
      conversationId: serializer.fromJson<String>(json['conversationId']),
      generation: serializer.fromJson<int>(json['generation']),
      epoch: serializer.fromJson<int>(json['epoch']),
      state: serializer.fromJson<Uint8List>(json['state']),
      pendingCommit: serializer.fromJson<Uint8List>(json['pendingCommit']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'conversationId': serializer.toJson<String>(conversationId),
      'generation': serializer.toJson<int>(generation),
      'epoch': serializer.toJson<int>(epoch),
      'state': serializer.toJson<Uint8List>(state),
      'pendingCommit': serializer.toJson<Uint8List>(pendingCommit),
    };
  }

  VaultGroupRow copyWith({
    String? conversationId,
    int? generation,
    int? epoch,
    Uint8List? state,
    Uint8List? pendingCommit,
  }) => VaultGroupRow(
    conversationId: conversationId ?? this.conversationId,
    generation: generation ?? this.generation,
    epoch: epoch ?? this.epoch,
    state: state ?? this.state,
    pendingCommit: pendingCommit ?? this.pendingCommit,
  );
  VaultGroupRow copyWithCompanion(VaultGroupsCompanion data) {
    return VaultGroupRow(
      conversationId: data.conversationId.present
          ? data.conversationId.value
          : this.conversationId,
      generation: data.generation.present
          ? data.generation.value
          : this.generation,
      epoch: data.epoch.present ? data.epoch.value : this.epoch,
      state: data.state.present ? data.state.value : this.state,
      pendingCommit: data.pendingCommit.present
          ? data.pendingCommit.value
          : this.pendingCommit,
    );
  }

  @override
  String toString() {
    return (StringBuffer('VaultGroupRow(')
          ..write('conversationId: $conversationId, ')
          ..write('generation: $generation, ')
          ..write('epoch: $epoch, ')
          ..write('state: $state, ')
          ..write('pendingCommit: $pendingCommit')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    conversationId,
    generation,
    epoch,
    $driftBlobEquality.hash(state),
    $driftBlobEquality.hash(pendingCommit),
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is VaultGroupRow &&
          other.conversationId == this.conversationId &&
          other.generation == this.generation &&
          other.epoch == this.epoch &&
          $driftBlobEquality.equals(other.state, this.state) &&
          $driftBlobEquality.equals(other.pendingCommit, this.pendingCommit));
}

class VaultGroupsCompanion extends UpdateCompanion<VaultGroupRow> {
  final Value<String> conversationId;
  final Value<int> generation;
  final Value<int> epoch;
  final Value<Uint8List> state;
  final Value<Uint8List> pendingCommit;
  final Value<int> rowid;
  const VaultGroupsCompanion({
    this.conversationId = const Value.absent(),
    this.generation = const Value.absent(),
    this.epoch = const Value.absent(),
    this.state = const Value.absent(),
    this.pendingCommit = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  VaultGroupsCompanion.insert({
    required String conversationId,
    required int generation,
    required int epoch,
    required Uint8List state,
    required Uint8List pendingCommit,
    this.rowid = const Value.absent(),
  }) : conversationId = Value(conversationId),
       generation = Value(generation),
       epoch = Value(epoch),
       state = Value(state),
       pendingCommit = Value(pendingCommit);
  static Insertable<VaultGroupRow> custom({
    Expression<String>? conversationId,
    Expression<int>? generation,
    Expression<int>? epoch,
    Expression<Uint8List>? state,
    Expression<Uint8List>? pendingCommit,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (conversationId != null) 'conversation_id': conversationId,
      if (generation != null) 'generation': generation,
      if (epoch != null) 'epoch': epoch,
      if (state != null) 'state': state,
      if (pendingCommit != null) 'pending_commit': pendingCommit,
      if (rowid != null) 'rowid': rowid,
    });
  }

  VaultGroupsCompanion copyWith({
    Value<String>? conversationId,
    Value<int>? generation,
    Value<int>? epoch,
    Value<Uint8List>? state,
    Value<Uint8List>? pendingCommit,
    Value<int>? rowid,
  }) {
    return VaultGroupsCompanion(
      conversationId: conversationId ?? this.conversationId,
      generation: generation ?? this.generation,
      epoch: epoch ?? this.epoch,
      state: state ?? this.state,
      pendingCommit: pendingCommit ?? this.pendingCommit,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (conversationId.present) {
      map['conversation_id'] = Variable<String>(conversationId.value);
    }
    if (generation.present) {
      map['generation'] = Variable<int>(generation.value);
    }
    if (epoch.present) {
      map['epoch'] = Variable<int>(epoch.value);
    }
    if (state.present) {
      map['state'] = Variable<Uint8List>(state.value);
    }
    if (pendingCommit.present) {
      map['pending_commit'] = Variable<Uint8List>(pendingCommit.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('VaultGroupsCompanion(')
          ..write('conversationId: $conversationId, ')
          ..write('generation: $generation, ')
          ..write('epoch: $epoch, ')
          ..write('state: $state, ')
          ..write('pendingCommit: $pendingCommit, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $VaultGroupStatesTable extends VaultGroupStates
    with TableInfo<$VaultGroupStatesTable, VaultGroupStateRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $VaultGroupStatesTable(this.attachedDatabase, [this._alias]);
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
  static const VerificationMeta _generationMeta = const VerificationMeta(
    'generation',
  );
  @override
  late final GeneratedColumn<int> generation = GeneratedColumn<int>(
    'generation',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _epochMeta = const VerificationMeta('epoch');
  @override
  late final GeneratedColumn<int> epoch = GeneratedColumn<int>(
    'epoch',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _provisionalMeta = const VerificationMeta(
    'provisional',
  );
  @override
  late final GeneratedColumn<int> provisional = GeneratedColumn<int>(
    'provisional',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _provisionalCreatedAtMeta =
      const VerificationMeta('provisionalCreatedAt');
  @override
  late final GeneratedColumn<int> provisionalCreatedAt = GeneratedColumn<int>(
    'provisional_created_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _stateMeta = const VerificationMeta('state');
  @override
  late final GeneratedColumn<Uint8List> state = GeneratedColumn<Uint8List>(
    'state',
    aliasedName,
    false,
    type: DriftSqlType.blob,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _pendingMeta = const VerificationMeta(
    'pending',
  );
  @override
  late final GeneratedColumn<Uint8List> pending = GeneratedColumn<Uint8List>(
    'pending',
    aliasedName,
    true,
    type: DriftSqlType.blob,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    conversationId,
    generation,
    epoch,
    provisional,
    provisionalCreatedAt,
    state,
    pending,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'vault_group_states';
  @override
  VerificationContext validateIntegrity(
    Insertable<VaultGroupStateRow> instance, {
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
    if (data.containsKey('generation')) {
      context.handle(
        _generationMeta,
        generation.isAcceptableOrUnknown(data['generation']!, _generationMeta),
      );
    } else if (isInserting) {
      context.missing(_generationMeta);
    }
    if (data.containsKey('epoch')) {
      context.handle(
        _epochMeta,
        epoch.isAcceptableOrUnknown(data['epoch']!, _epochMeta),
      );
    } else if (isInserting) {
      context.missing(_epochMeta);
    }
    if (data.containsKey('provisional')) {
      context.handle(
        _provisionalMeta,
        provisional.isAcceptableOrUnknown(
          data['provisional']!,
          _provisionalMeta,
        ),
      );
    }
    if (data.containsKey('provisional_created_at')) {
      context.handle(
        _provisionalCreatedAtMeta,
        provisionalCreatedAt.isAcceptableOrUnknown(
          data['provisional_created_at']!,
          _provisionalCreatedAtMeta,
        ),
      );
    }
    if (data.containsKey('state')) {
      context.handle(
        _stateMeta,
        state.isAcceptableOrUnknown(data['state']!, _stateMeta),
      );
    } else if (isInserting) {
      context.missing(_stateMeta);
    }
    if (data.containsKey('pending')) {
      context.handle(
        _pendingMeta,
        pending.isAcceptableOrUnknown(data['pending']!, _pendingMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {conversationId, generation};
  @override
  VaultGroupStateRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return VaultGroupStateRow(
      conversationId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}conversation_id'],
      )!,
      generation: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}generation'],
      )!,
      epoch: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}epoch'],
      )!,
      provisional: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}provisional'],
      )!,
      provisionalCreatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}provisional_created_at'],
      ),
      state: attachedDatabase.typeMapping.read(
        DriftSqlType.blob,
        data['${effectivePrefix}state'],
      )!,
      pending: attachedDatabase.typeMapping.read(
        DriftSqlType.blob,
        data['${effectivePrefix}pending'],
      ),
    );
  }

  @override
  $VaultGroupStatesTable createAlias(String alias) {
    return $VaultGroupStatesTable(attachedDatabase, alias);
  }
}

class VaultGroupStateRow extends DataClass
    implements Insertable<VaultGroupStateRow> {
  final String conversationId;
  final int generation;
  final int epoch;

  /// Clear: 1 while the group was created locally and the server has not
  /// accepted it yet.
  final int provisional;

  /// Clear: when a provisional group was created (microseconds).
  final int? provisionalCreatedAt;

  /// Sealed.
  final Uint8List state;

  /// Sealed: an encoded `PendingCommit`; NULL when there is none.
  final Uint8List? pending;
  const VaultGroupStateRow({
    required this.conversationId,
    required this.generation,
    required this.epoch,
    required this.provisional,
    this.provisionalCreatedAt,
    required this.state,
    this.pending,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['conversation_id'] = Variable<String>(conversationId);
    map['generation'] = Variable<int>(generation);
    map['epoch'] = Variable<int>(epoch);
    map['provisional'] = Variable<int>(provisional);
    if (!nullToAbsent || provisionalCreatedAt != null) {
      map['provisional_created_at'] = Variable<int>(provisionalCreatedAt);
    }
    map['state'] = Variable<Uint8List>(state);
    if (!nullToAbsent || pending != null) {
      map['pending'] = Variable<Uint8List>(pending);
    }
    return map;
  }

  VaultGroupStatesCompanion toCompanion(bool nullToAbsent) {
    return VaultGroupStatesCompanion(
      conversationId: Value(conversationId),
      generation: Value(generation),
      epoch: Value(epoch),
      provisional: Value(provisional),
      provisionalCreatedAt: provisionalCreatedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(provisionalCreatedAt),
      state: Value(state),
      pending: pending == null && nullToAbsent
          ? const Value.absent()
          : Value(pending),
    );
  }

  factory VaultGroupStateRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return VaultGroupStateRow(
      conversationId: serializer.fromJson<String>(json['conversationId']),
      generation: serializer.fromJson<int>(json['generation']),
      epoch: serializer.fromJson<int>(json['epoch']),
      provisional: serializer.fromJson<int>(json['provisional']),
      provisionalCreatedAt: serializer.fromJson<int?>(
        json['provisionalCreatedAt'],
      ),
      state: serializer.fromJson<Uint8List>(json['state']),
      pending: serializer.fromJson<Uint8List?>(json['pending']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'conversationId': serializer.toJson<String>(conversationId),
      'generation': serializer.toJson<int>(generation),
      'epoch': serializer.toJson<int>(epoch),
      'provisional': serializer.toJson<int>(provisional),
      'provisionalCreatedAt': serializer.toJson<int?>(provisionalCreatedAt),
      'state': serializer.toJson<Uint8List>(state),
      'pending': serializer.toJson<Uint8List?>(pending),
    };
  }

  VaultGroupStateRow copyWith({
    String? conversationId,
    int? generation,
    int? epoch,
    int? provisional,
    Value<int?> provisionalCreatedAt = const Value.absent(),
    Uint8List? state,
    Value<Uint8List?> pending = const Value.absent(),
  }) => VaultGroupStateRow(
    conversationId: conversationId ?? this.conversationId,
    generation: generation ?? this.generation,
    epoch: epoch ?? this.epoch,
    provisional: provisional ?? this.provisional,
    provisionalCreatedAt: provisionalCreatedAt.present
        ? provisionalCreatedAt.value
        : this.provisionalCreatedAt,
    state: state ?? this.state,
    pending: pending.present ? pending.value : this.pending,
  );
  VaultGroupStateRow copyWithCompanion(VaultGroupStatesCompanion data) {
    return VaultGroupStateRow(
      conversationId: data.conversationId.present
          ? data.conversationId.value
          : this.conversationId,
      generation: data.generation.present
          ? data.generation.value
          : this.generation,
      epoch: data.epoch.present ? data.epoch.value : this.epoch,
      provisional: data.provisional.present
          ? data.provisional.value
          : this.provisional,
      provisionalCreatedAt: data.provisionalCreatedAt.present
          ? data.provisionalCreatedAt.value
          : this.provisionalCreatedAt,
      state: data.state.present ? data.state.value : this.state,
      pending: data.pending.present ? data.pending.value : this.pending,
    );
  }

  @override
  String toString() {
    return (StringBuffer('VaultGroupStateRow(')
          ..write('conversationId: $conversationId, ')
          ..write('generation: $generation, ')
          ..write('epoch: $epoch, ')
          ..write('provisional: $provisional, ')
          ..write('provisionalCreatedAt: $provisionalCreatedAt, ')
          ..write('state: $state, ')
          ..write('pending: $pending')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    conversationId,
    generation,
    epoch,
    provisional,
    provisionalCreatedAt,
    $driftBlobEquality.hash(state),
    $driftBlobEquality.hash(pending),
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is VaultGroupStateRow &&
          other.conversationId == this.conversationId &&
          other.generation == this.generation &&
          other.epoch == this.epoch &&
          other.provisional == this.provisional &&
          other.provisionalCreatedAt == this.provisionalCreatedAt &&
          $driftBlobEquality.equals(other.state, this.state) &&
          $driftBlobEquality.equals(other.pending, this.pending));
}

class VaultGroupStatesCompanion extends UpdateCompanion<VaultGroupStateRow> {
  final Value<String> conversationId;
  final Value<int> generation;
  final Value<int> epoch;
  final Value<int> provisional;
  final Value<int?> provisionalCreatedAt;
  final Value<Uint8List> state;
  final Value<Uint8List?> pending;
  final Value<int> rowid;
  const VaultGroupStatesCompanion({
    this.conversationId = const Value.absent(),
    this.generation = const Value.absent(),
    this.epoch = const Value.absent(),
    this.provisional = const Value.absent(),
    this.provisionalCreatedAt = const Value.absent(),
    this.state = const Value.absent(),
    this.pending = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  VaultGroupStatesCompanion.insert({
    required String conversationId,
    required int generation,
    required int epoch,
    this.provisional = const Value.absent(),
    this.provisionalCreatedAt = const Value.absent(),
    required Uint8List state,
    this.pending = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : conversationId = Value(conversationId),
       generation = Value(generation),
       epoch = Value(epoch),
       state = Value(state);
  static Insertable<VaultGroupStateRow> custom({
    Expression<String>? conversationId,
    Expression<int>? generation,
    Expression<int>? epoch,
    Expression<int>? provisional,
    Expression<int>? provisionalCreatedAt,
    Expression<Uint8List>? state,
    Expression<Uint8List>? pending,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (conversationId != null) 'conversation_id': conversationId,
      if (generation != null) 'generation': generation,
      if (epoch != null) 'epoch': epoch,
      if (provisional != null) 'provisional': provisional,
      if (provisionalCreatedAt != null)
        'provisional_created_at': provisionalCreatedAt,
      if (state != null) 'state': state,
      if (pending != null) 'pending': pending,
      if (rowid != null) 'rowid': rowid,
    });
  }

  VaultGroupStatesCompanion copyWith({
    Value<String>? conversationId,
    Value<int>? generation,
    Value<int>? epoch,
    Value<int>? provisional,
    Value<int?>? provisionalCreatedAt,
    Value<Uint8List>? state,
    Value<Uint8List?>? pending,
    Value<int>? rowid,
  }) {
    return VaultGroupStatesCompanion(
      conversationId: conversationId ?? this.conversationId,
      generation: generation ?? this.generation,
      epoch: epoch ?? this.epoch,
      provisional: provisional ?? this.provisional,
      provisionalCreatedAt: provisionalCreatedAt ?? this.provisionalCreatedAt,
      state: state ?? this.state,
      pending: pending ?? this.pending,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (conversationId.present) {
      map['conversation_id'] = Variable<String>(conversationId.value);
    }
    if (generation.present) {
      map['generation'] = Variable<int>(generation.value);
    }
    if (epoch.present) {
      map['epoch'] = Variable<int>(epoch.value);
    }
    if (provisional.present) {
      map['provisional'] = Variable<int>(provisional.value);
    }
    if (provisionalCreatedAt.present) {
      map['provisional_created_at'] = Variable<int>(provisionalCreatedAt.value);
    }
    if (state.present) {
      map['state'] = Variable<Uint8List>(state.value);
    }
    if (pending.present) {
      map['pending'] = Variable<Uint8List>(pending.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('VaultGroupStatesCompanion(')
          ..write('conversationId: $conversationId, ')
          ..write('generation: $generation, ')
          ..write('epoch: $epoch, ')
          ..write('provisional: $provisional, ')
          ..write('provisionalCreatedAt: $provisionalCreatedAt, ')
          ..write('state: $state, ')
          ..write('pending: $pending, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $VaultConversationsTable extends VaultConversations
    with TableInfo<$VaultConversationsTable, VaultConversationRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $VaultConversationsTable(this.attachedDatabase, [this._alias]);
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
  static const VerificationMeta _afterGenerationMeta = const VerificationMeta(
    'afterGeneration',
  );
  @override
  late final GeneratedColumn<int> afterGeneration = GeneratedColumn<int>(
    'after_generation',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _afterEpochMeta = const VerificationMeta(
    'afterEpoch',
  );
  @override
  late final GeneratedColumn<int> afterEpoch = GeneratedColumn<int>(
    'after_epoch',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _joinGenerationMeta = const VerificationMeta(
    'joinGeneration',
  );
  @override
  late final GeneratedColumn<int> joinGeneration = GeneratedColumn<int>(
    'join_generation',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _joinEpochMeta = const VerificationMeta(
    'joinEpoch',
  );
  @override
  late final GeneratedColumn<int> joinEpoch = GeneratedColumn<int>(
    'join_epoch',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _syncMeta = const VerificationMeta('sync');
  @override
  late final GeneratedColumn<Uint8List> sync = GeneratedColumn<Uint8List>(
    'sync',
    aliasedName,
    true,
    type: DriftSqlType.blob,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    conversationId,
    afterGeneration,
    afterEpoch,
    joinGeneration,
    joinEpoch,
    sync,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'vault_conversations';
  @override
  VerificationContext validateIntegrity(
    Insertable<VaultConversationRow> instance, {
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
    if (data.containsKey('after_generation')) {
      context.handle(
        _afterGenerationMeta,
        afterGeneration.isAcceptableOrUnknown(
          data['after_generation']!,
          _afterGenerationMeta,
        ),
      );
    }
    if (data.containsKey('after_epoch')) {
      context.handle(
        _afterEpochMeta,
        afterEpoch.isAcceptableOrUnknown(data['after_epoch']!, _afterEpochMeta),
      );
    }
    if (data.containsKey('join_generation')) {
      context.handle(
        _joinGenerationMeta,
        joinGeneration.isAcceptableOrUnknown(
          data['join_generation']!,
          _joinGenerationMeta,
        ),
      );
    }
    if (data.containsKey('join_epoch')) {
      context.handle(
        _joinEpochMeta,
        joinEpoch.isAcceptableOrUnknown(data['join_epoch']!, _joinEpochMeta),
      );
    }
    if (data.containsKey('sync')) {
      context.handle(
        _syncMeta,
        sync.isAcceptableOrUnknown(data['sync']!, _syncMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {conversationId};
  @override
  VaultConversationRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return VaultConversationRow(
      conversationId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}conversation_id'],
      )!,
      afterGeneration: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}after_generation'],
      ),
      afterEpoch: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}after_epoch'],
      ),
      joinGeneration: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}join_generation'],
      ),
      joinEpoch: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}join_epoch'],
      ),
      sync: attachedDatabase.typeMapping.read(
        DriftSqlType.blob,
        data['${effectivePrefix}sync'],
      ),
    );
  }

  @override
  $VaultConversationsTable createAlias(String alias) {
    return $VaultConversationsTable(attachedDatabase, alias);
  }
}

class VaultConversationRow extends DataClass
    implements Insertable<VaultConversationRow> {
  final String conversationId;

  /// Clear: the after-pair mark (both columns, or neither).
  final int? afterGeneration;
  final int? afterEpoch;

  /// Clear: the join high-water mark (both columns, or neither).
  final int? joinGeneration;
  final int? joinEpoch;

  /// Sealed: an encoded `ConversationSync`; NULL before the first write.
  final Uint8List? sync;
  const VaultConversationRow({
    required this.conversationId,
    this.afterGeneration,
    this.afterEpoch,
    this.joinGeneration,
    this.joinEpoch,
    this.sync,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['conversation_id'] = Variable<String>(conversationId);
    if (!nullToAbsent || afterGeneration != null) {
      map['after_generation'] = Variable<int>(afterGeneration);
    }
    if (!nullToAbsent || afterEpoch != null) {
      map['after_epoch'] = Variable<int>(afterEpoch);
    }
    if (!nullToAbsent || joinGeneration != null) {
      map['join_generation'] = Variable<int>(joinGeneration);
    }
    if (!nullToAbsent || joinEpoch != null) {
      map['join_epoch'] = Variable<int>(joinEpoch);
    }
    if (!nullToAbsent || sync != null) {
      map['sync'] = Variable<Uint8List>(sync);
    }
    return map;
  }

  VaultConversationsCompanion toCompanion(bool nullToAbsent) {
    return VaultConversationsCompanion(
      conversationId: Value(conversationId),
      afterGeneration: afterGeneration == null && nullToAbsent
          ? const Value.absent()
          : Value(afterGeneration),
      afterEpoch: afterEpoch == null && nullToAbsent
          ? const Value.absent()
          : Value(afterEpoch),
      joinGeneration: joinGeneration == null && nullToAbsent
          ? const Value.absent()
          : Value(joinGeneration),
      joinEpoch: joinEpoch == null && nullToAbsent
          ? const Value.absent()
          : Value(joinEpoch),
      sync: sync == null && nullToAbsent ? const Value.absent() : Value(sync),
    );
  }

  factory VaultConversationRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return VaultConversationRow(
      conversationId: serializer.fromJson<String>(json['conversationId']),
      afterGeneration: serializer.fromJson<int?>(json['afterGeneration']),
      afterEpoch: serializer.fromJson<int?>(json['afterEpoch']),
      joinGeneration: serializer.fromJson<int?>(json['joinGeneration']),
      joinEpoch: serializer.fromJson<int?>(json['joinEpoch']),
      sync: serializer.fromJson<Uint8List?>(json['sync']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'conversationId': serializer.toJson<String>(conversationId),
      'afterGeneration': serializer.toJson<int?>(afterGeneration),
      'afterEpoch': serializer.toJson<int?>(afterEpoch),
      'joinGeneration': serializer.toJson<int?>(joinGeneration),
      'joinEpoch': serializer.toJson<int?>(joinEpoch),
      'sync': serializer.toJson<Uint8List?>(sync),
    };
  }

  VaultConversationRow copyWith({
    String? conversationId,
    Value<int?> afterGeneration = const Value.absent(),
    Value<int?> afterEpoch = const Value.absent(),
    Value<int?> joinGeneration = const Value.absent(),
    Value<int?> joinEpoch = const Value.absent(),
    Value<Uint8List?> sync = const Value.absent(),
  }) => VaultConversationRow(
    conversationId: conversationId ?? this.conversationId,
    afterGeneration: afterGeneration.present
        ? afterGeneration.value
        : this.afterGeneration,
    afterEpoch: afterEpoch.present ? afterEpoch.value : this.afterEpoch,
    joinGeneration: joinGeneration.present
        ? joinGeneration.value
        : this.joinGeneration,
    joinEpoch: joinEpoch.present ? joinEpoch.value : this.joinEpoch,
    sync: sync.present ? sync.value : this.sync,
  );
  VaultConversationRow copyWithCompanion(VaultConversationsCompanion data) {
    return VaultConversationRow(
      conversationId: data.conversationId.present
          ? data.conversationId.value
          : this.conversationId,
      afterGeneration: data.afterGeneration.present
          ? data.afterGeneration.value
          : this.afterGeneration,
      afterEpoch: data.afterEpoch.present
          ? data.afterEpoch.value
          : this.afterEpoch,
      joinGeneration: data.joinGeneration.present
          ? data.joinGeneration.value
          : this.joinGeneration,
      joinEpoch: data.joinEpoch.present ? data.joinEpoch.value : this.joinEpoch,
      sync: data.sync.present ? data.sync.value : this.sync,
    );
  }

  @override
  String toString() {
    return (StringBuffer('VaultConversationRow(')
          ..write('conversationId: $conversationId, ')
          ..write('afterGeneration: $afterGeneration, ')
          ..write('afterEpoch: $afterEpoch, ')
          ..write('joinGeneration: $joinGeneration, ')
          ..write('joinEpoch: $joinEpoch, ')
          ..write('sync: $sync')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    conversationId,
    afterGeneration,
    afterEpoch,
    joinGeneration,
    joinEpoch,
    $driftBlobEquality.hash(sync),
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is VaultConversationRow &&
          other.conversationId == this.conversationId &&
          other.afterGeneration == this.afterGeneration &&
          other.afterEpoch == this.afterEpoch &&
          other.joinGeneration == this.joinGeneration &&
          other.joinEpoch == this.joinEpoch &&
          $driftBlobEquality.equals(other.sync, this.sync));
}

class VaultConversationsCompanion
    extends UpdateCompanion<VaultConversationRow> {
  final Value<String> conversationId;
  final Value<int?> afterGeneration;
  final Value<int?> afterEpoch;
  final Value<int?> joinGeneration;
  final Value<int?> joinEpoch;
  final Value<Uint8List?> sync;
  final Value<int> rowid;
  const VaultConversationsCompanion({
    this.conversationId = const Value.absent(),
    this.afterGeneration = const Value.absent(),
    this.afterEpoch = const Value.absent(),
    this.joinGeneration = const Value.absent(),
    this.joinEpoch = const Value.absent(),
    this.sync = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  VaultConversationsCompanion.insert({
    required String conversationId,
    this.afterGeneration = const Value.absent(),
    this.afterEpoch = const Value.absent(),
    this.joinGeneration = const Value.absent(),
    this.joinEpoch = const Value.absent(),
    this.sync = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : conversationId = Value(conversationId);
  static Insertable<VaultConversationRow> custom({
    Expression<String>? conversationId,
    Expression<int>? afterGeneration,
    Expression<int>? afterEpoch,
    Expression<int>? joinGeneration,
    Expression<int>? joinEpoch,
    Expression<Uint8List>? sync,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (conversationId != null) 'conversation_id': conversationId,
      if (afterGeneration != null) 'after_generation': afterGeneration,
      if (afterEpoch != null) 'after_epoch': afterEpoch,
      if (joinGeneration != null) 'join_generation': joinGeneration,
      if (joinEpoch != null) 'join_epoch': joinEpoch,
      if (sync != null) 'sync': sync,
      if (rowid != null) 'rowid': rowid,
    });
  }

  VaultConversationsCompanion copyWith({
    Value<String>? conversationId,
    Value<int?>? afterGeneration,
    Value<int?>? afterEpoch,
    Value<int?>? joinGeneration,
    Value<int?>? joinEpoch,
    Value<Uint8List?>? sync,
    Value<int>? rowid,
  }) {
    return VaultConversationsCompanion(
      conversationId: conversationId ?? this.conversationId,
      afterGeneration: afterGeneration ?? this.afterGeneration,
      afterEpoch: afterEpoch ?? this.afterEpoch,
      joinGeneration: joinGeneration ?? this.joinGeneration,
      joinEpoch: joinEpoch ?? this.joinEpoch,
      sync: sync ?? this.sync,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (conversationId.present) {
      map['conversation_id'] = Variable<String>(conversationId.value);
    }
    if (afterGeneration.present) {
      map['after_generation'] = Variable<int>(afterGeneration.value);
    }
    if (afterEpoch.present) {
      map['after_epoch'] = Variable<int>(afterEpoch.value);
    }
    if (joinGeneration.present) {
      map['join_generation'] = Variable<int>(joinGeneration.value);
    }
    if (joinEpoch.present) {
      map['join_epoch'] = Variable<int>(joinEpoch.value);
    }
    if (sync.present) {
      map['sync'] = Variable<Uint8List>(sync.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('VaultConversationsCompanion(')
          ..write('conversationId: $conversationId, ')
          ..write('afterGeneration: $afterGeneration, ')
          ..write('afterEpoch: $afterEpoch, ')
          ..write('joinGeneration: $joinGeneration, ')
          ..write('joinEpoch: $joinEpoch, ')
          ..write('sync: $sync, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $VaultMembersTable extends VaultMembers
    with TableInfo<$VaultMembersTable, VaultMemberRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $VaultMembersTable(this.attachedDatabase, [this._alias]);
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
  static const VerificationMeta _deviceIdMeta = const VerificationMeta(
    'deviceId',
  );
  @override
  late final GeneratedColumn<String> deviceId = GeneratedColumn<String>(
    'device_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sideMeta = const VerificationMeta('side');
  @override
  late final GeneratedColumn<String> side = GeneratedColumn<String>(
    'side',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sinceGenerationMeta = const VerificationMeta(
    'sinceGeneration',
  );
  @override
  late final GeneratedColumn<int> sinceGeneration = GeneratedColumn<int>(
    'since_generation',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sinceEpochMeta = const VerificationMeta(
    'sinceEpoch',
  );
  @override
  late final GeneratedColumn<int> sinceEpoch = GeneratedColumn<int>(
    'since_epoch',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _signatureKeyMeta = const VerificationMeta(
    'signatureKey',
  );
  @override
  late final GeneratedColumn<Uint8List> signatureKey =
      GeneratedColumn<Uint8List>(
        'signature_key',
        aliasedName,
        false,
        type: DriftSqlType.blob,
        requiredDuringInsert: true,
      );
  @override
  List<GeneratedColumn> get $columns => [
    conversationId,
    deviceId,
    side,
    sinceGeneration,
    sinceEpoch,
    signatureKey,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'vault_members';
  @override
  VerificationContext validateIntegrity(
    Insertable<VaultMemberRow> instance, {
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
    if (data.containsKey('device_id')) {
      context.handle(
        _deviceIdMeta,
        deviceId.isAcceptableOrUnknown(data['device_id']!, _deviceIdMeta),
      );
    } else if (isInserting) {
      context.missing(_deviceIdMeta);
    }
    if (data.containsKey('side')) {
      context.handle(
        _sideMeta,
        side.isAcceptableOrUnknown(data['side']!, _sideMeta),
      );
    } else if (isInserting) {
      context.missing(_sideMeta);
    }
    if (data.containsKey('since_generation')) {
      context.handle(
        _sinceGenerationMeta,
        sinceGeneration.isAcceptableOrUnknown(
          data['since_generation']!,
          _sinceGenerationMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_sinceGenerationMeta);
    }
    if (data.containsKey('since_epoch')) {
      context.handle(
        _sinceEpochMeta,
        sinceEpoch.isAcceptableOrUnknown(data['since_epoch']!, _sinceEpochMeta),
      );
    } else if (isInserting) {
      context.missing(_sinceEpochMeta);
    }
    if (data.containsKey('signature_key')) {
      context.handle(
        _signatureKeyMeta,
        signatureKey.isAcceptableOrUnknown(
          data['signature_key']!,
          _signatureKeyMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_signatureKeyMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {conversationId, deviceId};
  @override
  VaultMemberRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return VaultMemberRow(
      conversationId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}conversation_id'],
      )!,
      deviceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}device_id'],
      )!,
      side: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}side'],
      )!,
      sinceGeneration: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}since_generation'],
      )!,
      sinceEpoch: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}since_epoch'],
      )!,
      signatureKey: attachedDatabase.typeMapping.read(
        DriftSqlType.blob,
        data['${effectivePrefix}signature_key'],
      )!,
    );
  }

  @override
  $VaultMembersTable createAlias(String alias) {
    return $VaultMembersTable(attachedDatabase, alias);
  }
}

class VaultMemberRow extends DataClass implements Insertable<VaultMemberRow> {
  final String conversationId;

  /// Clear: lower-case hex of the device id bytes.
  final String deviceId;

  /// Clear: one of `MemberSide`.
  final String side;
  final int sinceGeneration;
  final int sinceEpoch;

  /// Sealed.
  final Uint8List signatureKey;
  const VaultMemberRow({
    required this.conversationId,
    required this.deviceId,
    required this.side,
    required this.sinceGeneration,
    required this.sinceEpoch,
    required this.signatureKey,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['conversation_id'] = Variable<String>(conversationId);
    map['device_id'] = Variable<String>(deviceId);
    map['side'] = Variable<String>(side);
    map['since_generation'] = Variable<int>(sinceGeneration);
    map['since_epoch'] = Variable<int>(sinceEpoch);
    map['signature_key'] = Variable<Uint8List>(signatureKey);
    return map;
  }

  VaultMembersCompanion toCompanion(bool nullToAbsent) {
    return VaultMembersCompanion(
      conversationId: Value(conversationId),
      deviceId: Value(deviceId),
      side: Value(side),
      sinceGeneration: Value(sinceGeneration),
      sinceEpoch: Value(sinceEpoch),
      signatureKey: Value(signatureKey),
    );
  }

  factory VaultMemberRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return VaultMemberRow(
      conversationId: serializer.fromJson<String>(json['conversationId']),
      deviceId: serializer.fromJson<String>(json['deviceId']),
      side: serializer.fromJson<String>(json['side']),
      sinceGeneration: serializer.fromJson<int>(json['sinceGeneration']),
      sinceEpoch: serializer.fromJson<int>(json['sinceEpoch']),
      signatureKey: serializer.fromJson<Uint8List>(json['signatureKey']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'conversationId': serializer.toJson<String>(conversationId),
      'deviceId': serializer.toJson<String>(deviceId),
      'side': serializer.toJson<String>(side),
      'sinceGeneration': serializer.toJson<int>(sinceGeneration),
      'sinceEpoch': serializer.toJson<int>(sinceEpoch),
      'signatureKey': serializer.toJson<Uint8List>(signatureKey),
    };
  }

  VaultMemberRow copyWith({
    String? conversationId,
    String? deviceId,
    String? side,
    int? sinceGeneration,
    int? sinceEpoch,
    Uint8List? signatureKey,
  }) => VaultMemberRow(
    conversationId: conversationId ?? this.conversationId,
    deviceId: deviceId ?? this.deviceId,
    side: side ?? this.side,
    sinceGeneration: sinceGeneration ?? this.sinceGeneration,
    sinceEpoch: sinceEpoch ?? this.sinceEpoch,
    signatureKey: signatureKey ?? this.signatureKey,
  );
  VaultMemberRow copyWithCompanion(VaultMembersCompanion data) {
    return VaultMemberRow(
      conversationId: data.conversationId.present
          ? data.conversationId.value
          : this.conversationId,
      deviceId: data.deviceId.present ? data.deviceId.value : this.deviceId,
      side: data.side.present ? data.side.value : this.side,
      sinceGeneration: data.sinceGeneration.present
          ? data.sinceGeneration.value
          : this.sinceGeneration,
      sinceEpoch: data.sinceEpoch.present
          ? data.sinceEpoch.value
          : this.sinceEpoch,
      signatureKey: data.signatureKey.present
          ? data.signatureKey.value
          : this.signatureKey,
    );
  }

  @override
  String toString() {
    return (StringBuffer('VaultMemberRow(')
          ..write('conversationId: $conversationId, ')
          ..write('deviceId: $deviceId, ')
          ..write('side: $side, ')
          ..write('sinceGeneration: $sinceGeneration, ')
          ..write('sinceEpoch: $sinceEpoch, ')
          ..write('signatureKey: $signatureKey')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    conversationId,
    deviceId,
    side,
    sinceGeneration,
    sinceEpoch,
    $driftBlobEquality.hash(signatureKey),
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is VaultMemberRow &&
          other.conversationId == this.conversationId &&
          other.deviceId == this.deviceId &&
          other.side == this.side &&
          other.sinceGeneration == this.sinceGeneration &&
          other.sinceEpoch == this.sinceEpoch &&
          $driftBlobEquality.equals(other.signatureKey, this.signatureKey));
}

class VaultMembersCompanion extends UpdateCompanion<VaultMemberRow> {
  final Value<String> conversationId;
  final Value<String> deviceId;
  final Value<String> side;
  final Value<int> sinceGeneration;
  final Value<int> sinceEpoch;
  final Value<Uint8List> signatureKey;
  final Value<int> rowid;
  const VaultMembersCompanion({
    this.conversationId = const Value.absent(),
    this.deviceId = const Value.absent(),
    this.side = const Value.absent(),
    this.sinceGeneration = const Value.absent(),
    this.sinceEpoch = const Value.absent(),
    this.signatureKey = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  VaultMembersCompanion.insert({
    required String conversationId,
    required String deviceId,
    required String side,
    required int sinceGeneration,
    required int sinceEpoch,
    required Uint8List signatureKey,
    this.rowid = const Value.absent(),
  }) : conversationId = Value(conversationId),
       deviceId = Value(deviceId),
       side = Value(side),
       sinceGeneration = Value(sinceGeneration),
       sinceEpoch = Value(sinceEpoch),
       signatureKey = Value(signatureKey);
  static Insertable<VaultMemberRow> custom({
    Expression<String>? conversationId,
    Expression<String>? deviceId,
    Expression<String>? side,
    Expression<int>? sinceGeneration,
    Expression<int>? sinceEpoch,
    Expression<Uint8List>? signatureKey,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (conversationId != null) 'conversation_id': conversationId,
      if (deviceId != null) 'device_id': deviceId,
      if (side != null) 'side': side,
      if (sinceGeneration != null) 'since_generation': sinceGeneration,
      if (sinceEpoch != null) 'since_epoch': sinceEpoch,
      if (signatureKey != null) 'signature_key': signatureKey,
      if (rowid != null) 'rowid': rowid,
    });
  }

  VaultMembersCompanion copyWith({
    Value<String>? conversationId,
    Value<String>? deviceId,
    Value<String>? side,
    Value<int>? sinceGeneration,
    Value<int>? sinceEpoch,
    Value<Uint8List>? signatureKey,
    Value<int>? rowid,
  }) {
    return VaultMembersCompanion(
      conversationId: conversationId ?? this.conversationId,
      deviceId: deviceId ?? this.deviceId,
      side: side ?? this.side,
      sinceGeneration: sinceGeneration ?? this.sinceGeneration,
      sinceEpoch: sinceEpoch ?? this.sinceEpoch,
      signatureKey: signatureKey ?? this.signatureKey,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (conversationId.present) {
      map['conversation_id'] = Variable<String>(conversationId.value);
    }
    if (deviceId.present) {
      map['device_id'] = Variable<String>(deviceId.value);
    }
    if (side.present) {
      map['side'] = Variable<String>(side.value);
    }
    if (sinceGeneration.present) {
      map['since_generation'] = Variable<int>(sinceGeneration.value);
    }
    if (sinceEpoch.present) {
      map['since_epoch'] = Variable<int>(sinceEpoch.value);
    }
    if (signatureKey.present) {
      map['signature_key'] = Variable<Uint8List>(signatureKey.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('VaultMembersCompanion(')
          ..write('conversationId: $conversationId, ')
          ..write('deviceId: $deviceId, ')
          ..write('side: $side, ')
          ..write('sinceGeneration: $sinceGeneration, ')
          ..write('sinceEpoch: $sinceEpoch, ')
          ..write('signatureKey: $signatureKey, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $VaultSentTable extends VaultSent
    with TableInfo<$VaultSentTable, VaultSentRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $VaultSentTable(this.attachedDatabase, [this._alias]);
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
  static const VerificationMeta _generationMeta = const VerificationMeta(
    'generation',
  );
  @override
  late final GeneratedColumn<int> generation = GeneratedColumn<int>(
    'generation',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _epochMeta = const VerificationMeta('epoch');
  @override
  late final GeneratedColumn<int> epoch = GeneratedColumn<int>(
    'epoch',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _digestMeta = const VerificationMeta('digest');
  @override
  late final GeneratedColumn<String> digest = GeneratedColumn<String>(
    'digest',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    conversationId,
    generation,
    epoch,
    digest,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'vault_sent';
  @override
  VerificationContext validateIntegrity(
    Insertable<VaultSentRow> instance, {
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
    if (data.containsKey('generation')) {
      context.handle(
        _generationMeta,
        generation.isAcceptableOrUnknown(data['generation']!, _generationMeta),
      );
    } else if (isInserting) {
      context.missing(_generationMeta);
    }
    if (data.containsKey('epoch')) {
      context.handle(
        _epochMeta,
        epoch.isAcceptableOrUnknown(data['epoch']!, _epochMeta),
      );
    } else if (isInserting) {
      context.missing(_epochMeta);
    }
    if (data.containsKey('digest')) {
      context.handle(
        _digestMeta,
        digest.isAcceptableOrUnknown(data['digest']!, _digestMeta),
      );
    } else if (isInserting) {
      context.missing(_digestMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {
    conversationId,
    generation,
    epoch,
    digest,
  };
  @override
  VaultSentRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return VaultSentRow(
      conversationId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}conversation_id'],
      )!,
      generation: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}generation'],
      )!,
      epoch: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}epoch'],
      )!,
      digest: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}digest'],
      )!,
    );
  }

  @override
  $VaultSentTable createAlias(String alias) {
    return $VaultSentTable(attachedDatabase, alias);
  }
}

class VaultSentRow extends DataClass implements Insertable<VaultSentRow> {
  final String conversationId;
  final int generation;
  final int epoch;

  /// Clear: 64 hex.
  final String digest;
  const VaultSentRow({
    required this.conversationId,
    required this.generation,
    required this.epoch,
    required this.digest,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['conversation_id'] = Variable<String>(conversationId);
    map['generation'] = Variable<int>(generation);
    map['epoch'] = Variable<int>(epoch);
    map['digest'] = Variable<String>(digest);
    return map;
  }

  VaultSentCompanion toCompanion(bool nullToAbsent) {
    return VaultSentCompanion(
      conversationId: Value(conversationId),
      generation: Value(generation),
      epoch: Value(epoch),
      digest: Value(digest),
    );
  }

  factory VaultSentRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return VaultSentRow(
      conversationId: serializer.fromJson<String>(json['conversationId']),
      generation: serializer.fromJson<int>(json['generation']),
      epoch: serializer.fromJson<int>(json['epoch']),
      digest: serializer.fromJson<String>(json['digest']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'conversationId': serializer.toJson<String>(conversationId),
      'generation': serializer.toJson<int>(generation),
      'epoch': serializer.toJson<int>(epoch),
      'digest': serializer.toJson<String>(digest),
    };
  }

  VaultSentRow copyWith({
    String? conversationId,
    int? generation,
    int? epoch,
    String? digest,
  }) => VaultSentRow(
    conversationId: conversationId ?? this.conversationId,
    generation: generation ?? this.generation,
    epoch: epoch ?? this.epoch,
    digest: digest ?? this.digest,
  );
  VaultSentRow copyWithCompanion(VaultSentCompanion data) {
    return VaultSentRow(
      conversationId: data.conversationId.present
          ? data.conversationId.value
          : this.conversationId,
      generation: data.generation.present
          ? data.generation.value
          : this.generation,
      epoch: data.epoch.present ? data.epoch.value : this.epoch,
      digest: data.digest.present ? data.digest.value : this.digest,
    );
  }

  @override
  String toString() {
    return (StringBuffer('VaultSentRow(')
          ..write('conversationId: $conversationId, ')
          ..write('generation: $generation, ')
          ..write('epoch: $epoch, ')
          ..write('digest: $digest')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(conversationId, generation, epoch, digest);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is VaultSentRow &&
          other.conversationId == this.conversationId &&
          other.generation == this.generation &&
          other.epoch == this.epoch &&
          other.digest == this.digest);
}

class VaultSentCompanion extends UpdateCompanion<VaultSentRow> {
  final Value<String> conversationId;
  final Value<int> generation;
  final Value<int> epoch;
  final Value<String> digest;
  final Value<int> rowid;
  const VaultSentCompanion({
    this.conversationId = const Value.absent(),
    this.generation = const Value.absent(),
    this.epoch = const Value.absent(),
    this.digest = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  VaultSentCompanion.insert({
    required String conversationId,
    required int generation,
    required int epoch,
    required String digest,
    this.rowid = const Value.absent(),
  }) : conversationId = Value(conversationId),
       generation = Value(generation),
       epoch = Value(epoch),
       digest = Value(digest);
  static Insertable<VaultSentRow> custom({
    Expression<String>? conversationId,
    Expression<int>? generation,
    Expression<int>? epoch,
    Expression<String>? digest,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (conversationId != null) 'conversation_id': conversationId,
      if (generation != null) 'generation': generation,
      if (epoch != null) 'epoch': epoch,
      if (digest != null) 'digest': digest,
      if (rowid != null) 'rowid': rowid,
    });
  }

  VaultSentCompanion copyWith({
    Value<String>? conversationId,
    Value<int>? generation,
    Value<int>? epoch,
    Value<String>? digest,
    Value<int>? rowid,
  }) {
    return VaultSentCompanion(
      conversationId: conversationId ?? this.conversationId,
      generation: generation ?? this.generation,
      epoch: epoch ?? this.epoch,
      digest: digest ?? this.digest,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (conversationId.present) {
      map['conversation_id'] = Variable<String>(conversationId.value);
    }
    if (generation.present) {
      map['generation'] = Variable<int>(generation.value);
    }
    if (epoch.present) {
      map['epoch'] = Variable<int>(epoch.value);
    }
    if (digest.present) {
      map['digest'] = Variable<String>(digest.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('VaultSentCompanion(')
          ..write('conversationId: $conversationId, ')
          ..write('generation: $generation, ')
          ..write('epoch: $epoch, ')
          ..write('digest: $digest, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $VaultMessagesTable extends VaultMessages
    with TableInfo<$VaultMessagesTable, VaultMessageRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $VaultMessagesTable(this.attachedDatabase, [this._alias]);
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
  static const VerificationMeta _stateMeta = const VerificationMeta('state');
  @override
  late final GeneratedColumn<String> state = GeneratedColumn<String>(
    'state',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _generationMeta = const VerificationMeta(
    'generation',
  );
  @override
  late final GeneratedColumn<int> generation = GeneratedColumn<int>(
    'generation',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _epochMeta = const VerificationMeta('epoch');
  @override
  late final GeneratedColumn<int> epoch = GeneratedColumn<int>(
    'epoch',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _fromSelfMeta = const VerificationMeta(
    'fromSelf',
  );
  @override
  late final GeneratedColumn<Uint8List> fromSelf = GeneratedColumn<Uint8List>(
    'from_self',
    aliasedName,
    false,
    type: DriftSqlType.blob,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _contentMeta = const VerificationMeta(
    'content',
  );
  @override
  late final GeneratedColumn<Uint8List> content = GeneratedColumn<Uint8List>(
    'content',
    aliasedName,
    true,
    type: DriftSqlType.blob,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _checkStateMeta = const VerificationMeta(
    'checkState',
  );
  @override
  late final GeneratedColumn<String> checkState = GeneratedColumn<String>(
    'check_state',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('ok'),
  );
  static const VerificationMeta _kindMeta = const VerificationMeta('kind');
  @override
  late final GeneratedColumn<String> kind = GeneratedColumn<String>(
    'kind',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('message'),
  );
  static const VerificationMeta _mineMeta = const VerificationMeta('mine');
  @override
  late final GeneratedColumn<int> mine = GeneratedColumn<int>(
    'mine',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _senderDeviceIdMeta = const VerificationMeta(
    'senderDeviceId',
  );
  @override
  late final GeneratedColumn<Uint8List> senderDeviceId =
      GeneratedColumn<Uint8List>(
        'sender_device_id',
        aliasedName,
        true,
        type: DriftSqlType.blob,
        requiredDuringInsert: false,
      );
  @override
  List<GeneratedColumn> get $columns => [
    conversationId,
    messageId,
    sortKey,
    state,
    generation,
    epoch,
    fromSelf,
    content,
    checkState,
    kind,
    mine,
    senderDeviceId,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'vault_messages';
  @override
  VerificationContext validateIntegrity(
    Insertable<VaultMessageRow> instance, {
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
    if (data.containsKey('state')) {
      context.handle(
        _stateMeta,
        state.isAcceptableOrUnknown(data['state']!, _stateMeta),
      );
    } else if (isInserting) {
      context.missing(_stateMeta);
    }
    if (data.containsKey('generation')) {
      context.handle(
        _generationMeta,
        generation.isAcceptableOrUnknown(data['generation']!, _generationMeta),
      );
    } else if (isInserting) {
      context.missing(_generationMeta);
    }
    if (data.containsKey('epoch')) {
      context.handle(
        _epochMeta,
        epoch.isAcceptableOrUnknown(data['epoch']!, _epochMeta),
      );
    } else if (isInserting) {
      context.missing(_epochMeta);
    }
    if (data.containsKey('from_self')) {
      context.handle(
        _fromSelfMeta,
        fromSelf.isAcceptableOrUnknown(data['from_self']!, _fromSelfMeta),
      );
    } else if (isInserting) {
      context.missing(_fromSelfMeta);
    }
    if (data.containsKey('content')) {
      context.handle(
        _contentMeta,
        content.isAcceptableOrUnknown(data['content']!, _contentMeta),
      );
    }
    if (data.containsKey('check_state')) {
      context.handle(
        _checkStateMeta,
        checkState.isAcceptableOrUnknown(data['check_state']!, _checkStateMeta),
      );
    }
    if (data.containsKey('kind')) {
      context.handle(
        _kindMeta,
        kind.isAcceptableOrUnknown(data['kind']!, _kindMeta),
      );
    }
    if (data.containsKey('mine')) {
      context.handle(
        _mineMeta,
        mine.isAcceptableOrUnknown(data['mine']!, _mineMeta),
      );
    }
    if (data.containsKey('sender_device_id')) {
      context.handle(
        _senderDeviceIdMeta,
        senderDeviceId.isAcceptableOrUnknown(
          data['sender_device_id']!,
          _senderDeviceIdMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {conversationId, messageId};
  @override
  VaultMessageRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return VaultMessageRow(
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
      state: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}state'],
      )!,
      generation: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}generation'],
      )!,
      epoch: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}epoch'],
      )!,
      fromSelf: attachedDatabase.typeMapping.read(
        DriftSqlType.blob,
        data['${effectivePrefix}from_self'],
      )!,
      content: attachedDatabase.typeMapping.read(
        DriftSqlType.blob,
        data['${effectivePrefix}content'],
      ),
      checkState: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}check_state'],
      )!,
      kind: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}kind'],
      )!,
      mine: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}mine'],
      ),
      senderDeviceId: attachedDatabase.typeMapping.read(
        DriftSqlType.blob,
        data['${effectivePrefix}sender_device_id'],
      ),
    );
  }

  @override
  $VaultMessagesTable createAlias(String alias) {
    return $VaultMessagesTable(attachedDatabase, alias);
  }
}

class VaultMessageRow extends DataClass implements Insertable<VaultMessageRow> {
  final String conversationId;
  final String messageId;

  /// Clear: [vaultSortKey] of the message's creation time and id. The
  /// creation time is read back from it, so it has no column of its own.
  final String sortKey;

  /// Clear: one of [StoredMessageState].
  final String state;
  final int generation;
  final int epoch;

  /// Sealed: one byte, 1 for a message this user sent. Legacy (version 1):
  /// version 2 always writes it equal to [mine].
  final Uint8List fromSelf;

  /// Sealed; NULL for a tombstone (never a sealed empty value).
  final Uint8List? content;

  /// Clear (version 2): one of `StoredMessageCheck`.
  final String checkState;

  /// Clear (version 2): one of `StoredMessageKind`.
  final String kind;

  /// Clear (version 2): 1 for a message from this user's own devices; NULL
  /// for a version 1 row whose sealed [fromSelf] did not authenticate.
  final int? mine;

  /// Sealed (version 2): the sender's device id; NULL when not known.
  final Uint8List? senderDeviceId;
  const VaultMessageRow({
    required this.conversationId,
    required this.messageId,
    required this.sortKey,
    required this.state,
    required this.generation,
    required this.epoch,
    required this.fromSelf,
    this.content,
    required this.checkState,
    required this.kind,
    this.mine,
    this.senderDeviceId,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['conversation_id'] = Variable<String>(conversationId);
    map['message_id'] = Variable<String>(messageId);
    map['sort_key'] = Variable<String>(sortKey);
    map['state'] = Variable<String>(state);
    map['generation'] = Variable<int>(generation);
    map['epoch'] = Variable<int>(epoch);
    map['from_self'] = Variable<Uint8List>(fromSelf);
    if (!nullToAbsent || content != null) {
      map['content'] = Variable<Uint8List>(content);
    }
    map['check_state'] = Variable<String>(checkState);
    map['kind'] = Variable<String>(kind);
    if (!nullToAbsent || mine != null) {
      map['mine'] = Variable<int>(mine);
    }
    if (!nullToAbsent || senderDeviceId != null) {
      map['sender_device_id'] = Variable<Uint8List>(senderDeviceId);
    }
    return map;
  }

  VaultMessagesCompanion toCompanion(bool nullToAbsent) {
    return VaultMessagesCompanion(
      conversationId: Value(conversationId),
      messageId: Value(messageId),
      sortKey: Value(sortKey),
      state: Value(state),
      generation: Value(generation),
      epoch: Value(epoch),
      fromSelf: Value(fromSelf),
      content: content == null && nullToAbsent
          ? const Value.absent()
          : Value(content),
      checkState: Value(checkState),
      kind: Value(kind),
      mine: mine == null && nullToAbsent ? const Value.absent() : Value(mine),
      senderDeviceId: senderDeviceId == null && nullToAbsent
          ? const Value.absent()
          : Value(senderDeviceId),
    );
  }

  factory VaultMessageRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return VaultMessageRow(
      conversationId: serializer.fromJson<String>(json['conversationId']),
      messageId: serializer.fromJson<String>(json['messageId']),
      sortKey: serializer.fromJson<String>(json['sortKey']),
      state: serializer.fromJson<String>(json['state']),
      generation: serializer.fromJson<int>(json['generation']),
      epoch: serializer.fromJson<int>(json['epoch']),
      fromSelf: serializer.fromJson<Uint8List>(json['fromSelf']),
      content: serializer.fromJson<Uint8List?>(json['content']),
      checkState: serializer.fromJson<String>(json['checkState']),
      kind: serializer.fromJson<String>(json['kind']),
      mine: serializer.fromJson<int?>(json['mine']),
      senderDeviceId: serializer.fromJson<Uint8List?>(json['senderDeviceId']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'conversationId': serializer.toJson<String>(conversationId),
      'messageId': serializer.toJson<String>(messageId),
      'sortKey': serializer.toJson<String>(sortKey),
      'state': serializer.toJson<String>(state),
      'generation': serializer.toJson<int>(generation),
      'epoch': serializer.toJson<int>(epoch),
      'fromSelf': serializer.toJson<Uint8List>(fromSelf),
      'content': serializer.toJson<Uint8List?>(content),
      'checkState': serializer.toJson<String>(checkState),
      'kind': serializer.toJson<String>(kind),
      'mine': serializer.toJson<int?>(mine),
      'senderDeviceId': serializer.toJson<Uint8List?>(senderDeviceId),
    };
  }

  VaultMessageRow copyWith({
    String? conversationId,
    String? messageId,
    String? sortKey,
    String? state,
    int? generation,
    int? epoch,
    Uint8List? fromSelf,
    Value<Uint8List?> content = const Value.absent(),
    String? checkState,
    String? kind,
    Value<int?> mine = const Value.absent(),
    Value<Uint8List?> senderDeviceId = const Value.absent(),
  }) => VaultMessageRow(
    conversationId: conversationId ?? this.conversationId,
    messageId: messageId ?? this.messageId,
    sortKey: sortKey ?? this.sortKey,
    state: state ?? this.state,
    generation: generation ?? this.generation,
    epoch: epoch ?? this.epoch,
    fromSelf: fromSelf ?? this.fromSelf,
    content: content.present ? content.value : this.content,
    checkState: checkState ?? this.checkState,
    kind: kind ?? this.kind,
    mine: mine.present ? mine.value : this.mine,
    senderDeviceId: senderDeviceId.present
        ? senderDeviceId.value
        : this.senderDeviceId,
  );
  VaultMessageRow copyWithCompanion(VaultMessagesCompanion data) {
    return VaultMessageRow(
      conversationId: data.conversationId.present
          ? data.conversationId.value
          : this.conversationId,
      messageId: data.messageId.present ? data.messageId.value : this.messageId,
      sortKey: data.sortKey.present ? data.sortKey.value : this.sortKey,
      state: data.state.present ? data.state.value : this.state,
      generation: data.generation.present
          ? data.generation.value
          : this.generation,
      epoch: data.epoch.present ? data.epoch.value : this.epoch,
      fromSelf: data.fromSelf.present ? data.fromSelf.value : this.fromSelf,
      content: data.content.present ? data.content.value : this.content,
      checkState: data.checkState.present
          ? data.checkState.value
          : this.checkState,
      kind: data.kind.present ? data.kind.value : this.kind,
      mine: data.mine.present ? data.mine.value : this.mine,
      senderDeviceId: data.senderDeviceId.present
          ? data.senderDeviceId.value
          : this.senderDeviceId,
    );
  }

  @override
  String toString() {
    return (StringBuffer('VaultMessageRow(')
          ..write('conversationId: $conversationId, ')
          ..write('messageId: $messageId, ')
          ..write('sortKey: $sortKey, ')
          ..write('state: $state, ')
          ..write('generation: $generation, ')
          ..write('epoch: $epoch, ')
          ..write('fromSelf: $fromSelf, ')
          ..write('content: $content, ')
          ..write('checkState: $checkState, ')
          ..write('kind: $kind, ')
          ..write('mine: $mine, ')
          ..write('senderDeviceId: $senderDeviceId')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    conversationId,
    messageId,
    sortKey,
    state,
    generation,
    epoch,
    $driftBlobEquality.hash(fromSelf),
    $driftBlobEquality.hash(content),
    checkState,
    kind,
    mine,
    $driftBlobEquality.hash(senderDeviceId),
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is VaultMessageRow &&
          other.conversationId == this.conversationId &&
          other.messageId == this.messageId &&
          other.sortKey == this.sortKey &&
          other.state == this.state &&
          other.generation == this.generation &&
          other.epoch == this.epoch &&
          $driftBlobEquality.equals(other.fromSelf, this.fromSelf) &&
          $driftBlobEquality.equals(other.content, this.content) &&
          other.checkState == this.checkState &&
          other.kind == this.kind &&
          other.mine == this.mine &&
          $driftBlobEquality.equals(other.senderDeviceId, this.senderDeviceId));
}

class VaultMessagesCompanion extends UpdateCompanion<VaultMessageRow> {
  final Value<String> conversationId;
  final Value<String> messageId;
  final Value<String> sortKey;
  final Value<String> state;
  final Value<int> generation;
  final Value<int> epoch;
  final Value<Uint8List> fromSelf;
  final Value<Uint8List?> content;
  final Value<String> checkState;
  final Value<String> kind;
  final Value<int?> mine;
  final Value<Uint8List?> senderDeviceId;
  final Value<int> rowid;
  const VaultMessagesCompanion({
    this.conversationId = const Value.absent(),
    this.messageId = const Value.absent(),
    this.sortKey = const Value.absent(),
    this.state = const Value.absent(),
    this.generation = const Value.absent(),
    this.epoch = const Value.absent(),
    this.fromSelf = const Value.absent(),
    this.content = const Value.absent(),
    this.checkState = const Value.absent(),
    this.kind = const Value.absent(),
    this.mine = const Value.absent(),
    this.senderDeviceId = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  VaultMessagesCompanion.insert({
    required String conversationId,
    required String messageId,
    required String sortKey,
    required String state,
    required int generation,
    required int epoch,
    required Uint8List fromSelf,
    this.content = const Value.absent(),
    this.checkState = const Value.absent(),
    this.kind = const Value.absent(),
    this.mine = const Value.absent(),
    this.senderDeviceId = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : conversationId = Value(conversationId),
       messageId = Value(messageId),
       sortKey = Value(sortKey),
       state = Value(state),
       generation = Value(generation),
       epoch = Value(epoch),
       fromSelf = Value(fromSelf);
  static Insertable<VaultMessageRow> custom({
    Expression<String>? conversationId,
    Expression<String>? messageId,
    Expression<String>? sortKey,
    Expression<String>? state,
    Expression<int>? generation,
    Expression<int>? epoch,
    Expression<Uint8List>? fromSelf,
    Expression<Uint8List>? content,
    Expression<String>? checkState,
    Expression<String>? kind,
    Expression<int>? mine,
    Expression<Uint8List>? senderDeviceId,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (conversationId != null) 'conversation_id': conversationId,
      if (messageId != null) 'message_id': messageId,
      if (sortKey != null) 'sort_key': sortKey,
      if (state != null) 'state': state,
      if (generation != null) 'generation': generation,
      if (epoch != null) 'epoch': epoch,
      if (fromSelf != null) 'from_self': fromSelf,
      if (content != null) 'content': content,
      if (checkState != null) 'check_state': checkState,
      if (kind != null) 'kind': kind,
      if (mine != null) 'mine': mine,
      if (senderDeviceId != null) 'sender_device_id': senderDeviceId,
      if (rowid != null) 'rowid': rowid,
    });
  }

  VaultMessagesCompanion copyWith({
    Value<String>? conversationId,
    Value<String>? messageId,
    Value<String>? sortKey,
    Value<String>? state,
    Value<int>? generation,
    Value<int>? epoch,
    Value<Uint8List>? fromSelf,
    Value<Uint8List?>? content,
    Value<String>? checkState,
    Value<String>? kind,
    Value<int?>? mine,
    Value<Uint8List?>? senderDeviceId,
    Value<int>? rowid,
  }) {
    return VaultMessagesCompanion(
      conversationId: conversationId ?? this.conversationId,
      messageId: messageId ?? this.messageId,
      sortKey: sortKey ?? this.sortKey,
      state: state ?? this.state,
      generation: generation ?? this.generation,
      epoch: epoch ?? this.epoch,
      fromSelf: fromSelf ?? this.fromSelf,
      content: content ?? this.content,
      checkState: checkState ?? this.checkState,
      kind: kind ?? this.kind,
      mine: mine ?? this.mine,
      senderDeviceId: senderDeviceId ?? this.senderDeviceId,
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
    if (state.present) {
      map['state'] = Variable<String>(state.value);
    }
    if (generation.present) {
      map['generation'] = Variable<int>(generation.value);
    }
    if (epoch.present) {
      map['epoch'] = Variable<int>(epoch.value);
    }
    if (fromSelf.present) {
      map['from_self'] = Variable<Uint8List>(fromSelf.value);
    }
    if (content.present) {
      map['content'] = Variable<Uint8List>(content.value);
    }
    if (checkState.present) {
      map['check_state'] = Variable<String>(checkState.value);
    }
    if (kind.present) {
      map['kind'] = Variable<String>(kind.value);
    }
    if (mine.present) {
      map['mine'] = Variable<int>(mine.value);
    }
    if (senderDeviceId.present) {
      map['sender_device_id'] = Variable<Uint8List>(senderDeviceId.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('VaultMessagesCompanion(')
          ..write('conversationId: $conversationId, ')
          ..write('messageId: $messageId, ')
          ..write('sortKey: $sortKey, ')
          ..write('state: $state, ')
          ..write('generation: $generation, ')
          ..write('epoch: $epoch, ')
          ..write('fromSelf: $fromSelf, ')
          ..write('content: $content, ')
          ..write('checkState: $checkState, ')
          ..write('kind: $kind, ')
          ..write('mine: $mine, ')
          ..write('senderDeviceId: $senderDeviceId, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $VaultOutboxTable extends VaultOutbox
    with TableInfo<$VaultOutboxTable, VaultOutboxRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $VaultOutboxTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idempotencyKeyMeta = const VerificationMeta(
    'idempotencyKey',
  );
  @override
  late final GeneratedColumn<String> idempotencyKey = GeneratedColumn<String>(
    'idempotency_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _conversationIdMeta = const VerificationMeta(
    'conversationId',
  );
  @override
  late final GeneratedColumn<String> conversationId = GeneratedColumn<String>(
    'conversation_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
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
  static const VerificationMeta _generationMeta = const VerificationMeta(
    'generation',
  );
  @override
  late final GeneratedColumn<int> generation = GeneratedColumn<int>(
    'generation',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _epochMeta = const VerificationMeta('epoch');
  @override
  late final GeneratedColumn<int> epoch = GeneratedColumn<int>(
    'epoch',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _recipientUserIdMeta = const VerificationMeta(
    'recipientUserId',
  );
  @override
  late final GeneratedColumn<Uint8List> recipientUserId =
      GeneratedColumn<Uint8List>(
        'recipient_user_id',
        aliasedName,
        true,
        type: DriftSqlType.blob,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _ciphertextMeta = const VerificationMeta(
    'ciphertext',
  );
  @override
  late final GeneratedColumn<Uint8List> ciphertext = GeneratedColumn<Uint8List>(
    'ciphertext',
    aliasedName,
    false,
    type: DriftSqlType.blob,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _reportCommitmentMeta = const VerificationMeta(
    'reportCommitment',
  );
  @override
  late final GeneratedColumn<Uint8List> reportCommitment =
      GeneratedColumn<Uint8List>(
        'report_commitment',
        aliasedName,
        false,
        type: DriftSqlType.blob,
        requiredDuringInsert: true,
      );
  static const VerificationMeta _contentMeta = const VerificationMeta(
    'content',
  );
  @override
  late final GeneratedColumn<Uint8List> content = GeneratedColumn<Uint8List>(
    'content',
    aliasedName,
    false,
    type: DriftSqlType.blob,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _attemptsMeta = const VerificationMeta(
    'attempts',
  );
  @override
  late final GeneratedColumn<Uint8List> attempts = GeneratedColumn<Uint8List>(
    'attempts',
    aliasedName,
    false,
    type: DriftSqlType.blob,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _lastErrorMeta = const VerificationMeta(
    'lastError',
  );
  @override
  late final GeneratedColumn<Uint8List> lastError = GeneratedColumn<Uint8List>(
    'last_error',
    aliasedName,
    true,
    type: DriftSqlType.blob,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _stageMeta = const VerificationMeta('stage');
  @override
  late final GeneratedColumn<String> stage = GeneratedColumn<String>(
    'stage',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('encrypted'),
  );
  static const VerificationMeta _expectedMessageIdMeta = const VerificationMeta(
    'expectedMessageId',
  );
  @override
  late final GeneratedColumn<String> expectedMessageId =
      GeneratedColumn<String>(
        'expected_message_id',
        aliasedName,
        true,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _localIdMeta = const VerificationMeta(
    'localId',
  );
  @override
  late final GeneratedColumn<String> localId = GeneratedColumn<String>(
    'local_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _initMeta = const VerificationMeta('init');
  @override
  late final GeneratedColumn<Uint8List> init = GeneratedColumn<Uint8List>(
    'init',
    aliasedName,
    true,
    type: DriftSqlType.blob,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    idempotencyKey,
    conversationId,
    sortKey,
    generation,
    epoch,
    recipientUserId,
    ciphertext,
    reportCommitment,
    content,
    attempts,
    lastError,
    stage,
    expectedMessageId,
    localId,
    init,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'vault_outbox';
  @override
  VerificationContext validateIntegrity(
    Insertable<VaultOutboxRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('idempotency_key')) {
      context.handle(
        _idempotencyKeyMeta,
        idempotencyKey.isAcceptableOrUnknown(
          data['idempotency_key']!,
          _idempotencyKeyMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_idempotencyKeyMeta);
    }
    if (data.containsKey('conversation_id')) {
      context.handle(
        _conversationIdMeta,
        conversationId.isAcceptableOrUnknown(
          data['conversation_id']!,
          _conversationIdMeta,
        ),
      );
    }
    if (data.containsKey('sort_key')) {
      context.handle(
        _sortKeyMeta,
        sortKey.isAcceptableOrUnknown(data['sort_key']!, _sortKeyMeta),
      );
    } else if (isInserting) {
      context.missing(_sortKeyMeta);
    }
    if (data.containsKey('generation')) {
      context.handle(
        _generationMeta,
        generation.isAcceptableOrUnknown(data['generation']!, _generationMeta),
      );
    } else if (isInserting) {
      context.missing(_generationMeta);
    }
    if (data.containsKey('epoch')) {
      context.handle(
        _epochMeta,
        epoch.isAcceptableOrUnknown(data['epoch']!, _epochMeta),
      );
    } else if (isInserting) {
      context.missing(_epochMeta);
    }
    if (data.containsKey('recipient_user_id')) {
      context.handle(
        _recipientUserIdMeta,
        recipientUserId.isAcceptableOrUnknown(
          data['recipient_user_id']!,
          _recipientUserIdMeta,
        ),
      );
    }
    if (data.containsKey('ciphertext')) {
      context.handle(
        _ciphertextMeta,
        ciphertext.isAcceptableOrUnknown(data['ciphertext']!, _ciphertextMeta),
      );
    } else if (isInserting) {
      context.missing(_ciphertextMeta);
    }
    if (data.containsKey('report_commitment')) {
      context.handle(
        _reportCommitmentMeta,
        reportCommitment.isAcceptableOrUnknown(
          data['report_commitment']!,
          _reportCommitmentMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_reportCommitmentMeta);
    }
    if (data.containsKey('content')) {
      context.handle(
        _contentMeta,
        content.isAcceptableOrUnknown(data['content']!, _contentMeta),
      );
    } else if (isInserting) {
      context.missing(_contentMeta);
    }
    if (data.containsKey('attempts')) {
      context.handle(
        _attemptsMeta,
        attempts.isAcceptableOrUnknown(data['attempts']!, _attemptsMeta),
      );
    } else if (isInserting) {
      context.missing(_attemptsMeta);
    }
    if (data.containsKey('last_error')) {
      context.handle(
        _lastErrorMeta,
        lastError.isAcceptableOrUnknown(data['last_error']!, _lastErrorMeta),
      );
    }
    if (data.containsKey('stage')) {
      context.handle(
        _stageMeta,
        stage.isAcceptableOrUnknown(data['stage']!, _stageMeta),
      );
    }
    if (data.containsKey('expected_message_id')) {
      context.handle(
        _expectedMessageIdMeta,
        expectedMessageId.isAcceptableOrUnknown(
          data['expected_message_id']!,
          _expectedMessageIdMeta,
        ),
      );
    }
    if (data.containsKey('local_id')) {
      context.handle(
        _localIdMeta,
        localId.isAcceptableOrUnknown(data['local_id']!, _localIdMeta),
      );
    }
    if (data.containsKey('init')) {
      context.handle(
        _initMeta,
        init.isAcceptableOrUnknown(data['init']!, _initMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {idempotencyKey};
  @override
  VaultOutboxRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return VaultOutboxRow(
      idempotencyKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}idempotency_key'],
      )!,
      conversationId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}conversation_id'],
      ),
      sortKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}sort_key'],
      )!,
      generation: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}generation'],
      )!,
      epoch: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}epoch'],
      )!,
      recipientUserId: attachedDatabase.typeMapping.read(
        DriftSqlType.blob,
        data['${effectivePrefix}recipient_user_id'],
      ),
      ciphertext: attachedDatabase.typeMapping.read(
        DriftSqlType.blob,
        data['${effectivePrefix}ciphertext'],
      )!,
      reportCommitment: attachedDatabase.typeMapping.read(
        DriftSqlType.blob,
        data['${effectivePrefix}report_commitment'],
      )!,
      content: attachedDatabase.typeMapping.read(
        DriftSqlType.blob,
        data['${effectivePrefix}content'],
      )!,
      attempts: attachedDatabase.typeMapping.read(
        DriftSqlType.blob,
        data['${effectivePrefix}attempts'],
      )!,
      lastError: attachedDatabase.typeMapping.read(
        DriftSqlType.blob,
        data['${effectivePrefix}last_error'],
      ),
      stage: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}stage'],
      )!,
      expectedMessageId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}expected_message_id'],
      ),
      localId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}local_id'],
      ),
      init: attachedDatabase.typeMapping.read(
        DriftSqlType.blob,
        data['${effectivePrefix}init'],
      ),
    );
  }

  @override
  $VaultOutboxTable createAlias(String alias) {
    return $VaultOutboxTable(attachedDatabase, alias);
  }
}

class VaultOutboxRow extends DataClass implements Insertable<VaultOutboxRow> {
  final String idempotencyKey;

  /// Clear; NULL for a first message to [recipientUserId].
  final String? conversationId;

  /// Clear: [vaultSortKey] of the item's creation time and idempotency key.
  final String sortKey;
  final int generation;
  final int epoch;

  /// Sealed (utf8); NULL when [conversationId] is set.
  final Uint8List? recipientUserId;

  /// Sealed.
  final Uint8List ciphertext;

  /// Sealed.
  final Uint8List reportCommitment;

  /// Sealed.
  final Uint8List content;

  /// Sealed (utf8 decimal).
  final Uint8List attempts;

  /// Sealed (utf8); NULL when there was no error.
  final Uint8List? lastError;

  /// Clear (version 2): one of `OutboxStage`.
  final String stage;

  /// Clear (version 2): the message id the server will give this send.
  final String? expectedMessageId;

  /// Clear (version 2): stable across re-keying; the first idempotency key.
  final String? localId;

  /// Sealed (version 2): the serialized `MlsInit`, exact bytes.
  final Uint8List? init;
  const VaultOutboxRow({
    required this.idempotencyKey,
    this.conversationId,
    required this.sortKey,
    required this.generation,
    required this.epoch,
    this.recipientUserId,
    required this.ciphertext,
    required this.reportCommitment,
    required this.content,
    required this.attempts,
    this.lastError,
    required this.stage,
    this.expectedMessageId,
    this.localId,
    this.init,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['idempotency_key'] = Variable<String>(idempotencyKey);
    if (!nullToAbsent || conversationId != null) {
      map['conversation_id'] = Variable<String>(conversationId);
    }
    map['sort_key'] = Variable<String>(sortKey);
    map['generation'] = Variable<int>(generation);
    map['epoch'] = Variable<int>(epoch);
    if (!nullToAbsent || recipientUserId != null) {
      map['recipient_user_id'] = Variable<Uint8List>(recipientUserId);
    }
    map['ciphertext'] = Variable<Uint8List>(ciphertext);
    map['report_commitment'] = Variable<Uint8List>(reportCommitment);
    map['content'] = Variable<Uint8List>(content);
    map['attempts'] = Variable<Uint8List>(attempts);
    if (!nullToAbsent || lastError != null) {
      map['last_error'] = Variable<Uint8List>(lastError);
    }
    map['stage'] = Variable<String>(stage);
    if (!nullToAbsent || expectedMessageId != null) {
      map['expected_message_id'] = Variable<String>(expectedMessageId);
    }
    if (!nullToAbsent || localId != null) {
      map['local_id'] = Variable<String>(localId);
    }
    if (!nullToAbsent || init != null) {
      map['init'] = Variable<Uint8List>(init);
    }
    return map;
  }

  VaultOutboxCompanion toCompanion(bool nullToAbsent) {
    return VaultOutboxCompanion(
      idempotencyKey: Value(idempotencyKey),
      conversationId: conversationId == null && nullToAbsent
          ? const Value.absent()
          : Value(conversationId),
      sortKey: Value(sortKey),
      generation: Value(generation),
      epoch: Value(epoch),
      recipientUserId: recipientUserId == null && nullToAbsent
          ? const Value.absent()
          : Value(recipientUserId),
      ciphertext: Value(ciphertext),
      reportCommitment: Value(reportCommitment),
      content: Value(content),
      attempts: Value(attempts),
      lastError: lastError == null && nullToAbsent
          ? const Value.absent()
          : Value(lastError),
      stage: Value(stage),
      expectedMessageId: expectedMessageId == null && nullToAbsent
          ? const Value.absent()
          : Value(expectedMessageId),
      localId: localId == null && nullToAbsent
          ? const Value.absent()
          : Value(localId),
      init: init == null && nullToAbsent ? const Value.absent() : Value(init),
    );
  }

  factory VaultOutboxRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return VaultOutboxRow(
      idempotencyKey: serializer.fromJson<String>(json['idempotencyKey']),
      conversationId: serializer.fromJson<String?>(json['conversationId']),
      sortKey: serializer.fromJson<String>(json['sortKey']),
      generation: serializer.fromJson<int>(json['generation']),
      epoch: serializer.fromJson<int>(json['epoch']),
      recipientUserId: serializer.fromJson<Uint8List?>(json['recipientUserId']),
      ciphertext: serializer.fromJson<Uint8List>(json['ciphertext']),
      reportCommitment: serializer.fromJson<Uint8List>(
        json['reportCommitment'],
      ),
      content: serializer.fromJson<Uint8List>(json['content']),
      attempts: serializer.fromJson<Uint8List>(json['attempts']),
      lastError: serializer.fromJson<Uint8List?>(json['lastError']),
      stage: serializer.fromJson<String>(json['stage']),
      expectedMessageId: serializer.fromJson<String?>(
        json['expectedMessageId'],
      ),
      localId: serializer.fromJson<String?>(json['localId']),
      init: serializer.fromJson<Uint8List?>(json['init']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'idempotencyKey': serializer.toJson<String>(idempotencyKey),
      'conversationId': serializer.toJson<String?>(conversationId),
      'sortKey': serializer.toJson<String>(sortKey),
      'generation': serializer.toJson<int>(generation),
      'epoch': serializer.toJson<int>(epoch),
      'recipientUserId': serializer.toJson<Uint8List?>(recipientUserId),
      'ciphertext': serializer.toJson<Uint8List>(ciphertext),
      'reportCommitment': serializer.toJson<Uint8List>(reportCommitment),
      'content': serializer.toJson<Uint8List>(content),
      'attempts': serializer.toJson<Uint8List>(attempts),
      'lastError': serializer.toJson<Uint8List?>(lastError),
      'stage': serializer.toJson<String>(stage),
      'expectedMessageId': serializer.toJson<String?>(expectedMessageId),
      'localId': serializer.toJson<String?>(localId),
      'init': serializer.toJson<Uint8List?>(init),
    };
  }

  VaultOutboxRow copyWith({
    String? idempotencyKey,
    Value<String?> conversationId = const Value.absent(),
    String? sortKey,
    int? generation,
    int? epoch,
    Value<Uint8List?> recipientUserId = const Value.absent(),
    Uint8List? ciphertext,
    Uint8List? reportCommitment,
    Uint8List? content,
    Uint8List? attempts,
    Value<Uint8List?> lastError = const Value.absent(),
    String? stage,
    Value<String?> expectedMessageId = const Value.absent(),
    Value<String?> localId = const Value.absent(),
    Value<Uint8List?> init = const Value.absent(),
  }) => VaultOutboxRow(
    idempotencyKey: idempotencyKey ?? this.idempotencyKey,
    conversationId: conversationId.present
        ? conversationId.value
        : this.conversationId,
    sortKey: sortKey ?? this.sortKey,
    generation: generation ?? this.generation,
    epoch: epoch ?? this.epoch,
    recipientUserId: recipientUserId.present
        ? recipientUserId.value
        : this.recipientUserId,
    ciphertext: ciphertext ?? this.ciphertext,
    reportCommitment: reportCommitment ?? this.reportCommitment,
    content: content ?? this.content,
    attempts: attempts ?? this.attempts,
    lastError: lastError.present ? lastError.value : this.lastError,
    stage: stage ?? this.stage,
    expectedMessageId: expectedMessageId.present
        ? expectedMessageId.value
        : this.expectedMessageId,
    localId: localId.present ? localId.value : this.localId,
    init: init.present ? init.value : this.init,
  );
  VaultOutboxRow copyWithCompanion(VaultOutboxCompanion data) {
    return VaultOutboxRow(
      idempotencyKey: data.idempotencyKey.present
          ? data.idempotencyKey.value
          : this.idempotencyKey,
      conversationId: data.conversationId.present
          ? data.conversationId.value
          : this.conversationId,
      sortKey: data.sortKey.present ? data.sortKey.value : this.sortKey,
      generation: data.generation.present
          ? data.generation.value
          : this.generation,
      epoch: data.epoch.present ? data.epoch.value : this.epoch,
      recipientUserId: data.recipientUserId.present
          ? data.recipientUserId.value
          : this.recipientUserId,
      ciphertext: data.ciphertext.present
          ? data.ciphertext.value
          : this.ciphertext,
      reportCommitment: data.reportCommitment.present
          ? data.reportCommitment.value
          : this.reportCommitment,
      content: data.content.present ? data.content.value : this.content,
      attempts: data.attempts.present ? data.attempts.value : this.attempts,
      lastError: data.lastError.present ? data.lastError.value : this.lastError,
      stage: data.stage.present ? data.stage.value : this.stage,
      expectedMessageId: data.expectedMessageId.present
          ? data.expectedMessageId.value
          : this.expectedMessageId,
      localId: data.localId.present ? data.localId.value : this.localId,
      init: data.init.present ? data.init.value : this.init,
    );
  }

  @override
  String toString() {
    return (StringBuffer('VaultOutboxRow(')
          ..write('idempotencyKey: $idempotencyKey, ')
          ..write('conversationId: $conversationId, ')
          ..write('sortKey: $sortKey, ')
          ..write('generation: $generation, ')
          ..write('epoch: $epoch, ')
          ..write('recipientUserId: $recipientUserId, ')
          ..write('ciphertext: $ciphertext, ')
          ..write('reportCommitment: $reportCommitment, ')
          ..write('content: $content, ')
          ..write('attempts: $attempts, ')
          ..write('lastError: $lastError, ')
          ..write('stage: $stage, ')
          ..write('expectedMessageId: $expectedMessageId, ')
          ..write('localId: $localId, ')
          ..write('init: $init')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    idempotencyKey,
    conversationId,
    sortKey,
    generation,
    epoch,
    $driftBlobEquality.hash(recipientUserId),
    $driftBlobEquality.hash(ciphertext),
    $driftBlobEquality.hash(reportCommitment),
    $driftBlobEquality.hash(content),
    $driftBlobEquality.hash(attempts),
    $driftBlobEquality.hash(lastError),
    stage,
    expectedMessageId,
    localId,
    $driftBlobEquality.hash(init),
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is VaultOutboxRow &&
          other.idempotencyKey == this.idempotencyKey &&
          other.conversationId == this.conversationId &&
          other.sortKey == this.sortKey &&
          other.generation == this.generation &&
          other.epoch == this.epoch &&
          $driftBlobEquality.equals(
            other.recipientUserId,
            this.recipientUserId,
          ) &&
          $driftBlobEquality.equals(other.ciphertext, this.ciphertext) &&
          $driftBlobEquality.equals(
            other.reportCommitment,
            this.reportCommitment,
          ) &&
          $driftBlobEquality.equals(other.content, this.content) &&
          $driftBlobEquality.equals(other.attempts, this.attempts) &&
          $driftBlobEquality.equals(other.lastError, this.lastError) &&
          other.stage == this.stage &&
          other.expectedMessageId == this.expectedMessageId &&
          other.localId == this.localId &&
          $driftBlobEquality.equals(other.init, this.init));
}

class VaultOutboxCompanion extends UpdateCompanion<VaultOutboxRow> {
  final Value<String> idempotencyKey;
  final Value<String?> conversationId;
  final Value<String> sortKey;
  final Value<int> generation;
  final Value<int> epoch;
  final Value<Uint8List?> recipientUserId;
  final Value<Uint8List> ciphertext;
  final Value<Uint8List> reportCommitment;
  final Value<Uint8List> content;
  final Value<Uint8List> attempts;
  final Value<Uint8List?> lastError;
  final Value<String> stage;
  final Value<String?> expectedMessageId;
  final Value<String?> localId;
  final Value<Uint8List?> init;
  final Value<int> rowid;
  const VaultOutboxCompanion({
    this.idempotencyKey = const Value.absent(),
    this.conversationId = const Value.absent(),
    this.sortKey = const Value.absent(),
    this.generation = const Value.absent(),
    this.epoch = const Value.absent(),
    this.recipientUserId = const Value.absent(),
    this.ciphertext = const Value.absent(),
    this.reportCommitment = const Value.absent(),
    this.content = const Value.absent(),
    this.attempts = const Value.absent(),
    this.lastError = const Value.absent(),
    this.stage = const Value.absent(),
    this.expectedMessageId = const Value.absent(),
    this.localId = const Value.absent(),
    this.init = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  VaultOutboxCompanion.insert({
    required String idempotencyKey,
    this.conversationId = const Value.absent(),
    required String sortKey,
    required int generation,
    required int epoch,
    this.recipientUserId = const Value.absent(),
    required Uint8List ciphertext,
    required Uint8List reportCommitment,
    required Uint8List content,
    required Uint8List attempts,
    this.lastError = const Value.absent(),
    this.stage = const Value.absent(),
    this.expectedMessageId = const Value.absent(),
    this.localId = const Value.absent(),
    this.init = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : idempotencyKey = Value(idempotencyKey),
       sortKey = Value(sortKey),
       generation = Value(generation),
       epoch = Value(epoch),
       ciphertext = Value(ciphertext),
       reportCommitment = Value(reportCommitment),
       content = Value(content),
       attempts = Value(attempts);
  static Insertable<VaultOutboxRow> custom({
    Expression<String>? idempotencyKey,
    Expression<String>? conversationId,
    Expression<String>? sortKey,
    Expression<int>? generation,
    Expression<int>? epoch,
    Expression<Uint8List>? recipientUserId,
    Expression<Uint8List>? ciphertext,
    Expression<Uint8List>? reportCommitment,
    Expression<Uint8List>? content,
    Expression<Uint8List>? attempts,
    Expression<Uint8List>? lastError,
    Expression<String>? stage,
    Expression<String>? expectedMessageId,
    Expression<String>? localId,
    Expression<Uint8List>? init,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (idempotencyKey != null) 'idempotency_key': idempotencyKey,
      if (conversationId != null) 'conversation_id': conversationId,
      if (sortKey != null) 'sort_key': sortKey,
      if (generation != null) 'generation': generation,
      if (epoch != null) 'epoch': epoch,
      if (recipientUserId != null) 'recipient_user_id': recipientUserId,
      if (ciphertext != null) 'ciphertext': ciphertext,
      if (reportCommitment != null) 'report_commitment': reportCommitment,
      if (content != null) 'content': content,
      if (attempts != null) 'attempts': attempts,
      if (lastError != null) 'last_error': lastError,
      if (stage != null) 'stage': stage,
      if (expectedMessageId != null) 'expected_message_id': expectedMessageId,
      if (localId != null) 'local_id': localId,
      if (init != null) 'init': init,
      if (rowid != null) 'rowid': rowid,
    });
  }

  VaultOutboxCompanion copyWith({
    Value<String>? idempotencyKey,
    Value<String?>? conversationId,
    Value<String>? sortKey,
    Value<int>? generation,
    Value<int>? epoch,
    Value<Uint8List?>? recipientUserId,
    Value<Uint8List>? ciphertext,
    Value<Uint8List>? reportCommitment,
    Value<Uint8List>? content,
    Value<Uint8List>? attempts,
    Value<Uint8List?>? lastError,
    Value<String>? stage,
    Value<String?>? expectedMessageId,
    Value<String?>? localId,
    Value<Uint8List?>? init,
    Value<int>? rowid,
  }) {
    return VaultOutboxCompanion(
      idempotencyKey: idempotencyKey ?? this.idempotencyKey,
      conversationId: conversationId ?? this.conversationId,
      sortKey: sortKey ?? this.sortKey,
      generation: generation ?? this.generation,
      epoch: epoch ?? this.epoch,
      recipientUserId: recipientUserId ?? this.recipientUserId,
      ciphertext: ciphertext ?? this.ciphertext,
      reportCommitment: reportCommitment ?? this.reportCommitment,
      content: content ?? this.content,
      attempts: attempts ?? this.attempts,
      lastError: lastError ?? this.lastError,
      stage: stage ?? this.stage,
      expectedMessageId: expectedMessageId ?? this.expectedMessageId,
      localId: localId ?? this.localId,
      init: init ?? this.init,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (idempotencyKey.present) {
      map['idempotency_key'] = Variable<String>(idempotencyKey.value);
    }
    if (conversationId.present) {
      map['conversation_id'] = Variable<String>(conversationId.value);
    }
    if (sortKey.present) {
      map['sort_key'] = Variable<String>(sortKey.value);
    }
    if (generation.present) {
      map['generation'] = Variable<int>(generation.value);
    }
    if (epoch.present) {
      map['epoch'] = Variable<int>(epoch.value);
    }
    if (recipientUserId.present) {
      map['recipient_user_id'] = Variable<Uint8List>(recipientUserId.value);
    }
    if (ciphertext.present) {
      map['ciphertext'] = Variable<Uint8List>(ciphertext.value);
    }
    if (reportCommitment.present) {
      map['report_commitment'] = Variable<Uint8List>(reportCommitment.value);
    }
    if (content.present) {
      map['content'] = Variable<Uint8List>(content.value);
    }
    if (attempts.present) {
      map['attempts'] = Variable<Uint8List>(attempts.value);
    }
    if (lastError.present) {
      map['last_error'] = Variable<Uint8List>(lastError.value);
    }
    if (stage.present) {
      map['stage'] = Variable<String>(stage.value);
    }
    if (expectedMessageId.present) {
      map['expected_message_id'] = Variable<String>(expectedMessageId.value);
    }
    if (localId.present) {
      map['local_id'] = Variable<String>(localId.value);
    }
    if (init.present) {
      map['init'] = Variable<Uint8List>(init.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('VaultOutboxCompanion(')
          ..write('idempotencyKey: $idempotencyKey, ')
          ..write('conversationId: $conversationId, ')
          ..write('sortKey: $sortKey, ')
          ..write('generation: $generation, ')
          ..write('epoch: $epoch, ')
          ..write('recipientUserId: $recipientUserId, ')
          ..write('ciphertext: $ciphertext, ')
          ..write('reportCommitment: $reportCommitment, ')
          ..write('content: $content, ')
          ..write('attempts: $attempts, ')
          ..write('lastError: $lastError, ')
          ..write('stage: $stage, ')
          ..write('expectedMessageId: $expectedMessageId, ')
          ..write('localId: $localId, ')
          ..write('init: $init, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $VaultSettingsTable extends VaultSettings
    with TableInfo<$VaultSettingsTable, VaultSettingRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $VaultSettingsTable(this.attachedDatabase, [this._alias]);
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
  static const VerificationMeta _valueMeta = const VerificationMeta('value');
  @override
  late final GeneratedColumn<Uint8List> value = GeneratedColumn<Uint8List>(
    'value',
    aliasedName,
    false,
    type: DriftSqlType.blob,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [settingKey, value];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'vault_settings';
  @override
  VerificationContext validateIntegrity(
    Insertable<VaultSettingRow> instance, {
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
    if (data.containsKey('value')) {
      context.handle(
        _valueMeta,
        value.isAcceptableOrUnknown(data['value']!, _valueMeta),
      );
    } else if (isInserting) {
      context.missing(_valueMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {settingKey};
  @override
  VaultSettingRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return VaultSettingRow(
      settingKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}setting_key'],
      )!,
      value: attachedDatabase.typeMapping.read(
        DriftSqlType.blob,
        data['${effectivePrefix}value'],
      )!,
    );
  }

  @override
  $VaultSettingsTable createAlias(String alias) {
    return $VaultSettingsTable(attachedDatabase, alias);
  }
}

class VaultSettingRow extends DataClass implements Insertable<VaultSettingRow> {
  final String settingKey;

  /// Sealed.
  final Uint8List value;
  const VaultSettingRow({required this.settingKey, required this.value});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['setting_key'] = Variable<String>(settingKey);
    map['value'] = Variable<Uint8List>(value);
    return map;
  }

  VaultSettingsCompanion toCompanion(bool nullToAbsent) {
    return VaultSettingsCompanion(
      settingKey: Value(settingKey),
      value: Value(value),
    );
  }

  factory VaultSettingRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return VaultSettingRow(
      settingKey: serializer.fromJson<String>(json['settingKey']),
      value: serializer.fromJson<Uint8List>(json['value']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'settingKey': serializer.toJson<String>(settingKey),
      'value': serializer.toJson<Uint8List>(value),
    };
  }

  VaultSettingRow copyWith({String? settingKey, Uint8List? value}) =>
      VaultSettingRow(
        settingKey: settingKey ?? this.settingKey,
        value: value ?? this.value,
      );
  VaultSettingRow copyWithCompanion(VaultSettingsCompanion data) {
    return VaultSettingRow(
      settingKey: data.settingKey.present
          ? data.settingKey.value
          : this.settingKey,
      value: data.value.present ? data.value.value : this.value,
    );
  }

  @override
  String toString() {
    return (StringBuffer('VaultSettingRow(')
          ..write('settingKey: $settingKey, ')
          ..write('value: $value')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(settingKey, $driftBlobEquality.hash(value));
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is VaultSettingRow &&
          other.settingKey == this.settingKey &&
          $driftBlobEquality.equals(other.value, this.value));
}

class VaultSettingsCompanion extends UpdateCompanion<VaultSettingRow> {
  final Value<String> settingKey;
  final Value<Uint8List> value;
  final Value<int> rowid;
  const VaultSettingsCompanion({
    this.settingKey = const Value.absent(),
    this.value = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  VaultSettingsCompanion.insert({
    required String settingKey,
    required Uint8List value,
    this.rowid = const Value.absent(),
  }) : settingKey = Value(settingKey),
       value = Value(value);
  static Insertable<VaultSettingRow> custom({
    Expression<String>? settingKey,
    Expression<Uint8List>? value,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (settingKey != null) 'setting_key': settingKey,
      if (value != null) 'value': value,
      if (rowid != null) 'rowid': rowid,
    });
  }

  VaultSettingsCompanion copyWith({
    Value<String>? settingKey,
    Value<Uint8List>? value,
    Value<int>? rowid,
  }) {
    return VaultSettingsCompanion(
      settingKey: settingKey ?? this.settingKey,
      value: value ?? this.value,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (settingKey.present) {
      map['setting_key'] = Variable<String>(settingKey.value);
    }
    if (value.present) {
      map['value'] = Variable<Uint8List>(value.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('VaultSettingsCompanion(')
          ..write('settingKey: $settingKey, ')
          ..write('value: $value, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$VaultDatabase extends GeneratedDatabase {
  _$VaultDatabase(QueryExecutor e) : super(e);
  $VaultDatabaseManager get managers => $VaultDatabaseManager(this);
  late final $VaultMetaTable vaultMeta = $VaultMetaTable(this);
  late final $VaultDeviceTable vaultDevice = $VaultDeviceTable(this);
  late final $VaultGroupsTable vaultGroups = $VaultGroupsTable(this);
  late final $VaultGroupStatesTable vaultGroupStates = $VaultGroupStatesTable(
    this,
  );
  late final $VaultConversationsTable vaultConversations =
      $VaultConversationsTable(this);
  late final $VaultMembersTable vaultMembers = $VaultMembersTable(this);
  late final $VaultSentTable vaultSent = $VaultSentTable(this);
  late final $VaultMessagesTable vaultMessages = $VaultMessagesTable(this);
  late final $VaultOutboxTable vaultOutbox = $VaultOutboxTable(this);
  late final $VaultSettingsTable vaultSettings = $VaultSettingsTable(this);
  late final Index vaultMessagesBySort = Index(
    'vault_messages_by_sort',
    'CREATE INDEX vault_messages_by_sort ON vault_messages (conversation_id, sort_key)',
  );
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    vaultMeta,
    vaultDevice,
    vaultGroups,
    vaultGroupStates,
    vaultConversations,
    vaultMembers,
    vaultSent,
    vaultMessages,
    vaultOutbox,
    vaultSettings,
    vaultMessagesBySort,
  ];
}

typedef $$VaultMetaTableCreateCompanionBuilder = VaultMetaCompanion Function({
  required String metaKey,
  required String ownerUid,
  required int schemaVersion,
  required Uint8List sentinel,
  Value<int> rowid,
});
typedef $$VaultMetaTableUpdateCompanionBuilder = VaultMetaCompanion Function({
  Value<String> metaKey,
  Value<String> ownerUid,
  Value<int> schemaVersion,
  Value<Uint8List> sentinel,
  Value<int> rowid,
});

class $$VaultMetaTableFilterComposer
    extends Composer<_$VaultDatabase, $VaultMetaTable> {
  $$VaultMetaTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get metaKey => $composableBuilder(
    column: $table.metaKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get ownerUid => $composableBuilder(
    column: $table.ownerUid,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get schemaVersion => $composableBuilder(
    column: $table.schemaVersion,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<Uint8List> get sentinel => $composableBuilder(
    column: $table.sentinel,
    builder: (column) => ColumnFilters(column),
  );
}

class $$VaultMetaTableOrderingComposer
    extends Composer<_$VaultDatabase, $VaultMetaTable> {
  $$VaultMetaTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get metaKey => $composableBuilder(
    column: $table.metaKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get ownerUid => $composableBuilder(
    column: $table.ownerUid,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get schemaVersion => $composableBuilder(
    column: $table.schemaVersion,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<Uint8List> get sentinel => $composableBuilder(
    column: $table.sentinel,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$VaultMetaTableAnnotationComposer
    extends Composer<_$VaultDatabase, $VaultMetaTable> {
  $$VaultMetaTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get metaKey =>
      $composableBuilder(column: $table.metaKey, builder: (column) => column);

  GeneratedColumn<String> get ownerUid =>
      $composableBuilder(column: $table.ownerUid, builder: (column) => column);

  GeneratedColumn<int> get schemaVersion => $composableBuilder(
    column: $table.schemaVersion,
    builder: (column) => column,
  );

  GeneratedColumn<Uint8List> get sentinel =>
      $composableBuilder(column: $table.sentinel, builder: (column) => column);
}

class $$VaultMetaTableTableManager
    extends
        RootTableManager<
          _$VaultDatabase,
          $VaultMetaTable,
          VaultMetaRow,
          $$VaultMetaTableFilterComposer,
          $$VaultMetaTableOrderingComposer,
          $$VaultMetaTableAnnotationComposer,
          $$VaultMetaTableCreateCompanionBuilder,
          $$VaultMetaTableUpdateCompanionBuilder,
          (
            VaultMetaRow,
            BaseReferences<_$VaultDatabase, $VaultMetaTable, VaultMetaRow>,
          ),
          VaultMetaRow,
          PrefetchHooks Function()
        > {
  $$VaultMetaTableTableManager(_$VaultDatabase db, $VaultMetaTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$VaultMetaTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$VaultMetaTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$VaultMetaTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> metaKey = const Value.absent(),
                Value<String> ownerUid = const Value.absent(),
                Value<int> schemaVersion = const Value.absent(),
                Value<Uint8List> sentinel = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => VaultMetaCompanion(
                metaKey: metaKey,
                ownerUid: ownerUid,
                schemaVersion: schemaVersion,
                sentinel: sentinel,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String metaKey,
                required String ownerUid,
                required int schemaVersion,
                required Uint8List sentinel,
                Value<int> rowid = const Value.absent(),
              }) => VaultMetaCompanion.insert(
                metaKey: metaKey,
                ownerUid: ownerUid,
                schemaVersion: schemaVersion,
                sentinel: sentinel,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$VaultMetaTable, VaultMetaRow>(table),
                  BaseReferences<
                    _$VaultDatabase,
                    $VaultMetaTable,
                    VaultMetaRow
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$VaultMetaTableProcessedTableManager =
    ProcessedTableManager<
      _$VaultDatabase,
      $VaultMetaTable,
      VaultMetaRow,
      $$VaultMetaTableFilterComposer,
      $$VaultMetaTableOrderingComposer,
      $$VaultMetaTableAnnotationComposer,
      $$VaultMetaTableCreateCompanionBuilder,
      $$VaultMetaTableUpdateCompanionBuilder,
      (
        VaultMetaRow,
        BaseReferences<_$VaultDatabase, $VaultMetaTable, VaultMetaRow>,
      ),
      VaultMetaRow,
      PrefetchHooks Function()
    >;
typedef $$VaultDeviceTableCreateCompanionBuilder =
    VaultDeviceCompanion Function({
      required String slot,
      required Uint8List deviceId,
      required Uint8List deviceState,
      Value<int> rowid,
    });
typedef $$VaultDeviceTableUpdateCompanionBuilder =
    VaultDeviceCompanion Function({
      Value<String> slot,
      Value<Uint8List> deviceId,
      Value<Uint8List> deviceState,
      Value<int> rowid,
    });

class $$VaultDeviceTableFilterComposer
    extends Composer<_$VaultDatabase, $VaultDeviceTable> {
  $$VaultDeviceTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get slot => $composableBuilder(
    column: $table.slot,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<Uint8List> get deviceId => $composableBuilder(
    column: $table.deviceId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<Uint8List> get deviceState => $composableBuilder(
    column: $table.deviceState,
    builder: (column) => ColumnFilters(column),
  );
}

class $$VaultDeviceTableOrderingComposer
    extends Composer<_$VaultDatabase, $VaultDeviceTable> {
  $$VaultDeviceTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get slot => $composableBuilder(
    column: $table.slot,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<Uint8List> get deviceId => $composableBuilder(
    column: $table.deviceId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<Uint8List> get deviceState => $composableBuilder(
    column: $table.deviceState,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$VaultDeviceTableAnnotationComposer
    extends Composer<_$VaultDatabase, $VaultDeviceTable> {
  $$VaultDeviceTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get slot =>
      $composableBuilder(column: $table.slot, builder: (column) => column);

  GeneratedColumn<Uint8List> get deviceId =>
      $composableBuilder(column: $table.deviceId, builder: (column) => column);

  GeneratedColumn<Uint8List> get deviceState => $composableBuilder(
    column: $table.deviceState,
    builder: (column) => column,
  );
}

class $$VaultDeviceTableTableManager
    extends
        RootTableManager<
          _$VaultDatabase,
          $VaultDeviceTable,
          VaultDeviceRow,
          $$VaultDeviceTableFilterComposer,
          $$VaultDeviceTableOrderingComposer,
          $$VaultDeviceTableAnnotationComposer,
          $$VaultDeviceTableCreateCompanionBuilder,
          $$VaultDeviceTableUpdateCompanionBuilder,
          (
            VaultDeviceRow,
            BaseReferences<_$VaultDatabase, $VaultDeviceTable, VaultDeviceRow>,
          ),
          VaultDeviceRow,
          PrefetchHooks Function()
        > {
  $$VaultDeviceTableTableManager(_$VaultDatabase db, $VaultDeviceTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$VaultDeviceTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$VaultDeviceTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$VaultDeviceTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> slot = const Value.absent(),
                Value<Uint8List> deviceId = const Value.absent(),
                Value<Uint8List> deviceState = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => VaultDeviceCompanion(
                slot: slot,
                deviceId: deviceId,
                deviceState: deviceState,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String slot,
                required Uint8List deviceId,
                required Uint8List deviceState,
                Value<int> rowid = const Value.absent(),
              }) => VaultDeviceCompanion.insert(
                slot: slot,
                deviceId: deviceId,
                deviceState: deviceState,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$VaultDeviceTable, VaultDeviceRow>(table),
                  BaseReferences<
                    _$VaultDatabase,
                    $VaultDeviceTable,
                    VaultDeviceRow
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$VaultDeviceTableProcessedTableManager =
    ProcessedTableManager<
      _$VaultDatabase,
      $VaultDeviceTable,
      VaultDeviceRow,
      $$VaultDeviceTableFilterComposer,
      $$VaultDeviceTableOrderingComposer,
      $$VaultDeviceTableAnnotationComposer,
      $$VaultDeviceTableCreateCompanionBuilder,
      $$VaultDeviceTableUpdateCompanionBuilder,
      (
        VaultDeviceRow,
        BaseReferences<_$VaultDatabase, $VaultDeviceTable, VaultDeviceRow>,
      ),
      VaultDeviceRow,
      PrefetchHooks Function()
    >;
typedef $$VaultGroupsTableCreateCompanionBuilder =
    VaultGroupsCompanion Function({
      required String conversationId,
      required int generation,
      required int epoch,
      required Uint8List state,
      required Uint8List pendingCommit,
      Value<int> rowid,
    });
typedef $$VaultGroupsTableUpdateCompanionBuilder =
    VaultGroupsCompanion Function({
      Value<String> conversationId,
      Value<int> generation,
      Value<int> epoch,
      Value<Uint8List> state,
      Value<Uint8List> pendingCommit,
      Value<int> rowid,
    });

class $$VaultGroupsTableFilterComposer
    extends Composer<_$VaultDatabase, $VaultGroupsTable> {
  $$VaultGroupsTableFilterComposer({
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

  ColumnFilters<int> get generation => $composableBuilder(
    column: $table.generation,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get epoch => $composableBuilder(
    column: $table.epoch,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<Uint8List> get state => $composableBuilder(
    column: $table.state,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<Uint8List> get pendingCommit => $composableBuilder(
    column: $table.pendingCommit,
    builder: (column) => ColumnFilters(column),
  );
}

class $$VaultGroupsTableOrderingComposer
    extends Composer<_$VaultDatabase, $VaultGroupsTable> {
  $$VaultGroupsTableOrderingComposer({
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

  ColumnOrderings<int> get generation => $composableBuilder(
    column: $table.generation,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get epoch => $composableBuilder(
    column: $table.epoch,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<Uint8List> get state => $composableBuilder(
    column: $table.state,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<Uint8List> get pendingCommit => $composableBuilder(
    column: $table.pendingCommit,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$VaultGroupsTableAnnotationComposer
    extends Composer<_$VaultDatabase, $VaultGroupsTable> {
  $$VaultGroupsTableAnnotationComposer({
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

  GeneratedColumn<int> get generation => $composableBuilder(
    column: $table.generation,
    builder: (column) => column,
  );

  GeneratedColumn<int> get epoch =>
      $composableBuilder(column: $table.epoch, builder: (column) => column);

  GeneratedColumn<Uint8List> get state =>
      $composableBuilder(column: $table.state, builder: (column) => column);

  GeneratedColumn<Uint8List> get pendingCommit => $composableBuilder(
    column: $table.pendingCommit,
    builder: (column) => column,
  );
}

class $$VaultGroupsTableTableManager
    extends
        RootTableManager<
          _$VaultDatabase,
          $VaultGroupsTable,
          VaultGroupRow,
          $$VaultGroupsTableFilterComposer,
          $$VaultGroupsTableOrderingComposer,
          $$VaultGroupsTableAnnotationComposer,
          $$VaultGroupsTableCreateCompanionBuilder,
          $$VaultGroupsTableUpdateCompanionBuilder,
          (
            VaultGroupRow,
            BaseReferences<_$VaultDatabase, $VaultGroupsTable, VaultGroupRow>,
          ),
          VaultGroupRow,
          PrefetchHooks Function()
        > {
  $$VaultGroupsTableTableManager(_$VaultDatabase db, $VaultGroupsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$VaultGroupsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$VaultGroupsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$VaultGroupsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> conversationId = const Value.absent(),
                Value<int> generation = const Value.absent(),
                Value<int> epoch = const Value.absent(),
                Value<Uint8List> state = const Value.absent(),
                Value<Uint8List> pendingCommit = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => VaultGroupsCompanion(
                conversationId: conversationId,
                generation: generation,
                epoch: epoch,
                state: state,
                pendingCommit: pendingCommit,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String conversationId,
                required int generation,
                required int epoch,
                required Uint8List state,
                required Uint8List pendingCommit,
                Value<int> rowid = const Value.absent(),
              }) => VaultGroupsCompanion.insert(
                conversationId: conversationId,
                generation: generation,
                epoch: epoch,
                state: state,
                pendingCommit: pendingCommit,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$VaultGroupsTable, VaultGroupRow>(table),
                  BaseReferences<
                    _$VaultDatabase,
                    $VaultGroupsTable,
                    VaultGroupRow
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$VaultGroupsTableProcessedTableManager =
    ProcessedTableManager<
      _$VaultDatabase,
      $VaultGroupsTable,
      VaultGroupRow,
      $$VaultGroupsTableFilterComposer,
      $$VaultGroupsTableOrderingComposer,
      $$VaultGroupsTableAnnotationComposer,
      $$VaultGroupsTableCreateCompanionBuilder,
      $$VaultGroupsTableUpdateCompanionBuilder,
      (
        VaultGroupRow,
        BaseReferences<_$VaultDatabase, $VaultGroupsTable, VaultGroupRow>,
      ),
      VaultGroupRow,
      PrefetchHooks Function()
    >;
typedef $$VaultGroupStatesTableCreateCompanionBuilder =
    VaultGroupStatesCompanion Function({
      required String conversationId,
      required int generation,
      required int epoch,
      Value<int> provisional,
      Value<int?> provisionalCreatedAt,
      required Uint8List state,
      Value<Uint8List?> pending,
      Value<int> rowid,
    });
typedef $$VaultGroupStatesTableUpdateCompanionBuilder =
    VaultGroupStatesCompanion Function({
      Value<String> conversationId,
      Value<int> generation,
      Value<int> epoch,
      Value<int> provisional,
      Value<int?> provisionalCreatedAt,
      Value<Uint8List> state,
      Value<Uint8List?> pending,
      Value<int> rowid,
    });

class $$VaultGroupStatesTableFilterComposer
    extends Composer<_$VaultDatabase, $VaultGroupStatesTable> {
  $$VaultGroupStatesTableFilterComposer({
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

  ColumnFilters<int> get generation => $composableBuilder(
    column: $table.generation,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get epoch => $composableBuilder(
    column: $table.epoch,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get provisional => $composableBuilder(
    column: $table.provisional,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get provisionalCreatedAt => $composableBuilder(
    column: $table.provisionalCreatedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<Uint8List> get state => $composableBuilder(
    column: $table.state,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<Uint8List> get pending => $composableBuilder(
    column: $table.pending,
    builder: (column) => ColumnFilters(column),
  );
}

class $$VaultGroupStatesTableOrderingComposer
    extends Composer<_$VaultDatabase, $VaultGroupStatesTable> {
  $$VaultGroupStatesTableOrderingComposer({
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

  ColumnOrderings<int> get generation => $composableBuilder(
    column: $table.generation,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get epoch => $composableBuilder(
    column: $table.epoch,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get provisional => $composableBuilder(
    column: $table.provisional,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get provisionalCreatedAt => $composableBuilder(
    column: $table.provisionalCreatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<Uint8List> get state => $composableBuilder(
    column: $table.state,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<Uint8List> get pending => $composableBuilder(
    column: $table.pending,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$VaultGroupStatesTableAnnotationComposer
    extends Composer<_$VaultDatabase, $VaultGroupStatesTable> {
  $$VaultGroupStatesTableAnnotationComposer({
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

  GeneratedColumn<int> get generation => $composableBuilder(
    column: $table.generation,
    builder: (column) => column,
  );

  GeneratedColumn<int> get epoch =>
      $composableBuilder(column: $table.epoch, builder: (column) => column);

  GeneratedColumn<int> get provisional => $composableBuilder(
    column: $table.provisional,
    builder: (column) => column,
  );

  GeneratedColumn<int> get provisionalCreatedAt => $composableBuilder(
    column: $table.provisionalCreatedAt,
    builder: (column) => column,
  );

  GeneratedColumn<Uint8List> get state =>
      $composableBuilder(column: $table.state, builder: (column) => column);

  GeneratedColumn<Uint8List> get pending =>
      $composableBuilder(column: $table.pending, builder: (column) => column);
}

class $$VaultGroupStatesTableTableManager
    extends
        RootTableManager<
          _$VaultDatabase,
          $VaultGroupStatesTable,
          VaultGroupStateRow,
          $$VaultGroupStatesTableFilterComposer,
          $$VaultGroupStatesTableOrderingComposer,
          $$VaultGroupStatesTableAnnotationComposer,
          $$VaultGroupStatesTableCreateCompanionBuilder,
          $$VaultGroupStatesTableUpdateCompanionBuilder,
          (
            VaultGroupStateRow,
            BaseReferences<
              _$VaultDatabase,
              $VaultGroupStatesTable,
              VaultGroupStateRow
            >,
          ),
          VaultGroupStateRow,
          PrefetchHooks Function()
        > {
  $$VaultGroupStatesTableTableManager(
    _$VaultDatabase db,
    $VaultGroupStatesTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$VaultGroupStatesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$VaultGroupStatesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$VaultGroupStatesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> conversationId = const Value.absent(),
                Value<int> generation = const Value.absent(),
                Value<int> epoch = const Value.absent(),
                Value<int> provisional = const Value.absent(),
                Value<int?> provisionalCreatedAt = const Value.absent(),
                Value<Uint8List> state = const Value.absent(),
                Value<Uint8List?> pending = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => VaultGroupStatesCompanion(
                conversationId: conversationId,
                generation: generation,
                epoch: epoch,
                provisional: provisional,
                provisionalCreatedAt: provisionalCreatedAt,
                state: state,
                pending: pending,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String conversationId,
                required int generation,
                required int epoch,
                Value<int> provisional = const Value.absent(),
                Value<int?> provisionalCreatedAt = const Value.absent(),
                required Uint8List state,
                Value<Uint8List?> pending = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => VaultGroupStatesCompanion.insert(
                conversationId: conversationId,
                generation: generation,
                epoch: epoch,
                provisional: provisional,
                provisionalCreatedAt: provisionalCreatedAt,
                state: state,
                pending: pending,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$VaultGroupStatesTable, VaultGroupStateRow>(
                    table,
                  ),
                  BaseReferences<
                    _$VaultDatabase,
                    $VaultGroupStatesTable,
                    VaultGroupStateRow
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$VaultGroupStatesTableProcessedTableManager =
    ProcessedTableManager<
      _$VaultDatabase,
      $VaultGroupStatesTable,
      VaultGroupStateRow,
      $$VaultGroupStatesTableFilterComposer,
      $$VaultGroupStatesTableOrderingComposer,
      $$VaultGroupStatesTableAnnotationComposer,
      $$VaultGroupStatesTableCreateCompanionBuilder,
      $$VaultGroupStatesTableUpdateCompanionBuilder,
      (
        VaultGroupStateRow,
        BaseReferences<
          _$VaultDatabase,
          $VaultGroupStatesTable,
          VaultGroupStateRow
        >,
      ),
      VaultGroupStateRow,
      PrefetchHooks Function()
    >;
typedef $$VaultConversationsTableCreateCompanionBuilder =
    VaultConversationsCompanion Function({
      required String conversationId,
      Value<int?> afterGeneration,
      Value<int?> afterEpoch,
      Value<int?> joinGeneration,
      Value<int?> joinEpoch,
      Value<Uint8List?> sync,
      Value<int> rowid,
    });
typedef $$VaultConversationsTableUpdateCompanionBuilder =
    VaultConversationsCompanion Function({
      Value<String> conversationId,
      Value<int?> afterGeneration,
      Value<int?> afterEpoch,
      Value<int?> joinGeneration,
      Value<int?> joinEpoch,
      Value<Uint8List?> sync,
      Value<int> rowid,
    });

class $$VaultConversationsTableFilterComposer
    extends Composer<_$VaultDatabase, $VaultConversationsTable> {
  $$VaultConversationsTableFilterComposer({
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

  ColumnFilters<int> get afterGeneration => $composableBuilder(
    column: $table.afterGeneration,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get afterEpoch => $composableBuilder(
    column: $table.afterEpoch,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get joinGeneration => $composableBuilder(
    column: $table.joinGeneration,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get joinEpoch => $composableBuilder(
    column: $table.joinEpoch,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<Uint8List> get sync => $composableBuilder(
    column: $table.sync,
    builder: (column) => ColumnFilters(column),
  );
}

class $$VaultConversationsTableOrderingComposer
    extends Composer<_$VaultDatabase, $VaultConversationsTable> {
  $$VaultConversationsTableOrderingComposer({
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

  ColumnOrderings<int> get afterGeneration => $composableBuilder(
    column: $table.afterGeneration,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get afterEpoch => $composableBuilder(
    column: $table.afterEpoch,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get joinGeneration => $composableBuilder(
    column: $table.joinGeneration,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get joinEpoch => $composableBuilder(
    column: $table.joinEpoch,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<Uint8List> get sync => $composableBuilder(
    column: $table.sync,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$VaultConversationsTableAnnotationComposer
    extends Composer<_$VaultDatabase, $VaultConversationsTable> {
  $$VaultConversationsTableAnnotationComposer({
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

  GeneratedColumn<int> get afterGeneration => $composableBuilder(
    column: $table.afterGeneration,
    builder: (column) => column,
  );

  GeneratedColumn<int> get afterEpoch => $composableBuilder(
    column: $table.afterEpoch,
    builder: (column) => column,
  );

  GeneratedColumn<int> get joinGeneration => $composableBuilder(
    column: $table.joinGeneration,
    builder: (column) => column,
  );

  GeneratedColumn<int> get joinEpoch =>
      $composableBuilder(column: $table.joinEpoch, builder: (column) => column);

  GeneratedColumn<Uint8List> get sync =>
      $composableBuilder(column: $table.sync, builder: (column) => column);
}

class $$VaultConversationsTableTableManager
    extends
        RootTableManager<
          _$VaultDatabase,
          $VaultConversationsTable,
          VaultConversationRow,
          $$VaultConversationsTableFilterComposer,
          $$VaultConversationsTableOrderingComposer,
          $$VaultConversationsTableAnnotationComposer,
          $$VaultConversationsTableCreateCompanionBuilder,
          $$VaultConversationsTableUpdateCompanionBuilder,
          (
            VaultConversationRow,
            BaseReferences<
              _$VaultDatabase,
              $VaultConversationsTable,
              VaultConversationRow
            >,
          ),
          VaultConversationRow,
          PrefetchHooks Function()
        > {
  $$VaultConversationsTableTableManager(
    _$VaultDatabase db,
    $VaultConversationsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$VaultConversationsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$VaultConversationsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$VaultConversationsTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> conversationId = const Value.absent(),
                Value<int?> afterGeneration = const Value.absent(),
                Value<int?> afterEpoch = const Value.absent(),
                Value<int?> joinGeneration = const Value.absent(),
                Value<int?> joinEpoch = const Value.absent(),
                Value<Uint8List?> sync = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => VaultConversationsCompanion(
                conversationId: conversationId,
                afterGeneration: afterGeneration,
                afterEpoch: afterEpoch,
                joinGeneration: joinGeneration,
                joinEpoch: joinEpoch,
                sync: sync,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String conversationId,
                Value<int?> afterGeneration = const Value.absent(),
                Value<int?> afterEpoch = const Value.absent(),
                Value<int?> joinGeneration = const Value.absent(),
                Value<int?> joinEpoch = const Value.absent(),
                Value<Uint8List?> sync = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => VaultConversationsCompanion.insert(
                conversationId: conversationId,
                afterGeneration: afterGeneration,
                afterEpoch: afterEpoch,
                joinGeneration: joinGeneration,
                joinEpoch: joinEpoch,
                sync: sync,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$VaultConversationsTable, VaultConversationRow>(
                    table,
                  ),
                  BaseReferences<
                    _$VaultDatabase,
                    $VaultConversationsTable,
                    VaultConversationRow
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$VaultConversationsTableProcessedTableManager =
    ProcessedTableManager<
      _$VaultDatabase,
      $VaultConversationsTable,
      VaultConversationRow,
      $$VaultConversationsTableFilterComposer,
      $$VaultConversationsTableOrderingComposer,
      $$VaultConversationsTableAnnotationComposer,
      $$VaultConversationsTableCreateCompanionBuilder,
      $$VaultConversationsTableUpdateCompanionBuilder,
      (
        VaultConversationRow,
        BaseReferences<
          _$VaultDatabase,
          $VaultConversationsTable,
          VaultConversationRow
        >,
      ),
      VaultConversationRow,
      PrefetchHooks Function()
    >;
typedef $$VaultMembersTableCreateCompanionBuilder =
    VaultMembersCompanion Function({
      required String conversationId,
      required String deviceId,
      required String side,
      required int sinceGeneration,
      required int sinceEpoch,
      required Uint8List signatureKey,
      Value<int> rowid,
    });
typedef $$VaultMembersTableUpdateCompanionBuilder =
    VaultMembersCompanion Function({
      Value<String> conversationId,
      Value<String> deviceId,
      Value<String> side,
      Value<int> sinceGeneration,
      Value<int> sinceEpoch,
      Value<Uint8List> signatureKey,
      Value<int> rowid,
    });

class $$VaultMembersTableFilterComposer
    extends Composer<_$VaultDatabase, $VaultMembersTable> {
  $$VaultMembersTableFilterComposer({
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

  ColumnFilters<String> get deviceId => $composableBuilder(
    column: $table.deviceId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get side => $composableBuilder(
    column: $table.side,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get sinceGeneration => $composableBuilder(
    column: $table.sinceGeneration,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get sinceEpoch => $composableBuilder(
    column: $table.sinceEpoch,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<Uint8List> get signatureKey => $composableBuilder(
    column: $table.signatureKey,
    builder: (column) => ColumnFilters(column),
  );
}

class $$VaultMembersTableOrderingComposer
    extends Composer<_$VaultDatabase, $VaultMembersTable> {
  $$VaultMembersTableOrderingComposer({
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

  ColumnOrderings<String> get deviceId => $composableBuilder(
    column: $table.deviceId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get side => $composableBuilder(
    column: $table.side,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get sinceGeneration => $composableBuilder(
    column: $table.sinceGeneration,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get sinceEpoch => $composableBuilder(
    column: $table.sinceEpoch,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<Uint8List> get signatureKey => $composableBuilder(
    column: $table.signatureKey,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$VaultMembersTableAnnotationComposer
    extends Composer<_$VaultDatabase, $VaultMembersTable> {
  $$VaultMembersTableAnnotationComposer({
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

  GeneratedColumn<String> get deviceId =>
      $composableBuilder(column: $table.deviceId, builder: (column) => column);

  GeneratedColumn<String> get side =>
      $composableBuilder(column: $table.side, builder: (column) => column);

  GeneratedColumn<int> get sinceGeneration => $composableBuilder(
    column: $table.sinceGeneration,
    builder: (column) => column,
  );

  GeneratedColumn<int> get sinceEpoch => $composableBuilder(
    column: $table.sinceEpoch,
    builder: (column) => column,
  );

  GeneratedColumn<Uint8List> get signatureKey => $composableBuilder(
    column: $table.signatureKey,
    builder: (column) => column,
  );
}

class $$VaultMembersTableTableManager
    extends
        RootTableManager<
          _$VaultDatabase,
          $VaultMembersTable,
          VaultMemberRow,
          $$VaultMembersTableFilterComposer,
          $$VaultMembersTableOrderingComposer,
          $$VaultMembersTableAnnotationComposer,
          $$VaultMembersTableCreateCompanionBuilder,
          $$VaultMembersTableUpdateCompanionBuilder,
          (
            VaultMemberRow,
            BaseReferences<_$VaultDatabase, $VaultMembersTable, VaultMemberRow>,
          ),
          VaultMemberRow,
          PrefetchHooks Function()
        > {
  $$VaultMembersTableTableManager(_$VaultDatabase db, $VaultMembersTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$VaultMembersTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$VaultMembersTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$VaultMembersTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> conversationId = const Value.absent(),
                Value<String> deviceId = const Value.absent(),
                Value<String> side = const Value.absent(),
                Value<int> sinceGeneration = const Value.absent(),
                Value<int> sinceEpoch = const Value.absent(),
                Value<Uint8List> signatureKey = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => VaultMembersCompanion(
                conversationId: conversationId,
                deviceId: deviceId,
                side: side,
                sinceGeneration: sinceGeneration,
                sinceEpoch: sinceEpoch,
                signatureKey: signatureKey,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String conversationId,
                required String deviceId,
                required String side,
                required int sinceGeneration,
                required int sinceEpoch,
                required Uint8List signatureKey,
                Value<int> rowid = const Value.absent(),
              }) => VaultMembersCompanion.insert(
                conversationId: conversationId,
                deviceId: deviceId,
                side: side,
                sinceGeneration: sinceGeneration,
                sinceEpoch: sinceEpoch,
                signatureKey: signatureKey,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$VaultMembersTable, VaultMemberRow>(table),
                  BaseReferences<
                    _$VaultDatabase,
                    $VaultMembersTable,
                    VaultMemberRow
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$VaultMembersTableProcessedTableManager =
    ProcessedTableManager<
      _$VaultDatabase,
      $VaultMembersTable,
      VaultMemberRow,
      $$VaultMembersTableFilterComposer,
      $$VaultMembersTableOrderingComposer,
      $$VaultMembersTableAnnotationComposer,
      $$VaultMembersTableCreateCompanionBuilder,
      $$VaultMembersTableUpdateCompanionBuilder,
      (
        VaultMemberRow,
        BaseReferences<_$VaultDatabase, $VaultMembersTable, VaultMemberRow>,
      ),
      VaultMemberRow,
      PrefetchHooks Function()
    >;
typedef $$VaultSentTableCreateCompanionBuilder = VaultSentCompanion Function({
  required String conversationId,
  required int generation,
  required int epoch,
  required String digest,
  Value<int> rowid,
});
typedef $$VaultSentTableUpdateCompanionBuilder = VaultSentCompanion Function({
  Value<String> conversationId,
  Value<int> generation,
  Value<int> epoch,
  Value<String> digest,
  Value<int> rowid,
});

class $$VaultSentTableFilterComposer
    extends Composer<_$VaultDatabase, $VaultSentTable> {
  $$VaultSentTableFilterComposer({
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

  ColumnFilters<int> get generation => $composableBuilder(
    column: $table.generation,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get epoch => $composableBuilder(
    column: $table.epoch,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get digest => $composableBuilder(
    column: $table.digest,
    builder: (column) => ColumnFilters(column),
  );
}

class $$VaultSentTableOrderingComposer
    extends Composer<_$VaultDatabase, $VaultSentTable> {
  $$VaultSentTableOrderingComposer({
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

  ColumnOrderings<int> get generation => $composableBuilder(
    column: $table.generation,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get epoch => $composableBuilder(
    column: $table.epoch,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get digest => $composableBuilder(
    column: $table.digest,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$VaultSentTableAnnotationComposer
    extends Composer<_$VaultDatabase, $VaultSentTable> {
  $$VaultSentTableAnnotationComposer({
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

  GeneratedColumn<int> get generation => $composableBuilder(
    column: $table.generation,
    builder: (column) => column,
  );

  GeneratedColumn<int> get epoch =>
      $composableBuilder(column: $table.epoch, builder: (column) => column);

  GeneratedColumn<String> get digest =>
      $composableBuilder(column: $table.digest, builder: (column) => column);
}

class $$VaultSentTableTableManager
    extends
        RootTableManager<
          _$VaultDatabase,
          $VaultSentTable,
          VaultSentRow,
          $$VaultSentTableFilterComposer,
          $$VaultSentTableOrderingComposer,
          $$VaultSentTableAnnotationComposer,
          $$VaultSentTableCreateCompanionBuilder,
          $$VaultSentTableUpdateCompanionBuilder,
          (
            VaultSentRow,
            BaseReferences<_$VaultDatabase, $VaultSentTable, VaultSentRow>,
          ),
          VaultSentRow,
          PrefetchHooks Function()
        > {
  $$VaultSentTableTableManager(_$VaultDatabase db, $VaultSentTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$VaultSentTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$VaultSentTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$VaultSentTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> conversationId = const Value.absent(),
                Value<int> generation = const Value.absent(),
                Value<int> epoch = const Value.absent(),
                Value<String> digest = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => VaultSentCompanion(
                conversationId: conversationId,
                generation: generation,
                epoch: epoch,
                digest: digest,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String conversationId,
                required int generation,
                required int epoch,
                required String digest,
                Value<int> rowid = const Value.absent(),
              }) => VaultSentCompanion.insert(
                conversationId: conversationId,
                generation: generation,
                epoch: epoch,
                digest: digest,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$VaultSentTable, VaultSentRow>(table),
                  BaseReferences<
                    _$VaultDatabase,
                    $VaultSentTable,
                    VaultSentRow
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$VaultSentTableProcessedTableManager =
    ProcessedTableManager<
      _$VaultDatabase,
      $VaultSentTable,
      VaultSentRow,
      $$VaultSentTableFilterComposer,
      $$VaultSentTableOrderingComposer,
      $$VaultSentTableAnnotationComposer,
      $$VaultSentTableCreateCompanionBuilder,
      $$VaultSentTableUpdateCompanionBuilder,
      (
        VaultSentRow,
        BaseReferences<_$VaultDatabase, $VaultSentTable, VaultSentRow>,
      ),
      VaultSentRow,
      PrefetchHooks Function()
    >;
typedef $$VaultMessagesTableCreateCompanionBuilder =
    VaultMessagesCompanion Function({
      required String conversationId,
      required String messageId,
      required String sortKey,
      required String state,
      required int generation,
      required int epoch,
      required Uint8List fromSelf,
      Value<Uint8List?> content,
      Value<String> checkState,
      Value<String> kind,
      Value<int?> mine,
      Value<Uint8List?> senderDeviceId,
      Value<int> rowid,
    });
typedef $$VaultMessagesTableUpdateCompanionBuilder =
    VaultMessagesCompanion Function({
      Value<String> conversationId,
      Value<String> messageId,
      Value<String> sortKey,
      Value<String> state,
      Value<int> generation,
      Value<int> epoch,
      Value<Uint8List> fromSelf,
      Value<Uint8List?> content,
      Value<String> checkState,
      Value<String> kind,
      Value<int?> mine,
      Value<Uint8List?> senderDeviceId,
      Value<int> rowid,
    });

class $$VaultMessagesTableFilterComposer
    extends Composer<_$VaultDatabase, $VaultMessagesTable> {
  $$VaultMessagesTableFilterComposer({
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

  ColumnFilters<String> get state => $composableBuilder(
    column: $table.state,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get generation => $composableBuilder(
    column: $table.generation,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get epoch => $composableBuilder(
    column: $table.epoch,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<Uint8List> get fromSelf => $composableBuilder(
    column: $table.fromSelf,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<Uint8List> get content => $composableBuilder(
    column: $table.content,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get checkState => $composableBuilder(
    column: $table.checkState,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get mine => $composableBuilder(
    column: $table.mine,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<Uint8List> get senderDeviceId => $composableBuilder(
    column: $table.senderDeviceId,
    builder: (column) => ColumnFilters(column),
  );
}

class $$VaultMessagesTableOrderingComposer
    extends Composer<_$VaultDatabase, $VaultMessagesTable> {
  $$VaultMessagesTableOrderingComposer({
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

  ColumnOrderings<String> get state => $composableBuilder(
    column: $table.state,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get generation => $composableBuilder(
    column: $table.generation,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get epoch => $composableBuilder(
    column: $table.epoch,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<Uint8List> get fromSelf => $composableBuilder(
    column: $table.fromSelf,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<Uint8List> get content => $composableBuilder(
    column: $table.content,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get checkState => $composableBuilder(
    column: $table.checkState,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get mine => $composableBuilder(
    column: $table.mine,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<Uint8List> get senderDeviceId => $composableBuilder(
    column: $table.senderDeviceId,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$VaultMessagesTableAnnotationComposer
    extends Composer<_$VaultDatabase, $VaultMessagesTable> {
  $$VaultMessagesTableAnnotationComposer({
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

  GeneratedColumn<String> get state =>
      $composableBuilder(column: $table.state, builder: (column) => column);

  GeneratedColumn<int> get generation => $composableBuilder(
    column: $table.generation,
    builder: (column) => column,
  );

  GeneratedColumn<int> get epoch =>
      $composableBuilder(column: $table.epoch, builder: (column) => column);

  GeneratedColumn<Uint8List> get fromSelf =>
      $composableBuilder(column: $table.fromSelf, builder: (column) => column);

  GeneratedColumn<Uint8List> get content =>
      $composableBuilder(column: $table.content, builder: (column) => column);

  GeneratedColumn<String> get checkState => $composableBuilder(
    column: $table.checkState,
    builder: (column) => column,
  );

  GeneratedColumn<String> get kind =>
      $composableBuilder(column: $table.kind, builder: (column) => column);

  GeneratedColumn<int> get mine =>
      $composableBuilder(column: $table.mine, builder: (column) => column);

  GeneratedColumn<Uint8List> get senderDeviceId => $composableBuilder(
    column: $table.senderDeviceId,
    builder: (column) => column,
  );
}

class $$VaultMessagesTableTableManager
    extends
        RootTableManager<
          _$VaultDatabase,
          $VaultMessagesTable,
          VaultMessageRow,
          $$VaultMessagesTableFilterComposer,
          $$VaultMessagesTableOrderingComposer,
          $$VaultMessagesTableAnnotationComposer,
          $$VaultMessagesTableCreateCompanionBuilder,
          $$VaultMessagesTableUpdateCompanionBuilder,
          (
            VaultMessageRow,
            BaseReferences<
              _$VaultDatabase,
              $VaultMessagesTable,
              VaultMessageRow
            >,
          ),
          VaultMessageRow,
          PrefetchHooks Function()
        > {
  $$VaultMessagesTableTableManager(
    _$VaultDatabase db,
    $VaultMessagesTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$VaultMessagesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$VaultMessagesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$VaultMessagesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> conversationId = const Value.absent(),
                Value<String> messageId = const Value.absent(),
                Value<String> sortKey = const Value.absent(),
                Value<String> state = const Value.absent(),
                Value<int> generation = const Value.absent(),
                Value<int> epoch = const Value.absent(),
                Value<Uint8List> fromSelf = const Value.absent(),
                Value<Uint8List?> content = const Value.absent(),
                Value<String> checkState = const Value.absent(),
                Value<String> kind = const Value.absent(),
                Value<int?> mine = const Value.absent(),
                Value<Uint8List?> senderDeviceId = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => VaultMessagesCompanion(
                conversationId: conversationId,
                messageId: messageId,
                sortKey: sortKey,
                state: state,
                generation: generation,
                epoch: epoch,
                fromSelf: fromSelf,
                content: content,
                checkState: checkState,
                kind: kind,
                mine: mine,
                senderDeviceId: senderDeviceId,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String conversationId,
                required String messageId,
                required String sortKey,
                required String state,
                required int generation,
                required int epoch,
                required Uint8List fromSelf,
                Value<Uint8List?> content = const Value.absent(),
                Value<String> checkState = const Value.absent(),
                Value<String> kind = const Value.absent(),
                Value<int?> mine = const Value.absent(),
                Value<Uint8List?> senderDeviceId = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => VaultMessagesCompanion.insert(
                conversationId: conversationId,
                messageId: messageId,
                sortKey: sortKey,
                state: state,
                generation: generation,
                epoch: epoch,
                fromSelf: fromSelf,
                content: content,
                checkState: checkState,
                kind: kind,
                mine: mine,
                senderDeviceId: senderDeviceId,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$VaultMessagesTable, VaultMessageRow>(table),
                  BaseReferences<
                    _$VaultDatabase,
                    $VaultMessagesTable,
                    VaultMessageRow
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$VaultMessagesTableProcessedTableManager =
    ProcessedTableManager<
      _$VaultDatabase,
      $VaultMessagesTable,
      VaultMessageRow,
      $$VaultMessagesTableFilterComposer,
      $$VaultMessagesTableOrderingComposer,
      $$VaultMessagesTableAnnotationComposer,
      $$VaultMessagesTableCreateCompanionBuilder,
      $$VaultMessagesTableUpdateCompanionBuilder,
      (
        VaultMessageRow,
        BaseReferences<_$VaultDatabase, $VaultMessagesTable, VaultMessageRow>,
      ),
      VaultMessageRow,
      PrefetchHooks Function()
    >;
typedef $$VaultOutboxTableCreateCompanionBuilder =
    VaultOutboxCompanion Function({
      required String idempotencyKey,
      Value<String?> conversationId,
      required String sortKey,
      required int generation,
      required int epoch,
      Value<Uint8List?> recipientUserId,
      required Uint8List ciphertext,
      required Uint8List reportCommitment,
      required Uint8List content,
      required Uint8List attempts,
      Value<Uint8List?> lastError,
      Value<String> stage,
      Value<String?> expectedMessageId,
      Value<String?> localId,
      Value<Uint8List?> init,
      Value<int> rowid,
    });
typedef $$VaultOutboxTableUpdateCompanionBuilder =
    VaultOutboxCompanion Function({
      Value<String> idempotencyKey,
      Value<String?> conversationId,
      Value<String> sortKey,
      Value<int> generation,
      Value<int> epoch,
      Value<Uint8List?> recipientUserId,
      Value<Uint8List> ciphertext,
      Value<Uint8List> reportCommitment,
      Value<Uint8List> content,
      Value<Uint8List> attempts,
      Value<Uint8List?> lastError,
      Value<String> stage,
      Value<String?> expectedMessageId,
      Value<String?> localId,
      Value<Uint8List?> init,
      Value<int> rowid,
    });

class $$VaultOutboxTableFilterComposer
    extends Composer<_$VaultDatabase, $VaultOutboxTable> {
  $$VaultOutboxTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get idempotencyKey => $composableBuilder(
    column: $table.idempotencyKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get conversationId => $composableBuilder(
    column: $table.conversationId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get sortKey => $composableBuilder(
    column: $table.sortKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get generation => $composableBuilder(
    column: $table.generation,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get epoch => $composableBuilder(
    column: $table.epoch,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<Uint8List> get recipientUserId => $composableBuilder(
    column: $table.recipientUserId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<Uint8List> get ciphertext => $composableBuilder(
    column: $table.ciphertext,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<Uint8List> get reportCommitment => $composableBuilder(
    column: $table.reportCommitment,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<Uint8List> get content => $composableBuilder(
    column: $table.content,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<Uint8List> get attempts => $composableBuilder(
    column: $table.attempts,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<Uint8List> get lastError => $composableBuilder(
    column: $table.lastError,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get stage => $composableBuilder(
    column: $table.stage,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get expectedMessageId => $composableBuilder(
    column: $table.expectedMessageId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get localId => $composableBuilder(
    column: $table.localId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<Uint8List> get init => $composableBuilder(
    column: $table.init,
    builder: (column) => ColumnFilters(column),
  );
}

class $$VaultOutboxTableOrderingComposer
    extends Composer<_$VaultDatabase, $VaultOutboxTable> {
  $$VaultOutboxTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get idempotencyKey => $composableBuilder(
    column: $table.idempotencyKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get conversationId => $composableBuilder(
    column: $table.conversationId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get sortKey => $composableBuilder(
    column: $table.sortKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get generation => $composableBuilder(
    column: $table.generation,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get epoch => $composableBuilder(
    column: $table.epoch,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<Uint8List> get recipientUserId => $composableBuilder(
    column: $table.recipientUserId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<Uint8List> get ciphertext => $composableBuilder(
    column: $table.ciphertext,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<Uint8List> get reportCommitment => $composableBuilder(
    column: $table.reportCommitment,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<Uint8List> get content => $composableBuilder(
    column: $table.content,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<Uint8List> get attempts => $composableBuilder(
    column: $table.attempts,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<Uint8List> get lastError => $composableBuilder(
    column: $table.lastError,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get stage => $composableBuilder(
    column: $table.stage,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get expectedMessageId => $composableBuilder(
    column: $table.expectedMessageId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get localId => $composableBuilder(
    column: $table.localId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<Uint8List> get init => $composableBuilder(
    column: $table.init,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$VaultOutboxTableAnnotationComposer
    extends Composer<_$VaultDatabase, $VaultOutboxTable> {
  $$VaultOutboxTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get idempotencyKey => $composableBuilder(
    column: $table.idempotencyKey,
    builder: (column) => column,
  );

  GeneratedColumn<String> get conversationId => $composableBuilder(
    column: $table.conversationId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get sortKey =>
      $composableBuilder(column: $table.sortKey, builder: (column) => column);

  GeneratedColumn<int> get generation => $composableBuilder(
    column: $table.generation,
    builder: (column) => column,
  );

  GeneratedColumn<int> get epoch =>
      $composableBuilder(column: $table.epoch, builder: (column) => column);

  GeneratedColumn<Uint8List> get recipientUserId => $composableBuilder(
    column: $table.recipientUserId,
    builder: (column) => column,
  );

  GeneratedColumn<Uint8List> get ciphertext => $composableBuilder(
    column: $table.ciphertext,
    builder: (column) => column,
  );

  GeneratedColumn<Uint8List> get reportCommitment => $composableBuilder(
    column: $table.reportCommitment,
    builder: (column) => column,
  );

  GeneratedColumn<Uint8List> get content =>
      $composableBuilder(column: $table.content, builder: (column) => column);

  GeneratedColumn<Uint8List> get attempts =>
      $composableBuilder(column: $table.attempts, builder: (column) => column);

  GeneratedColumn<Uint8List> get lastError =>
      $composableBuilder(column: $table.lastError, builder: (column) => column);

  GeneratedColumn<String> get stage =>
      $composableBuilder(column: $table.stage, builder: (column) => column);

  GeneratedColumn<String> get expectedMessageId => $composableBuilder(
    column: $table.expectedMessageId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get localId =>
      $composableBuilder(column: $table.localId, builder: (column) => column);

  GeneratedColumn<Uint8List> get init =>
      $composableBuilder(column: $table.init, builder: (column) => column);
}

class $$VaultOutboxTableTableManager
    extends
        RootTableManager<
          _$VaultDatabase,
          $VaultOutboxTable,
          VaultOutboxRow,
          $$VaultOutboxTableFilterComposer,
          $$VaultOutboxTableOrderingComposer,
          $$VaultOutboxTableAnnotationComposer,
          $$VaultOutboxTableCreateCompanionBuilder,
          $$VaultOutboxTableUpdateCompanionBuilder,
          (
            VaultOutboxRow,
            BaseReferences<_$VaultDatabase, $VaultOutboxTable, VaultOutboxRow>,
          ),
          VaultOutboxRow,
          PrefetchHooks Function()
        > {
  $$VaultOutboxTableTableManager(_$VaultDatabase db, $VaultOutboxTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$VaultOutboxTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$VaultOutboxTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$VaultOutboxTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> idempotencyKey = const Value.absent(),
                Value<String?> conversationId = const Value.absent(),
                Value<String> sortKey = const Value.absent(),
                Value<int> generation = const Value.absent(),
                Value<int> epoch = const Value.absent(),
                Value<Uint8List?> recipientUserId = const Value.absent(),
                Value<Uint8List> ciphertext = const Value.absent(),
                Value<Uint8List> reportCommitment = const Value.absent(),
                Value<Uint8List> content = const Value.absent(),
                Value<Uint8List> attempts = const Value.absent(),
                Value<Uint8List?> lastError = const Value.absent(),
                Value<String> stage = const Value.absent(),
                Value<String?> expectedMessageId = const Value.absent(),
                Value<String?> localId = const Value.absent(),
                Value<Uint8List?> init = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => VaultOutboxCompanion(
                idempotencyKey: idempotencyKey,
                conversationId: conversationId,
                sortKey: sortKey,
                generation: generation,
                epoch: epoch,
                recipientUserId: recipientUserId,
                ciphertext: ciphertext,
                reportCommitment: reportCommitment,
                content: content,
                attempts: attempts,
                lastError: lastError,
                stage: stage,
                expectedMessageId: expectedMessageId,
                localId: localId,
                init: init,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String idempotencyKey,
                Value<String?> conversationId = const Value.absent(),
                required String sortKey,
                required int generation,
                required int epoch,
                Value<Uint8List?> recipientUserId = const Value.absent(),
                required Uint8List ciphertext,
                required Uint8List reportCommitment,
                required Uint8List content,
                required Uint8List attempts,
                Value<Uint8List?> lastError = const Value.absent(),
                Value<String> stage = const Value.absent(),
                Value<String?> expectedMessageId = const Value.absent(),
                Value<String?> localId = const Value.absent(),
                Value<Uint8List?> init = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => VaultOutboxCompanion.insert(
                idempotencyKey: idempotencyKey,
                conversationId: conversationId,
                sortKey: sortKey,
                generation: generation,
                epoch: epoch,
                recipientUserId: recipientUserId,
                ciphertext: ciphertext,
                reportCommitment: reportCommitment,
                content: content,
                attempts: attempts,
                lastError: lastError,
                stage: stage,
                expectedMessageId: expectedMessageId,
                localId: localId,
                init: init,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$VaultOutboxTable, VaultOutboxRow>(table),
                  BaseReferences<
                    _$VaultDatabase,
                    $VaultOutboxTable,
                    VaultOutboxRow
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$VaultOutboxTableProcessedTableManager =
    ProcessedTableManager<
      _$VaultDatabase,
      $VaultOutboxTable,
      VaultOutboxRow,
      $$VaultOutboxTableFilterComposer,
      $$VaultOutboxTableOrderingComposer,
      $$VaultOutboxTableAnnotationComposer,
      $$VaultOutboxTableCreateCompanionBuilder,
      $$VaultOutboxTableUpdateCompanionBuilder,
      (
        VaultOutboxRow,
        BaseReferences<_$VaultDatabase, $VaultOutboxTable, VaultOutboxRow>,
      ),
      VaultOutboxRow,
      PrefetchHooks Function()
    >;
typedef $$VaultSettingsTableCreateCompanionBuilder =
    VaultSettingsCompanion Function({
      required String settingKey,
      required Uint8List value,
      Value<int> rowid,
    });
typedef $$VaultSettingsTableUpdateCompanionBuilder =
    VaultSettingsCompanion Function({
      Value<String> settingKey,
      Value<Uint8List> value,
      Value<int> rowid,
    });

class $$VaultSettingsTableFilterComposer
    extends Composer<_$VaultDatabase, $VaultSettingsTable> {
  $$VaultSettingsTableFilterComposer({
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

  ColumnFilters<Uint8List> get value => $composableBuilder(
    column: $table.value,
    builder: (column) => ColumnFilters(column),
  );
}

class $$VaultSettingsTableOrderingComposer
    extends Composer<_$VaultDatabase, $VaultSettingsTable> {
  $$VaultSettingsTableOrderingComposer({
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

  ColumnOrderings<Uint8List> get value => $composableBuilder(
    column: $table.value,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$VaultSettingsTableAnnotationComposer
    extends Composer<_$VaultDatabase, $VaultSettingsTable> {
  $$VaultSettingsTableAnnotationComposer({
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

  GeneratedColumn<Uint8List> get value =>
      $composableBuilder(column: $table.value, builder: (column) => column);
}

class $$VaultSettingsTableTableManager
    extends
        RootTableManager<
          _$VaultDatabase,
          $VaultSettingsTable,
          VaultSettingRow,
          $$VaultSettingsTableFilterComposer,
          $$VaultSettingsTableOrderingComposer,
          $$VaultSettingsTableAnnotationComposer,
          $$VaultSettingsTableCreateCompanionBuilder,
          $$VaultSettingsTableUpdateCompanionBuilder,
          (
            VaultSettingRow,
            BaseReferences<
              _$VaultDatabase,
              $VaultSettingsTable,
              VaultSettingRow
            >,
          ),
          VaultSettingRow,
          PrefetchHooks Function()
        > {
  $$VaultSettingsTableTableManager(
    _$VaultDatabase db,
    $VaultSettingsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$VaultSettingsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$VaultSettingsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$VaultSettingsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> settingKey = const Value.absent(),
                Value<Uint8List> value = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => VaultSettingsCompanion(
                settingKey: settingKey,
                value: value,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String settingKey,
                required Uint8List value,
                Value<int> rowid = const Value.absent(),
              }) => VaultSettingsCompanion.insert(
                settingKey: settingKey,
                value: value,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$VaultSettingsTable, VaultSettingRow>(table),
                  BaseReferences<
                    _$VaultDatabase,
                    $VaultSettingsTable,
                    VaultSettingRow
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$VaultSettingsTableProcessedTableManager =
    ProcessedTableManager<
      _$VaultDatabase,
      $VaultSettingsTable,
      VaultSettingRow,
      $$VaultSettingsTableFilterComposer,
      $$VaultSettingsTableOrderingComposer,
      $$VaultSettingsTableAnnotationComposer,
      $$VaultSettingsTableCreateCompanionBuilder,
      $$VaultSettingsTableUpdateCompanionBuilder,
      (
        VaultSettingRow,
        BaseReferences<_$VaultDatabase, $VaultSettingsTable, VaultSettingRow>,
      ),
      VaultSettingRow,
      PrefetchHooks Function()
    >;

class $VaultDatabaseManager {
  final _$VaultDatabase _db;
  $VaultDatabaseManager(this._db);
  $$VaultMetaTableTableManager get vaultMeta =>
      $$VaultMetaTableTableManager(_db, _db.vaultMeta);
  $$VaultDeviceTableTableManager get vaultDevice =>
      $$VaultDeviceTableTableManager(_db, _db.vaultDevice);
  $$VaultGroupsTableTableManager get vaultGroups =>
      $$VaultGroupsTableTableManager(_db, _db.vaultGroups);
  $$VaultGroupStatesTableTableManager get vaultGroupStates =>
      $$VaultGroupStatesTableTableManager(_db, _db.vaultGroupStates);
  $$VaultConversationsTableTableManager get vaultConversations =>
      $$VaultConversationsTableTableManager(_db, _db.vaultConversations);
  $$VaultMembersTableTableManager get vaultMembers =>
      $$VaultMembersTableTableManager(_db, _db.vaultMembers);
  $$VaultSentTableTableManager get vaultSent =>
      $$VaultSentTableTableManager(_db, _db.vaultSent);
  $$VaultMessagesTableTableManager get vaultMessages =>
      $$VaultMessagesTableTableManager(_db, _db.vaultMessages);
  $$VaultOutboxTableTableManager get vaultOutbox =>
      $$VaultOutboxTableTableManager(_db, _db.vaultOutbox);
  $$VaultSettingsTableTableManager get vaultSettings =>
      $$VaultSettingsTableTableManager(_db, _db.vaultSettings);
}
