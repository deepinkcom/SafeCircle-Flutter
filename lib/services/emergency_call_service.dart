import 'package:url_launcher/url_launcher.dart';

class EmergencyCallService {
  EmergencyCallService({Future<bool> Function(Uri)? launch}) : _launch = launch;

  final Future<bool> Function(Uri)? _launch;

  Future<bool> openDialler() => (_launch ?? _launchUrl)(
        Uri(scheme: 'tel', path: '112'),
      );

  Future<bool> _launchUrl(Uri uri) => launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
}
