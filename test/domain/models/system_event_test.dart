import 'package:flutter_test/flutter_test.dart';
import 'package:memex/domain/models/system_event.dart';

void main() {
  group('DataChangeRecord', () {
    test('insert op: before is null, after is populated', () {
      final afterSnapshot = {'title': 'Hello', 'comments': [], 'insight': {}};
      final record = DataChangeRecord(
        op: DataChangeOp.insert,
        ns: DataChangeNs.card,
        documentKey: '2025/01/15.md#ts_1',
        before: null,
        after: afterSnapshot,
      );

      expect(record.op, DataChangeOp.insert);
      expect(record.ns, DataChangeNs.card);
      expect(record.documentKey, '2025/01/15.md#ts_1');
      expect(record.before, isNull);
      expect(record.after, afterSnapshot);
      expect(record.after!['title'], 'Hello');
    });

    test('update op: both before and after are populated', () {
      final beforeSnapshot = {
        'title': 'Old Title',
        'comments': [
          {'id': 'c1', 'content': 'first comment'}
        ],
        'insight': {'text': 'old insight'},
      };
      final afterSnapshot = {
        'title': 'Old Title',
        'comments': [
          {'id': 'c1', 'content': 'first comment'},
          {'id': 'c2', 'content': 'new comment'},
        ],
        'insight': {'text': 'updated insight'},
      };
      final record = DataChangeRecord(
        op: DataChangeOp.update,
        ns: DataChangeNs.card,
        documentKey: '2025/01/15.md#ts_1',
        before: beforeSnapshot,
        after: afterSnapshot,
      );

      expect(record.op, DataChangeOp.update);
      expect(record.before, beforeSnapshot);
      expect(record.after, afterSnapshot);
      expect(record.before!['comments'], hasLength(1));
      expect(record.after!['comments'], hasLength(2));
    });

    test('delete op: before is populated, after is null', () {
      final beforeSnapshot = {
        'title': 'Deleted Card',
        'comments': [],
        'insight': {'text': 'some insight'},
      };
      final record = DataChangeRecord(
        op: DataChangeOp.delete,
        ns: DataChangeNs.card,
        documentKey: '2025/01/15.md#ts_1',
        before: beforeSnapshot,
        after: null,
      );

      expect(record.op, DataChangeOp.delete);
      expect(record.before, beforeSnapshot);
      expect(record.after, isNull);
      expect(record.before!['title'], 'Deleted Card');
    });

    test('legacy delete shape: both before and after are null', () {
      // PKM delete publishers emit events with neither snapshot.
      // The model must allow this shape without throwing.
      final record = DataChangeRecord(
        op: DataChangeOp.delete,
        ns: DataChangeNs.pkmFile,
        documentKey: 'some/path.md',
        before: null,
        after: null,
      );

      expect(record.op, DataChangeOp.delete);
      expect(record.ns, DataChangeNs.pkmFile);
      expect(record.documentKey, 'some/path.md');
      expect(record.before, isNull);
      expect(record.after, isNull);
    });
  });
}
