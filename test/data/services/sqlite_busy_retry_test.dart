import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:memex/data/services/sqlite_busy_retry.dart';

void main() {
  group('SqliteBusyRetry', () {
    final logger = Logger('SqliteBusyRetryTest');

    test('recognizes common SQLite busy error variants', () {
      expect(
        SqliteBusyRetry.isDatabaseLocked(
          Exception('SqliteException(5): database is locked (code 5)'),
        ),
        isTrue,
      );
      expect(
        SqliteBusyRetry.isDatabaseLocked(Exception('database_busy')),
        isTrue,
      );
      expect(
        SqliteBusyRetry.isDatabaseLocked(Exception('SQLITE_ERROR: bad sql')),
        isFalse,
      );
    });

    test(
      'retries database locks with linear backoff and returns success',
      () async {
        var attempts = 0;

        final result = await SqliteBusyRetry.run<int>(
          operation: 'test retry',
          logger: logger,
          retryDelay: Duration.zero,
          action: () async {
            attempts++;
            if (attempts < 3) {
              throw Exception('database is locked');
            }
            return 42;
          },
        );

        expect(result, 42);
        expect(attempts, 3);
      },
    );

    test('does not retry non-lock failures', () async {
      var attempts = 0;

      await expectLater(
        SqliteBusyRetry.run<void>(
          operation: 'test non-lock',
          logger: logger,
          retryDelay: Duration.zero,
          action: () async {
            attempts++;
            throw StateError('bad state');
          },
        ),
        throwsA(isA<StateError>()),
      );
      expect(attempts, 1);
    });

    test('rethrows the final database lock failure', () async {
      var attempts = 0;

      await expectLater(
        SqliteBusyRetry.run<void>(
          operation: 'test exhausted lock',
          logger: logger,
          maxAttempts: 2,
          retryDelay: Duration.zero,
          action: () async {
            attempts++;
            throw Exception('database is locked');
          },
        ),
        throwsA(isA<Exception>()),
      );
      expect(attempts, 2);
    });
  });
}
