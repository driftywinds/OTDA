// The sync line must not shout about the lookup a phone fails while waking up,
// but must still report a server that refused, and must recover.
import 'package:flutter_test/flutter_test.dart';
import 'package:otda/src/api/api_exception.dart';
import 'package:otda/src/data/failure_meter.dart';

ApiException failure(String code, String message) => ApiException(0, code, message);

void main() {
  test('one lookup failure says nothing', () {
    final meter = FailureMeter();
    expect(meter.add(failure('network', 'failed host lookup')), isNull);
  });

  test('a second in a row says it plainly', () {
    final meter = FailureMeter();
    meter.add(failure('network', 'failed host lookup'));
    expect(
      meter.add(failure('network', 'failed host lookup')),
      'Offline — your changes are saved on this phone',
    );
  });

  test('a server refusal is shown at once, in its own words', () {
    final meter = FailureMeter();
    expect(meter.add(failure('forbidden', 'That token lacks admin scope')), 'That token lacks admin scope');
  });

  test('a refusal clears the streak of lookups', () {
    final meter = FailureMeter();
    meter.add(failure('network', 'failed host lookup'));
    meter.add(failure('server', 'storage failed'));
    expect(meter.add(failure('network', 'failed host lookup')), isNull);
  });

  test('success forgets the streak', () {
    final meter = FailureMeter();
    meter.add(failure('network', 'failed host lookup'));
    meter.reset();
    expect(meter.add(failure('network', 'failed host lookup')), isNull);
  });

  test('a timeout is treated like a lookup failure', () {
    final meter = FailureMeter();
    meter.add(failure('timeout', 'connection timed out'));
    expect(meter.add(failure('timeout', 'connection timed out')), contains('Offline'));
  });
}
