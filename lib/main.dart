import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'navigation/app_router.dart';
import 'state/app_state.dart';

void main() {
  runApp(
    ChangeNotifierProvider(
      create: (_) => AppState(),
      child: const SafeCircleApp(),
    ),
  );
}
