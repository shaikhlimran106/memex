import 'package:memex/agent/skills/schedule_aggregation/schedule_aggregation_skill.dart';
import 'package:test/test.dart';

void main() {
  group('ScheduleAggregationSkill tool schemas', () {
    test('declare items for every array parameter', () {
      final tools = [
        buildAddPendingItemTool(),
        buildUpdatePendingItemTool(),
        buildSetPresentationTool(),
      ];

      for (final tool in tools) {
        final missing = <String>[];
        _collectArraySchemasMissingItems(
          tool.parameters,
          tool.name,
          missing,
        );

        expect(missing, isEmpty, reason: missing.join('\n'));
      }
    });

    test('uses object item schemas for schedule aggregation payloads', () {
      final addPendingProperties = _properties(buildAddPendingItemTool());
      final updatePendingProperties = _properties(buildUpdatePendingItemTool());
      final presentationProperties = _properties(buildSetPresentationTool());

      expect(
        addPendingProperties['subtasks'],
        containsPair('items', containsPair('type', 'object')),
      );
      expect(
        updatePendingProperties['subtasks'],
        containsPair('items', containsPair('type', 'object')),
      );
      expect(
        presentationProperties['quote_blocks'],
        containsPair('items', containsPair('type', 'object')),
      );
      expect(
        presentationProperties['timeline'],
        containsPair('items', containsPair('type', 'object')),
      );
    });
  });
}

Map<String, dynamic> _properties(dynamic tool) {
  final parameters = Map<String, dynamic>.from(tool.parameters as Map);
  return Map<String, dynamic>.from(parameters['properties'] as Map);
}

void _collectArraySchemasMissingItems(
  dynamic schema,
  String path,
  List<String> missing,
) {
  if (schema is Map) {
    final typed = Map<String, dynamic>.from(schema);
    if (typed['type'] == 'array' && !typed.containsKey('items')) {
      missing.add('$path is an array schema without items');
    }
    typed.forEach((key, value) {
      _collectArraySchemasMissingItems(value, '$path.$key', missing);
    });
  } else if (schema is List) {
    for (final entry in schema.indexed) {
      _collectArraySchemasMissingItems(
        entry.$2,
        '$path[${entry.$1}]',
        missing,
      );
    }
  }
}
