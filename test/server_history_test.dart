// The sign-in screen remembers where this device has been, so signing out never
// leaves the address lost.
import 'package:flutter_test/flutter_test.dart';
import 'package:otda/src/data/server_history.dart';

void main() {
  test('a new server goes to the front', () {
    expect(rememberServer(['https://a'], 'https://b'), ['https://b', 'https://a']);
  });

  test('the same server is not listed twice', () {
    expect(rememberServer(['https://a', 'https://b'], 'https://a'), ['https://a', 'https://b']);
  });

  test('the list is capped, oldest dropped', () {
    final list = rememberServer(
      ['https://1', 'https://2', 'https://3', 'https://4', 'https://5'],
      'https://6',
    );
    expect(list, ['https://6', 'https://1', 'https://2', 'https://3', 'https://4']);
  });

  test('an empty address changes nothing', () {
    expect(rememberServer(['https://a'], '   '), ['https://a']);
  });

  test('the remembered address is trimmed', () {
    expect(rememberServer([], ' https://a '), ['https://a']);
  });
}
