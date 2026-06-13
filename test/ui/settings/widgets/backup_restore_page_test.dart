import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memex/data/services/backup_service.dart';
import 'package:memex/data/services/event_bus_service.dart';
import 'package:memex/l10n/app_localizations.dart';
import 'package:memex/ui/settings/widgets/backup_restore_page.dart';
import 'package:memex/utils/user_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({'language': 'en'});
    await UserStorage.initL10n();
    await UserStorage.saveUser('backup-test-user');
    EventBusService.instance.clearHandlers();
    await EventBusService.instance.connect();
  });

  testWidgets('renders automatic backup settings and persists toggle', (
    tester,
  ) async {
    await _pumpBackupPage(tester);

    expect(find.text(UserStorage.l10n.automaticBackup), findsOneWidget);
    expect(find.text(UserStorage.l10n.createSnapshotNow), findsOneWidget);
    expect(await UserStorage.isAutoBackupEnabled('backup-test-user'), isFalse);

    await tester.tap(find.byType(Switch));
    await tester.pump();

    expect(await UserStorage.isAutoBackupEnabled('backup-test-user'), isTrue);
  });

  testWidgets('shows estimated backup size and persists retention policy', (
    tester,
  ) async {
    var pruneCalls = 0;

    await _pumpBackupPage(
      tester,
      estimateBackupSize: () async => 5 * 1024 * 1024,
      pruneAutoBackups: () async {
        pruneCalls += 1;
      },
    );

    expect(find.text(UserStorage.l10n.estimatedSize), findsOneWidget);
    expect(find.text('5.0 MB'), findsWidgets);
    expect(
      find.text(UserStorage.l10n.autoBackupRetentionDays(30)),
      findsOneWidget,
    );
    expect(find.text(UserStorage.l10n.autoBackupMaxSize), findsOneWidget);
    expect(find.text('2.0 GB'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('auto-backup-retention-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(UserStorage.l10n.autoBackupRetentionDays(14)));
    await tester.pumpAndSettle();

    expect(
      await UserStorage.getAutoBackupRetentionDays('backup-test-user'),
      14,
    );
    expect(pruneCalls, 1);
    expect(
      find.text(UserStorage.l10n.autoBackupRetentionDays(14)),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('auto-backup-retention-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(UserStorage.l10n.autoBackupRetentionForever));
    await tester.pumpAndSettle();

    expect(
      await UserStorage.getAutoBackupRetentionDays('backup-test-user'),
      isNull,
    );
    expect(pruneCalls, 2);
    expect(
      find.text(UserStorage.l10n.autoBackupRetentionForever),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('auto-backup-max-size-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1.0 GB'));
    await tester.pumpAndSettle();

    expect(
      await UserStorage.getAutoBackupMaxBytes('backup-test-user'),
      1024 * 1024 * 1024,
    );
    expect(pruneCalls, 3);
    expect(find.text('1.0 GB'), findsOneWidget);
  });

  testWidgets(
    'shows stored automatic and safety snapshots with restore confirmation',
    (tester) async {
      const autoName = 'memex_auto_2026-05-15T10-00-00.memex';
      const safetyName =
          'memex_safety_before_restore_2026-05-15T10-05-00.memex';
      const manualName = 'memex_backup_2026-05-15T09-00-00.memex';
      final autoSnapshot = BackupSnapshot(
        id: 'auto',
        name: autoName,
        createdAt: DateTime(2026, 5, 15, 10),
        sizeBytes: 3,
        filePath: '/tmp/$autoName',
      );
      final safetySnapshot = BackupSnapshot(
        id: 'safety',
        name: safetyName,
        createdAt: DateTime(2026, 5, 15, 10, 5),
        sizeBytes: 3,
        filePath: '/tmp/$safetyName',
      );
      final manualSnapshot = BackupSnapshot(
        id: 'manual',
        name: manualName,
        createdAt: DateTime(2026, 5, 15, 9),
        sizeBytes: 4,
        filePath: '/tmp/$manualName',
      );

      await _pumpBackupPage(
        tester,
        listStoredBackups: () async =>
            [safetySnapshot, autoSnapshot, manualSnapshot],
      );
      await _scrollUntilVisible(tester, find.text(autoName));
      await _scrollUntilVisible(tester, find.text(manualName));

      expect(find.text(autoName), findsOneWidget);
      expect(find.text(safetyName), findsOneWidget);
      expect(find.text(manualName), findsOneWidget);
      expect(find.textContaining(UserStorage.l10n.backupTypeAutoSnapshot),
          findsOneWidget);
      expect(find.textContaining(UserStorage.l10n.backupTypeSafetySnapshot),
          findsOneWidget);
      expect(find.textContaining(UserStorage.l10n.backupTypeManualBackup),
          findsOneWidget);
      expect(find.textContaining('3 B'), findsWidgets);
      expect(find.byTooltip(UserStorage.l10n.restoreThisBackup), findsWidgets);

      await tester.ensureVisible(find.text(autoName));
      await tester.pump();
      await tester.tap(
        find.byTooltip(UserStorage.l10n.restoreThisBackup).first,
      );
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text(UserStorage.l10n.confirmRestore), findsOneWidget);
      expect(find.text(UserStorage.l10n.confirmRestoreMessage), findsOneWidget);
    },
  );

  testWidgets('deletes one backup from a mixed history after confirmation', (
    tester,
  ) async {
    const oldAutoName = 'memex_auto_2026-05-14T10-00-00.memex';
    const latestAutoName = 'memex_auto_2026-05-15T10-00-00.memex';
    const safetyName = 'memex_safety_before_restore_2026-05-15T10-05-00.memex';
    final oldAutoSnapshot = BackupSnapshot(
      id: 'old-auto',
      name: oldAutoName,
      createdAt: DateTime(2026, 5, 14, 10),
      sizeBytes: 3,
      filePath: '/tmp/$oldAutoName',
    );
    final latestAutoSnapshot = BackupSnapshot(
      id: 'android-latest-auto',
      name: latestAutoName,
      createdAt: DateTime(2026, 5, 15, 10),
      sizeBytes: 5 * 1024 * 1024,
      documentUri: 'content://backups/latest',
    );
    final safetySnapshot = BackupSnapshot(
      id: 'local-safety',
      name: safetyName,
      createdAt: DateTime(2026, 5, 15, 10, 5),
      sizeBytes: 8,
      filePath: '/tmp/$safetyName',
    );
    final snapshots = <BackupSnapshot>[
      safetySnapshot,
      latestAutoSnapshot,
      oldAutoSnapshot,
    ];
    final deletedIds = <String>[];

    await _pumpBackupPage(
      tester,
      listStoredBackups: () async => List<BackupSnapshot>.of(snapshots),
      deleteStoredBackup: (snapshot) async {
        deletedIds.add(snapshot.id);
        await Future<void>.delayed(const Duration(milliseconds: 10));
        snapshots.removeWhere((item) => item.id == snapshot.id);
      },
    );

    await _scrollUntilVisible(tester, find.text(oldAutoName));
    await tester.tap(find.byKey(const ValueKey('backup-delete-old-auto')));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text(UserStorage.l10n.confirmDeleteBackup), findsOneWidget);
    expect(
      find.text(UserStorage.l10n.confirmDeleteBackupMessage(oldAutoName)),
      findsOneWidget,
    );

    await tester.tap(find.text(UserStorage.l10n.cancel));
    await tester.pump(const Duration(milliseconds: 300));

    expect(deletedIds, isEmpty);
    expect(find.text(oldAutoName), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('backup-delete-old-auto')));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text(UserStorage.l10n.delete));
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await tester.pumpAndSettle();

    expect(deletedIds, ['old-auto']);
    expect(find.text(oldAutoName), findsNothing);
    expect(find.text(latestAutoName), findsOneWidget);
    expect(find.text(safetyName), findsOneWidget);

    await _scrollUntilVisible(
      tester,
      find.text(UserStorage.l10n.backupDeleted(oldAutoName)),
    );
    expect(
      find.text(UserStorage.l10n.backupDeleted(oldAutoName)),
      findsOneWidget,
    );
  });

  testWidgets('manual snapshot button refreshes list and status', (
    tester,
  ) async {
    final snapshots = <BackupSnapshot>[];
    final snapshot = BackupSnapshot(
      id: 'manual',
      name: 'memex_auto_2026-05-15T11-00-00.memex',
      createdAt: DateTime(2026, 5, 15, 11),
      sizeBytes: 8,
      filePath: '/tmp/memex_auto_2026-05-15T11-00-00.memex',
    );

    await _pumpBackupPage(
      tester,
      listStoredBackups: () async => List<BackupSnapshot>.of(snapshots),
      createAutoBackup: ({
        String trigger = 'automatic',
        bool force = false,
        void Function(String status)? onProgress,
      }) async {
        expect(trigger, 'manual');
        expect(force, isTrue);
        onProgress?.call('Compressing...');
        snapshots.add(snapshot);
        return snapshot;
      },
    );

    await tester.tap(find.text(UserStorage.l10n.createSnapshotNow));
    await _scrollUntilVisible(tester, find.text(snapshot.name));

    expect(find.text(snapshot.name), findsOneWidget);
    await _scrollUntilVisible(
      tester,
      find.text(UserStorage.l10n.autoBackupCreated(snapshot.name)),
    );
    expect(
      find.text(UserStorage.l10n.autoBackupCreated(snapshot.name)),
      findsOneWidget,
    );
  });

  testWidgets('manual snapshot refresh does not rescan estimated source size', (
    tester,
  ) async {
    var estimateCalls = 0;
    final snapshot = BackupSnapshot(
      id: 'manual',
      name: 'memex_auto_2026-05-15T11-30-00.memex',
      createdAt: DateTime(2026, 5, 15, 11, 30),
      sizeBytes: 8,
      filePath: '/tmp/memex_auto_2026-05-15T11-30-00.memex',
    );
    final snapshots = <BackupSnapshot>[];

    await _pumpBackupPage(
      tester,
      estimateBackupSize: () async {
        estimateCalls += 1;
        return 42;
      },
      listStoredBackups: () async => List<BackupSnapshot>.of(snapshots),
      createAutoBackup: ({
        String trigger = 'automatic',
        bool force = false,
        void Function(String status)? onProgress,
      }) async {
        snapshots.add(snapshot);
        return snapshot;
      },
    );

    expect(estimateCalls, 1);

    await tester.tap(find.text(UserStorage.l10n.createSnapshotNow));
    await _scrollUntilVisible(tester, find.text(snapshot.name));

    expect(estimateCalls, 1);
  });

  testWidgets('refreshes stored backup list when backup event is emitted', (
    tester,
  ) async {
    final snapshots = <BackupSnapshot>[];
    final snapshot = BackupSnapshot(
      id: 'background-auto',
      name: 'memex_auto_2026-05-15T12-00-00.memex',
      createdAt: DateTime(2026, 5, 15, 12),
      sizeBytes: 12,
      filePath: '/tmp/memex_auto_2026-05-15T12-00-00.memex',
    );

    await _pumpBackupPage(
      tester,
      listStoredBackups: () async => List<BackupSnapshot>.of(snapshots),
    );

    expect(find.text(snapshot.name), findsNothing);

    snapshots.add(snapshot);
    EventBusService.instance.emitEvent(
      BackupSnapshotsChangedMessage(reason: 'created', snapshotId: snapshot.id),
    );

    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();

    await _scrollUntilVisible(tester, find.text(snapshot.name));
    expect(find.text(snapshot.name), findsOneWidget);
  });

  testWidgets('shows Android backup location picker menu', (tester) async {
    await _pumpBackupPage(tester, isAndroid: true);

    final locationButton = find.widgetWithText(
      OutlinedButton,
      UserStorage.l10n.backupLocationMenu,
    );
    expect(locationButton, findsOneWidget);

    await tester.tap(locationButton);
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text(UserStorage.l10n.defaultBackupLocation), findsOneWidget);
    expect(find.text(UserStorage.l10n.chooseBackupLocation), findsOneWidget);
  });

  testWidgets('opens copyable full backup location details', (tester) async {
    const fullPath =
        '/very/long/device/path/that/does/not/fit/in/two/lines/Memex/Backups';

    await _pumpBackupPage(
      tester,
      currentBackupLocationInfo: () async => const BackupLocationInfo(
        kind: BackupLocationKind.fileSystem,
        label: fullPath,
        detail: fullPath,
      ),
    );

    await tester.tap(find.byKey(const ValueKey('backup-location-row')));
    await tester.pumpAndSettle();

    expect(find.text(UserStorage.l10n.backupLocationDetails), findsOneWidget);
    expect(find.text(UserStorage.l10n.backupLocationFullPath), findsOneWidget);
    final detail = tester.widget<SelectableText>(
      find.byKey(const ValueKey('backup-location-detail-value')),
    );
    expect(detail.data, fullPath);
    expect(find.text(UserStorage.l10n.copyBackupLocationPath), findsOneWidget);
  });

  testWidgets('shows iOS Files label with full sandbox path in details', (
    tester,
  ) async {
    const fullPath =
        '/private/var/mobile/Library/Mobile Documents/iCloud~com~memexlab~memex/Documents/Backups';

    await _pumpBackupPage(
      tester,
      currentBackupLocationInfo: () async => const BackupLocationInfo(
        kind: BackupLocationKind.iosICloud,
        label: fullPath,
        detail: fullPath,
      ),
    );

    expect(find.text(UserStorage.l10n.iosICloudBackupLocation), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('backup-location-row')));
    await tester.pumpAndSettle();

    final detail = tester.widget<SelectableText>(
      find.byKey(const ValueKey('backup-location-detail-value')),
    );
    expect(detail.data, fullPath);
  });

  testWidgets('shows Android SAF folder name and URI details', (tester) async {
    const treeUri = 'content://com.android.externalstorage.documents/tree/'
        'primary%3ADownload%2FMemexBackups';

    await _pumpBackupPage(
      tester,
      isAndroid: true,
      currentBackupLocationInfo: () async => const BackupLocationInfo(
        kind: BackupLocationKind.androidTree,
        label: 'MemexBackups',
        detail: treeUri,
      ),
    );

    expect(
      find.text(UserStorage.l10n.androidBackupLocationSelected('MemexBackups')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('backup-location-row')));
    await tester.pumpAndSettle();

    expect(find.text(UserStorage.l10n.backupLocationUri), findsOneWidget);
    expect(find.text(UserStorage.l10n.backupLocationMenu), findsWidgets);
    final detail = tester.widget<SelectableText>(
      find.byKey(const ValueKey('backup-location-detail-value')),
    );
    expect(detail.data, treeUri);
  });
}

Future<void> _pumpBackupPage(
  WidgetTester tester, {
  bool isAndroid = false,
  Future<int> Function()? estimateBackupSize,
  Future<BackupLocationInfo> Function()? currentBackupLocationInfo,
  Future<List<BackupSnapshot>> Function()? listStoredBackups,
  AutoBackupCreator? createAutoBackup,
  StoredBackupDeleter? deleteStoredBackup,
  Future<void> Function()? pruneAutoBackups,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: BackupRestorePage(
        isAndroidOverride: isAndroid,
        estimateBackupSize: estimateBackupSize ?? () async => 0,
        currentBackupLocationInfo: currentBackupLocationInfo,
        currentBackupLocationLabel: () async => '/tmp/Backups',
        listStoredBackups: listStoredBackups ?? () async => const [],
        createAutoBackup: createAutoBackup,
        deleteStoredBackup: deleteStoredBackup,
        pruneAutoBackups: pruneAutoBackups,
      ),
    ),
  );
  await tester.pump();
  await tester.runAsync(() async {
    await Future<void>.delayed(const Duration(milliseconds: 50));
  });
  await tester.pump();
}

Future<void> _scrollUntilVisible(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(
    finder,
    250,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pump(const Duration(milliseconds: 100));
}
