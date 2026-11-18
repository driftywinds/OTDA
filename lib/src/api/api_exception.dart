import 'dart:convert';

/// The server's error envelope: `{"error":{"code","message"}}`.
class ApiException implements Exception {
  const ApiException(this.status, this.code, this.message, {this.field});

  final int status;
  final String code;
  final String message;
  final String? field;

  /// The credential is gone or rejected: the caller must sign in again.
  bool get isUnauthenticated => status == 401;

  /// Valid credential, too narrow (a `read` token on a write, a token on a
  /// credential route).
  bool get isForbidden => status == 403;

  /// A step-up route needs a password or code confirmed in the last 10 minutes.
  bool get needsReauth => status == 403 && code == 'reauth_required';

  bool get isRateLimited => status == 429;

  @override
  String toString() => '$code ($status): $message';

  static ApiException fromBody(int status, String body, {String? fallback}) {
    try {
      final map = jsonDecode(body);
      final error = map is Map ? map['error'] : null;
      if (error is Map) {
        return ApiException(
          status,
          error['code']?.toString() ?? 'unknown',
          error['message']?.toString() ?? '',
          field: error['field']?.toString(),
        );
      }
    } on FormatException {
      // not JSON: fall through to the raw status
    }
    return ApiException(status, 'http_$status', fallback ?? 'unexpected response');
  }
}
