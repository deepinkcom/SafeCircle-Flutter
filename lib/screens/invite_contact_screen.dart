import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/registered_user.dart';
import '../state/contact_links_state.dart';
import '../widgets/contact_links_feedback.dart';

class InviteContactScreen extends StatefulWidget {
  const InviteContactScreen(
      {super.key, required this.onSignIn, required this.onCompleteProfile});
  final Future<void> Function() onSignIn;
  final Future<void> Function() onCompleteProfile;

  @override
  State<InviteContactScreen> createState() => _InviteContactScreenState();
}

class _InviteContactScreenState extends State<InviteContactScreen> {
  final _email = TextEditingController();
  final _form = GlobalKey<FormState>();
  late final ContactLinksState _state;
  String? _owner;
  String? _feedback;
  bool _success = false;
  bool _uncertain = false;

  @override
  void initState() {
    super.initState();
    _state = context.read<ContactLinksState>();
    _owner = _state.userId;
    _state.addListener(_sessionChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _state.setSearchEmail('');
        _state.refresh();
      }
    });
  }

  void _sessionChanged() {
    if (_owner == _state.userId) return;
    _owner = _state.userId;
    _email.clear();
    if (mounted) {
      setState(() {
        _feedback = null;
        _success = false;
        _uncertain = false;
      });
    }
  }

  @override
  void dispose() {
    _state.removeListener(_sessionChanged);
    _email.dispose();
    super.dispose();
  }

  String? _validate(String? value) {
    final email = value?.trim() ?? '';
    return email.length >= 3 &&
            email.length <= 255 &&
            RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email)
        ? null
        : 'Enter a complete email address.';
  }

  Future<void> _search() async {
    if (_state.isAccessBlocked ||
        _state.search.isLoading ||
        _state.invitation.isLoading) {
      return;
    }
    if (!_form.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _feedback = null;
      _success = false;
      _uncertain = false;
    });
    await _state.searchRegisteredUsers(_email.text);
  }

  Future<void> _send(RegisteredUser user, String? owner) async {
    if (owner == null ||
        owner != _state.userId ||
        _state.invitation.isLoading ||
        _state.isAccessBlocked ||
        _state.invitation.requiresRefresh ||
        _state.searchEmail != _email.text.trim() ||
        !_state.search.items
            .any((candidate) => candidate.email == user.email)) {
      return;
    }
    final query = _state.searchEmail;
    final result = await _state.sendInvitation(user.email);
    if (!mounted ||
        owner != _state.userId ||
        query != _state.searchEmail ||
        result.outcome == ContactLinkMutationOutcome.stale) {
      return;
    }
    setState(() {
      _feedback = contactLinkActionMessage(result, 'Invitation sent.');
      _success = result.succeeded;
      _uncertain = result.outcome == ContactLinkMutationOutcome.uncertain;
    });
  }

  Future<void> _refresh() async {
    final session = _state.sessionVersion;
    final refreshed = await _state.refresh();
    if (mounted &&
        session == _state.sessionVersion &&
        refreshed.succeeded &&
        _uncertain) {
      setState(() => _feedback =
          'Connections refreshed. Check their status before trying again.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<ContactLinksState>();
    final queryMatches = state.searchEmail == _email.text.trim();
    final search = state.search;
    final invitation = state.invitation;
    final busy = search.isLoading || invitation.isLoading;
    final owner = state.userId;
    return Scaffold(
      appBar: AppBar(
          toolbarHeight: 72, title: const Text('Invite by email', maxLines: 2)),
      body: SafeArea(
          child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: ListView(
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  padding: const EdgeInsets.all(20),
                  children: [
                    const Text(
                        'Find a registered SafeCircle user using their complete email address.'),
                    const SizedBox(height: 16),
                    if (state.isAccessBlocked)
                      ContactLinksAccessPanel(
                          state: state,
                          onSignIn: widget.onSignIn,
                          onCompleteProfile: widget.onCompleteProfile),
                    Form(
                        key: _form,
                        child: TextFormField(
                          key: const ValueKey('invite-email'),
                          controller: _email,
                          enabled:
                              !invitation.isLoading && !state.isAccessBlocked,
                          keyboardType: TextInputType.emailAddress,
                          textInputAction: TextInputAction.search,
                          autocorrect: false,
                          enableSuggestions: false,
                          validator: _validate,
                          decoration: const InputDecoration(
                              labelText: 'Complete email address',
                              hintText: 'member@example.com'),
                          onChanged: (value) {
                            state.setSearchEmail(value);
                            setState(() {
                              _feedback = null;
                              _success = false;
                              _uncertain = false;
                            });
                          },
                          onFieldSubmitted: (_) => _search(),
                        )),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                        onPressed:
                            busy || state.isAccessBlocked ? null : _search,
                        icon: const Icon(Icons.search),
                        label: const Text('Search')),
                    if (search.isLoading)
                      const Padding(
                          padding: EdgeInsets.symmetric(vertical: 12),
                          child: LinearProgressIndicator(
                              semanticsLabel: 'Searching registered users')),
                    if (queryMatches &&
                        search.error != null &&
                        !state.isAccessBlocked)
                      ContactLinksNotice(
                          message: search.error!.message,
                          isError: true,
                          actionLabel: 'Retry search',
                          onRefresh: busy ? null : _search),
                    if (queryMatches &&
                        search.hasLoaded &&
                        !search.isLoading &&
                        search.error == null &&
                        search.items.isEmpty)
                      const Padding(
                          padding: EdgeInsets.symmetric(vertical: 20),
                          child: Text('No matching registered user found.')),
                    if (queryMatches && !state.isAccessBlocked)
                      for (final user in search.items)
                        Card(
                            child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                    user.name.isEmpty
                                        ? 'SafeCircle member'
                                        : user.name,
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium),
                                const SizedBox(height: 8),
                                Text(user.email),
                                const SizedBox(height: 12),
                                if (state.hasActiveInvitationOrRelationship(
                                    user.email))
                                  const Text(
                                      'An invitation or connection already exists. Check Received, Sent or Connections.'),
                                FilledButton.icon(
                                    onPressed: busy ||
                                            invitation.requiresRefresh ||
                                            state
                                                .hasActiveInvitationOrRelationship(
                                                    user.email)
                                        ? null
                                        : () => _send(user, owner),
                                    icon: const Icon(Icons.person_add_alt_1),
                                    label: const Text('Send invitation')),
                              ]),
                        )),
                    if (invitation.isLoading)
                      const LinearProgressIndicator(
                          semanticsLabel: 'Sending invitation'),
                    if (_feedback != null && !state.isAccessBlocked)
                      ContactLinksNotice(
                          message: _feedback!,
                          isError: !_success,
                          onRefresh: invitation.isLoading ? null : _refresh),
                    if (invitation.requiresRefresh &&
                        _feedback == null &&
                        !state.isAccessBlocked)
                      ContactLinksNotice(
                          message:
                              'The previous invitation outcome is uncertain. Refresh connections before trying again.',
                          isError: true,
                          onRefresh: invitation.isLoading ? null : _refresh),
                    const SizedBox(height: 16),
                    const Text(
                        'An invitation requires acceptance. Connections are not included in emergency alerts yet.'),
                  ],
                ),
              ))),
    );
  }
}
