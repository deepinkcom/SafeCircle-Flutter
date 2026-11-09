import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:safecircle/models/backend_profile_status.dart';
import 'package:safecircle/screens/profile_screen.dart';
import 'package:safecircle/services/api_failure.dart';
import 'package:safecircle/state/app_state.dart';
import 'package:safecircle/widgets/backend_profile_banner.dart';
import 'notifications_ui_test.dart' as ui;
import 'support/notifications_fakes.dart';
import 'support/contact_links_fakes.dart';
import 'support/contact_links_widget_harness.dart' show tapText;

const missing = BackendProfileStatus(
    id: null, profileReady: false, missingFields: ['city']);
const ready =
    BackendProfileStatus(id: 42, profileReady: true, missingFields: []);
void main() {
  testWidgets('identity conflict is explained without invitation wording',
      (tester) async {
    final api = NotificationsFakeApi()
      ..onProfileStatus =
          () async => throw const ApiFailure(ApiFailureKind.conflict);
    await ui.boot(tester, api);
    expect(find.textContaining('Contact support; no accounts were relinked.'),
        findsWidgets);
  });
  testWidgets(
      'restored missing profile is guided from Home to Personal Details',
      (tester) async {
    final api = NotificationsFakeApi()..onProfileStatus = () async => missing;
    await ui.boot(tester, api);
    expect(
        find.textContaining('Complete Personal Details, including your city'),
        findsWidgets);
    await tapText(tester, 'Complete Personal Details');
    expect(find.byType(ProfileScreen), findsOneWidget);
    await tapText(tester, 'Personal Details');
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('City'), findsOneWidget);
    await tester.enterText(find.byType(TextField).at(2), 'New City');
    api.onProfileStatus = () async => ready;
    await tapText(tester, 'Save');
    expect(api.profileSyncs, 1);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('SafeCircle account #42'), findsOneWidget);
  });
  testWidgets(
      'readiness network error has safe retry without another registration',
      (tester) async {
    final api = NotificationsFakeApi()
      ..onProfileStatus =
          () async => throw const ApiFailure(ApiFailureKind.network);
    final app = await ui.boot(tester, api);
    expect(find.textContaining('Account check failed.'), findsWidgets);
    api.onProfileStatus = () async => ready;
    await tapText(tester, 'Retry account check');
    expect(app.backendProfile!.id, 42);
    expect(api.profileSyncs, 0);
    expect(find.textContaining('Account check failed.'), findsNothing);
  });
  testWidgets('expired account check offers existing sign-in recovery',
      (tester) async {
    final api = NotificationsFakeApi()
      ..onProfileStatus =
          () async => throw const ApiFailure(ApiFailureKind.authentication);
    await ui.boot(tester, api);
    expect(find.text('Sign in again'), findsWidgets);
  });
  testWidgets(
      'Personal Details hides previous account identity after switching',
      (tester) async {
    final api = NotificationsFakeApi();
    final app = await ui.boot(tester, api);
    await tapText(tester, 'Profile');
    await tapText(tester, 'Personal Details');
    expect(find.text('alice@example.invalid'), findsWidgets);
    app.userProfile = testProfile('bob');
    app.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.text('Account changed'), findsOneWidget);
    expect(find.text('alice@example.invalid'), findsNothing);
  });
  testWidgets('missing city gives actionable validation without backend writes',
      (tester) async {
    final api = NotificationsFakeApi();
    await ui.boot(tester, api);
    await tapText(tester, 'Profile');
    await tapText(tester, 'Personal Details');
    await tester.enterText(find.byType(TextField).at(2), '');
    await tapText(tester, 'Save');
    expect(
        find.textContaining('Enter your name, phone and city'), findsOneWidget);
    expect(api.profileSyncs, 0);
  });
  testWidgets('banner stays usable on narrow layout with large text',
      (tester) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final app = AppState(
        apiService: NotificationsFakeApi()
          ..onProfileStatus = () async => missing,
        authService: ContactLinksFakeAuth())
      ..userProfile = testProfile('alice');
    addTearDown(app.dispose);
    await app.checkBackendProfile();
    await tester.pumpWidget(ChangeNotifierProvider.value(
        value: app,
        child: MaterialApp(
            builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: const TextScaler.linear(1.6)),
                child: child!),
            home: Scaffold(
                body: BackendProfileBanner(
                    onCompleteProfile: () {}, onSignIn: () {})))));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Complete Personal Details'), findsOneWidget);
  });
}
