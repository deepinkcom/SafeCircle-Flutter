import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:safecircle/models/contact_link.dart';
import 'package:safecircle/models/registered_user.dart';
import 'package:safecircle/screens/invite_contact_screen.dart';
import 'package:safecircle/services/api_failure.dart';
import 'package:safecircle/state/app_state.dart';

import 'support/contact_links_fakes.dart';
import 'support/contact_links_widget_harness.dart';

InviteContactScreen screen(
        {Future<void> Function()? signIn, Future<void> Function()? profile}) =>
    InviteContactScreen(
        onSignIn: signIn ?? () async {},
        onCompleteProfile: profile ?? () async {});

Future<void> lookup(WidgetTester tester,
    [String email = 'member@example.invalid']) async {
  await tester.enterText(find.byKey(const ValueKey('invite-email')), email);
  await tapText(tester, 'Search');
}

void main() {
  testWidgets(
      'leaving during invitation ignores late success without disposed-widget updates',
      (tester) async {
    final pending = Completer<ContactLink>();
    final api = ContactLinksFakeApi()..onSend = (_) => pending.future;
    await pumpContactLinks(tester, api, screen());
    await tester.pumpAndSettle();
    await lookup(tester);
    await tester.tap(find.text('Send invitation'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    api.outgoingData = [testLink(7, 'pending', incoming: false)];
    pending.complete(api.outgoingData.single);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(api.sendCalls, 1);
  });

  testWidgets(
      'recovery callback failures show a safe message without internal details',
      (tester) async {
    final api = ContactLinksFakeApi()
      ..onSearch =
          (_) async => throw const ApiFailure(ApiFailureKind.authentication);
    await pumpContactLinks(tester, api, screen(signIn: () async {
      throw StateError('synthetic internal detail');
    }));
    await tester.pumpAndSettle();
    await lookup(tester);
    await tapText(tester, 'Sign in again');
    expect(find.text('Could not complete account recovery. Please try again.'),
        findsOneWidget);
    expect(find.textContaining('synthetic internal detail'), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'requires a complete email and explicit lookup, including plus and ampersand',
      (tester) async {
    final api = ContactLinksFakeApi();
    await pumpContactLinks(tester, api, screen());
    await tester.pumpAndSettle();
    for (final invalid in [
      '',
      'member',
      'member@',
      'member@example',
      'member @example.invalid'
    ]) {
      await lookup(tester, invalid);
      expect(find.text('Enter a complete email address.'), findsOneWidget);
      expect(api.searchCalls, 0);
    }
    const email = 'member+family&friends@example.invalid';
    api.onSearch = (query) async {
      expect(query, email);
      return const [RegisteredUser(name: 'Example Member', email: email)];
    };
    await tester.enterText(find.byKey(const ValueKey('invite-email')), email);
    await tester.pump();
    expect(api.searchCalls, 0);
    await tapText(tester, 'Search');
    expect(find.text('Example Member'), findsOneWidget);
    expect(find.text(email), findsNWidgets(2));
    expect(api.searchCalls, 1);
  });

  testWidgets(
      'matching user can be invited once and receives confirmed success',
      (tester) async {
    final pending = Completer<ContactLink>();
    final api = ContactLinksFakeApi()..onSend = (_) => pending.future;
    await pumpContactLinks(tester, api, screen());
    await tester.pumpAndSettle();
    await lookup(tester);
    await tester.tap(find.text('Send invitation'));
    await tester.pump();
    expect(find.text('Invitation sent.'), findsNothing);
    await tester.tap(find.text('Send invitation'));
    expect(api.sendCalls, 1);
    expect(tester.widget<TextFormField>(find.byType(TextFormField)).enabled,
        isFalse);
    api.outgoingData = [testLink(7, 'pending', incoming: false)];
    pending.complete(api.outgoingData.single);
    await tester.pumpAndSettle();
    expect(find.text('Invitation sent.'), findsOneWidget);
    expect(find.textContaining('An invitation or connection already exists.'),
        findsOneWidget);
    expect(
        tester
            .widget<FilledButton>(
                find.widgetWithText(FilledButton, 'Send invitation'))
            .onPressed,
        isNull);
    expect(api.sendCalls, 1);
  });

  testWidgets(
      'editing lookup clears match immediately and stale search cannot restore it',
      (tester) async {
    final api = ContactLinksFakeApi();
    await pumpContactLinks(tester, api, screen());
    await tester.pumpAndSettle();
    await lookup(tester);
    await tester.enterText(
        find.byKey(const ValueKey('invite-email')), 'new@example.invalid');
    await tester.pump();
    expect(find.text('Example Member'), findsNothing);
    expect(find.text('Send invitation'), findsNothing);
    final pending = Completer<List<RegisteredUser>>();
    api.onSearch = (_) => pending.future;
    await tester.tap(find.text('Search'));
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    await tester.enterText(
        find.byKey(const ValueKey('invite-email')), 'another@example.invalid');
    pending.complete(api.searchData);
    await tester.pumpAndSettle();
    expect(find.text('Example Member'), findsNothing);
    expect(api.sendCalls, 0);
  });

  testWidgets(
      'no match is a safe empty result and failed search has read retry',
      (tester) async {
    final api = ContactLinksFakeApi()..searchData = [];
    await pumpContactLinks(tester, api, screen());
    await tester.pumpAndSettle();
    await lookup(tester);
    expect(find.text('No matching registered user found.'), findsOneWidget);
    api.onSearch = (_) async => throw const ApiFailure(ApiFailureKind.network);
    await tapText(tester, 'Search');
    expect(find.text(const ApiFailure(ApiFailureKind.network).message),
        findsOneWidget);
    expect(find.text('No matching registered user found.'), findsNothing);
    api.onSearch = null;
    api.searchData = [
      const RegisteredUser(
          name: 'Example Member', email: 'member@example.invalid')
    ];
    await tapText(tester, 'Retry search');
    expect(find.text('Example Member'), findsOneWidget);
  });

  for (final kind in [
    ApiFailureKind.conflict,
    ApiFailureKind.validation,
    ApiFailureKind.notFound,
    ApiFailureKind.network
  ]) {
    testWidgets('invitation failure $kind is safe and never confirms success',
        (tester) async {
      final api = ContactLinksFakeApi()
        ..onSend = (_) async => throw ApiFailure(kind);
      await pumpContactLinks(tester, api, screen());
      await tester.pumpAndSettle();
      await lookup(tester);
      await tapText(tester, 'Send invitation');
      expect(
          kind == ApiFailureKind.network
              ? find.textContaining('outcome was uncertain')
              : find.text(ApiFailure(kind).message),
          findsOneWidget);
      expect(find.text('Invitation sent.'), findsNothing);
      expect(api.sendCalls, 1);
    });
  }

  testWidgets(
      'timeout requires authoritative refresh before another invitation attempt',
      (tester) async {
    final api = ContactLinksFakeApi();
    api.onSend = (_) async {
      api.onOutgoing =
          () async => throw const ApiFailure(ApiFailureKind.network);
      throw const ApiFailure(ApiFailureKind.timeout);
    };
    await pumpContactLinks(tester, api, screen());
    await tester.pumpAndSettle();
    await lookup(tester);
    await tapText(tester, 'Send invitation');
    expect(find.textContaining('outcome is uncertain'), findsOneWidget);
    expect(
        tester
            .widget<FilledButton>(
                find.widgetWithText(FilledButton, 'Send invitation'))
            .onPressed,
        isNull);
    api.onOutgoing = null;
    api.outgoingData = [testLink(7, 'pending', incoming: false)];
    await tapText(tester, 'Refresh connections');
    expect(find.textContaining('An invitation or connection already exists.'),
        findsOneWidget);
    expect(
        tester
            .widget<FilledButton>(
                find.widgetWithText(FilledButton, 'Send invitation'))
            .onPressed,
        isNull);
    expect(api.sendCalls, 1);
  });

  testWidgets(
      'successful invite with refresh failure offers refresh rather than claiming a failed write',
      (tester) async {
    final api = ContactLinksFakeApi();
    api.onSend = (_) async {
      api.onOutgoing =
          () async => throw const ApiFailure(ApiFailureKind.network);
      return testLink(7, 'pending', incoming: false);
    };
    await pumpContactLinks(tester, api, screen());
    await tester.pumpAndSettle();
    await lookup(tester);
    await tapText(tester, 'Send invitation');
    expect(find.textContaining('Invitation sent. Could not refresh all lists.'),
        findsOneWidget);
    expect(api.sendCalls, 1);
    expect(
        tester
            .widget<FilledButton>(
                find.widgetWithText(FilledButton, 'Send invitation'))
            .onPressed,
        isNull);
  });

  for (final kind in [
    ApiFailureKind.authentication,
    ApiFailureKind.forbidden
  ]) {
    testWidgets('lookup $kind exposes recovery and disables search/send',
        (tester) async {
      final api = ContactLinksFakeApi()
        ..onSearch = (_) async => throw ApiFailure(kind);
      var calls = 0;
      await pumpContactLinks(
          tester,
          api,
          screen(signIn: () async {
            calls++;
          }, profile: () async {
            calls++;
            api.onSearch = null;
          }));
      await tester.pumpAndSettle();
      await lookup(tester);
      expect(find.text('Send invitation'), findsNothing);
      expect(
          tester
              .widget<FilledButton>(find.widgetWithText(FilledButton, 'Search'))
              .onPressed,
          isNull);
      await tapText(
          tester,
          kind == ApiFailureKind.authentication
              ? 'Sign in again'
              : 'Complete or sync profile');
      expect(calls, 1);
      if (kind == ApiFailureKind.forbidden) {
        expect(
            tester
                .widget<FilledButton>(
                    find.widgetWithText(FilledButton, 'Search'))
                .onPressed,
            isNotNull);
      }
    });
  }

  testWidgets(
      'account switching clears input and rejects a late mutation success',
      (tester) async {
    final pending = Completer<ContactLink>();
    final api = ContactLinksFakeApi()..onSend = (_) => pending.future;
    await pumpContactLinks(tester, api, screen());
    await tester.pumpAndSettle();
    await lookup(tester);
    await tester.tap(find.text('Send invitation'));
    await tester.pump();
    tester
        .element(find.byType(InviteContactScreen))
        .read<AppState>()
        .userProfile = testProfile('bob');
    await tester.pump();
    pending.complete(testLink(7, 'pending', incoming: false));
    await tester.pumpAndSettle();
    expect(find.text('Invitation sent.'), findsNothing);
    expect(find.text('Example Member'), findsNothing);
    expect(
        tester
            .widget<TextFormField>(find.byType(TextFormField))
            .controller!
            .text,
        isEmpty);
  });

  testWidgets('narrow keyboard-safe form supports large text without overflow',
      (tester) async {
    final api = ContactLinksFakeApi();
    await pumpContactLinks(tester, api, screen(),
        size: const Size(320, 640), textScale: 1.8);
    await tester.pumpAndSettle();
    tester.view.viewInsets = const FakeViewPadding(bottom: 240);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();
    await lookup(tester);
    await tester.scrollUntilVisible(find.text('Send invitation'), 120,
        scrollable: find.byType(Scrollable).first);
    expect(tester.takeException(), isNull);
    expect(
        tester
            .getSize(find.widgetWithText(FilledButton, 'Send invitation'))
            .height,
        greaterThanOrEqualTo(48));
  });
}
