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

  /// Sealed: one byte, 1 for a message this user sent.
  final Uint8List fromSelf;

  /// Sealed; NULL for a tombstone (never a sealed empty value).
  final Uint8List? content;
  const VaultMessageRow({
    required this.conversationId,
    required this.messageId,
    required this.sortKey,
    required this.state,
    required this.generation,
    required this.epoch,
    required this.fromSelf,
    this.content,
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
  }) => VaultMessageRow(
    conversationId: conversationId ?? this.conversationId,
    messageId: messageId ?? this.messageId,
    sortKey: sortKey ?? this.sortKey,
    state: state ?? this.state,
    generation: generation ?? this.generation,
    epoch: epoch ?? this.epoch,
    fromSelf: fromSelf ?? this.fromSelf,
    content: content.present ? content.value : this.content,
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
          ..write('content: $content')
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
          $driftBlobEquality.equals(other.content, this.content));
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
          ..write('lastError: $lastError')
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
          $driftBlobEquality.equals(other.lastError, this.lastError));
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
  $$VaultMessagesTableTableManager get vaultMessages =>
      $$VaultMessagesTableTableManager(_db, _db.vaultMessages);
  $$VaultOutboxTableTableManager get vaultOutbox =>
      $$VaultOutboxTableTableManager(_db, _db.vaultOutbox);
  $$VaultSettingsTableTableManager get vaultSettings =>
      $$VaultSettingsTableTableManager(_db, _db.vaultSettings);
}
