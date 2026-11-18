import 'db.dart';

/// Hybrid logical clock: every local write is stamped so it orders after
/// anything the device has already seen, and so a clock that runs ahead of the
/// server cannot make an edit jump the queue forever.
class HybridClock {
  HybridClock._(this._db, this._last, this._offset);

  final OtdaDb _db;
  int _last;
  int _offset;

  static Future<HybridClock> load(OtdaDb db) async {
    final last = await db.metaInt('clock.last');
    final offset = await db.metaInt('clock.offset');
    return HybridClock._(db, last, offset);
  }

  int get last => _last;

  /// The next stamp: `max(now + offset, last + 1)`.
  Future<int> next() async {
    final now = DateTime.now().millisecondsSinceEpoch + _offset;
    final ts = now > _last + 1 ? now : _last + 1;
    _last = ts;
    await _db.setMetaInt('clock.last', _last);
    return ts;
  }

  /// Moves the clock past a value received from the server.
  void observe(int ts) {
    if (ts > _last) _last = ts;
  }

  /// Adopts the server's idea of now when the two differ by more than 2 s, so
  /// a device with a wrong clock does not keep stamping far in the future.
  Future<void> adopt(int serverTime) async {
    final skew = serverTime - DateTime.now().millisecondsSinceEpoch;
    final offset = skew.abs() > 2000 ? skew : 0;
    if (offset != _offset) {
      _offset = offset;
      await _db.setMetaInt('clock.offset', _offset);
    }
    await _db.setMetaInt('clock.last', _last);
  }
}
