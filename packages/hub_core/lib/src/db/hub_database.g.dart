// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'hub_database.dart';

// ignore_for_file: type=lint
class $DevicesTable extends Devices with TableInfo<$DevicesTable, DeviceRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $DevicesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _roleMeta = const VerificationMeta('role');
  @override
  late final GeneratedColumn<String> role = GeneratedColumn<String>(
    'role',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [id, name, role, createdAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'devices';
  @override
  VerificationContext validateIntegrity(
    Insertable<DeviceRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('role')) {
      context.handle(
        _roleMeta,
        role.isAcceptableOrUnknown(data['role']!, _roleMeta),
      );
    } else if (isInserting) {
      context.missing(_roleMeta);
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
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  DeviceRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return DeviceRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      role: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}role'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at'],
      )!,
    );
  }

  @override
  $DevicesTable createAlias(String alias) {
    return $DevicesTable(attachedDatabase, alias);
  }
}

class DeviceRow extends DataClass implements Insertable<DeviceRow> {
  final String id;
  final String name;
  final String role;
  final int createdAt;
  const DeviceRow({
    required this.id,
    required this.name,
    required this.role,
    required this.createdAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['name'] = Variable<String>(name);
    map['role'] = Variable<String>(role);
    map['created_at'] = Variable<int>(createdAt);
    return map;
  }

  DevicesCompanion toCompanion(bool nullToAbsent) {
    return DevicesCompanion(
      id: Value(id),
      name: Value(name),
      role: Value(role),
      createdAt: Value(createdAt),
    );
  }

  factory DeviceRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return DeviceRow(
      id: serializer.fromJson<String>(json['id']),
      name: serializer.fromJson<String>(json['name']),
      role: serializer.fromJson<String>(json['role']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'name': serializer.toJson<String>(name),
      'role': serializer.toJson<String>(role),
      'createdAt': serializer.toJson<int>(createdAt),
    };
  }

  DeviceRow copyWith({
    String? id,
    String? name,
    String? role,
    int? createdAt,
  }) => DeviceRow(
    id: id ?? this.id,
    name: name ?? this.name,
    role: role ?? this.role,
    createdAt: createdAt ?? this.createdAt,
  );
  DeviceRow copyWithCompanion(DevicesCompanion data) {
    return DeviceRow(
      id: data.id.present ? data.id.value : this.id,
      name: data.name.present ? data.name.value : this.name,
      role: data.role.present ? data.role.value : this.role,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('DeviceRow(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('role: $role, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, name, role, createdAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is DeviceRow &&
          other.id == this.id &&
          other.name == this.name &&
          other.role == this.role &&
          other.createdAt == this.createdAt);
}

class DevicesCompanion extends UpdateCompanion<DeviceRow> {
  final Value<String> id;
  final Value<String> name;
  final Value<String> role;
  final Value<int> createdAt;
  final Value<int> rowid;
  const DevicesCompanion({
    this.id = const Value.absent(),
    this.name = const Value.absent(),
    this.role = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  DevicesCompanion.insert({
    required String id,
    required String name,
    required String role,
    required int createdAt,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       name = Value(name),
       role = Value(role),
       createdAt = Value(createdAt);
  static Insertable<DeviceRow> custom({
    Expression<String>? id,
    Expression<String>? name,
    Expression<String>? role,
    Expression<int>? createdAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (name != null) 'name': name,
      if (role != null) 'role': role,
      if (createdAt != null) 'created_at': createdAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  DevicesCompanion copyWith({
    Value<String>? id,
    Value<String>? name,
    Value<String>? role,
    Value<int>? createdAt,
    Value<int>? rowid,
  }) {
    return DevicesCompanion(
      id: id ?? this.id,
      name: name ?? this.name,
      role: role ?? this.role,
      createdAt: createdAt ?? this.createdAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (role.present) {
      map['role'] = Variable<String>(role.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('DevicesCompanion(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('role: $role, ')
          ..write('createdAt: $createdAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $PairingsTable extends Pairings
    with TableInfo<$PairingsTable, PairingRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $PairingsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _tokenHashMeta = const VerificationMeta(
    'tokenHash',
  );
  @override
  late final GeneratedColumn<String> tokenHash = GeneratedColumn<String>(
    'token_hash',
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
  static const VerificationMeta _clientNameMeta = const VerificationMeta(
    'clientName',
  );
  @override
  late final GeneratedColumn<String> clientName = GeneratedColumn<String>(
    'client_name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _lastSeenAtMeta = const VerificationMeta(
    'lastSeenAt',
  );
  @override
  late final GeneratedColumn<int> lastSeenAt = GeneratedColumn<int>(
    'last_seen_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    tokenHash,
    deviceId,
    clientName,
    createdAt,
    lastSeenAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'pairings';
  @override
  VerificationContext validateIntegrity(
    Insertable<PairingRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('token_hash')) {
      context.handle(
        _tokenHashMeta,
        tokenHash.isAcceptableOrUnknown(data['token_hash']!, _tokenHashMeta),
      );
    } else if (isInserting) {
      context.missing(_tokenHashMeta);
    }
    if (data.containsKey('device_id')) {
      context.handle(
        _deviceIdMeta,
        deviceId.isAcceptableOrUnknown(data['device_id']!, _deviceIdMeta),
      );
    } else if (isInserting) {
      context.missing(_deviceIdMeta);
    }
    if (data.containsKey('client_name')) {
      context.handle(
        _clientNameMeta,
        clientName.isAcceptableOrUnknown(data['client_name']!, _clientNameMeta),
      );
    } else if (isInserting) {
      context.missing(_clientNameMeta);
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('last_seen_at')) {
      context.handle(
        _lastSeenAtMeta,
        lastSeenAt.isAcceptableOrUnknown(
          data['last_seen_at']!,
          _lastSeenAtMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_lastSeenAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {tokenHash};
  @override
  PairingRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return PairingRow(
      tokenHash: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}token_hash'],
      )!,
      deviceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}device_id'],
      )!,
      clientName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}client_name'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at'],
      )!,
      lastSeenAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}last_seen_at'],
      )!,
    );
  }

  @override
  $PairingsTable createAlias(String alias) {
    return $PairingsTable(attachedDatabase, alias);
  }
}

class PairingRow extends DataClass implements Insertable<PairingRow> {
  final String tokenHash;
  final String deviceId;
  final String clientName;
  final int createdAt;
  final int lastSeenAt;
  const PairingRow({
    required this.tokenHash,
    required this.deviceId,
    required this.clientName,
    required this.createdAt,
    required this.lastSeenAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['token_hash'] = Variable<String>(tokenHash);
    map['device_id'] = Variable<String>(deviceId);
    map['client_name'] = Variable<String>(clientName);
    map['created_at'] = Variable<int>(createdAt);
    map['last_seen_at'] = Variable<int>(lastSeenAt);
    return map;
  }

  PairingsCompanion toCompanion(bool nullToAbsent) {
    return PairingsCompanion(
      tokenHash: Value(tokenHash),
      deviceId: Value(deviceId),
      clientName: Value(clientName),
      createdAt: Value(createdAt),
      lastSeenAt: Value(lastSeenAt),
    );
  }

  factory PairingRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return PairingRow(
      tokenHash: serializer.fromJson<String>(json['tokenHash']),
      deviceId: serializer.fromJson<String>(json['deviceId']),
      clientName: serializer.fromJson<String>(json['clientName']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
      lastSeenAt: serializer.fromJson<int>(json['lastSeenAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'tokenHash': serializer.toJson<String>(tokenHash),
      'deviceId': serializer.toJson<String>(deviceId),
      'clientName': serializer.toJson<String>(clientName),
      'createdAt': serializer.toJson<int>(createdAt),
      'lastSeenAt': serializer.toJson<int>(lastSeenAt),
    };
  }

  PairingRow copyWith({
    String? tokenHash,
    String? deviceId,
    String? clientName,
    int? createdAt,
    int? lastSeenAt,
  }) => PairingRow(
    tokenHash: tokenHash ?? this.tokenHash,
    deviceId: deviceId ?? this.deviceId,
    clientName: clientName ?? this.clientName,
    createdAt: createdAt ?? this.createdAt,
    lastSeenAt: lastSeenAt ?? this.lastSeenAt,
  );
  PairingRow copyWithCompanion(PairingsCompanion data) {
    return PairingRow(
      tokenHash: data.tokenHash.present ? data.tokenHash.value : this.tokenHash,
      deviceId: data.deviceId.present ? data.deviceId.value : this.deviceId,
      clientName: data.clientName.present
          ? data.clientName.value
          : this.clientName,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      lastSeenAt: data.lastSeenAt.present
          ? data.lastSeenAt.value
          : this.lastSeenAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('PairingRow(')
          ..write('tokenHash: $tokenHash, ')
          ..write('deviceId: $deviceId, ')
          ..write('clientName: $clientName, ')
          ..write('createdAt: $createdAt, ')
          ..write('lastSeenAt: $lastSeenAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(tokenHash, deviceId, clientName, createdAt, lastSeenAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PairingRow &&
          other.tokenHash == this.tokenHash &&
          other.deviceId == this.deviceId &&
          other.clientName == this.clientName &&
          other.createdAt == this.createdAt &&
          other.lastSeenAt == this.lastSeenAt);
}

class PairingsCompanion extends UpdateCompanion<PairingRow> {
  final Value<String> tokenHash;
  final Value<String> deviceId;
  final Value<String> clientName;
  final Value<int> createdAt;
  final Value<int> lastSeenAt;
  final Value<int> rowid;
  const PairingsCompanion({
    this.tokenHash = const Value.absent(),
    this.deviceId = const Value.absent(),
    this.clientName = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.lastSeenAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  PairingsCompanion.insert({
    required String tokenHash,
    required String deviceId,
    required String clientName,
    required int createdAt,
    required int lastSeenAt,
    this.rowid = const Value.absent(),
  }) : tokenHash = Value(tokenHash),
       deviceId = Value(deviceId),
       clientName = Value(clientName),
       createdAt = Value(createdAt),
       lastSeenAt = Value(lastSeenAt);
  static Insertable<PairingRow> custom({
    Expression<String>? tokenHash,
    Expression<String>? deviceId,
    Expression<String>? clientName,
    Expression<int>? createdAt,
    Expression<int>? lastSeenAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (tokenHash != null) 'token_hash': tokenHash,
      if (deviceId != null) 'device_id': deviceId,
      if (clientName != null) 'client_name': clientName,
      if (createdAt != null) 'created_at': createdAt,
      if (lastSeenAt != null) 'last_seen_at': lastSeenAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  PairingsCompanion copyWith({
    Value<String>? tokenHash,
    Value<String>? deviceId,
    Value<String>? clientName,
    Value<int>? createdAt,
    Value<int>? lastSeenAt,
    Value<int>? rowid,
  }) {
    return PairingsCompanion(
      tokenHash: tokenHash ?? this.tokenHash,
      deviceId: deviceId ?? this.deviceId,
      clientName: clientName ?? this.clientName,
      createdAt: createdAt ?? this.createdAt,
      lastSeenAt: lastSeenAt ?? this.lastSeenAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (tokenHash.present) {
      map['token_hash'] = Variable<String>(tokenHash.value);
    }
    if (deviceId.present) {
      map['device_id'] = Variable<String>(deviceId.value);
    }
    if (clientName.present) {
      map['client_name'] = Variable<String>(clientName.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (lastSeenAt.present) {
      map['last_seen_at'] = Variable<int>(lastSeenAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('PairingsCompanion(')
          ..write('tokenHash: $tokenHash, ')
          ..write('deviceId: $deviceId, ')
          ..write('clientName: $clientName, ')
          ..write('createdAt: $createdAt, ')
          ..write('lastSeenAt: $lastSeenAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $LibraryItemsTable extends LibraryItems
    with TableInfo<$LibraryItemsTable, LibraryItemRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LibraryItemsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _kindMeta = const VerificationMeta('kind');
  @override
  late final GeneratedColumn<String> kind = GeneratedColumn<String>(
    'kind',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sha256Meta = const VerificationMeta('sha256');
  @override
  late final GeneratedColumn<String> sha256 = GeneratedColumn<String>(
    'sha256',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways('UNIQUE'),
  );
  static const VerificationMeta _bytesMeta = const VerificationMeta('bytes');
  @override
  late final GeneratedColumn<int> bytes = GeneratedColumn<int>(
    'bytes',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _widthMeta = const VerificationMeta('width');
  @override
  late final GeneratedColumn<int> width = GeneratedColumn<int>(
    'width',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _heightMeta = const VerificationMeta('height');
  @override
  late final GeneratedColumn<int> height = GeneratedColumn<int>(
    'height',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _durationMsMeta = const VerificationMeta(
    'durationMs',
  );
  @override
  late final GeneratedColumn<int> durationMs = GeneratedColumn<int>(
    'duration_ms',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _codecMeta = const VerificationMeta('codec');
  @override
  late final GeneratedColumn<String> codec = GeneratedColumn<String>(
    'codec',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _hdrMeta = const VerificationMeta('hdr');
  @override
  late final GeneratedColumn<String> hdr = GeneratedColumn<String>(
    'hdr',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _fpsMeta = const VerificationMeta('fps');
  @override
  late final GeneratedColumn<double> fps = GeneratedColumn<double>(
    'fps',
    aliasedName,
    true,
    type: DriftSqlType.double,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _bitrateMeta = const VerificationMeta(
    'bitrate',
  );
  @override
  late final GeneratedColumn<int> bitrate = GeneratedColumn<int>(
    'bitrate',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _audioCodecMeta = const VerificationMeta(
    'audioCodec',
  );
  @override
  late final GeneratedColumn<String> audioCodec = GeneratedColumn<String>(
    'audio_codec',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _profileMeta = const VerificationMeta(
    'profile',
  );
  @override
  late final GeneratedColumn<String> profile = GeneratedColumn<String>(
    'profile',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _stateMeta = const VerificationMeta('state');
  @override
  late final GeneratedColumn<String> state = GeneratedColumn<String>(
    'state',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('new'),
  );
  static const VerificationMeta _stateReasonMeta = const VerificationMeta(
    'stateReason',
  );
  @override
  late final GeneratedColumn<String> stateReason = GeneratedColumn<String>(
    'state_reason',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _cacheRequiredMeta = const VerificationMeta(
    'cacheRequired',
  );
  @override
  late final GeneratedColumn<bool> cacheRequired = GeneratedColumn<bool>(
    'cache_required',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("cache_required" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _variantsMeta = const VerificationMeta(
    'variants',
  );
  @override
  late final GeneratedColumn<String> variants = GeneratedColumn<String>(
    'variants',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    kind,
    name,
    sha256,
    bytes,
    width,
    height,
    durationMs,
    codec,
    hdr,
    fps,
    bitrate,
    createdAt,
    audioCodec,
    profile,
    state,
    stateReason,
    cacheRequired,
    variants,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'library_items';
  @override
  VerificationContext validateIntegrity(
    Insertable<LibraryItemRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('kind')) {
      context.handle(
        _kindMeta,
        kind.isAcceptableOrUnknown(data['kind']!, _kindMeta),
      );
    } else if (isInserting) {
      context.missing(_kindMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('sha256')) {
      context.handle(
        _sha256Meta,
        sha256.isAcceptableOrUnknown(data['sha256']!, _sha256Meta),
      );
    } else if (isInserting) {
      context.missing(_sha256Meta);
    }
    if (data.containsKey('bytes')) {
      context.handle(
        _bytesMeta,
        bytes.isAcceptableOrUnknown(data['bytes']!, _bytesMeta),
      );
    } else if (isInserting) {
      context.missing(_bytesMeta);
    }
    if (data.containsKey('width')) {
      context.handle(
        _widthMeta,
        width.isAcceptableOrUnknown(data['width']!, _widthMeta),
      );
    }
    if (data.containsKey('height')) {
      context.handle(
        _heightMeta,
        height.isAcceptableOrUnknown(data['height']!, _heightMeta),
      );
    }
    if (data.containsKey('duration_ms')) {
      context.handle(
        _durationMsMeta,
        durationMs.isAcceptableOrUnknown(data['duration_ms']!, _durationMsMeta),
      );
    }
    if (data.containsKey('codec')) {
      context.handle(
        _codecMeta,
        codec.isAcceptableOrUnknown(data['codec']!, _codecMeta),
      );
    }
    if (data.containsKey('hdr')) {
      context.handle(
        _hdrMeta,
        hdr.isAcceptableOrUnknown(data['hdr']!, _hdrMeta),
      );
    }
    if (data.containsKey('fps')) {
      context.handle(
        _fpsMeta,
        fps.isAcceptableOrUnknown(data['fps']!, _fpsMeta),
      );
    }
    if (data.containsKey('bitrate')) {
      context.handle(
        _bitrateMeta,
        bitrate.isAcceptableOrUnknown(data['bitrate']!, _bitrateMeta),
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
    if (data.containsKey('audio_codec')) {
      context.handle(
        _audioCodecMeta,
        audioCodec.isAcceptableOrUnknown(data['audio_codec']!, _audioCodecMeta),
      );
    }
    if (data.containsKey('profile')) {
      context.handle(
        _profileMeta,
        profile.isAcceptableOrUnknown(data['profile']!, _profileMeta),
      );
    }
    if (data.containsKey('state')) {
      context.handle(
        _stateMeta,
        state.isAcceptableOrUnknown(data['state']!, _stateMeta),
      );
    }
    if (data.containsKey('state_reason')) {
      context.handle(
        _stateReasonMeta,
        stateReason.isAcceptableOrUnknown(
          data['state_reason']!,
          _stateReasonMeta,
        ),
      );
    }
    if (data.containsKey('cache_required')) {
      context.handle(
        _cacheRequiredMeta,
        cacheRequired.isAcceptableOrUnknown(
          data['cache_required']!,
          _cacheRequiredMeta,
        ),
      );
    }
    if (data.containsKey('variants')) {
      context.handle(
        _variantsMeta,
        variants.isAcceptableOrUnknown(data['variants']!, _variantsMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  LibraryItemRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return LibraryItemRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      kind: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}kind'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      sha256: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}sha256'],
      )!,
      bytes: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}bytes'],
      )!,
      width: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}width'],
      ),
      height: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}height'],
      ),
      durationMs: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}duration_ms'],
      ),
      codec: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}codec'],
      ),
      hdr: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}hdr'],
      ),
      fps: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}fps'],
      ),
      bitrate: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}bitrate'],
      ),
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at'],
      )!,
      audioCodec: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}audio_codec'],
      ),
      profile: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}profile'],
      ),
      state: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}state'],
      )!,
      stateReason: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}state_reason'],
      ),
      cacheRequired: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}cache_required'],
      )!,
      variants: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}variants'],
      )!,
    );
  }

  @override
  $LibraryItemsTable createAlias(String alias) {
    return $LibraryItemsTable(attachedDatabase, alias);
  }
}

class LibraryItemRow extends DataClass implements Insertable<LibraryItemRow> {
  final String id;
  final String kind;
  final String name;

  /// Lowercase hex SHA-256, or `pending:<id>` until the startup import has
  /// hashed a loose file.
  final String sha256;
  final int bytes;
  final int? width;
  final int? height;
  final int? durationMs;
  final String? codec;
  final String? hdr;
  final double? fps;
  final int? bitrate;
  final int createdAt;
  final String? audioCodec;
  final String? profile;

  /// `new` (not checked yet), `ready`, `unsupported` or `error`.
  final String state;
  final String? stateReason;

  /// The video is above the streaming ceiling: the TV plays it once cached.
  final bool cacheRequired;

  /// Comma list of the variants that exist (`poster,thumb` / `1920,thumb`).
  final String variants;
  const LibraryItemRow({
    required this.id,
    required this.kind,
    required this.name,
    required this.sha256,
    required this.bytes,
    this.width,
    this.height,
    this.durationMs,
    this.codec,
    this.hdr,
    this.fps,
    this.bitrate,
    required this.createdAt,
    this.audioCodec,
    this.profile,
    required this.state,
    this.stateReason,
    required this.cacheRequired,
    required this.variants,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['kind'] = Variable<String>(kind);
    map['name'] = Variable<String>(name);
    map['sha256'] = Variable<String>(sha256);
    map['bytes'] = Variable<int>(bytes);
    if (!nullToAbsent || width != null) {
      map['width'] = Variable<int>(width);
    }
    if (!nullToAbsent || height != null) {
      map['height'] = Variable<int>(height);
    }
    if (!nullToAbsent || durationMs != null) {
      map['duration_ms'] = Variable<int>(durationMs);
    }
    if (!nullToAbsent || codec != null) {
      map['codec'] = Variable<String>(codec);
    }
    if (!nullToAbsent || hdr != null) {
      map['hdr'] = Variable<String>(hdr);
    }
    if (!nullToAbsent || fps != null) {
      map['fps'] = Variable<double>(fps);
    }
    if (!nullToAbsent || bitrate != null) {
      map['bitrate'] = Variable<int>(bitrate);
    }
    map['created_at'] = Variable<int>(createdAt);
    if (!nullToAbsent || audioCodec != null) {
      map['audio_codec'] = Variable<String>(audioCodec);
    }
    if (!nullToAbsent || profile != null) {
      map['profile'] = Variable<String>(profile);
    }
    map['state'] = Variable<String>(state);
    if (!nullToAbsent || stateReason != null) {
      map['state_reason'] = Variable<String>(stateReason);
    }
    map['cache_required'] = Variable<bool>(cacheRequired);
    map['variants'] = Variable<String>(variants);
    return map;
  }

  LibraryItemsCompanion toCompanion(bool nullToAbsent) {
    return LibraryItemsCompanion(
      id: Value(id),
      kind: Value(kind),
      name: Value(name),
      sha256: Value(sha256),
      bytes: Value(bytes),
      width: width == null && nullToAbsent
          ? const Value.absent()
          : Value(width),
      height: height == null && nullToAbsent
          ? const Value.absent()
          : Value(height),
      durationMs: durationMs == null && nullToAbsent
          ? const Value.absent()
          : Value(durationMs),
      codec: codec == null && nullToAbsent
          ? const Value.absent()
          : Value(codec),
      hdr: hdr == null && nullToAbsent ? const Value.absent() : Value(hdr),
      fps: fps == null && nullToAbsent ? const Value.absent() : Value(fps),
      bitrate: bitrate == null && nullToAbsent
          ? const Value.absent()
          : Value(bitrate),
      createdAt: Value(createdAt),
      audioCodec: audioCodec == null && nullToAbsent
          ? const Value.absent()
          : Value(audioCodec),
      profile: profile == null && nullToAbsent
          ? const Value.absent()
          : Value(profile),
      state: Value(state),
      stateReason: stateReason == null && nullToAbsent
          ? const Value.absent()
          : Value(stateReason),
      cacheRequired: Value(cacheRequired),
      variants: Value(variants),
    );
  }

  factory LibraryItemRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return LibraryItemRow(
      id: serializer.fromJson<String>(json['id']),
      kind: serializer.fromJson<String>(json['kind']),
      name: serializer.fromJson<String>(json['name']),
      sha256: serializer.fromJson<String>(json['sha256']),
      bytes: serializer.fromJson<int>(json['bytes']),
      width: serializer.fromJson<int?>(json['width']),
      height: serializer.fromJson<int?>(json['height']),
      durationMs: serializer.fromJson<int?>(json['durationMs']),
      codec: serializer.fromJson<String?>(json['codec']),
      hdr: serializer.fromJson<String?>(json['hdr']),
      fps: serializer.fromJson<double?>(json['fps']),
      bitrate: serializer.fromJson<int?>(json['bitrate']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
      audioCodec: serializer.fromJson<String?>(json['audioCodec']),
      profile: serializer.fromJson<String?>(json['profile']),
      state: serializer.fromJson<String>(json['state']),
      stateReason: serializer.fromJson<String?>(json['stateReason']),
      cacheRequired: serializer.fromJson<bool>(json['cacheRequired']),
      variants: serializer.fromJson<String>(json['variants']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'kind': serializer.toJson<String>(kind),
      'name': serializer.toJson<String>(name),
      'sha256': serializer.toJson<String>(sha256),
      'bytes': serializer.toJson<int>(bytes),
      'width': serializer.toJson<int?>(width),
      'height': serializer.toJson<int?>(height),
      'durationMs': serializer.toJson<int?>(durationMs),
      'codec': serializer.toJson<String?>(codec),
      'hdr': serializer.toJson<String?>(hdr),
      'fps': serializer.toJson<double?>(fps),
      'bitrate': serializer.toJson<int?>(bitrate),
      'createdAt': serializer.toJson<int>(createdAt),
      'audioCodec': serializer.toJson<String?>(audioCodec),
      'profile': serializer.toJson<String?>(profile),
      'state': serializer.toJson<String>(state),
      'stateReason': serializer.toJson<String?>(stateReason),
      'cacheRequired': serializer.toJson<bool>(cacheRequired),
      'variants': serializer.toJson<String>(variants),
    };
  }

  LibraryItemRow copyWith({
    String? id,
    String? kind,
    String? name,
    String? sha256,
    int? bytes,
    Value<int?> width = const Value.absent(),
    Value<int?> height = const Value.absent(),
    Value<int?> durationMs = const Value.absent(),
    Value<String?> codec = const Value.absent(),
    Value<String?> hdr = const Value.absent(),
    Value<double?> fps = const Value.absent(),
    Value<int?> bitrate = const Value.absent(),
    int? createdAt,
    Value<String?> audioCodec = const Value.absent(),
    Value<String?> profile = const Value.absent(),
    String? state,
    Value<String?> stateReason = const Value.absent(),
    bool? cacheRequired,
    String? variants,
  }) => LibraryItemRow(
    id: id ?? this.id,
    kind: kind ?? this.kind,
    name: name ?? this.name,
    sha256: sha256 ?? this.sha256,
    bytes: bytes ?? this.bytes,
    width: width.present ? width.value : this.width,
    height: height.present ? height.value : this.height,
    durationMs: durationMs.present ? durationMs.value : this.durationMs,
    codec: codec.present ? codec.value : this.codec,
    hdr: hdr.present ? hdr.value : this.hdr,
    fps: fps.present ? fps.value : this.fps,
    bitrate: bitrate.present ? bitrate.value : this.bitrate,
    createdAt: createdAt ?? this.createdAt,
    audioCodec: audioCodec.present ? audioCodec.value : this.audioCodec,
    profile: profile.present ? profile.value : this.profile,
    state: state ?? this.state,
    stateReason: stateReason.present ? stateReason.value : this.stateReason,
    cacheRequired: cacheRequired ?? this.cacheRequired,
    variants: variants ?? this.variants,
  );
  LibraryItemRow copyWithCompanion(LibraryItemsCompanion data) {
    return LibraryItemRow(
      id: data.id.present ? data.id.value : this.id,
      kind: data.kind.present ? data.kind.value : this.kind,
      name: data.name.present ? data.name.value : this.name,
      sha256: data.sha256.present ? data.sha256.value : this.sha256,
      bytes: data.bytes.present ? data.bytes.value : this.bytes,
      width: data.width.present ? data.width.value : this.width,
      height: data.height.present ? data.height.value : this.height,
      durationMs: data.durationMs.present
          ? data.durationMs.value
          : this.durationMs,
      codec: data.codec.present ? data.codec.value : this.codec,
      hdr: data.hdr.present ? data.hdr.value : this.hdr,
      fps: data.fps.present ? data.fps.value : this.fps,
      bitrate: data.bitrate.present ? data.bitrate.value : this.bitrate,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      audioCodec: data.audioCodec.present
          ? data.audioCodec.value
          : this.audioCodec,
      profile: data.profile.present ? data.profile.value : this.profile,
      state: data.state.present ? data.state.value : this.state,
      stateReason: data.stateReason.present
          ? data.stateReason.value
          : this.stateReason,
      cacheRequired: data.cacheRequired.present
          ? data.cacheRequired.value
          : this.cacheRequired,
      variants: data.variants.present ? data.variants.value : this.variants,
    );
  }

  @override
  String toString() {
    return (StringBuffer('LibraryItemRow(')
          ..write('id: $id, ')
          ..write('kind: $kind, ')
          ..write('name: $name, ')
          ..write('sha256: $sha256, ')
          ..write('bytes: $bytes, ')
          ..write('width: $width, ')
          ..write('height: $height, ')
          ..write('durationMs: $durationMs, ')
          ..write('codec: $codec, ')
          ..write('hdr: $hdr, ')
          ..write('fps: $fps, ')
          ..write('bitrate: $bitrate, ')
          ..write('createdAt: $createdAt, ')
          ..write('audioCodec: $audioCodec, ')
          ..write('profile: $profile, ')
          ..write('state: $state, ')
          ..write('stateReason: $stateReason, ')
          ..write('cacheRequired: $cacheRequired, ')
          ..write('variants: $variants')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    kind,
    name,
    sha256,
    bytes,
    width,
    height,
    durationMs,
    codec,
    hdr,
    fps,
    bitrate,
    createdAt,
    audioCodec,
    profile,
    state,
    stateReason,
    cacheRequired,
    variants,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is LibraryItemRow &&
          other.id == this.id &&
          other.kind == this.kind &&
          other.name == this.name &&
          other.sha256 == this.sha256 &&
          other.bytes == this.bytes &&
          other.width == this.width &&
          other.height == this.height &&
          other.durationMs == this.durationMs &&
          other.codec == this.codec &&
          other.hdr == this.hdr &&
          other.fps == this.fps &&
          other.bitrate == this.bitrate &&
          other.createdAt == this.createdAt &&
          other.audioCodec == this.audioCodec &&
          other.profile == this.profile &&
          other.state == this.state &&
          other.stateReason == this.stateReason &&
          other.cacheRequired == this.cacheRequired &&
          other.variants == this.variants);
}

class LibraryItemsCompanion extends UpdateCompanion<LibraryItemRow> {
  final Value<String> id;
  final Value<String> kind;
  final Value<String> name;
  final Value<String> sha256;
  final Value<int> bytes;
  final Value<int?> width;
  final Value<int?> height;
  final Value<int?> durationMs;
  final Value<String?> codec;
  final Value<String?> hdr;
  final Value<double?> fps;
  final Value<int?> bitrate;
  final Value<int> createdAt;
  final Value<String?> audioCodec;
  final Value<String?> profile;
  final Value<String> state;
  final Value<String?> stateReason;
  final Value<bool> cacheRequired;
  final Value<String> variants;
  final Value<int> rowid;
  const LibraryItemsCompanion({
    this.id = const Value.absent(),
    this.kind = const Value.absent(),
    this.name = const Value.absent(),
    this.sha256 = const Value.absent(),
    this.bytes = const Value.absent(),
    this.width = const Value.absent(),
    this.height = const Value.absent(),
    this.durationMs = const Value.absent(),
    this.codec = const Value.absent(),
    this.hdr = const Value.absent(),
    this.fps = const Value.absent(),
    this.bitrate = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.audioCodec = const Value.absent(),
    this.profile = const Value.absent(),
    this.state = const Value.absent(),
    this.stateReason = const Value.absent(),
    this.cacheRequired = const Value.absent(),
    this.variants = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  LibraryItemsCompanion.insert({
    required String id,
    required String kind,
    required String name,
    required String sha256,
    required int bytes,
    this.width = const Value.absent(),
    this.height = const Value.absent(),
    this.durationMs = const Value.absent(),
    this.codec = const Value.absent(),
    this.hdr = const Value.absent(),
    this.fps = const Value.absent(),
    this.bitrate = const Value.absent(),
    required int createdAt,
    this.audioCodec = const Value.absent(),
    this.profile = const Value.absent(),
    this.state = const Value.absent(),
    this.stateReason = const Value.absent(),
    this.cacheRequired = const Value.absent(),
    this.variants = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       kind = Value(kind),
       name = Value(name),
       sha256 = Value(sha256),
       bytes = Value(bytes),
       createdAt = Value(createdAt);
  static Insertable<LibraryItemRow> custom({
    Expression<String>? id,
    Expression<String>? kind,
    Expression<String>? name,
    Expression<String>? sha256,
    Expression<int>? bytes,
    Expression<int>? width,
    Expression<int>? height,
    Expression<int>? durationMs,
    Expression<String>? codec,
    Expression<String>? hdr,
    Expression<double>? fps,
    Expression<int>? bitrate,
    Expression<int>? createdAt,
    Expression<String>? audioCodec,
    Expression<String>? profile,
    Expression<String>? state,
    Expression<String>? stateReason,
    Expression<bool>? cacheRequired,
    Expression<String>? variants,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (kind != null) 'kind': kind,
      if (name != null) 'name': name,
      if (sha256 != null) 'sha256': sha256,
      if (bytes != null) 'bytes': bytes,
      if (width != null) 'width': width,
      if (height != null) 'height': height,
      if (durationMs != null) 'duration_ms': durationMs,
      if (codec != null) 'codec': codec,
      if (hdr != null) 'hdr': hdr,
      if (fps != null) 'fps': fps,
      if (bitrate != null) 'bitrate': bitrate,
      if (createdAt != null) 'created_at': createdAt,
      if (audioCodec != null) 'audio_codec': audioCodec,
      if (profile != null) 'profile': profile,
      if (state != null) 'state': state,
      if (stateReason != null) 'state_reason': stateReason,
      if (cacheRequired != null) 'cache_required': cacheRequired,
      if (variants != null) 'variants': variants,
      if (rowid != null) 'rowid': rowid,
    });
  }

  LibraryItemsCompanion copyWith({
    Value<String>? id,
    Value<String>? kind,
    Value<String>? name,
    Value<String>? sha256,
    Value<int>? bytes,
    Value<int?>? width,
    Value<int?>? height,
    Value<int?>? durationMs,
    Value<String?>? codec,
    Value<String?>? hdr,
    Value<double?>? fps,
    Value<int?>? bitrate,
    Value<int>? createdAt,
    Value<String?>? audioCodec,
    Value<String?>? profile,
    Value<String>? state,
    Value<String?>? stateReason,
    Value<bool>? cacheRequired,
    Value<String>? variants,
    Value<int>? rowid,
  }) {
    return LibraryItemsCompanion(
      id: id ?? this.id,
      kind: kind ?? this.kind,
      name: name ?? this.name,
      sha256: sha256 ?? this.sha256,
      bytes: bytes ?? this.bytes,
      width: width ?? this.width,
      height: height ?? this.height,
      durationMs: durationMs ?? this.durationMs,
      codec: codec ?? this.codec,
      hdr: hdr ?? this.hdr,
      fps: fps ?? this.fps,
      bitrate: bitrate ?? this.bitrate,
      createdAt: createdAt ?? this.createdAt,
      audioCodec: audioCodec ?? this.audioCodec,
      profile: profile ?? this.profile,
      state: state ?? this.state,
      stateReason: stateReason ?? this.stateReason,
      cacheRequired: cacheRequired ?? this.cacheRequired,
      variants: variants ?? this.variants,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (kind.present) {
      map['kind'] = Variable<String>(kind.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (sha256.present) {
      map['sha256'] = Variable<String>(sha256.value);
    }
    if (bytes.present) {
      map['bytes'] = Variable<int>(bytes.value);
    }
    if (width.present) {
      map['width'] = Variable<int>(width.value);
    }
    if (height.present) {
      map['height'] = Variable<int>(height.value);
    }
    if (durationMs.present) {
      map['duration_ms'] = Variable<int>(durationMs.value);
    }
    if (codec.present) {
      map['codec'] = Variable<String>(codec.value);
    }
    if (hdr.present) {
      map['hdr'] = Variable<String>(hdr.value);
    }
    if (fps.present) {
      map['fps'] = Variable<double>(fps.value);
    }
    if (bitrate.present) {
      map['bitrate'] = Variable<int>(bitrate.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (audioCodec.present) {
      map['audio_codec'] = Variable<String>(audioCodec.value);
    }
    if (profile.present) {
      map['profile'] = Variable<String>(profile.value);
    }
    if (state.present) {
      map['state'] = Variable<String>(state.value);
    }
    if (stateReason.present) {
      map['state_reason'] = Variable<String>(stateReason.value);
    }
    if (cacheRequired.present) {
      map['cache_required'] = Variable<bool>(cacheRequired.value);
    }
    if (variants.present) {
      map['variants'] = Variable<String>(variants.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LibraryItemsCompanion(')
          ..write('id: $id, ')
          ..write('kind: $kind, ')
          ..write('name: $name, ')
          ..write('sha256: $sha256, ')
          ..write('bytes: $bytes, ')
          ..write('width: $width, ')
          ..write('height: $height, ')
          ..write('durationMs: $durationMs, ')
          ..write('codec: $codec, ')
          ..write('hdr: $hdr, ')
          ..write('fps: $fps, ')
          ..write('bitrate: $bitrate, ')
          ..write('createdAt: $createdAt, ')
          ..write('audioCodec: $audioCodec, ')
          ..write('profile: $profile, ')
          ..write('state: $state, ')
          ..write('stateReason: $stateReason, ')
          ..write('cacheRequired: $cacheRequired, ')
          ..write('variants: $variants, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $UploadsTable extends Uploads with TableInfo<$UploadsTable, UploadRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $UploadsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _bytesMeta = const VerificationMeta('bytes');
  @override
  late final GeneratedColumn<int> bytes = GeneratedColumn<int>(
    'bytes',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sha256Meta = const VerificationMeta('sha256');
  @override
  late final GeneratedColumn<String> sha256 = GeneratedColumn<String>(
    'sha256',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways('UNIQUE'),
  );
  static const VerificationMeta _mimeMeta = const VerificationMeta('mime');
  @override
  late final GeneratedColumn<String> mime = GeneratedColumn<String>(
    'mime',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _receivedMeta = const VerificationMeta(
    'received',
  );
  @override
  late final GeneratedColumn<int> received = GeneratedColumn<int>(
    'received',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
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
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    name,
    bytes,
    sha256,
    mime,
    received,
    deviceId,
    createdAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'uploads';
  @override
  VerificationContext validateIntegrity(
    Insertable<UploadRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('bytes')) {
      context.handle(
        _bytesMeta,
        bytes.isAcceptableOrUnknown(data['bytes']!, _bytesMeta),
      );
    } else if (isInserting) {
      context.missing(_bytesMeta);
    }
    if (data.containsKey('sha256')) {
      context.handle(
        _sha256Meta,
        sha256.isAcceptableOrUnknown(data['sha256']!, _sha256Meta),
      );
    } else if (isInserting) {
      context.missing(_sha256Meta);
    }
    if (data.containsKey('mime')) {
      context.handle(
        _mimeMeta,
        mime.isAcceptableOrUnknown(data['mime']!, _mimeMeta),
      );
    } else if (isInserting) {
      context.missing(_mimeMeta);
    }
    if (data.containsKey('received')) {
      context.handle(
        _receivedMeta,
        received.isAcceptableOrUnknown(data['received']!, _receivedMeta),
      );
    }
    if (data.containsKey('device_id')) {
      context.handle(
        _deviceIdMeta,
        deviceId.isAcceptableOrUnknown(data['device_id']!, _deviceIdMeta),
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
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  UploadRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return UploadRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      bytes: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}bytes'],
      )!,
      sha256: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}sha256'],
      )!,
      mime: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}mime'],
      )!,
      received: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}received'],
      )!,
      deviceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}device_id'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at'],
      )!,
    );
  }

  @override
  $UploadsTable createAlias(String alias) {
    return $UploadsTable(attachedDatabase, alias);
  }
}

class UploadRow extends DataClass implements Insertable<UploadRow> {
  final String id;
  final String name;
  final int bytes;
  final String sha256;
  final String mime;
  final int received;

  /// The paired device that started it; empty for the static token.
  final String deviceId;
  final int createdAt;
  const UploadRow({
    required this.id,
    required this.name,
    required this.bytes,
    required this.sha256,
    required this.mime,
    required this.received,
    required this.deviceId,
    required this.createdAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['name'] = Variable<String>(name);
    map['bytes'] = Variable<int>(bytes);
    map['sha256'] = Variable<String>(sha256);
    map['mime'] = Variable<String>(mime);
    map['received'] = Variable<int>(received);
    map['device_id'] = Variable<String>(deviceId);
    map['created_at'] = Variable<int>(createdAt);
    return map;
  }

  UploadsCompanion toCompanion(bool nullToAbsent) {
    return UploadsCompanion(
      id: Value(id),
      name: Value(name),
      bytes: Value(bytes),
      sha256: Value(sha256),
      mime: Value(mime),
      received: Value(received),
      deviceId: Value(deviceId),
      createdAt: Value(createdAt),
    );
  }

  factory UploadRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return UploadRow(
      id: serializer.fromJson<String>(json['id']),
      name: serializer.fromJson<String>(json['name']),
      bytes: serializer.fromJson<int>(json['bytes']),
      sha256: serializer.fromJson<String>(json['sha256']),
      mime: serializer.fromJson<String>(json['mime']),
      received: serializer.fromJson<int>(json['received']),
      deviceId: serializer.fromJson<String>(json['deviceId']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'name': serializer.toJson<String>(name),
      'bytes': serializer.toJson<int>(bytes),
      'sha256': serializer.toJson<String>(sha256),
      'mime': serializer.toJson<String>(mime),
      'received': serializer.toJson<int>(received),
      'deviceId': serializer.toJson<String>(deviceId),
      'createdAt': serializer.toJson<int>(createdAt),
    };
  }

  UploadRow copyWith({
    String? id,
    String? name,
    int? bytes,
    String? sha256,
    String? mime,
    int? received,
    String? deviceId,
    int? createdAt,
  }) => UploadRow(
    id: id ?? this.id,
    name: name ?? this.name,
    bytes: bytes ?? this.bytes,
    sha256: sha256 ?? this.sha256,
    mime: mime ?? this.mime,
    received: received ?? this.received,
    deviceId: deviceId ?? this.deviceId,
    createdAt: createdAt ?? this.createdAt,
  );
  UploadRow copyWithCompanion(UploadsCompanion data) {
    return UploadRow(
      id: data.id.present ? data.id.value : this.id,
      name: data.name.present ? data.name.value : this.name,
      bytes: data.bytes.present ? data.bytes.value : this.bytes,
      sha256: data.sha256.present ? data.sha256.value : this.sha256,
      mime: data.mime.present ? data.mime.value : this.mime,
      received: data.received.present ? data.received.value : this.received,
      deviceId: data.deviceId.present ? data.deviceId.value : this.deviceId,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('UploadRow(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('bytes: $bytes, ')
          ..write('sha256: $sha256, ')
          ..write('mime: $mime, ')
          ..write('received: $received, ')
          ..write('deviceId: $deviceId, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(id, name, bytes, sha256, mime, received, deviceId, createdAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is UploadRow &&
          other.id == this.id &&
          other.name == this.name &&
          other.bytes == this.bytes &&
          other.sha256 == this.sha256 &&
          other.mime == this.mime &&
          other.received == this.received &&
          other.deviceId == this.deviceId &&
          other.createdAt == this.createdAt);
}

class UploadsCompanion extends UpdateCompanion<UploadRow> {
  final Value<String> id;
  final Value<String> name;
  final Value<int> bytes;
  final Value<String> sha256;
  final Value<String> mime;
  final Value<int> received;
  final Value<String> deviceId;
  final Value<int> createdAt;
  final Value<int> rowid;
  const UploadsCompanion({
    this.id = const Value.absent(),
    this.name = const Value.absent(),
    this.bytes = const Value.absent(),
    this.sha256 = const Value.absent(),
    this.mime = const Value.absent(),
    this.received = const Value.absent(),
    this.deviceId = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  UploadsCompanion.insert({
    required String id,
    required String name,
    required int bytes,
    required String sha256,
    required String mime,
    this.received = const Value.absent(),
    this.deviceId = const Value.absent(),
    required int createdAt,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       name = Value(name),
       bytes = Value(bytes),
       sha256 = Value(sha256),
       mime = Value(mime),
       createdAt = Value(createdAt);
  static Insertable<UploadRow> custom({
    Expression<String>? id,
    Expression<String>? name,
    Expression<int>? bytes,
    Expression<String>? sha256,
    Expression<String>? mime,
    Expression<int>? received,
    Expression<String>? deviceId,
    Expression<int>? createdAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (name != null) 'name': name,
      if (bytes != null) 'bytes': bytes,
      if (sha256 != null) 'sha256': sha256,
      if (mime != null) 'mime': mime,
      if (received != null) 'received': received,
      if (deviceId != null) 'device_id': deviceId,
      if (createdAt != null) 'created_at': createdAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  UploadsCompanion copyWith({
    Value<String>? id,
    Value<String>? name,
    Value<int>? bytes,
    Value<String>? sha256,
    Value<String>? mime,
    Value<int>? received,
    Value<String>? deviceId,
    Value<int>? createdAt,
    Value<int>? rowid,
  }) {
    return UploadsCompanion(
      id: id ?? this.id,
      name: name ?? this.name,
      bytes: bytes ?? this.bytes,
      sha256: sha256 ?? this.sha256,
      mime: mime ?? this.mime,
      received: received ?? this.received,
      deviceId: deviceId ?? this.deviceId,
      createdAt: createdAt ?? this.createdAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (bytes.present) {
      map['bytes'] = Variable<int>(bytes.value);
    }
    if (sha256.present) {
      map['sha256'] = Variable<String>(sha256.value);
    }
    if (mime.present) {
      map['mime'] = Variable<String>(mime.value);
    }
    if (received.present) {
      map['received'] = Variable<int>(received.value);
    }
    if (deviceId.present) {
      map['device_id'] = Variable<String>(deviceId.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('UploadsCompanion(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('bytes: $bytes, ')
          ..write('sha256: $sha256, ')
          ..write('mime: $mime, ')
          ..write('received: $received, ')
          ..write('deviceId: $deviceId, ')
          ..write('createdAt: $createdAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$HubDatabase extends GeneratedDatabase {
  _$HubDatabase(QueryExecutor e) : super(e);
  $HubDatabaseManager get managers => $HubDatabaseManager(this);
  late final $DevicesTable devices = $DevicesTable(this);
  late final $PairingsTable pairings = $PairingsTable(this);
  late final $LibraryItemsTable libraryItems = $LibraryItemsTable(this);
  late final $UploadsTable uploads = $UploadsTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    devices,
    pairings,
    libraryItems,
    uploads,
  ];
}

typedef $$DevicesTableCreateCompanionBuilder =
    DevicesCompanion Function({
      required String id,
      required String name,
      required String role,
      required int createdAt,
      Value<int> rowid,
    });
typedef $$DevicesTableUpdateCompanionBuilder =
    DevicesCompanion Function({
      Value<String> id,
      Value<String> name,
      Value<String> role,
      Value<int> createdAt,
      Value<int> rowid,
    });

class $$DevicesTableFilterComposer
    extends Composer<_$HubDatabase, $DevicesTable> {
  $$DevicesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get role => $composableBuilder(
    column: $table.role,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$DevicesTableOrderingComposer
    extends Composer<_$HubDatabase, $DevicesTable> {
  $$DevicesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get role => $composableBuilder(
    column: $table.role,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$DevicesTableAnnotationComposer
    extends Composer<_$HubDatabase, $DevicesTable> {
  $$DevicesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get role =>
      $composableBuilder(column: $table.role, builder: (column) => column);

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);
}

class $$DevicesTableTableManager
    extends
        RootTableManager<
          _$HubDatabase,
          $DevicesTable,
          DeviceRow,
          $$DevicesTableFilterComposer,
          $$DevicesTableOrderingComposer,
          $$DevicesTableAnnotationComposer,
          $$DevicesTableCreateCompanionBuilder,
          $$DevicesTableUpdateCompanionBuilder,
          (DeviceRow, BaseReferences<_$HubDatabase, $DevicesTable, DeviceRow>),
          DeviceRow,
          PrefetchHooks Function()
        > {
  $$DevicesTableTableManager(_$HubDatabase db, $DevicesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$DevicesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$DevicesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$DevicesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<String> role = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => DevicesCompanion(
                id: id,
                name: name,
                role: role,
                createdAt: createdAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String name,
                required String role,
                required int createdAt,
                Value<int> rowid = const Value.absent(),
              }) => DevicesCompanion.insert(
                id: id,
                name: name,
                role: role,
                createdAt: createdAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$DevicesTableProcessedTableManager =
    ProcessedTableManager<
      _$HubDatabase,
      $DevicesTable,
      DeviceRow,
      $$DevicesTableFilterComposer,
      $$DevicesTableOrderingComposer,
      $$DevicesTableAnnotationComposer,
      $$DevicesTableCreateCompanionBuilder,
      $$DevicesTableUpdateCompanionBuilder,
      (DeviceRow, BaseReferences<_$HubDatabase, $DevicesTable, DeviceRow>),
      DeviceRow,
      PrefetchHooks Function()
    >;
typedef $$PairingsTableCreateCompanionBuilder =
    PairingsCompanion Function({
      required String tokenHash,
      required String deviceId,
      required String clientName,
      required int createdAt,
      required int lastSeenAt,
      Value<int> rowid,
    });
typedef $$PairingsTableUpdateCompanionBuilder =
    PairingsCompanion Function({
      Value<String> tokenHash,
      Value<String> deviceId,
      Value<String> clientName,
      Value<int> createdAt,
      Value<int> lastSeenAt,
      Value<int> rowid,
    });

class $$PairingsTableFilterComposer
    extends Composer<_$HubDatabase, $PairingsTable> {
  $$PairingsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get tokenHash => $composableBuilder(
    column: $table.tokenHash,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get deviceId => $composableBuilder(
    column: $table.deviceId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get clientName => $composableBuilder(
    column: $table.clientName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get lastSeenAt => $composableBuilder(
    column: $table.lastSeenAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$PairingsTableOrderingComposer
    extends Composer<_$HubDatabase, $PairingsTable> {
  $$PairingsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get tokenHash => $composableBuilder(
    column: $table.tokenHash,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get deviceId => $composableBuilder(
    column: $table.deviceId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get clientName => $composableBuilder(
    column: $table.clientName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get lastSeenAt => $composableBuilder(
    column: $table.lastSeenAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$PairingsTableAnnotationComposer
    extends Composer<_$HubDatabase, $PairingsTable> {
  $$PairingsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get tokenHash =>
      $composableBuilder(column: $table.tokenHash, builder: (column) => column);

  GeneratedColumn<String> get deviceId =>
      $composableBuilder(column: $table.deviceId, builder: (column) => column);

  GeneratedColumn<String> get clientName => $composableBuilder(
    column: $table.clientName,
    builder: (column) => column,
  );

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<int> get lastSeenAt => $composableBuilder(
    column: $table.lastSeenAt,
    builder: (column) => column,
  );
}

class $$PairingsTableTableManager
    extends
        RootTableManager<
          _$HubDatabase,
          $PairingsTable,
          PairingRow,
          $$PairingsTableFilterComposer,
          $$PairingsTableOrderingComposer,
          $$PairingsTableAnnotationComposer,
          $$PairingsTableCreateCompanionBuilder,
          $$PairingsTableUpdateCompanionBuilder,
          (
            PairingRow,
            BaseReferences<_$HubDatabase, $PairingsTable, PairingRow>,
          ),
          PairingRow,
          PrefetchHooks Function()
        > {
  $$PairingsTableTableManager(_$HubDatabase db, $PairingsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$PairingsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$PairingsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$PairingsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> tokenHash = const Value.absent(),
                Value<String> deviceId = const Value.absent(),
                Value<String> clientName = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
                Value<int> lastSeenAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => PairingsCompanion(
                tokenHash: tokenHash,
                deviceId: deviceId,
                clientName: clientName,
                createdAt: createdAt,
                lastSeenAt: lastSeenAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String tokenHash,
                required String deviceId,
                required String clientName,
                required int createdAt,
                required int lastSeenAt,
                Value<int> rowid = const Value.absent(),
              }) => PairingsCompanion.insert(
                tokenHash: tokenHash,
                deviceId: deviceId,
                clientName: clientName,
                createdAt: createdAt,
                lastSeenAt: lastSeenAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$PairingsTableProcessedTableManager =
    ProcessedTableManager<
      _$HubDatabase,
      $PairingsTable,
      PairingRow,
      $$PairingsTableFilterComposer,
      $$PairingsTableOrderingComposer,
      $$PairingsTableAnnotationComposer,
      $$PairingsTableCreateCompanionBuilder,
      $$PairingsTableUpdateCompanionBuilder,
      (PairingRow, BaseReferences<_$HubDatabase, $PairingsTable, PairingRow>),
      PairingRow,
      PrefetchHooks Function()
    >;
typedef $$LibraryItemsTableCreateCompanionBuilder =
    LibraryItemsCompanion Function({
      required String id,
      required String kind,
      required String name,
      required String sha256,
      required int bytes,
      Value<int?> width,
      Value<int?> height,
      Value<int?> durationMs,
      Value<String?> codec,
      Value<String?> hdr,
      Value<double?> fps,
      Value<int?> bitrate,
      required int createdAt,
      Value<String?> audioCodec,
      Value<String?> profile,
      Value<String> state,
      Value<String?> stateReason,
      Value<bool> cacheRequired,
      Value<String> variants,
      Value<int> rowid,
    });
typedef $$LibraryItemsTableUpdateCompanionBuilder =
    LibraryItemsCompanion Function({
      Value<String> id,
      Value<String> kind,
      Value<String> name,
      Value<String> sha256,
      Value<int> bytes,
      Value<int?> width,
      Value<int?> height,
      Value<int?> durationMs,
      Value<String?> codec,
      Value<String?> hdr,
      Value<double?> fps,
      Value<int?> bitrate,
      Value<int> createdAt,
      Value<String?> audioCodec,
      Value<String?> profile,
      Value<String> state,
      Value<String?> stateReason,
      Value<bool> cacheRequired,
      Value<String> variants,
      Value<int> rowid,
    });

class $$LibraryItemsTableFilterComposer
    extends Composer<_$HubDatabase, $LibraryItemsTable> {
  $$LibraryItemsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get sha256 => $composableBuilder(
    column: $table.sha256,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get bytes => $composableBuilder(
    column: $table.bytes,
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

  ColumnFilters<int> get durationMs => $composableBuilder(
    column: $table.durationMs,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get codec => $composableBuilder(
    column: $table.codec,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get hdr => $composableBuilder(
    column: $table.hdr,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get fps => $composableBuilder(
    column: $table.fps,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get bitrate => $composableBuilder(
    column: $table.bitrate,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get audioCodec => $composableBuilder(
    column: $table.audioCodec,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get profile => $composableBuilder(
    column: $table.profile,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get state => $composableBuilder(
    column: $table.state,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get stateReason => $composableBuilder(
    column: $table.stateReason,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get cacheRequired => $composableBuilder(
    column: $table.cacheRequired,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get variants => $composableBuilder(
    column: $table.variants,
    builder: (column) => ColumnFilters(column),
  );
}

class $$LibraryItemsTableOrderingComposer
    extends Composer<_$HubDatabase, $LibraryItemsTable> {
  $$LibraryItemsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get sha256 => $composableBuilder(
    column: $table.sha256,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get bytes => $composableBuilder(
    column: $table.bytes,
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

  ColumnOrderings<int> get durationMs => $composableBuilder(
    column: $table.durationMs,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get codec => $composableBuilder(
    column: $table.codec,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get hdr => $composableBuilder(
    column: $table.hdr,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get fps => $composableBuilder(
    column: $table.fps,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get bitrate => $composableBuilder(
    column: $table.bitrate,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get audioCodec => $composableBuilder(
    column: $table.audioCodec,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get profile => $composableBuilder(
    column: $table.profile,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get state => $composableBuilder(
    column: $table.state,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get stateReason => $composableBuilder(
    column: $table.stateReason,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get cacheRequired => $composableBuilder(
    column: $table.cacheRequired,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get variants => $composableBuilder(
    column: $table.variants,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$LibraryItemsTableAnnotationComposer
    extends Composer<_$HubDatabase, $LibraryItemsTable> {
  $$LibraryItemsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get kind =>
      $composableBuilder(column: $table.kind, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get sha256 =>
      $composableBuilder(column: $table.sha256, builder: (column) => column);

  GeneratedColumn<int> get bytes =>
      $composableBuilder(column: $table.bytes, builder: (column) => column);

  GeneratedColumn<int> get width =>
      $composableBuilder(column: $table.width, builder: (column) => column);

  GeneratedColumn<int> get height =>
      $composableBuilder(column: $table.height, builder: (column) => column);

  GeneratedColumn<int> get durationMs => $composableBuilder(
    column: $table.durationMs,
    builder: (column) => column,
  );

  GeneratedColumn<String> get codec =>
      $composableBuilder(column: $table.codec, builder: (column) => column);

  GeneratedColumn<String> get hdr =>
      $composableBuilder(column: $table.hdr, builder: (column) => column);

  GeneratedColumn<double> get fps =>
      $composableBuilder(column: $table.fps, builder: (column) => column);

  GeneratedColumn<int> get bitrate =>
      $composableBuilder(column: $table.bitrate, builder: (column) => column);

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<String> get audioCodec => $composableBuilder(
    column: $table.audioCodec,
    builder: (column) => column,
  );

  GeneratedColumn<String> get profile =>
      $composableBuilder(column: $table.profile, builder: (column) => column);

  GeneratedColumn<String> get state =>
      $composableBuilder(column: $table.state, builder: (column) => column);

  GeneratedColumn<String> get stateReason => $composableBuilder(
    column: $table.stateReason,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get cacheRequired => $composableBuilder(
    column: $table.cacheRequired,
    builder: (column) => column,
  );

  GeneratedColumn<String> get variants =>
      $composableBuilder(column: $table.variants, builder: (column) => column);
}

class $$LibraryItemsTableTableManager
    extends
        RootTableManager<
          _$HubDatabase,
          $LibraryItemsTable,
          LibraryItemRow,
          $$LibraryItemsTableFilterComposer,
          $$LibraryItemsTableOrderingComposer,
          $$LibraryItemsTableAnnotationComposer,
          $$LibraryItemsTableCreateCompanionBuilder,
          $$LibraryItemsTableUpdateCompanionBuilder,
          (
            LibraryItemRow,
            BaseReferences<_$HubDatabase, $LibraryItemsTable, LibraryItemRow>,
          ),
          LibraryItemRow,
          PrefetchHooks Function()
        > {
  $$LibraryItemsTableTableManager(_$HubDatabase db, $LibraryItemsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$LibraryItemsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$LibraryItemsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$LibraryItemsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> kind = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<String> sha256 = const Value.absent(),
                Value<int> bytes = const Value.absent(),
                Value<int?> width = const Value.absent(),
                Value<int?> height = const Value.absent(),
                Value<int?> durationMs = const Value.absent(),
                Value<String?> codec = const Value.absent(),
                Value<String?> hdr = const Value.absent(),
                Value<double?> fps = const Value.absent(),
                Value<int?> bitrate = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
                Value<String?> audioCodec = const Value.absent(),
                Value<String?> profile = const Value.absent(),
                Value<String> state = const Value.absent(),
                Value<String?> stateReason = const Value.absent(),
                Value<bool> cacheRequired = const Value.absent(),
                Value<String> variants = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => LibraryItemsCompanion(
                id: id,
                kind: kind,
                name: name,
                sha256: sha256,
                bytes: bytes,
                width: width,
                height: height,
                durationMs: durationMs,
                codec: codec,
                hdr: hdr,
                fps: fps,
                bitrate: bitrate,
                createdAt: createdAt,
                audioCodec: audioCodec,
                profile: profile,
                state: state,
                stateReason: stateReason,
                cacheRequired: cacheRequired,
                variants: variants,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String kind,
                required String name,
                required String sha256,
                required int bytes,
                Value<int?> width = const Value.absent(),
                Value<int?> height = const Value.absent(),
                Value<int?> durationMs = const Value.absent(),
                Value<String?> codec = const Value.absent(),
                Value<String?> hdr = const Value.absent(),
                Value<double?> fps = const Value.absent(),
                Value<int?> bitrate = const Value.absent(),
                required int createdAt,
                Value<String?> audioCodec = const Value.absent(),
                Value<String?> profile = const Value.absent(),
                Value<String> state = const Value.absent(),
                Value<String?> stateReason = const Value.absent(),
                Value<bool> cacheRequired = const Value.absent(),
                Value<String> variants = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => LibraryItemsCompanion.insert(
                id: id,
                kind: kind,
                name: name,
                sha256: sha256,
                bytes: bytes,
                width: width,
                height: height,
                durationMs: durationMs,
                codec: codec,
                hdr: hdr,
                fps: fps,
                bitrate: bitrate,
                createdAt: createdAt,
                audioCodec: audioCodec,
                profile: profile,
                state: state,
                stateReason: stateReason,
                cacheRequired: cacheRequired,
                variants: variants,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$LibraryItemsTableProcessedTableManager =
    ProcessedTableManager<
      _$HubDatabase,
      $LibraryItemsTable,
      LibraryItemRow,
      $$LibraryItemsTableFilterComposer,
      $$LibraryItemsTableOrderingComposer,
      $$LibraryItemsTableAnnotationComposer,
      $$LibraryItemsTableCreateCompanionBuilder,
      $$LibraryItemsTableUpdateCompanionBuilder,
      (
        LibraryItemRow,
        BaseReferences<_$HubDatabase, $LibraryItemsTable, LibraryItemRow>,
      ),
      LibraryItemRow,
      PrefetchHooks Function()
    >;
typedef $$UploadsTableCreateCompanionBuilder =
    UploadsCompanion Function({
      required String id,
      required String name,
      required int bytes,
      required String sha256,
      required String mime,
      Value<int> received,
      Value<String> deviceId,
      required int createdAt,
      Value<int> rowid,
    });
typedef $$UploadsTableUpdateCompanionBuilder =
    UploadsCompanion Function({
      Value<String> id,
      Value<String> name,
      Value<int> bytes,
      Value<String> sha256,
      Value<String> mime,
      Value<int> received,
      Value<String> deviceId,
      Value<int> createdAt,
      Value<int> rowid,
    });

class $$UploadsTableFilterComposer
    extends Composer<_$HubDatabase, $UploadsTable> {
  $$UploadsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get bytes => $composableBuilder(
    column: $table.bytes,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get sha256 => $composableBuilder(
    column: $table.sha256,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get mime => $composableBuilder(
    column: $table.mime,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get received => $composableBuilder(
    column: $table.received,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get deviceId => $composableBuilder(
    column: $table.deviceId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$UploadsTableOrderingComposer
    extends Composer<_$HubDatabase, $UploadsTable> {
  $$UploadsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get bytes => $composableBuilder(
    column: $table.bytes,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get sha256 => $composableBuilder(
    column: $table.sha256,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get mime => $composableBuilder(
    column: $table.mime,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get received => $composableBuilder(
    column: $table.received,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get deviceId => $composableBuilder(
    column: $table.deviceId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$UploadsTableAnnotationComposer
    extends Composer<_$HubDatabase, $UploadsTable> {
  $$UploadsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<int> get bytes =>
      $composableBuilder(column: $table.bytes, builder: (column) => column);

  GeneratedColumn<String> get sha256 =>
      $composableBuilder(column: $table.sha256, builder: (column) => column);

  GeneratedColumn<String> get mime =>
      $composableBuilder(column: $table.mime, builder: (column) => column);

  GeneratedColumn<int> get received =>
      $composableBuilder(column: $table.received, builder: (column) => column);

  GeneratedColumn<String> get deviceId =>
      $composableBuilder(column: $table.deviceId, builder: (column) => column);

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);
}

class $$UploadsTableTableManager
    extends
        RootTableManager<
          _$HubDatabase,
          $UploadsTable,
          UploadRow,
          $$UploadsTableFilterComposer,
          $$UploadsTableOrderingComposer,
          $$UploadsTableAnnotationComposer,
          $$UploadsTableCreateCompanionBuilder,
          $$UploadsTableUpdateCompanionBuilder,
          (UploadRow, BaseReferences<_$HubDatabase, $UploadsTable, UploadRow>),
          UploadRow,
          PrefetchHooks Function()
        > {
  $$UploadsTableTableManager(_$HubDatabase db, $UploadsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$UploadsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$UploadsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$UploadsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<int> bytes = const Value.absent(),
                Value<String> sha256 = const Value.absent(),
                Value<String> mime = const Value.absent(),
                Value<int> received = const Value.absent(),
                Value<String> deviceId = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => UploadsCompanion(
                id: id,
                name: name,
                bytes: bytes,
                sha256: sha256,
                mime: mime,
                received: received,
                deviceId: deviceId,
                createdAt: createdAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String name,
                required int bytes,
                required String sha256,
                required String mime,
                Value<int> received = const Value.absent(),
                Value<String> deviceId = const Value.absent(),
                required int createdAt,
                Value<int> rowid = const Value.absent(),
              }) => UploadsCompanion.insert(
                id: id,
                name: name,
                bytes: bytes,
                sha256: sha256,
                mime: mime,
                received: received,
                deviceId: deviceId,
                createdAt: createdAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$UploadsTableProcessedTableManager =
    ProcessedTableManager<
      _$HubDatabase,
      $UploadsTable,
      UploadRow,
      $$UploadsTableFilterComposer,
      $$UploadsTableOrderingComposer,
      $$UploadsTableAnnotationComposer,
      $$UploadsTableCreateCompanionBuilder,
      $$UploadsTableUpdateCompanionBuilder,
      (UploadRow, BaseReferences<_$HubDatabase, $UploadsTable, UploadRow>),
      UploadRow,
      PrefetchHooks Function()
    >;

class $HubDatabaseManager {
  final _$HubDatabase _db;
  $HubDatabaseManager(this._db);
  $$DevicesTableTableManager get devices =>
      $$DevicesTableTableManager(_db, _db.devices);
  $$PairingsTableTableManager get pairings =>
      $$PairingsTableTableManager(_db, _db.pairings);
  $$LibraryItemsTableTableManager get libraryItems =>
      $$LibraryItemsTableTableManager(_db, _db.libraryItems);
  $$UploadsTableTableManager get uploads =>
      $$UploadsTableTableManager(_db, _db.uploads);
}
