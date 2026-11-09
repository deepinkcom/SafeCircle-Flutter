import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/profile_photo.dart';
import '../state/app_state.dart';
import '../theme/app_colors.dart';
import 'profile_photo_avatar.dart';

Future<bool?> showProfilePhotoEditor(BuildContext context) {
  final app = context.read<AppState>();
  return showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => ProfilePhotoEditor(ownerUid: app.userProfile.uid,
      sessionVersion: app.photoSessionVersion),
  );
}

class ProfilePhotoEditor extends StatefulWidget {
  const ProfilePhotoEditor({super.key, required this.ownerUid, required this.sessionVersion});

  final String ownerUid;
  final int sessionVersion;

  @override
  State<ProfilePhotoEditor> createState() => _ProfilePhotoEditorState();
}

class _ProfilePhotoEditorState extends State<ProfilePhotoEditor> {
  ProfilePhotoDraft? _draft;
  bool _confirmingRemoval = false;

  bool _current(AppState app) => mounted && widget.ownerUid.isNotEmpty &&
      widget.ownerUid == app.userProfile.uid && widget.sessionVersion == app.photoSessionVersion;

  void _discardDraft() {
    final draft = _draft;
    _draft = null;
    if (draft != null) {
      unawaited(MemoryImage(draft.bytes).evict().catchError((Object _) => false));
      draft.dispose();
    }
  }

  @override
  void dispose() {
    _discardDraft();
    super.dispose();
  }

  Future<void> _pick(ProfilePhotoSource source) async {
    final app = context.read<AppState>();
    if (!_current(app) || app.photoBusy || app.savingProfile || _confirmingRemoval) return;
    final draft = await app.selectProfilePhoto(source);
    if (!_current(app)) {
      draft?.dispose();
      return;
    }
    if (draft != null) {
      setState(() {
        _discardDraft();
        _draft = draft;
      });
    }
  }

  Future<void> _save() async {
    final app = context.read<AppState>();
    final draft = _draft;
    if (!_current(app) || draft == null || app.photoBusy || app.savingProfile || _confirmingRemoval) return;
    final saved = await app.saveProfilePhoto(draft);
    if (!mounted) return;
    if (!_current(app)) return;
    if (saved) Navigator.of(context).pop(true);
  }

  Future<void> _refresh() async {
    final app = context.read<AppState>();
    if (!_current(app) || app.photoBusy || app.photoLoading) return;
    final loaded = await app.refreshProfilePhoto();
    if (_current(app) && loaded) setState(_discardDraft);
  }

  Future<void> _remove() async {
    final app = context.read<AppState>();
    if (!_current(app) || app.photoBusy || app.savingProfile || _confirmingRemoval) return;
    setState(() => _confirmingRemoval = true);
    final confirmed = await showDialog<bool>(context: context, builder: (dialogContext) => AlertDialog(
      title: const Text('Remove profile picture?'),
      content: const Text('Your default avatar will return. Your account and other details will remain.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Remove')),
      ],
    ));
    if (!mounted) return;
    setState(() => _confirmingRemoval = false);
    if (!_current(app) || confirmed != true) return;
    final removed = await app.removeProfilePhoto();
    if (!mounted) return;
    if (_current(app) && removed) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    if (!_current(app)) {
      return AlertDialog(title: const Text('Account changed'),
        content: const Text('Close this editor and reopen it for the signed-in account.'),
        actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Close'))]);
    }
    final blocked = app.photoBusy || app.photoLoading || app.savingProfile || _confirmingRemoval;
    return PopScope(
      canPop: !app.photoBusy && !_confirmingRemoval,
      child: AlertDialog(
        title: const Text('Profile picture'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (_draft == null)
              ProfilePhotoAvatar(ownerUid: widget.ownerUid, size: 144)
            else
              Semantics(label: 'Selected picture preview', image: true,
                child: ClipOval(child: Image.memory(_draft!.bytes, width: 180, height: 180,
                  fit: BoxFit.cover, gaplessPlayback: false,
                  errorBuilder: (_, __, ___) => const SizedBox(width: 180, height: 180,
                    child: Center(child: Text('Preview unavailable. Choose another picture.')))))),
            const SizedBox(height: 16),
            const Text('Private to your account. JPEG or PNG; 8 MiB after selection. '
              'Pictures are resized to 512 pixels and stored as PNG (maximum 2 MiB).'),
            const SizedBox(height: 12),
            OutlinedButton.icon(onPressed: blocked ? null : () => _pick(ProfilePhotoSource.gallery),
              icon: const Icon(Icons.photo_library_outlined), label: const Text('Choose from gallery')),
            if (app.photoCameraSupported)
              OutlinedButton.icon(onPressed: blocked ? null : () => _pick(ProfilePhotoSource.camera),
                icon: const Icon(Icons.camera_alt_outlined), label: const Text('Take a photo')),
            if (_draft != null)
              TextButton(onPressed: blocked ? null : () => setState(_discardDraft), child: const Text('Discard preview')),
            if (app.userProfile.photoStoragePath != null)
              TextButton.icon(onPressed: blocked || app.photoNeedsRefresh ? null : _remove,
                icon: const Icon(Icons.delete_outline), label: const Text('Remove picture')),
            if (app.photoBusy) ...[
              LinearProgressIndicator(value: app.photoProgress),
              const SizedBox(height: 8),
              const Text('Processing picture. Please wait.'),
            ],
            if (app.photoError != null) ...[
              const SizedBox(height: 12),
              Text(app.photoError!, style: const TextStyle(color: AppColors.redAlert)),
              TextButton.icon(onPressed: blocked ? null : _refresh,
                icon: const Icon(Icons.refresh), label: const Text('Refresh picture')),
            ],
          ])),
        ),
        actions: [
          TextButton(onPressed: app.photoBusy || _confirmingRemoval ? null : () => Navigator.pop(context, false),
            child: const Text('Cancel')),
          FilledButton(onPressed: blocked || app.photoNeedsRefresh || _draft == null ? null : _save,
            child: const Text('Upload picture')),
        ],
      ),
    );
  }
}
