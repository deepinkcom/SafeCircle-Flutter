/// Only readiness metadata for the identity authenticated by the API token.
class BackendProfileStatus {
  const BackendProfileStatus(
      {required this.id,
      required this.profileReady,
      required this.missingFields});

  final int? id;
  final bool profileReady;
  final List<String> missingFields;

  factory BackendProfileStatus.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final ready = json['profile_ready'];
    final missing = json['missing_fields'];
    if ((id != null && (id is! int || id <= 0)) ||
        ready is! bool ||
        missing is! List ||
        missing.any((field) => !{'name', 'phone', 'city'}.contains(field)) ||
        (ready && (id == null || missing.isNotEmpty)) ||
        (!ready && missing.isEmpty)) {
      throw const FormatException('Invalid profile readiness.');
    }
    return BackendProfileStatus(
        id: id as int?,
        profileReady: ready,
        missingFields: List<String>.unmodifiable(missing.cast<String>()));
  }
}
