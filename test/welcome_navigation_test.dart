import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:safecircle/navigation/app_router.dart';
import 'package:safecircle/screens/create_account_screen.dart';
import 'package:safecircle/screens/login_screen.dart';
import 'package:safecircle/screens/welcome_screen.dart';
import 'package:safecircle/state/app_state.dart';

import 'support/contact_links_fakes.dart';

Future<void> bootWelcome(WidgetTester tester) async {
  final auth = ContactLinksFakeAuth()..onRestore = () async => null;
  final app = AppState(apiService: ContactLinksFakeApi(), authService: auth);
  addTearDown(app.dispose);
  await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
      value: app, child: const SafeCircleApp()));
  await tester.pumpAndSettle();
}

Future<void> tapWelcomeText(WidgetTester tester, String label) async {
  await Scrollable.ensureVisible(tester.element(find.text(label).last),
      alignment: 0.5);
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Create an account onboarding row opens existing registration',
      (tester) async {
    await bootWelcome(tester);
    await tapWelcomeText(tester, 'Create an account');
    expect(find.byType(CreateAccountScreen), findsOneWidget);
  });

  testWidgets(
      'welcome displays the circular branding asset with preserved aspect ratio',
      (tester) async {
    await bootWelcome(tester);
    final logo = tester.widget<Image>(find.byType(Image));
    expect((logo.image as AssetImage).assetName,
        'assets/branding/neon_guardian_shield_original.png');
    expect(logo.fit, BoxFit.contain);
    expect(logo.semanticLabel, 'SafeCircle logo');
    await tester.runAsync(() async {
      await precacheImage(logo.image, tester.element(find.byType(Image)));
    });
    await tester.pumpAndSettle();
    final rendered = tester.renderObject<RenderImage>(find.byType(RawImage));
    expect(rendered.image, isNotNull);
    expect(rendered.image!.width, rendered.image!.height);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'Get Started still opens registration and Back returns to Welcome',
      (tester) async {
    await bootWelcome(tester);
    await tapWelcomeText(tester, 'Get Started');
    expect(find.byType(CreateAccountScreen), findsOneWidget);
    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();
    expect(find.byType(WelcomeScreen), findsOneWidget);
  });

  testWidgets('Log In and existing Create account navigation remain available',
      (tester) async {
    await bootWelcome(tester);
    await tapWelcomeText(tester, 'Log In');
    expect(find.byType(LoginScreen), findsOneWidget);
    final create = find.textContaining('Create');
    await Scrollable.ensureVisible(tester.element(create.last), alignment: 0.5);
    await tester.tap(create.last);
    await tester.pumpAndSettle();
    expect(find.byType(CreateAccountScreen), findsOneWidget);
  });
}
