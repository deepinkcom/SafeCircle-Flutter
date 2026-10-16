// Android is connected to Firebase project deepinkapp-124a6 (DeepinkApp).
// Other platforms still need `flutterfire configure` before they can sign in.
import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) return web;
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      case TargetPlatform.iOS:
        return ios;
      case TargetPlatform.macOS:
        return macos;
      case TargetPlatform.windows:
        return windows;
      case TargetPlatform.linux:
        throw UnsupportedError(
          'Firebase options are not configured for Linux. '
          'Run flutterfire configure on a supported platform.',
        );
      default:
        throw UnsupportedError(
          'Firebase options are not configured for this platform.',
        );
    }
  }

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyCnU4dCFjfppak14EqTnbaeW_qqmz-UISQ',
    appId: '1:926463275124:android:c6240bc0a09c786dd2a121',
    messagingSenderId: '926463275124',
    projectId: 'deepinkapp-124a6',
    storageBucket: 'deepinkapp-124a6.firebasestorage.app',
  );
  static const FirebaseOptions ios = FirebaseOptions(
    apiKey: 'REPLACE_ME',
    appId: '1:000000000000:ios:0000000000000000000000',
    messagingSenderId: '000000000000',
    projectId: 'safecircle-REPLACE_ME',
    storageBucket: 'safecircle-REPLACE_ME.firebasestorage.app',
    iosBundleId: 'com.example.safecircle',
  );

  static const FirebaseOptions macos = FirebaseOptions(
    apiKey: 'REPLACE_ME',
    appId: '1:000000000000:ios:0000000000000000000000',
    messagingSenderId: '000000000000',
    projectId: 'safecircle-REPLACE_ME',
    storageBucket: 'safecircle-REPLACE_ME.firebasestorage.app',
    iosBundleId: 'com.example.safecircle',
  );

  static const FirebaseOptions windows = FirebaseOptions(
    apiKey: 'REPLACE_ME',
    appId: '1:000000000000:web:0000000000000000000000',
    messagingSenderId: '000000000000',
    projectId: 'safecircle-REPLACE_ME',
    authDomain: 'safecircle-REPLACE_ME.firebaseapp.com',
    storageBucket: 'safecircle-REPLACE_ME.firebasestorage.app',
  );

  static const FirebaseOptions web = FirebaseOptions(
    apiKey: 'REPLACE_ME',
    appId: '1:000000000000:web:0000000000000000000000',
    messagingSenderId: '000000000000',
    projectId: 'safecircle-REPLACE_ME',
    authDomain: 'safecircle-REPLACE_ME.firebaseapp.com',
    storageBucket: 'safecircle-REPLACE_ME.firebasestorage.app',
  );
}
