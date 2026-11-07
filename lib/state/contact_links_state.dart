import 'package:flutter/foundation.dart';

import '../models/contact_link.dart';
import '../models/registered_user.dart';
import '../services/api_failure.dart';
import '../services/api_service.dart';

/// Immutable resource snapshot. A failed refresh retains the last loaded data.
class ContactLinksLoadState<T> {
  ContactLinksLoadState({
    List<T> items = const [],
    this.isLoading = false,
    this.hasLoaded = false,
    this.error,
  }) : items = List.unmodifiable(items);

  final List<T> items;
  final bool isLoading;
  final bool hasLoaded;
  final ApiFailure? error;
}

enum ContactLinkMutationOutcome { succeeded, failed, uncertain, blocked, stale }

class ContactLinkMutationResult {
  const ContactLinkMutationResult(
    this.outcome, {
    this.link,
    this.error,
    this.refreshError,
    this.refreshSucceeded = false,
  });

  final ContactLinkMutationOutcome outcome;
  final ContactLink? link;
  final ApiFailure? error;
  final ApiFailure? refreshError;
  final bool refreshSucceeded;
  bool get succeeded => outcome == ContactLinkMutationOutcome.succeeded;
}

class ContactLinkMutationState {
  const ContactLinkMutationState({
    this.isLoading = false,
    this.error,
    this.refreshError,
    this.confirmed,
    this.requiresRefresh = false,
    this.refreshSucceeded,
  });

  final bool isLoading;
  final ApiFailure? error;
  final ApiFailure? refreshError;
  final ContactLink? confirmed;
  final bool requiresRefresh;
  final bool? refreshSucceeded;

  ContactLinkMutationState _finishRefresh(ContactLinksRefreshResult result) {
    if (result.superseded) return this;
    return ContactLinkMutationState(
      isLoading: isLoading,
      error: error,
      confirmed: confirmed,
      requiresRefresh: requiresRefresh && !result.succeeded,
      refreshError: result.error,
      refreshSucceeded: result.succeeded,
    );
  }

  ContactLinkMutationState _idle() => ContactLinkMutationState(
        error: error,
        refreshError: refreshError,
        confirmed: confirmed,
        requiresRefresh: requiresRefresh,
        refreshSucceeded: refreshSucceeded,
      );
}

class ContactLinksRefreshResult {
  const ContactLinksRefreshResult({
    required this.succeeded,
    this.error,
    this.superseded = false,
  });

  final bool succeeded;
  final ApiFailure? error;
  final bool superseded;
}

enum _ListKind { incoming, outgoing, accepted }

enum _MutationKind { send, accept, reject, revoke }

/// Session-scoped relationship data. Firebase UIDs identify cache ownership,
/// never backend participant IDs. Authorization remains with the API.
class ContactLinksState extends ChangeNotifier {
  ContactLinksState({required ApiService apiService}) : _api = apiService;

  final ApiService _api;
  String? _userId;
  bool _disposed = false;
  int _generation = 0;
  int _sessionGeneration = 0;
  int _searchVersion = 0;
  int _operationVersion = 0;
  int _sendToken = 0;
  bool _accessRecovering = false;
  final _versions = {for (final kind in _ListKind.values) kind: 0};
  final Map<int, int> _mutationTokens = {};
  final Map<int, ContactLinkMutationState> _mutations = {};
  var _search = ContactLinksLoadState<RegisteredUser>();
  var _incoming = ContactLinksLoadState<ContactLink>();
  var _outgoing = ContactLinksLoadState<ContactLink>();
  var _accepted = ContactLinksLoadState<ContactLink>();
  var _invitation = const ContactLinkMutationState();
  String _searchEmail = '';
  String? _invitationEmail;
  ApiFailure? _accessFailure;

  String? get userId => _userId;
  String get searchEmail => _searchEmail;
  String? get invitationEmail => _invitationEmail;
  ContactLinksLoadState<RegisteredUser> get search => _search;
  ContactLinksLoadState<ContactLink> get incoming => _incoming;
  ContactLinksLoadState<ContactLink> get outgoing => _outgoing;
  ContactLinksLoadState<ContactLink> get accepted => _accepted;
  ContactLinkMutationState get invitation => _invitation;
  Map<int, ContactLinkMutationState> get mutations =>
      Map.unmodifiable(_mutations);
  ApiFailure? get accessFailure => _accessFailure;
  bool get needsAuthentication =>
      _userId == null || _accessFailure?.kind == ApiFailureKind.authentication;
  bool get needsBackendProfile =>
      _accessFailure?.kind == ApiFailureKind.forbidden;
  bool get isAccessBlocked =>
      _userId == null || _accessFailure != null || _accessRecovering;

  ContactLinkMutationState mutationFor(int linkId) =>
      _mutations[linkId] ?? const ContactLinkMutationState();

  /// Called by AppState on every account transition. Does not start HTTP calls.
  void setSession(String? userId) {
    if (_disposed) return;
    final owner = userId == null || userId.isEmpty ? null : userId;
    if (_userId == owner) return;
    _userId = owner;
    _sessionGeneration++;
    _clear();
    notifyListeners();
  }

  void reset() {
    if (_disposed) return;
    _sessionGeneration++;
    _clear();
    notifyListeners();
  }

  void _clear() {
    _generation++;
    _searchVersion++;
    for (final kind in _ListKind.values) {
      _versions[kind] = _versions[kind]! + 1;
    }
    _search = ContactLinksLoadState();
    _incoming = ContactLinksLoadState();
    _outgoing = ContactLinksLoadState();
    _accepted = ContactLinksLoadState();
    _invitation = const ContactLinkMutationState();
    _mutations.clear();
    _mutationTokens.clear();
    _searchEmail = '';
    _invitationEmail = null;
    _accessFailure = null;
    _accessRecovering = false;
  }

  bool _current(int generation) => !_disposed && _generation == generation;

  ApiFailure? get _readFailure => _userId == null
      ? const ApiFailure(ApiFailureKind.authentication)
      : _accessFailure;

  static ApiFailure _failure(Object error) =>
      error is ApiFailure ? error : const ApiFailure(ApiFailureKind.unexpected);

  bool _blockAccess(ApiFailure failure) {
    if (failure.kind != ApiFailureKind.authentication &&
        failure.kind != ApiFailureKind.forbidden) {
      return false;
    }
    _clear();
    _accessFailure = failure;
    _search = ContactLinksLoadState(error: failure);
    _incoming = ContactLinksLoadState(error: failure);
    _outgoing = ContactLinksLoadState(error: failure);
    _accepted = ContactLinksLoadState(error: failure);
    notifyListeners();
    return true;
  }

  /// Explicit read-only recovery after sign-in/profile repair. Mutations stay
  /// disabled until all three relationship lists have been read successfully.
  Future<ContactLinksRefreshResult> retryAccess() async {
    if (_disposed || _userId == null) {
      return const ContactLinksRefreshResult(
        succeeded: false,
        error: ApiFailure(ApiFailureKind.authentication),
      );
    }
    _accessFailure = null;
    _accessRecovering = true;
    final generation = _generation;
    notifyListeners();
    if (!_current(generation)) {
      return const ContactLinksRefreshResult(
          succeeded: false, superseded: true);
    }
    final result = await refresh();
    if (_current(generation) && result.succeeded) {
      _accessRecovering = false;
      notifyListeners();
    }
    return result;
  }

  /// Invalidates a displayed match immediately when the user edits the field.
  void setSearchEmail(String email) {
    if (_disposed || _searchEmail == email.trim()) return;
    _searchEmail = email.trim();
    _searchVersion++;
    _search = ContactLinksLoadState();
    notifyListeners();
  }

  Future<bool> searchRegisteredUsers(String email) async {
    if (_disposed) return false;
    final generation = _generation;
    setSearchEmail(email);
    if (!_current(generation)) return false;
    final version = ++_searchVersion;
    final previous = _search;
    final failure = _readFailure;
    if (failure != null) {
      _search = ContactLinksLoadState(error: failure);
      notifyListeners();
      return false;
    }
    _search = ContactLinksLoadState(
      items: previous.items,
      hasLoaded: previous.hasLoaded,
      isLoading: true,
    );
    notifyListeners();
    try {
      if (!_current(generation) || version != _searchVersion) return false;
      final users = await _api.searchRegisteredUsers(email: _searchEmail);
      if (!_current(generation) || version != _searchVersion) return false;
      _search = ContactLinksLoadState(items: users, hasLoaded: true);
      notifyListeners();
      return _current(generation) && version == _searchVersion;
    } catch (error) {
      if (!_current(generation) || version != _searchVersion) return false;
      final failure = _failure(error);
      if (!_blockAccess(failure)) {
        _search = ContactLinksLoadState(
          items: previous.items,
          hasLoaded: previous.hasLoaded,
          error: failure,
        );
        notifyListeners();
      }
      return false;
    }
  }

  ContactLinksLoadState<ContactLink> _list(_ListKind kind) => switch (kind) {
        _ListKind.incoming => _incoming,
        _ListKind.outgoing => _outgoing,
        _ListKind.accepted => _accepted,
      };

  void _setList(_ListKind kind, ContactLinksLoadState<ContactLink> value) {
    switch (kind) {
      case _ListKind.incoming:
        _incoming = value;
      case _ListKind.outgoing:
        _outgoing = value;
      case _ListKind.accepted:
        _accepted = value;
    }
  }

  Future<bool> loadIncomingInvitations() => _load(_ListKind.incoming);
  Future<bool> loadOutgoingInvitations() => _load(_ListKind.outgoing);
  Future<bool> loadAcceptedRelationships() => _load(_ListKind.accepted);

  Future<bool> _load(_ListKind kind) async {
    if (_disposed) return false;
    final generation = _generation;
    final version = _versions[kind]! + 1;
    _versions[kind] = version;
    final previous = _list(kind);
    final failure = _readFailure;
    if (failure != null) {
      _setList(kind, ContactLinksLoadState(error: failure));
      notifyListeners();
      return false;
    }
    _setList(
        kind,
        ContactLinksLoadState(
          items: previous.items,
          hasLoaded: previous.hasLoaded,
          isLoading: true,
        ));
    notifyListeners();
    try {
      if (!_current(generation) || _versions[kind] != version) return false;
      final links = await switch (kind) {
        _ListKind.incoming => _api.fetchIncomingInvitations(),
        _ListKind.outgoing => _api.fetchOutgoingInvitations(),
        _ListKind.accepted => _api.fetchContactRelationships(),
      };
      if (!_current(generation) || _versions[kind] != version) return false;
      final filtered = links
          .where((link) => switch (kind) {
                _ListKind.incoming => link.status == ContactLinkStatus.pending,
                _ListKind.outgoing => true,
                _ListKind.accepted => link.isAccepted,
              })
          .toList();
      _setList(kind, ContactLinksLoadState(items: filtered, hasLoaded: true));
      notifyListeners();
      return _current(generation) && _versions[kind] == version;
    } catch (error) {
      if (!_current(generation) || _versions[kind] != version) return false;
      final failure = _failure(error);
      if (!_blockAccess(failure)) {
        _setList(
            kind,
            ContactLinksLoadState(
              items: previous.items,
              hasLoaded: previous.hasLoaded,
              error: failure,
            ));
        notifyListeners();
      }
      return false;
    }
  }

  /// Only gates already pending when this refresh started may be released.
  /// A read initiated before a timed-out mutation cannot authorize a retry.
  Future<ContactLinksRefreshResult> refresh() async {
    if (_disposed) {
      return const ContactLinksRefreshResult(
          succeeded: false, superseded: true);
    }
    final generation = _generation;
    final recoveryTokens = {
      for (final entry in _mutations.entries)
        if (entry.value.requiresRefresh) entry.key: _mutationTokens[entry.key],
    };
    final sendRecovery = _invitation.requiresRefresh ? _sendToken : null;
    final loaded = await Future.wait(_ListKind.values.map(
        (kind) => _current(generation) ? _load(kind) : Future.value(false)));
    if (!_current(generation)) {
      return const ContactLinksRefreshResult(
          succeeded: false, superseded: true);
    }
    ApiFailure? error;
    for (final kind in _ListKind.values) {
      error ??= _list(kind).error;
    }
    final succeeded = loaded.every((value) => value);
    final result = ContactLinksRefreshResult(
      succeeded: succeeded,
      error: error,
      superseded: !succeeded && error == null,
    );
    for (final entry in recoveryTokens.entries) {
      if (_mutationTokens[entry.key] == entry.value) {
        _mutations[entry.key] = mutationFor(entry.key)._finishRefresh(result);
      }
    }
    if (sendRecovery != null && _sendToken == sendRecovery) {
      _invitation = _invitation._finishRefresh(result);
    }
    notifyListeners();
    return _current(generation)
        ? result
        : const ContactLinksRefreshResult(succeeded: false, superseded: true);
  }

  Future<ContactLinkMutationResult> sendInvitation(String email) =>
      _mutate(_MutationKind.send, email: email.trim());
  Future<ContactLinkMutationResult> acceptInvitation(int linkId) =>
      _mutate(_MutationKind.accept, linkId: linkId);
  Future<ContactLinkMutationResult> rejectInvitation(int linkId) =>
      _mutate(_MutationKind.reject, linkId: linkId);
  Future<ContactLinkMutationResult> revokeRelationship(int linkId) =>
      _mutate(_MutationKind.revoke, linkId: linkId);

  bool _activeEmail(String email) => [
        ..._incoming.items,
        ..._outgoing.items,
        ..._accepted.items,
      ].any((link) =>
          link.isActive &&
          link.otherUser?.email.toLowerCase() == email.toLowerCase());

  ContactLink? _knownLink(int id) {
    for (final link in [
      ..._incoming.items,
      ..._outgoing.items,
      ..._accepted.items
    ]) {
      if (link.id == id) return link;
    }
    return null;
  }

  Future<ContactLinkMutationResult> _mutate(_MutationKind kind,
      {int? linkId, String? email}) async {
    if (_disposed) {
      return const ContactLinkMutationResult(ContactLinkMutationOutcome.stale);
    }
    final sending = kind == _MutationKind.send;
    final existing = sending ? _invitation : mutationFor(linkId!);
    if (existing.isLoading || existing.requiresRefresh || _accessRecovering) {
      return const ContactLinkMutationResult(
          ContactLinkMutationOutcome.blocked);
    }
    final failure = _readFailure;
    if (failure != null) {
      return ContactLinkMutationResult(ContactLinkMutationOutcome.failed,
          error: failure);
    }
    final known = sending ? null : _knownLink(linkId!);
    if ((sending && _activeEmail(email!)) ||
        (!sending &&
            known != null &&
            (kind == _MutationKind.revoke
                ? !known.isActive
                : known.status != ContactLinkStatus.pending))) {
      return const ContactLinkMutationResult(
        ContactLinkMutationOutcome.blocked,
        error: ApiFailure(ApiFailureKind.conflict),
      );
    }
    final generation = _generation;
    final session = _sessionGeneration;
    final token = ++_operationVersion;
    if (sending) {
      _sendToken = token;
      _invitationEmail = email;
    } else {
      _mutationTokens[linkId!] = token;
    }
    bool current() =>
        _current(generation) &&
        (sending ? _sendToken == token : _mutationTokens[linkId] == token);
    ContactLinkMutationState value() =>
        sending ? _invitation : mutationFor(linkId!);
    void setValue(ContactLinkMutationState state) {
      if (sending) {
        _invitation = state;
      } else {
        _mutations[linkId!] = state;
      }
    }

    setValue(const ContactLinkMutationState(isLoading: true));
    notifyListeners();
    try {
      if (!current()) {
        return const ContactLinkMutationResult(
            ContactLinkMutationOutcome.stale);
      }
      final link = await switch (kind) {
        _MutationKind.send => _api.sendContactInvitation(email: email!),
        _MutationKind.accept => _api.respondToContactInvitation(
            linkId: linkId!, action: ContactInvitationAction.accept),
        _MutationKind.reject => _api.respondToContactInvitation(
            linkId: linkId!, action: ContactInvitationAction.reject),
        _MutationKind.revoke => _api.revokeContactRelationship(linkId: linkId!),
      };
      if (!current()) {
        return const ContactLinkMutationResult(
            ContactLinkMutationOutcome.stale);
      }
      final expectedStatus = switch (kind) {
        _MutationKind.send => ContactLinkStatus.pending,
        _MutationKind.accept => ContactLinkStatus.accepted,
        _MutationKind.reject => ContactLinkStatus.rejected,
        _MutationKind.revoke => ContactLinkStatus.revoked,
      };
      if ((!sending && link.id != linkId) || link.status != expectedStatus) {
        throw const ApiFailure(ApiFailureKind.invalidResponse);
      }
      _applyConfirmed(link, kind);
      setValue(ContactLinkMutationState(isLoading: true, confirmed: link));
      notifyListeners();
      if (!current()) {
        return const ContactLinkMutationResult(
            ContactLinkMutationOutcome.stale);
      }
      final refreshed = await refresh();
      if (!current()) {
        if (!_disposed &&
            _sessionGeneration == session &&
            _accessFailure != null) {
          return ContactLinkMutationResult(
            ContactLinkMutationOutcome.succeeded,
            link: link,
            refreshError: _accessFailure,
          );
        }
        return const ContactLinkMutationResult(
            ContactLinkMutationOutcome.stale);
      }
      setValue(value()._finishRefresh(refreshed)._idle());
      notifyListeners();
      if (!current()) {
        return const ContactLinkMutationResult(
            ContactLinkMutationOutcome.stale);
      }
      return ContactLinkMutationResult(
        ContactLinkMutationOutcome.succeeded,
        link: link,
        refreshError: value().refreshError,
        refreshSucceeded: value().refreshSucceeded ?? false,
      );
    } catch (error) {
      if (!current()) {
        return const ContactLinkMutationResult(
            ContactLinkMutationOutcome.stale);
      }
      final failure = _failure(error);
      if (_blockAccess(failure)) {
        return ContactLinkMutationResult(ContactLinkMutationOutcome.failed,
            error: failure);
      }
      final uncertain = switch (failure.kind) {
        ApiFailureKind.timeout ||
        ApiFailureKind.network ||
        ApiFailureKind.invalidResponse ||
        ApiFailureKind.server ||
        ApiFailureKind.unexpected =>
          true,
        _ => false,
      };
      final reconcile = uncertain ||
          failure.kind == ApiFailureKind.conflict ||
          failure.kind == ApiFailureKind.notFound;
      setValue(ContactLinkMutationState(
        isLoading: reconcile,
        error: failure,
        requiresRefresh: uncertain,
      ));
      if (reconcile) _invalidateLists();
      notifyListeners();
      if (!current()) {
        return const ContactLinkMutationResult(
            ContactLinkMutationOutcome.stale);
      }
      final refreshed = reconcile ? await refresh() : null;
      if (!current()) {
        if (!_disposed &&
            _sessionGeneration == session &&
            _accessFailure != null) {
          return ContactLinkMutationResult(
            uncertain
                ? ContactLinkMutationOutcome.uncertain
                : ContactLinkMutationOutcome.failed,
            error: failure,
            refreshError: _accessFailure,
          );
        }
        return const ContactLinkMutationResult(
            ContactLinkMutationOutcome.stale);
      }
      if (refreshed != null) {
        setValue(value()._finishRefresh(refreshed)._idle());
      }
      notifyListeners();
      if (!current()) {
        return const ContactLinkMutationResult(
            ContactLinkMutationOutcome.stale);
      }
      return ContactLinkMutationResult(
        uncertain
            ? ContactLinkMutationOutcome.uncertain
            : ContactLinkMutationOutcome.failed,
        error: failure,
        refreshError: value().refreshError,
        refreshSucceeded: value().refreshSucceeded ?? false,
      );
    }
  }

  void _invalidateLists() {
    for (final kind in _ListKind.values) {
      _versions[kind] = _versions[kind]! + 1;
      final old = _list(kind);
      _setList(
          kind,
          ContactLinksLoadState(
            items: old.items,
            hasLoaded: old.hasLoaded,
            error: old.error,
          ));
    }
  }

  void _applyConfirmed(ContactLink link, _MutationKind kind) {
    _invalidateLists();
    for (final listKind in _ListKind.values) {
      final old = _list(listKind);
      final hadLink = old.items.any((item) => item.id == link.id);
      final items = old.items.where((item) => item.id != link.id).toList();
      final include = switch (listKind) {
        _ListKind.incoming =>
          hadLink && link.status == ContactLinkStatus.pending,
        _ListKind.outgoing => hadLink || kind == _MutationKind.send,
        _ListKind.accepted => link.isAccepted,
      };
      if (include) items.add(link);
      items.sort((a, b) {
        final order = listKind == _ListKind.accepted
            ? b.updatedAt.compareTo(a.updatedAt)
            : b.createdAt.compareTo(a.createdAt);
        return order == 0 ? b.id.compareTo(a.id) : order;
      });
      _setList(
          listKind,
          ContactLinksLoadState(
            items: items,
            hasLoaded: old.hasLoaded,
            error: old.error,
          ));
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _sessionGeneration++;
    _userId = null;
    _clear();
    super.dispose();
  }
}
