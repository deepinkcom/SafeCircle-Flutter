
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safecircle/screens/activate_panic_screen.dart';

void main() {
  testWidgets(
    'shows an error and allows retry when alert submission fails',
    (WidgetTester tester) async {
      var attempts = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: ActivatePanicScreen(
            onBack: () {},
            onAlertSent: () async {
              attempts++;
              throw Exception('Simulated test failure');
            },
          ),
        ),
      );

      await tester.ensureVisible(find.text('Send Alert Now'));
      await tester.tap(find.text('Send Alert Now'));
      await tester.pump();
      await tester.pumpAndSettle();

      expect(attempts, 1);
      expect(
        find.text(
          'Could not send the alert. Check your location permissions and connection, then try again.',
        ),
        findsOneWidget,
      );

      await tester.ensureVisible(find.text('Send Alert Now'));
      await tester.tap(find.text('Send Alert Now'));
      await tester.pump();
      await tester.pumpAndSettle();

      expect(attempts, 2);
      expect(
        find.text(
          'Could not send the alert. Check your location permissions and connection, then try again.',
        ),
        findsOneWidget,
      );
    },
  );
}
