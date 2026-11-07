import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/contact_link.dart';
import '../state/contact_links_state.dart';
import '../widgets/contact_link_card.dart';
import '../widgets/contact_links_feedback.dart';

class ContactLinksScreen extends StatefulWidget {
  const ContactLinksScreen({
    super.key,
    required this.onInvite,
    required this.onSignIn,
    required this.onCompleteProfile,
  });

  final Future<void> Function() onInvite;
  final Future<void> Function() onSignIn;
  final Future<void> Function() onCompleteProfile;

  @override
  State<ContactLinksScreen> createState() => _ContactLinksScreenState();
}

class _ContactLinksScreenState extends State<ContactLinksScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  late final ContactLinksState _state;
  int _view = 0;
  bool _confirming = false;

  @override
  void initState() {
    super.initState();
    _state = context.read<ContactLinksState>();
    _tabs = TabController(length: 3, vsync: this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _refresh();
    });
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    await _state.refresh();
  }

  void _select(int index) {
    if (_view == index) return;
    setState(() => _view = index);
    switch (index) {
      case 0:
        _state.loadAcceptedRelationships();
      case 1:
        _state.loadIncomingInvitations();
      case 2:
        _state.loadOutgoingInvitations();
    }
  }

  Future<void> _invite() async {
    final owner = _state.userId;
    await widget.onInvite();
    if (mounted && _state.userId == owner) await _refresh();
  }

  Future<void> _perform(Future<ContactLinkMutationResult> Function() action,
      String success, String? owner) async {
    if (!mounted || owner == null || owner != _state.userId) return;
    final result = await action();
    if (!mounted || owner != _state.userId) return;
    final message = contactLinkActionMessage(result, success);
    if (message != null) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _revoke(ContactLink link, String? owner) async {
    if (_confirming || owner == null || owner != _state.userId) return;
    final session = _state.sessionVersion;
    _confirming = true;
    try {
      final confirmed = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
                title: const Text('Revoke connection?'),
                content: const Text(
                    'This accepted relationship will end. A new invitation will be needed to reconnect.'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(dialogContext, false),
                      child: const Text('Keep connection')),
                  FilledButton(
                      onPressed: () => Navigator.pop(dialogContext, true),
                      child: const Text('Revoke connection')),
                ],
              ));
      if (mounted && confirmed == true && session == _state.sessionVersion) {
        await _perform(() => _state.revokeRelationship(link.id),
            'Connection revoked.', owner);
      }
    } finally {
      _confirming = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<ContactLinksState>();
    final data = switch (_view) {
      0 => state.accepted,
      1 => state.incoming,
      _ => state.outgoing
    };
    final owner = state.userId;
    final loading = state.incoming.isLoading ||
        state.outgoing.isLoading ||
        state.accepted.isLoading;
    final empty = switch (_view) {
      0 => 'No SafeCircle connections yet.',
      1 => 'No received invitations.',
      _ => 'No sent invitations.',
    };
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 72,
        title: const Text('SafeCircle Connections',
            maxLines: 2, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
              tooltip: 'Refresh connections',
              onPressed: loading ? null : _refresh,
              icon: const Icon(Icons.refresh))
        ],
      ),
      body: SafeArea(
          child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: Column(children: [
                  TabBar(
                      controller: _tabs,
                      isScrollable: true,
                      tabAlignment: TabAlignment.start,
                      onTap: _select,
                      tabs: const [
                        Tab(text: 'Connections'),
                        Tab(text: 'Received'),
                        Tab(text: 'Sent')
                      ]),
                  Expanded(
                      child: RefreshIndicator(
                          onRefresh: _refresh,
                          child: ListView(
                            physics: const AlwaysScrollableScrollPhysics(),
                            padding: const EdgeInsets.all(16),
                            children: [
                              FilledButton.icon(
                                  onPressed:
                                      state.isAccessBlocked ? null : _invite,
                                  icon: const Icon(Icons.person_add_alt_1),
                                  label: const Text('Invite by email')),
                              const SizedBox(height: 12),
                              const Text(
                                  'Connections are not included in emergency alerts yet. Your phone contacts remain separate.'),
                              const SizedBox(height: 12),
                              if (state.isAccessBlocked)
                                ContactLinksAccessPanel(
                                    state: state,
                                    onSignIn: widget.onSignIn,
                                    onCompleteProfile: widget.onCompleteProfile)
                              else ...[
                                if (data.isLoading)
                                  const LinearProgressIndicator(
                                      semanticsLabel: 'Loading connections'),
                                if (data.error != null)
                                  ContactLinksNotice(
                                    isError: true,
                                    message:
                                        '${data.error!.message}${data.hasLoaded ? ' Previously loaded items are shown.' : ''}',
                                    onRefresh: loading ? null : _refresh,
                                  ),
                                if (!data.isLoading &&
                                    data.items.isEmpty &&
                                    data.error == null)
                                  Padding(
                                      padding: const EdgeInsets.symmetric(
                                          vertical: 28),
                                      child: Text(
                                          data.hasLoaded
                                              ? empty
                                              : 'Refresh to load your connections.',
                                          textAlign: TextAlign.center)),
                                for (final link in data.items)
                                  _card(link, state, owner),
                              ],
                            ],
                          ))),
                ]),
              ))),
    );
  }

  Widget _card(ContactLink link, ContactLinksState state, String? owner) {
    final mutation = state.mutationFor(link.id);
    final enabled = !state.isAccessBlocked &&
        !mutation.isLoading &&
        !mutation.requiresRefresh;
    final actions = <Widget>[];
    if (_view == 0 && link.isAccepted) {
      actions.add(OutlinedButton.icon(
          onPressed: enabled ? () => _revoke(link, owner) : null,
          icon: const Icon(Icons.link_off),
          label: const Text('Revoke connection')));
    } else if (_view == 1 && link.status == ContactLinkStatus.pending) {
      actions.addAll([
        FilledButton(
            onPressed: enabled
                ? () => _perform(() => state.acceptInvitation(link.id),
                    'Invitation accepted.', owner)
                : null,
            child: const Text('Accept invitation')),
        OutlinedButton(
            onPressed: enabled
                ? () => _perform(() => state.rejectInvitation(link.id),
                    'Invitation rejected.', owner)
                : null,
            child: const Text('Reject invitation')),
      ]);
    } else if (_view == 2 && link.status == ContactLinkStatus.pending) {
      actions.add(OutlinedButton(
          onPressed: enabled
              ? () => _perform(() => state.revokeRelationship(link.id),
                  'Invitation cancelled.', owner)
              : null,
          child: const Text('Cancel invitation')));
    }
    final warning = contactLinkMutationWarning(mutation);
    return ContactLinkCard(
        key: ValueKey('contact-link-${link.id}'),
        link: link,
        isBusy: mutation.isLoading,
        actions: actions,
        feedback: warning == null
            ? null
            : ContactLinksNotice(
                message: warning, isError: true, onRefresh: _refresh));
  }
}
