import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:safecircle/state/app_state.dart';
import 'package:safecircle/state/contact_links_state.dart';
import 'package:safecircle/theme/app_theme.dart';

import 'contact_links_fakes.dart';

Future<void> pumpContactLinks(
    WidgetTester tester, ContactLinksFakeApi api, Widget screen,
    {Size? size, double textScale = 1}) async {
  if (size != null) {
    tester.view.reset();
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }
  final app = AppState(apiService: api, authService: ContactLinksFakeAuth())
    ..userProfile = testProfile('alice');
  addTearDown(app.dispose);
  await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<AppState>.value(value: app),
        ChangeNotifierProvider<ContactLinksState>.value(
            value: app.contactLinks),
      ],
      child: MaterialApp(
          theme: AppTheme.light,
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(textScale)),
              child: child!),
          home: screen)));
  await tester.pump();
}

Future<void> tapText(WidgetTester tester, String text) async {
  await tester.pump();
  if (find.text(text).evaluate().isEmpty) {
    await tester.scrollUntilVisible(find.text(text), 100,
        scrollable: find.byType(Scrollable).first);
  }
  final target = find.text(text).last;
  await Scrollable.ensureVisible(tester.element(target), alignment: 0.5);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}
