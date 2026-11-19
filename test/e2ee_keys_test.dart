// The key record: create, unlock both ways, change the passphrase, and reset with
// the recovery key. Fast iteration counts here; the production default is 600,000.
import 'package:flutter_test/flutter_test.dart';
import 'package:otda/src/e2ee/crypto.dart';
import 'package:otda/src/e2ee/keys.dart';

const fast = 1000;
const passphrase = 'correct horse battery staple';

void main() {
  test('a new record unlocks with its passphrase and its recovery key', () {
    final made = createKeyRecord(passphrase, iterations: fast);
    final viaPassphrase = unlockWithPassphrase(made.record, passphrase, strict: false);
    final viaRecovery = unlockWithRecoveryKey(made.record, made.recoveryKey, strict: false);
    expect(viaPassphrase, made.accountKey);
    expect(viaRecovery, made.accountKey);
  });

  test('the record carries only wrapped material', () {
    final made = createKeyRecord(passphrase, iterations: fast);
    final json = made.record.toJson();
    expect(json.keys, containsAll(['version', 'kdf', 'salt', 'iterations', 'wrappedByPassphrase', 'wrappedByRecovery']));
    expect(json['kdf'], 1);
    expect(json['version'], 1);
    // The account key never appears in the record.
    final asText = json.values.join('|');
    expect(asText.contains(made.accountKey.map((b) => b.toRadixString(16)).join()), isFalse);
  });

  test('a wrong passphrase does not unlock', () {
    final made = createKeyRecord(passphrase, iterations: fast);
    expect(
      () => unlockWithPassphrase(made.record, 'not the passphrase', strict: false),
      throwsA(isA<E2eeError>().having((e) => e.code, 'code', 'wrong_secret')),
    );
  });

  test('changing the passphrase keeps the account key and the recovery key', () {
    final made = createKeyRecord(passphrase, iterations: fast);
    final next = 'a much longer passphrase';
    final rewrapped = rewrapWithPassphrase(made.record, passphrase, next, iterations: fast, strict: false);

    expect(unlockWithPassphrase(rewrapped, next, strict: false), made.accountKey);
    expect(unlockWithRecoveryKey(rewrapped, made.recoveryKey, strict: false), made.accountKey);
    expect(
      () => unlockWithPassphrase(rewrapped, passphrase, strict: false),
      throwsA(isA<E2eeError>()),
    );
  });

  test('a reset issues a new recovery key and retires the old one', () {
    final made = createKeyRecord(passphrase, iterations: fast);
    final reset = resetWithRecoveryKey(made.record, made.recoveryKey, 'fresh passphrase', iterations: fast, strict: false);

    expect(unlockWithPassphrase(reset.record, 'fresh passphrase', strict: false), made.accountKey);
    expect(unlockWithRecoveryKey(reset.record, reset.recoveryKey, strict: false), made.accountKey);
    expect(reset.recoveryKey, isNot(made.recoveryKey));
    expect(
      () => unlockWithRecoveryKey(reset.record, made.recoveryKey, strict: false),
      throwsA(isA<E2eeError>()),
    );
  });

  test('a host of weak iterations or a bad format keeps the device locked', () {
    final made = createKeyRecord(passphrase, iterations: fast);
    final weak = KeyRecord(
      salt: made.record.salt,
      iterations: 1000,
      wrappedByPassphrase: made.record.wrappedByPassphrase,
      wrappedByRecovery: made.record.wrappedByRecovery,
    );
    expect(() => weak.validate(), throwsA(isA<E2eeError>().having((e) => e.code, 'code', 'bad_iterations')));

    final wrongVersion = KeyRecord(
      version: 2,
      salt: made.record.salt,
      iterations: 600000,
      wrappedByPassphrase: made.record.wrappedByPassphrase,
      wrappedByRecovery: made.record.wrappedByRecovery,
    );
    expect(() => wrongVersion.validate(), throwsA(isA<E2eeError>().having((e) => e.code, 'code', 'bad_key_record')));
  });

  test('a passphrase under 12 characters is refused', () {
    expect(
      () => createKeyRecord('short', iterations: fast),
      throwsA(isA<E2eeError>().having((e) => e.code, 'code', 'weak_passphrase')),
    );
  });

  test('the JSON round-trips, so the record can be stored and read back', () {
    final made = createKeyRecord(passphrase, iterations: fast);
    final back = KeyRecord.fromJson(made.record.toJson());
    expect(unlockWithPassphrase(back, passphrase, strict: false), made.accountKey);
  });
}
