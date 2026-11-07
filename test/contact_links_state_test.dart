import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:safecircle/models/contact_link.dart';
import 'package:safecircle/models/registered_user.dart';
import 'package:safecircle/services/api_failure.dart';
import 'package:safecircle/state/contact_links_state.dart';

import 'support/contact_links_fakes.dart';

Future<void> flush() => Future<void>.delayed(Duration.zero);

void main() {
  late ContactLinksFakeApi api;
  late ContactLinksState state;
  setUp(() {
    api = ContactLinksFakeApi();
    state = ContactLinksState(apiService: api)..setSession('alice');
  });
  tearDown(() => state.dispose());

  test('starts with independent unloaded snapshots and no HTTP calls', () {
    expect(state.search.items, isEmpty);
    expect(state.incoming.hasLoaded, isFalse);
    expect(state.outgoing.hasLoaded, isFalse);
    expect(state.accepted.hasLoaded, isFalse);
    expect(state.mutations, isEmpty);
    expect(state.invitation.isLoading, isFalse);
    expect(
        api.incomingCalls +
            api.outgoingCalls +
            api.acceptedCalls +
            api.searchCalls,
        0);
  });

  test('search tracks loading, complete email, success, and immutable results',
      () async {
    final pending = Completer<List<RegisteredUser>>();
    api.onSearch = (email) {
      expect(email, 'member@example.invalid');
      return pending.future;
    };
    final request = state.searchRegisteredUsers(' member@example.invalid ');
    expect(state.search.isLoading, isTrue);
    expect(state.incoming.isLoading, isFalse);
    pending.complete(api.searchData);
    expect(await request, isTrue);
    expect(state.search.hasLoaded, isTrue);
    expect(state.search.items.single.email, 'member@example.invalid');
    expect(() => state.search.items.clear(), throwsUnsupportedError);
  });

  test('empty search is loaded success, validation failure is distinct',
      () async {
    api.searchData = [];
    expect(await state.searchRegisteredUsers('none@example.invalid'), isTrue);
    expect(state.search.hasLoaded, isTrue);
    expect(state.search.items, isEmpty);
    api.onSearch =
        (_) async => throw const ApiFailure(ApiFailureKind.validation);
    expect(await state.searchRegisteredUsers('partial'), isFalse);
    expect(state.search.error!.kind, ApiFailureKind.validation);
    expect(state.search.isLoading, isFalse);
  });

  test('search failure retains only results for the same query', () async {
    await state.searchRegisteredUsers('member@example.invalid');
    api.onSearch = (_) async => throw const ApiFailure(ApiFailureKind.network);
    await state.searchRegisteredUsers('member@example.invalid');
    expect(state.search.items, hasLength(1));
    expect(state.search.error!.kind, ApiFailureKind.network);
    state.setSearchEmail('different@example.invalid');
    expect(state.search.items, isEmpty);
    expect(state.search.error, isNull);
    expect(state.search.hasLoaded, isFalse);
  });

  test('newer searches win and editing invalidates pending results', () async {
    final first = Completer<List<RegisteredUser>>();
    final second = Completer<List<RegisteredUser>>();
    api.onSearch =
        (email) => email.startsWith('first') ? first.future : second.future;
    final old = state.searchRegisteredUsers('first@example.invalid');
    final newer = state.searchRegisteredUsers('second@example.invalid');
    second.complete(const [
      RegisteredUser(name: 'Second', email: 'second@example.invalid')
    ]);
    expect(await newer, isTrue);
    first.completeError(const ApiFailure(ApiFailureKind.network));
    expect(await old, isFalse);
    expect(state.search.items.single.name, 'Second');
    expect(state.search.error, isNull);
    final late = Completer<List<RegisteredUser>>();
    api.onSearch = (_) => late.future;
    final request = state.searchRegisteredUsers('third@example.invalid');
    state.setSearchEmail('fourth@example.invalid');
    late.complete(api.searchData);
    expect(await request, isFalse);
    expect(state.search.items, isEmpty);
  });

  test('loads independent lists and filters inactive or unknown records',
      () async {
    api.incomingData = [
      for (final status in [
        'pending',
        'accepted',
        'rejected',
        'revoked',
        'future'
      ])
        testLink(status.length, status)
    ];
    api.outgoingData = List.of(api.incomingData);
    api.acceptedData = List.of(api.incomingData);
    final pending = Completer<List<ContactLink>>();
    api.onIncoming = () => pending.future;
    final incoming = state.loadIncomingInvitations();
    await state.loadOutgoingInvitations();
    await state.loadAcceptedRelationships();
    expect(state.incoming.isLoading, isTrue);
    expect(state.outgoing.items, hasLength(5));
    expect(state.accepted.items.single.status, ContactLinkStatus.accepted);
    pending.complete(api.incomingData);
    expect(await incoming, isTrue);
    expect(state.incoming.items.single.status, ContactLinkStatus.pending);
    expect(() => state.accepted.items.clear(), throwsUnsupportedError);
  });

  for (final resource in ['incoming', 'outgoing', 'accepted']) {
    test('$resource retains previous data on refresh failure', () async {
      api.incomingData = [testLink(7, 'pending')];
      api.outgoingData = [testLink(7, 'rejected')];
      api.acceptedData = [testLink(7, 'accepted')];
      await state.refresh();
      Future<List<ContactLink>> fail() async =>
          throw const ApiFailure(ApiFailureKind.network);
      final loader = switch (resource) {
        'incoming' => state.loadIncomingInvitations,
        'outgoing' => state.loadOutgoingInvitations,
        _ => state.loadAcceptedRelationships,
      };
      switch (resource) {
        case 'incoming':
          api.onIncoming = fail;
        case 'outgoing':
          api.onOutgoing = fail;
        case 'accepted':
          api.onAccepted = fail;
      }
      expect(await loader(), isFalse);
      final snapshot = switch (resource) {
        'incoming' => state.incoming,
        'outgoing' => state.outgoing,
        _ => state.accepted,
      };
      expect(snapshot.items.single.id, 7);
      expect(snapshot.hasLoaded, isTrue);
      expect(snapshot.isLoading, isFalse);
      expect(snapshot.error!.kind, ApiFailureKind.network);
    });
  }

  test('a stale list response cannot overwrite the newest data or loading flag',
      () async {
    final first = Completer<List<ContactLink>>();
    final second = Completer<List<ContactLink>>();
    api.onIncoming =
        () => api.incomingCalls == 1 ? first.future : second.future;
    final old = state.loadIncomingInvitations();
    final newer = state.loadIncomingInvitations();
    first.complete([testLink(1, 'pending')]);
    expect(await old, isFalse);
    expect(state.incoming.isLoading, isTrue);
    second.complete([testLink(2, 'pending')]);
    expect(await newer, isTrue);
    expect(state.incoming.items.single.id, 2);
    expect(state.incoming.isLoading, isFalse);
  });

  for (final kind in [
    ApiFailureKind.authentication,
    ApiFailureKind.forbidden
  ]) {
    test(
        '$kind clears protected data, invalidates peers, and requires explicit recovery',
        () async {
      api.outgoingData = [testLink(7, 'pending')];
      await state.loadOutgoingInvitations();
      final peer = Completer<List<ContactLink>>();
      api.onIncoming = () => peer.future;
      final stale = state.loadIncomingInvitations();
      api.onAccepted = () async => throw ApiFailure(kind);
      expect(await state.loadAcceptedRelationships(), isFalse);
      expect(state.outgoing.items, isEmpty);
      expect(state.isAccessBlocked, isTrue);
      expect(state.needsAuthentication, kind == ApiFailureKind.authentication);
      expect(state.needsBackendProfile, kind == ApiFailureKind.forbidden);
      peer.complete([testLink(8, 'pending')]);
      expect(await stale, isFalse);
      expect((await state.sendInvitation('member@example.invalid')).error!.kind,
          kind);
      expect(api.sendCalls, 0);
      api.onIncoming = null;
      api.onAccepted = null;
      expect((await state.retryAccess()).succeeded, isTrue);
      expect(state.isAccessBlocked, isFalse);
      expect(state.accessFailure, isNull);
    });
  }

  test('failed access recovery remains blocked until a successful retry',
      () async {
    api.onIncoming =
        () async => throw const ApiFailure(ApiFailureKind.forbidden);
    await state.loadIncomingInvitations();
    api.onIncoming = () async => throw const ApiFailure(ApiFailureKind.network);
    expect((await state.retryAccess()).succeeded, isFalse);
    expect(state.isAccessBlocked, isTrue);
    expect((await state.sendInvitation('member@example.invalid')).outcome,
        ContactLinkMutationOutcome.blocked);
    api.onIncoming = null;
    expect((await state.retryAccess()).succeeded, isTrue);
    expect(state.isAccessBlocked, isFalse);
  });

  test('send prevents duplicate submissions and refreshes all three lists',
      () async {
    final pending = Completer<ContactLink>();
    api.onSend = (_) => pending.future;
    final send = state.sendInvitation('member@example.invalid');
    expect(state.invitation.isLoading, isTrue);
    expect(state.outgoing.items, isEmpty);
    expect((await state.sendInvitation('MEMBER@example.invalid')).outcome,
        ContactLinkMutationOutcome.blocked);
    expect(api.sendCalls, 1);
    api.outgoingData = [testLink(7, 'pending', incoming: false)];
    pending.complete(api.outgoingData.single);
    final result = await send;
    expect(result.succeeded, isTrue);
    expect(result.refreshSucceeded, isTrue);
    expect(state.invitation.confirmed!.id, 7);
    expect(state.invitation.isLoading, isFalse);
    expect(state.invitationEmail, 'member@example.invalid');
    expect(api.incomingCalls, 1);
    expect(api.outgoingCalls, 1);
    expect(api.acceptedCalls, 1);
    expect((await state.sendInvitation('member@example.invalid')).outcome,
        ContactLinkMutationOutcome.blocked);
    expect(api.sendCalls, 1);
  });

  for (final action in ['accept', 'reject', 'revoke']) {
    test('$action waits for confirmation and reconciles affected lists',
        () async {
      final original = testLink(7, action == 'revoke' ? 'accepted' : 'pending');
      if (action == 'revoke') {
        api.acceptedData = [original];
      } else {
        api.incomingData = [original];
      }
      await state.refresh();
      final pending = Completer<ContactLink>();
      api.onRespond = (_, __) => pending.future;
      api.onRevoke = (_) => pending.future;
      final mutate = switch (action) {
        'accept' => state.acceptInvitation,
        'reject' => state.rejectInvitation,
        _ => state.revokeRelationship,
      };
      final request = mutate(7);
      expect(state.mutationFor(7).isLoading, isTrue);
      expect(
          (action == 'revoke' ? state.accepted : state.incoming).items.single,
          same(original));
      expect((await mutate(7)).outcome, ContactLinkMutationOutcome.blocked);
      expect(api.responses.length + api.revocations.length, 1);
      final confirmed = testLink(
          7,
          switch (action) {
            'accept' => 'accepted',
            'reject' => 'rejected',
            _ => 'revoked'
          });
      api.incomingData = [];
      api.acceptedData = action == 'accept' ? [confirmed] : [];
      pending.complete(confirmed);
      final result = await request;
      expect(result.succeeded, isTrue);
      expect(result.refreshSucceeded, isTrue);
      expect(state.incoming.items, isEmpty);
      expect(state.accepted.items.length, action == 'accept' ? 1 : 0);
      expect(state.mutationFor(7).confirmed, same(confirmed));
      expect(state.mutationFor(7).isLoading, isFalse);
      expect(api.incomingCalls, 2);
      expect(api.outgoingCalls, 2);
      expect(api.acceptedCalls, 2);
    });
  }

  test('successful mutation with failed refresh remains a confirmed success',
      () async {
    api.incomingData = [testLink(7, 'pending')];
    api.outgoingData = [testLink(8, 'rejected')];
    await state.refresh();
    api.onIncoming = () async => throw const ApiFailure(ApiFailureKind.network);
    api.onOutgoing = () async => throw const ApiFailure(ApiFailureKind.network);
    api.onAccepted = () async => throw const ApiFailure(ApiFailureKind.network);
    final result = await state.acceptInvitation(7);
    expect(result.succeeded, isTrue);
    expect(result.error, isNull);
    expect(result.refreshError!.kind, ApiFailureKind.network);
    expect(state.mutationFor(7).error, isNull);
    expect(state.mutationFor(7).refreshError!.kind, ApiFailureKind.network);
    expect(state.mutationFor(7).requiresRefresh, isFalse);
    expect(state.incoming.items, isEmpty);
    expect(state.outgoing.items.single.id, 8);
    expect(state.accepted.items.single.id, 7);
  });

  test('confirmed revocation stays removed if the accepted-list refresh fails',
      () async {
    api.acceptedData = [testLink(7, 'accepted')];
    api.outgoingData = [testLink(7, 'accepted', incoming: false)];
    await state.refresh();
    api.onAccepted = () async => throw const ApiFailure(ApiFailureKind.network);
    api.onOutgoing = () async => throw const ApiFailure(ApiFailureKind.network);
    final result = await state.revokeRelationship(7);
    expect(result.succeeded, isTrue);
    expect(state.accepted.items, isEmpty);
    expect(state.outgoing.items.single.status, ContactLinkStatus.revoked);
  });

  for (final kind in [
    ApiFailureKind.validation,
    ApiFailureKind.conflict,
    ApiFailureKind.notFound
  ]) {
    test(
        'write failure $kind is distinct and never optimistically changes status',
        () async {
      api.incomingData = [testLink(7, 'pending')];
      await state.loadIncomingInvitations();
      api.onRespond = (_, __) async => throw ApiFailure(kind);
      final result = await state.rejectInvitation(7);
      expect(result.outcome, ContactLinkMutationOutcome.failed);
      expect(result.error!.kind, kind);
      expect(state.mutationFor(7).error!.kind, kind);
      expect(state.incoming.items.single.status, ContactLinkStatus.pending);
      expect(state.mutationFor(7).isLoading, isFalse);
      expect(api.outgoingCalls, kind == ApiFailureKind.validation ? 0 : 1);
    });
  }

  for (final kind in [
    ApiFailureKind.authentication,
    ApiFailureKind.forbidden
  ]) {
    test('mutation access failure $kind blocks the feature without refreshing',
        () async {
      api.onSend = (_) async => throw ApiFailure(kind);
      final result = await state.sendInvitation('member@example.invalid');
      expect(result.error!.kind, kind);
      expect(state.accessFailure!.kind, kind);
      expect(api.incomingCalls + api.outgoingCalls + api.acceptedCalls, 0);
    });
    test('successful write followed by $kind refresh failure stays successful',
        () async {
      api.onIncoming = () async => throw ApiFailure(kind);
      final result = await state.sendInvitation('member@example.invalid');
      expect(result.succeeded, isTrue);
      expect(result.link!.id, 7);
      expect(result.refreshError!.kind, kind);
      expect(state.isAccessBlocked, isTrue);
    });
  }

  test('different records may mutate concurrently; the same record cannot',
      () async {
    final first = Completer<ContactLink>();
    final second = Completer<ContactLink>();
    api.onRespond = (id, _) => id == 7 ? first.future : second.future;
    final a = state.acceptInvitation(7);
    final b = state.rejectInvitation(8);
    expect(state.mutationFor(7).isLoading, isTrue);
    expect(state.mutationFor(8).isLoading, isTrue);
    expect((await state.revokeRelationship(7)).outcome,
        ContactLinkMutationOutcome.blocked);
    expect(api.revocations, isEmpty);
    first.complete(testLink(7, 'accepted'));
    second.complete(testLink(8, 'rejected'));
    final results = await Future.wait([a, b]);
    expect(results.every((result) => result.succeeded), isTrue);
    expect(api.responses.length, 2);
    expect(state.mutations.values.every((value) => !value.isLoading), isTrue);
  });

  test('reads started before confirmation cannot resurrect a revoked link',
      () async {
    final old = Completer<List<ContactLink>>();
    api.onAccepted =
        () => api.acceptedCalls == 1 ? old.future : Future.value([]);
    final read = state.loadAcceptedRelationships();
    expect((await state.revokeRelationship(7)).succeeded, isTrue);
    old.complete([testLink(7, 'accepted')]);
    expect(await read, isFalse);
    expect(state.accepted.items, isEmpty);
  });

  for (final kind in [
    ApiFailureKind.timeout,
    ApiFailureKind.network,
    ApiFailureKind.invalidResponse,
    ApiFailureKind.server,
    ApiFailureKind.unexpected
  ]) {
    test('uncertain $kind write is gated until authoritative recovery succeeds',
        () async {
      api.onRespond = (_, __) async => throw ApiFailure(kind);
      api.onAccepted =
          () async => throw const ApiFailure(ApiFailureKind.network);
      final result = await state.acceptInvitation(7);
      expect(result.outcome, ContactLinkMutationOutcome.uncertain);
      expect(result.error!.kind, kind);
      expect(result.refreshError!.kind, ApiFailureKind.network);
      expect(state.mutationFor(7).requiresRefresh, isTrue);
      expect((await state.acceptInvitation(7)).outcome,
          ContactLinkMutationOutcome.blocked);
      expect(api.responses, hasLength(1));
      api.onAccepted = null;
      api.acceptedData = [testLink(7, 'accepted')];
      expect((await state.refresh()).succeeded, isTrue);
      expect(state.mutationFor(7).requiresRefresh, isFalse);
      expect(state.mutationFor(7).error!.kind, kind);
      expect((await state.acceptInvitation(7)).outcome,
          ContactLinkMutationOutcome.blocked);
      expect(api.responses, hasLength(1));
    });
  }

  test('timeout with successful automatic refresh permits a deliberate retry',
      () async {
    api.onRespond =
        (_, __) async => throw const ApiFailure(ApiFailureKind.timeout);
    final result = await state.acceptInvitation(7);
    expect(result.outcome, ContactLinkMutationOutcome.uncertain);
    expect(result.refreshSucceeded, isTrue);
    expect(state.mutationFor(7).requiresRefresh, isFalse);
    expect(api.responses, hasLength(1));
    api.onRespond = null;
    expect((await state.acceptInvitation(7)).succeeded, isTrue);
    expect(api.responses, hasLength(2));
  });

  test('uncertain send blocks repeated invitations until refreshed', () async {
    api.onSend = (_) async => throw const ApiFailure(ApiFailureKind.timeout);
    api.onOutgoing = () async => throw const ApiFailure(ApiFailureKind.network);
    await state.sendInvitation('member@example.invalid');
    expect(state.invitation.requiresRefresh, isTrue);
    expect((await state.sendInvitation('another@example.invalid')).outcome,
        ContactLinkMutationOutcome.blocked);
    expect(api.sendCalls, 1);
    api.onOutgoing = null;
    api.outgoingData = [testLink(7, 'pending', incoming: false)];
    await state.refresh();
    expect(state.invitation.requiresRefresh, isFalse);
    expect((await state.sendInvitation('member@example.invalid')).outcome,
        ContactLinkMutationOutcome.blocked);
    expect(api.sendCalls, 1);
  });

  test('a refresh started before a timeout cannot release its recovery gate',
      () async {
    final old = Completer<List<ContactLink>>();
    api.onAccepted = () => api.acceptedCalls == 1
        ? old.future
        : Future.error(const ApiFailure(ApiFailureKind.network));
    final preTimeoutRefresh = state.refresh();
    api.onRespond =
        (_, __) async => throw const ApiFailure(ApiFailureKind.timeout);
    await state.acceptInvitation(7);
    expect(state.mutationFor(7).requiresRefresh, isTrue);
    old.complete([]);
    expect((await preTimeoutRefresh).succeeded, isFalse);
    expect(state.mutationFor(7).requiresRefresh, isTrue);
    expect((await state.rejectInvitation(7)).outcome,
        ContactLinkMutationOutcome.blocked);
  });

  test('unknown internal exceptions never enter displayed error state',
      () async {
    api.onSend = (_) async => throw StateError('synthetic-private-detail');
    final result = await state.sendInvitation('member@example.invalid');
    expect(result.error!.kind, ApiFailureKind.unexpected);
    expect(
        result.error.toString(), isNot(contains('synthetic-private-detail')));
  });

  test('unexpected confirmed status requires reconciliation, not acceptance',
      () async {
    api.onRespond = (_, __) async => testLink(7, 'future-status');
    final result = await state.acceptInvitation(7);
    expect(result.outcome, ContactLinkMutationOutcome.uncertain);
    expect(result.error!.kind, ApiFailureKind.invalidResponse);
    expect(state.accepted.items, isEmpty);
  });

  for (final transition in ['logout', 'account', 'dispose', 'reset']) {
    test(
        '$transition discards pending searches, lists, mutations, and notifications',
        () async {
      final search = Completer<List<RegisteredUser>>();
      final list = Completer<List<ContactLink>>();
      final write = Completer<ContactLink>();
      api.onSearch = (_) => search.future;
      api.onIncoming = () => list.future;
      api.onSend = (_) => write.future;
      final a = state.searchRegisteredUsers('member@example.invalid');
      final b = state.loadIncomingInvitations();
      final c = state.sendInvitation('member@example.invalid');
      var notifications = 0;
      state.addListener(() => notifications++);
      switch (transition) {
        case 'logout':
          state.setSession(null);
        case 'account':
          state.setSession('bob');
        case 'dispose':
          state.dispose();
        case 'reset':
          state.reset();
      }
      final afterTransition = notifications;
      search.complete(api.searchData);
      list.complete([testLink(7, 'pending')]);
      write.complete(testLink(7, 'pending', incoming: false));
      expect(await a, isFalse);
      expect(await b, isFalse);
      expect((await c).outcome, ContactLinkMutationOutcome.stale);
      expect(notifications, afterTransition);
      expect(state.search.items, isEmpty);
      expect(state.incoming.items, isEmpty);
      expect(state.outgoing.items, isEmpty);
      expect(state.invitation.confirmed, isNull);
      expect(api.outgoingCalls, 0);
    });
  }

  test('old completions cannot clear a new account mutation lock', () async {
    final first = Completer<ContactLink>();
    final second = Completer<ContactLink>();
    api.onRespond =
        (_, __) => api.responses.length == 1 ? first.future : second.future;
    final old = state.acceptInvitation(7);
    state.setSession('bob');
    final current = state.rejectInvitation(7);
    first.complete(testLink(7, 'accepted'));
    expect((await old).outcome, ContactLinkMutationOutcome.stale);
    expect(state.mutationFor(7).isLoading, isTrue);
    second.complete(testLink(7, 'rejected'));
    expect((await current).succeeded, isTrue);
    expect(state.mutationFor(7).isLoading, isFalse);
  });

  test('no new requests or notifications occur after disposal', () async {
    state.dispose();
    expect(
        await state.searchRegisteredUsers('member@example.invalid'), isFalse);
    expect(await state.loadIncomingInvitations(), isFalse);
    expect((await state.refresh()).succeeded, isFalse);
    expect((await state.sendInvitation('member@example.invalid')).outcome,
        ContactLinkMutationOutcome.stale);
    state.reset();
    state.setSession('bob');
    expect(api.searchCalls + api.incomingCalls + api.sendCalls, 0);
  });

  test('signed-out operations fail safely without requests', () async {
    state.setSession(null);
    expect(state.needsAuthentication, isTrue);
    expect(await state.loadIncomingInvitations(), isFalse);
    expect(state.incoming.error!.kind, ApiFailureKind.authentication);
    expect((await state.sendInvitation('member@example.invalid')).error!.kind,
        ApiFailureKind.authentication);
    expect(api.incomingCalls + api.sendCalls, 0);
  });

  test('same owner preserves data and terminal or unknown rows cannot mutate',
      () async {
    api.outgoingData = [
      testLink(7, 'rejected'),
      testLink(8, 'revoked'),
      testLink(9, 'future')
    ];
    await state.loadOutgoingInvitations();
    state.setSession('alice');
    expect(state.outgoing.items, hasLength(3));
    for (final id in [7, 8, 9]) {
      expect((await state.acceptInvitation(id)).outcome,
          ContactLinkMutationOutcome.blocked);
      expect((await state.rejectInvitation(id)).outcome,
          ContactLinkMutationOutcome.blocked);
      expect((await state.revokeRelationship(id)).outcome,
          ContactLinkMutationOutcome.blocked);
    }
    expect(api.responses, isEmpty);
    expect(api.revocations, isEmpty);
  });

  test(
      'listener account changes cannot dispatch an old mutation as the new account',
      () async {
    state.addListener(() {
      if (state.invitation.isLoading) state.setSession('bob');
    });
    expect((await state.sendInvitation('member@example.invalid')).outcome,
        ContactLinkMutationOutcome.stale);
    expect(api.sendCalls, 0);
  });

  test('account changes during refresh notification stop the remaining reads',
      () async {
    state.addListener(() {
      if (state.incoming.isLoading) state.setSession('bob');
    });
    expect((await state.refresh()).succeeded, isFalse);
    expect(api.incomingCalls + api.outgoingCalls + api.acceptedCalls, 0);
    expect(state.userId, 'bob');
  });

  test(
      'logout during confirmation notification cannot start a new-session refresh',
      () async {
    state.addListener(() {
      if (state.invitation.confirmed != null) state.setSession(null);
    });
    expect((await state.sendInvitation('member@example.invalid')).outcome,
        ContactLinkMutationOutcome.stale);
    expect(api.sendCalls, 1);
    expect(api.incomingCalls + api.outgoingCalls + api.acceptedCalls, 0);
    expect(state.invitation.confirmed, isNull);
  });

  test('a superseded recovery cannot overwrite a newer successful recovery',
      () async {
    final old = Completer<List<ContactLink>>();
    api.onIncoming =
        () => api.incomingCalls == 1 ? old.future : Future.value([]);
    api.onRespond =
        (_, __) async => throw const ApiFailure(ApiFailureKind.timeout);
    final mutation = state.acceptInvitation(7);
    await flush();
    expect(state.mutationFor(7).requiresRefresh, isTrue);
    expect((await state.refresh()).succeeded, isTrue);
    expect(state.mutationFor(7).requiresRefresh, isFalse);
    expect(state.mutationFor(7).refreshSucceeded, isTrue);
    old.completeError(const ApiFailure(ApiFailureKind.network));
    final result = await mutation;
    expect(result.outcome, ContactLinkMutationOutcome.uncertain);
    expect(result.refreshSucceeded, isTrue);
    expect(result.refreshError, isNull);
    expect(state.mutationFor(7).refreshSucceeded, isTrue);
    expect(state.mutationFor(7).requiresRefresh, isFalse);
  });

  test('logout during follow-up refresh discards a confirmed result', () async {
    final refresh = Completer<List<ContactLink>>();
    api.onOutgoing = () => refresh.future;
    final mutation = state.sendInvitation('member@example.invalid');
    await flush();
    expect(state.invitation.confirmed, isNotNull);
    state.setSession(null);
    refresh.complete([testLink(7, 'pending', incoming: false)]);
    final result = await mutation;
    expect(result.outcome, ContactLinkMutationOutcome.stale);
    expect(result.link, isNull);
    expect(state.outgoing.items, isEmpty);
  });

  test('logout on final notification never returns another sessions identity',
      () async {
    state.addListener(() {
      if (!state.invitation.isLoading && state.invitation.confirmed != null) {
        state.setSession('bob');
      }
    });
    final result = await state.sendInvitation('member@example.invalid');
    expect(result.outcome, ContactLinkMutationOutcome.stale);
    expect(result.link, isNull);
    expect(state.userId, 'bob');
    expect(state.outgoing.items, isEmpty);
  });

  test(
      'logout on list completion makes the result stale as well as clearing data',
      () async {
    api.incomingData = [testLink(7, 'pending')];
    state.addListener(() {
      if (state.incoming.hasLoaded) state.setSession(null);
    });
    expect(await state.loadIncomingInvitations(), isFalse);
    expect(state.incoming.items, isEmpty);
  });
}
