import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:health/health.dart';
import 'package:memex/data/services/health_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('iOS registers rich HealthKit metrics, not just steps', () {
    // The registry is platform-branched; this assertion is meaningful on the
    // non-Android (iOS) branch that the test host resolves to.
    if (Platform.isAndroid) return;

    final types = HealthService().registeredTypes;
    expect(
      types,
      containsAll(<HealthDataType>[
        HealthDataType.STEPS,
        HealthDataType.HEART_RATE,
        HealthDataType.RESTING_HEART_RATE,
        HealthDataType.BLOOD_OXYGEN,
        HealthDataType.BLOOD_PRESSURE_SYSTOLIC,
        HealthDataType.BLOOD_PRESSURE_DIASTOLIC,
        HealthDataType.BLOOD_GLUCOSE,
        HealthDataType.SLEEP_ASLEEP,
        HealthDataType.ACTIVE_ENERGY_BURNED,
        HealthDataType.WEIGHT,
        HealthDataType.WORKOUT,
      ]),
    );
  });
}
