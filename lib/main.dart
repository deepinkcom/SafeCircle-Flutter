import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'firebase_bootstrap.dart';
import 'firebase_options.dart';
import 'navigation/app_router.dart';
import 'state/app_state.dart';

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(
  RemoteMessage message,
) async {
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  debugPrint(
    'FCM: Background message received: ${message.messageId}',
  );
}

Future<void> main() async {
WidgetsFlutterBinding.ensureInitialized();
await _initializeFirebase();

if (FirebaseBootstrap.isReady) {
  FirebaseMessaging.onBackgroundMessage(
    firebaseMessagingBackgroundHandler,
  );
}

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
