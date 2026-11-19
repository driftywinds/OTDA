import '../api/api_exception.dart';

/// Decides what a failed exchange is worth saying.
///
/// A phone that has just woken up resolves nothing for a moment, and "failed host
/// lookup" is a developer's sentence, so an unreachable server is only reported
/// once it fails twice in a row, in plain words. A server that answered and said
/// no is reported at once, in its own words, because that one needs action.
class FailureMeter {
  int _unreachable = 0;

  /// The line to show, or null to keep quiet.
  String? add(ApiException failure) {
    if (failure.code != 'network' && failure.code != 'timeout') {
      _unreachable = 0;
      return failure.message;
    }
    _unreachable++;
    return _unreachable >= 2 ? 'Offline — your changes are saved on this phone' : null;
  }

  /// A successful exchange clears the streak.
  void reset() => _unreachable = 0;
}
