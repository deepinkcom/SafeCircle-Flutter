import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:safecircle/models/models.dart';
import 'package:safecircle/screens/alert_history_screen.dart';
import 'package:safecircle/state/app_state.dart';

import 'support/contact_links_fakes.dart';
import 'support/notifications_fakes.dart';

void main() {
  for (final status in [AlertStatus.active, AlertStatus.resolved]) {
    testWidgets('tapping a $status history entry opens backend history details',
        (tester) async {
      final app = AppState(
        apiService: NotificationsFakeApi(),
        authService: ContactLinksFakeAuth(),
      )..alertHistory.add(AlertEvent(
          id: 19,
          kind: AlertKind.emergencySent,
          title: 'Emergency sent',
          timeLabel: '16 Nov 2026, 10:00',
          locationLabel: 'Recorded area',
          status: status,
        ));
      addTearDown(app.dispose);
      await tester.pumpWidget(ChangeNotifierProvider.value(
        value: app,
        child: MaterialApp(
          home: AlertHistoryScreen(
            onOpenNotifications: () {},
            onOpenActiveAlert: (_) async {},
          ),
        ),
      ));
      await tester.tap(find.text('Emergency sent'));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDetailsScreen), findsOneWidget);
      expect(find.textContaining('Recorded: 16 Nov'), findsOneWidget);
      expect(find.text('Status: ${status == AlertStatus.active ? 'Active' : 'Emergency ended'}'), findsOneWidget);
    });
  }

  testWidgets('active owned alert details can return to active alert',
      (tester) async {
    var opened = 0;
    await tester.pumpWidget(MaterialApp(
      home: AlertDetailsScreen(
        event: const AlertEvent(
          id: 5,
          kind: AlertKind.emergencySent,
          title: 'Emergency sent',
          timeLabel: '16 Nov 2026, 10:00',
          locationLabel: 'City centre',
          status: AlertStatus.active,
        ),
        onOpenActiveAlert: () async {
          opened++;
        },
      ),
    ));
    expect(find.text('Status: Active'), findsOneWidget);
    expect(find.textContaining('Recorded: 16 Nov'), findsOneWidget);
    await tester.tap(find.text('Return to active alert'));
    expect(opened, 1);
  });

  testWidgets(
      'resolved alert is historical and has no live or acknowledgement action',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: AlertDetailsScreen(
        event: AlertEvent(
          id: 6,
          kind: AlertKind.emergencySent,
          title: 'Emergency sent',
          timeLabel: '15 Nov 2026, 10:00',
          locationLabel: 'Older recorded area',
          status: AlertStatus.resolved,
        ),
      ),
    ));
    expect(find.text('Status: Emergency ended'), findsOneWidget);
    expect(find.textContaining('historical'), findsOneWidget);
    expect(find.text('Return to active alert'), findsNothing);
    expect(find.textContaining('live'), findsNothing);
  });
}
