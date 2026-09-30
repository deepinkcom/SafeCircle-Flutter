import 'package:flutter/material.dart';
import '../theme/app_colors.dart';

class SafeCircleMark extends StatelessWidget {
  const SafeCircleMark({super.key, this.size = 36});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: const BoxDecoration(
        color: AppColors.tealPrimary,
        shape: BoxShape.circle,
      ),
      child: Icon(Icons.groups, color: Colors.white, size: size * 0.6),
    );
  }
}
