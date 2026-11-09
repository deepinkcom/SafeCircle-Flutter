import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import '../theme/app_colors.dart';

/// Uses only the current account's in-memory authenticated image bytes.
class ProfilePhotoAvatar extends StatelessWidget {
  const ProfilePhotoAvatar({super.key, required this.ownerUid, this.size = 64, this.onTap});

  final String ownerUid;
  final double size;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final bytes = app.userProfile.uid == ownerUid ? app.profilePhotoBytes : null;
    final fallback = Icon(Icons.person, color: AppColors.tealPrimary, size: size / 2);
    return Semantics(
      label: onTap == null ? 'Profile picture' : 'Change profile picture',
      button: onTap != null,
      child: Tooltip(
        message: onTap == null ? 'Profile picture' : 'Change profile picture',
        child: SizedBox(
          width: size,
          height: size,
          child: Material(
            color: AppColors.tealBg,
            shape: const CircleBorder(),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onTap,
              child: Stack(fit: StackFit.expand, children: [
                if (bytes == null)
                  Center(child: fallback)
                else
                  Image.memory(bytes,
                    key: ValueKey('$ownerUid:${app.userProfile.photoStoragePath}'),
                    width: size, height: size, fit: BoxFit.cover,
                    gaplessPlayback: false, excludeFromSemantics: true,
                    errorBuilder: (_, __, ___) => Center(child: fallback)),
                if (app.userProfile.uid == ownerUid && app.photoLoading)
                  const Padding(padding: EdgeInsets.all(16), child: CircularProgressIndicator(strokeWidth: 2)),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
