import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'firebase_bootstrap.dart';
import 'firebase_options.dart';
import 'navigation/app_router.dart';
import 'state/app_state.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _initializeFirebase();
  runApp(
    ChangeNotifierProvider(
      create: (_) => AppState(),
      child: const SafeCircleApp(),
    ),
  );
}

Future<void> _initializeFirebase() async {
  try {
    final options = DefaultFirebaseOptions.currentPlatform;
    final configured = !options.apiKey.startsWith('REPLACE') &&
        !options.projectId.contains('REPLACE');
    if (!configured) {
      debugPrint(
        'Firebase is not configured. Run flutterfire configure to connect '
        'SafeCircle to your Firebase project.',
      );
      return;
    }
    await Firebase.initializeApp(options: options);
    FirebaseBootstrap.isReady = true;
  } catch (error, stackTrace) {
    debugPrint('Firebase initialization skipped: $error');
    debugPrint('$stackTrace');
  }
}
