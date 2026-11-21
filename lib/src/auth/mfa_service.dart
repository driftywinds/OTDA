import '../api/api_client.dart';

/// The account's second factor, as `GET /api/v1/mfa` reports it.
///
/// `required` is the server owner's policy for this account; `restricted` means
/// the session may only enrol until it is satisfied (the server refuses every
/// other route with `mfa_enrolment_required`).
class MfaStatus {
  const MfaStatus({
    required this.enrolled,
    required this.recoveryCodesRemaining,
    required this.policy,
    required this.required,
    required this.restricted,
  });

  final bool enrolled;
  final int recoveryCodesRemaining;

  /// `none`, `owner` or `all`.
  final String policy;
  final bool required;
  final bool restricted;

  static const off = MfaStatus(
    enrolled: false,
    recoveryCodesRemaining: 0,
    policy: 'none',
    required: false,
    restricted: false,
  );

  static MfaStatus fromJson(Map<String, dynamic> json) => MfaStatus(
    enrolled: json['enrolled'] == true,
    recoveryCodesRemaining:
        (json['recoveryCodesRemaining'] as num?)?.toInt() ?? 0,
    policy: json['policy']?.toString() ?? 'none',
    required: json['required'] == true,
    restricted: json['restricted'] == true,
  );
}

/// The one-time answer of the enrol step: the secret and its `otpauth://` URI.
class TotpEnrollment {
  const TotpEnrollment({
    required this.secret,
    required this.uri,
    required this.expiresAt,
  });

  final String secret;
  final String uri;
  final int expiresAt;

  static TotpEnrollment fromJson(Map<String, dynamic> json) => TotpEnrollment(
    secret: json['secret']?.toString() ?? '',
    uri: json['uri']?.toString() ?? '',
    expiresAt: (json['expiresAt'] as num?)?.toInt() ?? 0,
  );
}

/// A confirmed enrolment: the recovery codes, shown once, and the new status.
class MfaConfirmation {
  const MfaConfirmation({required this.recoveryCodes, required this.status});

  final List<String> recoveryCodes;
  final MfaStatus status;
}

/// One browser remembered by "trust this device for 30 days".
class TrustedDevice {
  const TrustedDevice({
    required this.id,
    required this.userAgent,
    required this.createdAt,
    required this.expiresAt,
    required this.lastUsedAt,
  });

  final String id;
  final String userAgent;
  final int createdAt;
  final int expiresAt;
  final int? lastUsedAt;

  static TrustedDevice fromJson(Map<String, dynamic> json) => TrustedDevice(
    id: json['id']?.toString() ?? '',
    userAgent: json['userAgent']?.toString() ?? '',
    createdAt: (json['createdAt'] as num?)?.toInt() ?? 0,
    expiresAt: (json['expiresAt'] as num?)?.toInt() ?? 0,
    lastUsedAt: (json['lastUsedAt'] as num?)?.toInt(),
  );
}

/// The second-factor routes, kept apart from sign-in so the Settings card can
/// manage an account that is already signed in.
///
/// Every mutating route is `.Sensitive()` on the server: it needs a session (or
/// an admin token) that confirmed identity in the last ten minutes, so callers
/// must be ready for [ApiException.needsReauth] and call `/auth/reauth`.
class MfaService {
  const MfaService();

  Future<MfaStatus> status(ApiClient client) async {
    final json = await client.get('/api/v1/mfa') as Map<String, dynamic>;
    final mfa = json['mfa'];
    return mfa is Map
        ? MfaStatus.fromJson(mfa.cast<String, dynamic>())
        : MfaStatus.off;
  }

  Future<TotpEnrollment> enroll(ApiClient client) async {
    final json =
        await client.post('/api/v1/mfa/totp/enroll') as Map<String, dynamic>;
    return TotpEnrollment.fromJson(json);
  }

  Future<MfaConfirmation> confirm(ApiClient client, String code) async {
    final json = await client.post(
      '/api/v1/mfa/totp/confirm',
      body: {'code': code.trim()},
    ) as Map<String, dynamic>;
    final mfa = json['mfa'];
    return MfaConfirmation(
      recoveryCodes: _codes(json['recoveryCodes']),
      status: mfa is Map
          ? MfaStatus.fromJson(mfa.cast<String, dynamic>())
          : MfaStatus.off,
    );
  }

  Future<void> disable(ApiClient client) => client.delete('/api/v1/mfa/totp');

  Future<List<String>> regenerateRecoveryCodes(ApiClient client) async {
    final json = await client.post(
      '/api/v1/mfa/recovery-codes/regenerate',
    ) as Map<String, dynamic>;
    return _codes(json['recoveryCodes']);
  }

  Future<List<TrustedDevice>> trustedDevices(ApiClient client) async {
    final json =
        await client.get('/api/v1/mfa/trusted-devices') as Map<String, dynamic>;
    final devices = json['devices'];
    if (devices is! List) return const [];
    return [
      for (final entry in devices)
        if (entry is Map) TrustedDevice.fromJson(entry.cast<String, dynamic>()),
    ];
  }

  Future<void> forgetTrustedDevice(ApiClient client, String id) =>
      client.delete('/api/v1/mfa/trusted-devices/${Uri.encodeComponent(id)}');

  Future<void> forgetAllTrustedDevices(ApiClient client) =>
      client.delete('/api/v1/mfa/trusted-devices');

  static List<String> _codes(Object? raw) => [
    if (raw is List)
      for (final code in raw) code.toString(),
  ];
}
