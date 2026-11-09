enum ApiFailureKind {
  authentication,
  forbidden,
  notFound,
  conflict,
  validation,
  rateLimited,
  server,
  requestRejected,
  invalidResponse,
  network,
  timeout,
  unexpected,
}

/// Contains only safe metadata. Never retains response bodies or causes.
class ApiFailure implements Exception {
  const ApiFailure(this.kind, {this.statusCode});

  final ApiFailureKind kind;
  final int? statusCode;

  factory ApiFailure.fromStatus(int statusCode) => ApiFailure(
        switch (statusCode) {
          401 => ApiFailureKind.authentication,
          403 => ApiFailureKind.forbidden,
          404 => ApiFailureKind.notFound,
          409 => ApiFailureKind.conflict,
          400 || 422 => ApiFailureKind.validation,
          429 => ApiFailureKind.rateLimited,
          >= 500 => ApiFailureKind.server,
          _ => ApiFailureKind.requestRejected,
        },
        statusCode: statusCode,
      );

  String get message => switch (kind) {
        ApiFailureKind.authentication => 'Please sign in to continue.',
        ApiFailureKind.forbidden =>
          'Your account cannot access this feature. Check your SafeCircle profile.',
        ApiFailureKind.notFound =>
          'This user, invitation, or relationship is unavailable.',
        ApiFailureKind.conflict =>
          'This invitation or relationship has changed. Refresh and try again.',
        ApiFailureKind.validation => 'Check the details and try again.',
        ApiFailureKind.rateLimited =>
          'Too many requests. Please try again later.',
        ApiFailureKind.server =>
          'SafeCircle is unavailable right now. Please try again later.',
        ApiFailureKind.requestRejected => 'The request could not be completed.',
        ApiFailureKind.invalidResponse =>
          'SafeCircle returned an unexpected response. Please try again.',
        ApiFailureKind.network =>
          'Could not connect to SafeCircle. Check your connection and try again.',
        ApiFailureKind.timeout =>
          'The request timed out. Refresh before trying again.',
        ApiFailureKind.unexpected => 'Something went wrong. Please try again.',
      };

  @override
  String toString() => message;
}
