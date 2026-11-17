import 'package:flutter_test/flutter_test.dart';
import 'package:safecircle/services/emergency_call_service.dart';

void main() {
  test('opens the South African emergency number in the dialler', () async {
    Uri? requested;
    final service = EmergencyCallService(launch: (uri) async {
      requested = uri;
      return true;
    });

    expect(await service.openDialler(), isTrue);
    expect(requested?.scheme, 'tel');
    expect(requested?.path, '112');
  });

  test('reports a device that cannot open the dialler', () async {
    final service = EmergencyCallService(launch: (_) async => false);
    expect(await service.openDialler(), isFalse);
  });
}
