import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:safecircle/models/contact_link.dart';
import 'package:safecircle/screens/contact_links_screen.dart';
import 'package:safecircle/services/api_failure.dart';
import 'package:safecircle/state/contact_links_state.dart';
import 'package:safecircle/widgets/contact_link_card.dart';

import 'support/contact_links_fakes.dart';
import 'support/contact_links_widget_harness.dart';

ContactLinksScreen screen(
        {Future<void> Function()? signIn,
        Future<void> Function()? profile,
        Future<void> Function()? invite}) =>
    ContactLinksScreen(
        onInvite: invite ?? () async {},
        onSignIn: signIn ?? () async {},
        onCompleteProfile: profile ?? () async {});

void main() {
  testWidgets(
      'network failure during profile access retry offers a safe read retry',
      (tester) async {
    final api = ContactLinksFakeApi()
      ..onIncoming =
          () async => throw const ApiFailure(ApiFailureKind.forbidden);
    await pumpContactLinks(tester, api, screen(profile: () async {
      api.onIncoming =
          () async => throw const ApiFailure(ApiFailureKind.network);
    }));
    await tester.pumpAndSettle();
    await tapText(tester, 'Complete or sync profile');
    expect(find.text('Restore connection access'), findsOneWidget);
    expect(find.text(const ApiFailure(ApiFailureKind.network).message),
        findsOneWidget);
    expect(find.text('Complete or sync profile'), findsNothing);
    api.onIncoming = null;
    await tapText(tester, 'Retry access');
    expect(find.text('No SafeCircle connections yet.'), findsOneWidget);
  });
  testWidgets(
      'open confirmation cannot mutate after logout and same-account sign-in',
      (tester) async {
    final api = ContactLinksFakeApi()..acceptedData = [testLink(1, 'accepted')];
    await pumpContactLinks(tester, api, screen());
    await tester.pumpAndSettle();
    final state = tester
        .element(find.byType(ContactLinksScreen))
        .read<ContactLinksState>();
    await tapText(tester, 'Revoke connection');
    state.setSession(null);
    state.setSession('alice');
    await tapText(tester, 'Revoke connection');
    expect(api.revocations, isEmpty);
  });
  testWidgets(
      'three views load on entry and switching, with distinct empty states',
      (tester) async {
    final api = ContactLinksFakeApi();
    await pumpContactLinks(tester, api, screen());
    await tester.pumpAndSettle();
    expect(find.text('No SafeCircle connections yet.'), findsOneWidget);
    expect(
        (api.incomingCalls, api.outgoingCalls, api.acceptedCalls), (1, 1, 1));
    await tapText(tester, 'Received');
    expect(find.text('No received invitations.'), findsOneWidget);
    expect(api.incomingCalls, 2);
    await tapText(tester, 'Sent');
    expect(find.text('No sent invitations.'), findsOneWidget);
    expect(api.outgoingCalls, 2);
    await tapText(tester, 'Connections');
    expect(api.acceptedCalls, 2);
    final counts = (api.incomingCalls, api.outgoingCalls, api.acceptedCalls);
    tester
        .element(find.byType(ContactLinksScreen))
        .read<ContactLinksState>()
        .setSearchEmail('test@example.invalid');
    await tester.pump();
    expect((api.incomingCalls, api.outgoingCalls, api.acceptedCalls), counts);
  });

  testWidgets(
      'received invitation waits for server and blocks duplicate and conflicting actions',
      (tester) async {
    final api = ContactLinksFakeApi()..incomingData = [testLink(1, 'pending')];
    final pending = Completer<ContactLink>();
    api.onRespond = (_, action) => pending.future;
    await pumpContactLinks(tester, api, screen());
    await tester.pumpAndSettle();
    await tapText(tester, 'Received');
    await tester.tap(find.text('Accept invitation'));
    await tester.pump();
    expect(find.text('Pending'), findsOneWidget);
    expect(find.text('Accepted'), findsNothing);
    await tester.tap(find.text('Accept invitation'));
    await tester.tap(find.text('Reject invitation'));
    expect(api.responses, [(1, ContactInvitationAction.accept)]);
    api.incomingData = [];
    api.acceptedData = [testLink(1, 'accepted')];
    pending.complete(testLink(1, 'accepted'));
    await tester.pumpAndSettle();
    expect(find.text('Invitation accepted.'), findsOneWidget);
    expect(find.text('No received invitations.'), findsOneWidget);
    await tapText(tester, 'Connections');
    expect(find.text('Accepted'), findsOneWidget);
  });

  testWidgets('reject refreshes lists and never becomes an accepted contact',
      (tester) async {
    final api = ContactLinksFakeApi()..incomingData = [testLink(2, 'pending')];
    api.onRespond = (id, action) async {
      expect(action, ContactInvitationAction.reject);
      api.incomingData = [];
      return testLink(id, 'rejected');
    };
    await pumpContactLinks(tester, api, screen());
    await tester.pumpAndSettle();
    await tapText(tester, 'Received');
    await tapText(tester, 'Reject invitation');
    expect(find.text('Invitation rejected.'), findsOneWidget);
    await tapText(tester, 'Connections');
    expect(find.byType(ContactLinkCard), findsNothing);
  });

  testWidgets(
      'sent history shows all statuses and only pending can be cancelled',
      (tester) async {
    final api = ContactLinksFakeApi()
      ..outgoingData = [
        for (final (id, status) in [
          (1, 'pending'),
          (2, 'accepted'),
          (3, 'rejected'),
          (4, 'revoked'),
          (5, 'future')
        ])
          testLink(id, status, incoming: false),
      ];
    api.onRevoke = (id) async {
      api.outgoingData[0] = testLink(id, 'revoked', incoming: false);
      return api.outgoingData[0];
    };
    await pumpContactLinks(tester, api, screen(), size: const Size(800, 1800));
    await tester.pumpAndSettle();
    await tapText(tester, 'Sent');
    for (final status in [
      'Pending',
      'Accepted',
      'Rejected',
      'Revoked',
      'Unknown status'
    ]) {
      expect(find.text(status), findsOneWidget);
    }
    expect(find.text('Cancel invitation'), findsOneWidget);
    await tapText(tester, 'Cancel invitation');
    expect(api.revocations, [1]);
    expect(find.text('Cancel invitation'), findsNothing);
    expect(find.text('Revoked'), findsNWidgets(2));
  });

  testWidgets(
      'accepted revoke requires confirmation and supports keeping connection',
      (tester) async {
    final api = ContactLinksFakeApi()..acceptedData = [testLink(3, 'accepted')];
    api.onRevoke = (id) async {
      api.acceptedData = [];
      return testLink(id, 'revoked');
    };
    await pumpContactLinks(tester, api, screen());
    await tester.pumpAndSettle();
    await tapText(tester, 'Revoke connection');
    expect(find.text('Revoke connection?'), findsOneWidget);
    expect(api.revocations, isEmpty);
    await tapText(tester, 'Keep connection');
    expect(api.revocations, isEmpty);
    await tapText(tester, 'Revoke connection');
    await tapText(tester, 'Revoke connection');
    expect(api.revocations, [3]);
    expect(find.text('No SafeCircle connections yet.'), findsOneWidget);
  });

  testWidgets(
      'missing identity is neutral, never substitutes another participant',
      (tester) async {
    final api = ContactLinksFakeApi()
      ..acceptedData = [
        ContactLink.fromJson({
          ...testLink(1, 'accepted').toJson(),
          'other_user': null,
        })
      ];
    await pumpContactLinks(tester, api, screen());
    await tester.pumpAndSettle();
    expect(find.text('Member unavailable'), findsOneWidget);
    expect(find.textContaining('@'), findsNothing);
    expect(find.text('Example Member'), findsNothing);
    expect(find.text('Revoke connection'), findsOneWidget);
  });

  testWidgets(
      'loading and failed refresh preserve loaded items and allow safe retry',
      (tester) async {
    final pending = Completer<List<ContactLink>>();
    final api = ContactLinksFakeApi()..onAccepted = () => pending.future;
    await pumpContactLinks(tester, api, screen());
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    pending.complete([testLink(1, 'accepted')]);
    await tester.pumpAndSettle();
    api.onAccepted = () async => throw const ApiFailure(ApiFailureKind.network);
    await tester.tap(find.byTooltip('Refresh connections'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Previously loaded items are shown.'),
        findsOneWidget);
    expect(find.text('Example Member'), findsOneWidget);
    api.onAccepted = null;
    api.acceptedData = [testLink(1, 'accepted')];
    await tapText(tester, 'Refresh connections');
    expect(find.textContaining('Previously loaded items'), findsNothing);
  });

  for (final kind in [
    ApiFailureKind.authentication,
    ApiFailureKind.forbidden
  ]) {
    testWidgets(
        '$kind offers appropriate account recovery and hides identities',
        (tester) async {
      final api = ContactLinksFakeApi()
        ..onAccepted = () async => throw ApiFailure(kind);
      var recoveries = 0;
      await pumpContactLinks(
          tester,
          api,
          screen(signIn: () async {
            recoveries++;
          }, profile: () async {
            recoveries++;
            api.onAccepted = null;
          }));
      await tester.pumpAndSettle();
      expect(find.byType(ContactLinkCard), findsNothing);
      await tapText(
          tester,
          kind == ApiFailureKind.authentication
              ? 'Sign in again'
              : 'Complete or sync profile');
      expect(recoveries, 1);
      if (kind == ApiFailureKind.forbidden) {
        expect(find.text('No SafeCircle connections yet.'), findsOneWidget);
      }
    });
  }

  testWidgets(
      'uncertain timeout blocks actions until authoritative refresh succeeds',
      (tester) async {
    final api = ContactLinksFakeApi()..incomingData = [testLink(1, 'pending')];
    api.onRespond = (_, __) async {
      api.onIncoming =
          () async => throw const ApiFailure(ApiFailureKind.network);
      throw const ApiFailure(ApiFailureKind.timeout);
    };
    await pumpContactLinks(tester, api, screen());
    await tester.pumpAndSettle();
    await tapText(tester, 'Received');
    await tapText(tester, 'Accept invitation');
    expect(find.textContaining('outcome is uncertain'), findsWidgets);
    final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Accept invitation'));
    expect(button.onPressed, isNull);
    api.onIncoming = null;
    api.incomingData = [];
    api.acceptedData = [testLink(1, 'accepted')];
    await tester.tap(find.byTooltip('Refresh connections'));
    await tester.pumpAndSettle();
    expect(find.text('No received invitations.'), findsOneWidget);
    await tapText(tester, 'Connections');
    expect(find.text('Accepted'), findsOneWidget);
    expect(api.responses, hasLength(1));
  });

  testWidgets(
      'successful mutation with failed refresh reports saved change without resubmission',
      (tester) async {
    final api = ContactLinksFakeApi()..incomingData = [testLink(1, 'pending')];
    api.onRespond = (id, _) async {
      api.onOutgoing =
          () async => throw const ApiFailure(ApiFailureKind.network);
      api.incomingData = [];
      api.acceptedData = [testLink(id, 'accepted')];
      return testLink(id, 'accepted');
    };
    await pumpContactLinks(tester, api, screen());
    await tester.pumpAndSettle();
    await tapText(tester, 'Received');
    await tapText(tester, 'Accept invitation');
    expect(
        find.textContaining(
            'Invitation accepted. Could not refresh all lists.'),
        findsOneWidget);
    expect(api.responses, hasLength(1));
    expect(find.text('Accept invitation'), findsNothing);
  });

  testWidgets(
      'narrow layout and large text keep relationship actions accessible',
      (tester) async {
    final api = ContactLinksFakeApi()..incomingData = [testLink(1, 'pending')];
    await pumpContactLinks(tester, api, screen(),
        size: const Size(320, 640), textScale: 1.8);
    await tester.pumpAndSettle();
    await tapText(tester, 'Received');
    await tester.ensureVisible(find.text('Reject invitation'));
    expect(tester.takeException(), isNull);
    expect(
        tester
            .getSize(find.widgetWithText(OutlinedButton, 'Reject invitation'))
            .height,
        greaterThanOrEqualTo(48));
  });
}
