// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'user_notifications_migration_test.dart';

// ignore_for_file: type=lint
class $UserNotificationsTable extends UserNotifications
    with TableInfo<$UserNotificationsTable, UserNotification> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $UserNotificationsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
      'id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _userIdMeta = const VerificationMeta('userId');
  @override
  late final GeneratedColumn<String> userId = GeneratedColumn<String>(
      'user_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _notificationTypeMeta =
      const VerificationMeta('notificationType');
  @override
  late final GeneratedColumn<String> notificationType = GeneratedColumn<String>(
      'notification_type', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _subjectKeyMeta =
      const VerificationMeta('subjectKey');
  @override
  late final GeneratedColumn<String> subjectKey = GeneratedColumn<String>(
      'subject_key', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _payloadMeta =
      const VerificationMeta('payload');
  @override
  late final GeneratedColumn<String> payload = GeneratedColumn<String>(
      'payload', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _createdAtMeta =
      const VerificationMeta('createdAt');
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
      'created_at', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _updatedAtMeta =
      const VerificationMeta('updatedAt');
  @override
  late final GeneratedColumn<int> updatedAt = GeneratedColumn<int>(
      'updated_at', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns =>
      [id, userId, notificationType, subjectKey, payload, createdAt, updatedAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'user_notifications';
  @override
  VerificationContext validateIntegrity(Insertable<UserNotification> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('user_id')) {
      context.handle(_userIdMeta,
          userId.isAcceptableOrUnknown(data['user_id']!, _userIdMeta));
    } else if (isInserting) {
      context.missing(_userIdMeta);
    }
    if (data.containsKey('notification_type')) {
      context.handle(
          _notificationTypeMeta,
          notificationType.isAcceptableOrUnknown(
              data['notification_type']!, _notificationTypeMeta));
    } else if (isInserting) {
      context.missing(_notificationTypeMeta);
    }
    if (data.containsKey('subject_key')) {
      context.handle(
          _subjectKeyMeta,
          subjectKey.isAcceptableOrUnknown(
              data['subject_key']!, _subjectKeyMeta));
    } else if (isInserting) {
      context.missing(_subjectKeyMeta);
    }
    if (data.containsKey('payload')) {
      context.handle(_payloadMeta,
          payload.isAcceptableOrUnknown(data['payload']!, _payloadMeta));
    }
    if (data.containsKey('created_at')) {
      context.handle(_createdAtMeta,
          createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta));
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(_updatedAtMeta,
          updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta));
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  UserNotification map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return UserNotification(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}id'])!,
      userId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}user_id'])!,
      notificationType: attachedDatabase.typeMapping.read(
          DriftSqlType.string, data['${effectivePrefix}notification_type'])!,
      subjectKey: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}subject_key'])!,
      payload: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}payload']),
      createdAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}created_at'])!,
      updatedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}updated_at'])!,
    );
  }

  @override
  $UserNotificationsTable createAlias(String alias) {
    return $UserNotificationsTable(attachedDatabase, alias);
  }
}

class UserNotification extends DataClass
    implements Insertable<UserNotification> {
  /// UUID v4 string.
  final String id;
  final String userId;

  /// Open string namespace. First value: 'card_detail_update'.
  final String notificationType;

  /// Type-specific aggregation key. For card_detail_update: factId.
  final String subjectKey;

  /// Opaque JSON blob defined by the producer. Null allowed.
  final String? payload;

  /// Seconds since epoch.
  final int createdAt;

  /// Seconds since epoch.
  final int updatedAt;
  const UserNotification(
      {required this.id,
      required this.userId,
      required this.notificationType,
      required this.subjectKey,
      this.payload,
      required this.createdAt,
      required this.updatedAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['user_id'] = Variable<String>(userId);
    map['notification_type'] = Variable<String>(notificationType);
    map['subject_key'] = Variable<String>(subjectKey);
    if (!nullToAbsent || payload != null) {
      map['payload'] = Variable<String>(payload);
    }
    map['created_at'] = Variable<int>(createdAt);
    map['updated_at'] = Variable<int>(updatedAt);
    return map;
  }

  UserNotificationsCompanion toCompanion(bool nullToAbsent) {
    return UserNotificationsCompanion(
      id: Value(id),
      userId: Value(userId),
      notificationType: Value(notificationType),
      subjectKey: Value(subjectKey),
      payload: payload == null && nullToAbsent
          ? const Value.absent()
          : Value(payload),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
    );
  }

  factory UserNotification.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return UserNotification(
      id: serializer.fromJson<String>(json['id']),
      userId: serializer.fromJson<String>(json['userId']),
      notificationType: serializer.fromJson<String>(json['notificationType']),
      subjectKey: serializer.fromJson<String>(json['subjectKey']),
      payload: serializer.fromJson<String?>(json['payload']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
      updatedAt: serializer.fromJson<int>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'userId': serializer.toJson<String>(userId),
      'notificationType': serializer.toJson<String>(notificationType),
      'subjectKey': serializer.toJson<String>(subjectKey),
      'payload': serializer.toJson<String?>(payload),
      'createdAt': serializer.toJson<int>(createdAt),
      'updatedAt': serializer.toJson<int>(updatedAt),
    };
  }

  UserNotification copyWith(
          {String? id,
          String? userId,
          String? notificationType,
          String? subjectKey,
          Value<String?> payload = const Value.absent(),
          int? createdAt,
          int? updatedAt}) =>
      UserNotification(
        id: id ?? this.id,
        userId: userId ?? this.userId,
        notificationType: notificationType ?? this.notificationType,
        subjectKey: subjectKey ?? this.subjectKey,
        payload: payload.present ? payload.value : this.payload,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );
  UserNotification copyWithCompanion(UserNotificationsCompanion data) {
    return UserNotification(
      id: data.id.present ? data.id.value : this.id,
      userId: data.userId.present ? data.userId.value : this.userId,
      notificationType: data.notificationType.present
          ? data.notificationType.value
          : this.notificationType,
      subjectKey:
          data.subjectKey.present ? data.subjectKey.value : this.subjectKey,
      payload: data.payload.present ? data.payload.value : this.payload,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('UserNotification(')
          ..write('id: $id, ')
          ..write('userId: $userId, ')
          ..write('notificationType: $notificationType, ')
          ..write('subjectKey: $subjectKey, ')
          ..write('payload: $payload, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
      id, userId, notificationType, subjectKey, payload, createdAt, updatedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is UserNotification &&
          other.id == this.id &&
          other.userId == this.userId &&
          other.notificationType == this.notificationType &&
          other.subjectKey == this.subjectKey &&
          other.payload == this.payload &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt);
}

class UserNotificationsCompanion extends UpdateCompanion<UserNotification> {
  final Value<String> id;
  final Value<String> userId;
  final Value<String> notificationType;
  final Value<String> subjectKey;
  final Value<String?> payload;
  final Value<int> createdAt;
  final Value<int> updatedAt;
  final Value<int> rowid;
  const UserNotificationsCompanion({
    this.id = const Value.absent(),
    this.userId = const Value.absent(),
    this.notificationType = const Value.absent(),
    this.subjectKey = const Value.absent(),
    this.payload = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  UserNotificationsCompanion.insert({
    required String id,
    required String userId,
    required String notificationType,
    required String subjectKey,
    this.payload = const Value.absent(),
    required int createdAt,
    required int updatedAt,
    this.rowid = const Value.absent(),
  })  : id = Value(id),
        userId = Value(userId),
        notificationType = Value(notificationType),
        subjectKey = Value(subjectKey),
        createdAt = Value(createdAt),
        updatedAt = Value(updatedAt);
  static Insertable<UserNotification> custom({
    Expression<String>? id,
    Expression<String>? userId,
    Expression<String>? notificationType,
    Expression<String>? subjectKey,
    Expression<String>? payload,
    Expression<int>? createdAt,
    Expression<int>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (userId != null) 'user_id': userId,
      if (notificationType != null) 'notification_type': notificationType,
      if (subjectKey != null) 'subject_key': subjectKey,
      if (payload != null) 'payload': payload,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  UserNotificationsCompanion copyWith(
      {Value<String>? id,
      Value<String>? userId,
      Value<String>? notificationType,
      Value<String>? subjectKey,
      Value<String?>? payload,
      Value<int>? createdAt,
      Value<int>? updatedAt,
      Value<int>? rowid}) {
    return UserNotificationsCompanion(
      id: id ?? this.id,
      userId: userId ?? this.userId,
      notificationType: notificationType ?? this.notificationType,
      subjectKey: subjectKey ?? this.subjectKey,
      payload: payload ?? this.payload,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (userId.present) {
      map['user_id'] = Variable<String>(userId.value);
    }
    if (notificationType.present) {
      map['notification_type'] = Variable<String>(notificationType.value);
    }
    if (subjectKey.present) {
      map['subject_key'] = Variable<String>(subjectKey.value);
    }
    if (payload.present) {
      map['payload'] = Variable<String>(payload.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<int>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('UserNotificationsCompanion(')
          ..write('id: $id, ')
          ..write('userId: $userId, ')
          ..write('notificationType: $notificationType, ')
          ..write('subjectKey: $subjectKey, ')
          ..write('payload: $payload, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$TestNotificationsDb extends GeneratedDatabase {
  _$TestNotificationsDb(QueryExecutor e) : super(e);
  $TestNotificationsDbManager get managers => $TestNotificationsDbManager(this);
  late final $UserNotificationsTable userNotifications =
      $UserNotificationsTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [userNotifications];
}

typedef $$UserNotificationsTableCreateCompanionBuilder
    = UserNotificationsCompanion Function({
  required String id,
  required String userId,
  required String notificationType,
  required String subjectKey,
  Value<String?> payload,
  required int createdAt,
  required int updatedAt,
  Value<int> rowid,
});
typedef $$UserNotificationsTableUpdateCompanionBuilder
    = UserNotificationsCompanion Function({
  Value<String> id,
  Value<String> userId,
  Value<String> notificationType,
  Value<String> subjectKey,
  Value<String?> payload,
  Value<int> createdAt,
  Value<int> updatedAt,
  Value<int> rowid,
});

class $$UserNotificationsTableFilterComposer
    extends Composer<_$TestNotificationsDb, $UserNotificationsTable> {
  $$UserNotificationsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get userId => $composableBuilder(
      column: $table.userId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get notificationType => $composableBuilder(
      column: $table.notificationType,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get subjectKey => $composableBuilder(
      column: $table.subjectKey, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get payload => $composableBuilder(
      column: $table.payload, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnFilters(column));
}

class $$UserNotificationsTableOrderingComposer
    extends Composer<_$TestNotificationsDb, $UserNotificationsTable> {
  $$UserNotificationsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get userId => $composableBuilder(
      column: $table.userId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get notificationType => $composableBuilder(
      column: $table.notificationType,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get subjectKey => $composableBuilder(
      column: $table.subjectKey, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get payload => $composableBuilder(
      column: $table.payload, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnOrderings(column));
}

class $$UserNotificationsTableAnnotationComposer
    extends Composer<_$TestNotificationsDb, $UserNotificationsTable> {
  $$UserNotificationsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get userId =>
      $composableBuilder(column: $table.userId, builder: (column) => column);

  GeneratedColumn<String> get notificationType => $composableBuilder(
      column: $table.notificationType, builder: (column) => column);

  GeneratedColumn<String> get subjectKey => $composableBuilder(
      column: $table.subjectKey, builder: (column) => column);

  GeneratedColumn<String> get payload =>
      $composableBuilder(column: $table.payload, builder: (column) => column);

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<int> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $$UserNotificationsTableTableManager extends RootTableManager<
    _$TestNotificationsDb,
    $UserNotificationsTable,
    UserNotification,
    $$UserNotificationsTableFilterComposer,
    $$UserNotificationsTableOrderingComposer,
    $$UserNotificationsTableAnnotationComposer,
    $$UserNotificationsTableCreateCompanionBuilder,
    $$UserNotificationsTableUpdateCompanionBuilder,
    (
      UserNotification,
      BaseReferences<_$TestNotificationsDb, $UserNotificationsTable,
          UserNotification>
    ),
    UserNotification,
    PrefetchHooks Function()> {
  $$UserNotificationsTableTableManager(
      _$TestNotificationsDb db, $UserNotificationsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$UserNotificationsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$UserNotificationsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$UserNotificationsTableAnnotationComposer(
                  $db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> id = const Value.absent(),
            Value<String> userId = const Value.absent(),
            Value<String> notificationType = const Value.absent(),
            Value<String> subjectKey = const Value.absent(),
            Value<String?> payload = const Value.absent(),
            Value<int> createdAt = const Value.absent(),
            Value<int> updatedAt = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              UserNotificationsCompanion(
            id: id,
            userId: userId,
            notificationType: notificationType,
            subjectKey: subjectKey,
            payload: payload,
            createdAt: createdAt,
            updatedAt: updatedAt,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String id,
            required String userId,
            required String notificationType,
            required String subjectKey,
            Value<String?> payload = const Value.absent(),
            required int createdAt,
            required int updatedAt,
            Value<int> rowid = const Value.absent(),
          }) =>
              UserNotificationsCompanion.insert(
            id: id,
            userId: userId,
            notificationType: notificationType,
            subjectKey: subjectKey,
            payload: payload,
            createdAt: createdAt,
            updatedAt: updatedAt,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$UserNotificationsTableProcessedTableManager = ProcessedTableManager<
    _$TestNotificationsDb,
    $UserNotificationsTable,
    UserNotification,
    $$UserNotificationsTableFilterComposer,
    $$UserNotificationsTableOrderingComposer,
    $$UserNotificationsTableAnnotationComposer,
    $$UserNotificationsTableCreateCompanionBuilder,
    $$UserNotificationsTableUpdateCompanionBuilder,
    (
      UserNotification,
      BaseReferences<_$TestNotificationsDb, $UserNotificationsTable,
          UserNotification>
    ),
    UserNotification,
    PrefetchHooks Function()>;

class $TestNotificationsDbManager {
  final _$TestNotificationsDb _db;
  $TestNotificationsDbManager(this._db);
  $$UserNotificationsTableTableManager get userNotifications =>
      $$UserNotificationsTableTableManager(_db, _db.userNotifications);
}
