import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:provider/provider.dart';
import 'package:safecircle/navigation/app_router.dart';
import 'package:safecircle/screens/contact_links_screen.dart';
import 'package:safecircle/screens/contacts_screen.dart';
import 'package:safecircle/screens/emergency_active_screen.dart';
import 'package:safecircle/screens/invite_contact_screen.dart';
import 'package:safecircle/screens/login_screen.dart';
import 'package:safecircle/screens/profile_screen.dart';
import 'package:safecircle/services/api_failure.dart';
import 'package:safecircle/state/app_state.dart';
import 'package:safecircle/state/contact_links_state.dart';

import 'support/contact_links_fakes.dart';
import 'support/contact_links_widget_harness.dart';

// Prevent unrelated location/alert plugins and APIs from making live calls.
class NavigationAppState extends AppState {
  NavigationAppState(ContactLinksFakeApi api)
      : super(apiService: api, authService: ContactLinksFakeAuth());
  @override
  Future<void> loadAlertHistory() async {}
  @override
  Future<void> loadCurrentLocation() async {}
  @override
  Future<void> loadNearbyAlert() async {}
}

class NoDeviceLocation extends GeolocatorPlatform {
  @override
  Future<bool> isLocationServiceEnabled() async => false;
}

Future<NavigationAppState> boot(
    WidgetTester tester, ContactLinksFakeApi api) async {
  final location = GeolocatorPlatform.instance;
  GeolocatorPlatform.instance = NoDeviceLocation();
  addTearDown(() => GeolocatorPlatform.instance = location);
  tester.view.physicalSize = const Size(800, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final state = NavigationAppState(api);
  addTearDown(state.dispose);
  await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
      value: state, child: const SafeCircleApp()));
  await tester.pumpAndSettle();
  return state;
}

Future<void> openConnections(WidgetTester tester) async {
  await tapText(tester, 'Profile');
  await tapText(tester, 'Emergency Contacts');
  await tapText(tester, 'SafeCircle Connections');
}

void main() {
  testWidgets(
      'existing contact entry opens shared state, invitation route and refreshes on return',
      (tester) async {
    final api = ContactLinksFakeApi()..acceptedData = [testLink(1, 'accepted')];
    final state = await boot(tester, api);
    await tapText(tester, 'Emergency\nContacts');
    expect(find.byType(ContactsScreen), findsOneWidget);
    expect(find.text('Phone Contact'), findsOneWidget);
    await tapText(tester, 'SafeCircle Connections');
    final provided = tester
        .element(find.byType(ContactLinksScreen))
        .read<ContactLinksState>();
    expect(identical(provided, state.contactLinks), isTrue);
    expect(find.text('Accepted'), findsOneWidget);
    await tapText(tester, 'Invite by email');
    expect(find.byType(InviteContactScreen), findsOneWidget);
    expect(
        identical(
            tester
                .element(find.byType(InviteContactScreen))
                .read<ContactLinksState>(),
            provided),
        isTrue);
    await tester.enterText(
        find.byType(TextFormField), 'member@example.invalid');
    await tapText(tester, 'Search');
    expect(find.textContaining('An invitation or connection already exists.'),
        findsOneWidget);
    final before = api.acceptedCalls;
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(api.acceptedCalls, before + 1);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Phone Contact'), findsOneWidget);
    expect(api.phoneReads, 1);
    expect(api.phoneWrites, 0);
    expect(state.contacts.where((contact) => contact.enabled), hasLength(1));
  });

  testWidgets(
      'authentication recovery logs out, removes pushed pages and opens existing login',
      (tester) async {
    final api = ContactLinksFakeApi()
      ..onIncoming =
          () async => throw const ApiFailure(ApiFailureKind.authentication);
    final state = await boot(tester, api);
    await openConnections(tester);
    await tapText(tester, 'Sign in again');
    expect(find.byType(LoginScreen), findsOneWidget);
    expect(find.byType(ContactLinksScreen), findsNothing);
    expect(find.byType(ContactsScreen), findsNothing);
    expect(state.contactLinks.userId, isNull);
    expect(state.contactLinks.accepted.items, isEmpty);
  });

  testWidgets(
      'profile recovery uses Personal Details synchronization then retries access',
      (tester) async {
    final api = ContactLinksFakeApi()
      ..onIncoming =
          () async => throw const ApiFailure(ApiFailureKind.forbidden);
    final state = await boot(tester, api);
    await openConnections(tester);
    expect(api.profileSyncs, 0);
    await tapText(tester, 'Complete or sync profile');
    expect(find.text('Account recovery'), findsOneWidget);
    expect(find.byType(ProfileScreen), findsOneWidget);
    await tapText(tester, 'Personal Details');
    await tapText(tester, 'Save');
    expect(api.profileSyncs, 1);
    api.onIncoming = null;
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(ContactLinksScreen), findsOneWidget);
    expect(find.text('No SafeCircle connections yet.'), findsOneWidget);
    expect(state.contactLinks.isAccessBlocked, isFalse);
  });

  testWidgets(
      'existing phone add, edit, enable and disable remain separate from relationships',
      (tester) async {
    final api = ContactLinksFakeApi()..acceptedData = [testLink(1, 'accepted')];
    final state = await boot(tester, api);
    await tapText(tester, 'Emergency\nContacts');
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(state.contacts.single.enabled, isFalse);
    await tester.tap(find.byTooltip('Edit phone contact'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byType(TextField).first, 'Edited Phone Contact');
    await tapText(tester, 'Save');
    expect(state.contacts.single.name, 'Edited Phone Contact');
    await tapText(tester, 'Add Contact');
    await tester.enterText(
        find.byType(TextField).at(0), 'Another Phone Contact');
    await tester.enterText(find.byType(TextField).at(1), 'Family');
    await tester.enterText(find.byType(TextField).at(2), '0000000001');
    await tapText(tester, 'Add');
    expect(state.contacts, hasLength(2));
    expect(state.contacts.where((contact) => contact.enabled), hasLength(1));
    await tapText(tester, 'SafeCircle Connections');
    expect(find.text('Accepted'), findsOneWidget);
    expect(state.contacts, hasLength(2));
    expect(state.contacts.where((contact) => contact.enabled), hasLength(1));
    expect(api.phoneWrites, 3);
    await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(
            home:
                EmergencyActiveScreen(onBack: () {}, onImSafe: () async {}))));
    await tester.pumpAndSettle();
    expect(find.text('1'), findsWidgets);
    expect(state.contacts.where((contact) => contact.enabled).length, 1);
    expect(state.contactLinks.accepted.items, hasLength(1));
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
