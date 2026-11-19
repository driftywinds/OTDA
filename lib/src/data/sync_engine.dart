import 'dart:async';
import 'dart:convert';

import '../api/api_client.dart';
import '../api/api_exception.dart';
import '../e2ee/session.dart';
import 'clock.dart';
import 'db.dart';

/// What one exchange did, for the status line and for tests.
class SyncResult {
  const SyncResult({
    required this.applied,
    required this.pulled,
    required this.rejected,
    required this.pending,
    required this.pages,
  });

  final int applied;
  final int pulled;
  final int rejected;
  final int pending;
  final int pages;

  bool get ok => rejected == 0;
}

/// The offline engine: push what is queued, pull everything after the cursor,
/// apply it under the same last-writer-wins rule the server uses.
class SyncEngine {
  SyncEngine({required this.db, required this.client, required this.clock});

  final OtdaDb db;
  final ApiClient client;
  final HybridClock clock;

  static const _features = ['clock_skew', 'latest_docs', 'backfill_ack'];
  static const _maxPages = 20;

  int _cursor = 0;
  String? _generation;
  int _backfillSeq = 0;
  bool _running = false;
  DateTime? _lastSync;
  ApiException? _failure;
  int _pending = 0;

  final _status = StreamController<void>.broadcast();

  Stream<void> get changes => _status.stream;
  DateTime? get lastSync => _lastSync;
  /// The last exchange failure, so the caller can decide how to word it: the raw
  /// socket text is not what a person should read.
  ApiException? get failure => _failure;

  String? get error => _failure?.message;
  bool get isRunning => _running;
  int get pending => _pending;

  /// The server position this device has read up to.
  int get cursorForTest => _cursor;
  bool get hasCachedCursor => _cursor > 0;

  /// Loads the stored cursor, generation and device id. The device id is made
  /// once and kept: the server uses it to skip a device's own ops.
  Future<void> open() async {
    _cursor = await db.metaInt('sync.cursor');
    _generation = await db.meta('sync.generation');
    _backfillSeq = await db.metaInt('sync.backfillSeq');
    _deviceId = await _loadDeviceId();
  }

  /// The device id is made once per install and never changes: the server uses
  /// it to skip a device's own ops when it pulls.
  Future<String> _loadDeviceId() async {
    final stored = await db.meta('device.id');
    if (stored != null && stored.isNotEmpty) return stored;
    final id = 'otda:${_randomId()}';
    await db.setMeta('device.id', id);
    return id;
  }

  String get device => _deviceId;
  String _deviceId = '';

  /// One full run: drain the outbox, then pull until the server says done.
  Future<SyncResult> exchange() async {
    if (_deviceId.isEmpty) {
      _deviceId = await _loadDeviceId();
    }
    if (_running) return const SyncResult(applied: 0, pulled: 0, rejected: 0, pending: 0, pages: 0);
    // An encrypted account with no key here must not pull: the batch would land as
    // ciphertext in the replica. The app asks for the passphrase instead.
    if (E2eeSession.instance.enabled && !E2eeSession.instance.unlocked) {
      throw const E2eeLockedException();
    }
    _running = true;
    _failure = null;
    _status.add(null);

    var applied = 0;
    var pulled = 0;
    var rejected = 0;
    var pages = 0;
    var more = true;
    final sent = <String>[];

    try {
      while (more && pages < _maxPages) {
        final queued = await db.pendingOps();
        _pending = queued.length;
        final ops = <Map<String, dynamic>>[];
        final batchIds = <String>[];
        for (final row in queued) {
          if (sent.contains(row['id'])) continue; // already pushed, not yet acknowledged
          ops.add({
            'id': row['id'],
            'entity': row['entity'],
            'entityId': row['entity_id'],
            'field': row['field'],
            'value': E2eeSession.instance.seal(
              row['entity'] as String,
              row['entity_id'] as String,
              row['field'] as String,
              jsonDecode(row['value'] as String),
            ),
            'ts': row['ts'],
            'device': row['device'],
          });
          batchIds.add(row['id'] as String);
          if (ops.length >= 500) break;
        }

        final body = <String, dynamic>{
          'device': _deviceId,
          'cursor': _cursor,
          'ops': ops,
          'features': _features,
          if (_backfillSeq > 0) 'backfillAck': _backfillSeq,
        };

        final json = await client.post('/api/v1/sync', body: body) as Map<String, dynamic>;
        pages++;

        // The server took the batch (applied or duplicates): the outbox rows go.
        if (ops.isNotEmpty) {
          sent.addAll(batchIds);
          await db.dropOutbox(batchIds);
        }
        applied += (json['applied'] as num?)?.toInt() ?? 0;

        // Refused ops are a verdict: drop them locally instead of retrying forever.
        final rejectedOps = (json['rejected'] as List?) ?? const [];
        await db.dropOutbox([
          for (final r in rejectedOps)
            if (r is Map && r['id'] != null) r['id'].toString(),
        ]);
        rejected += rejectedOps.length;

        // Apply everything pulled, newest winner per field.
        final incoming = (json['ops'] as List?) ?? const [];
        final page = [
          for (final raw in incoming)
            if (raw is Map) raw.cast<String, dynamic>(),
        ];
        await db.applyOps([
          if (E2eeSession.instance.enabled)
            for (final op in page) E2eeSession.instance.openOp(op)
          else
            ...page,
        ]);
        for (final op in page) {
          clock.observe(((op['ts'] as num?) ?? 0).toInt());
        }
        pulled += page.length;

        for (final p in (json['purged'] as List?) ?? const []) {
          if (p is Map) await db.purgeEntity(p['entity'].toString(), p['entityId'].toString());
        }

        _cursor = (json['cursor'] as num?)?.toInt() ?? _cursor;
        await db.setMetaInt('sync.cursor', _cursor);
        _backfillSeq = (json['backfillSeq'] as num?)?.toInt() ?? 0;
        if (_backfillSeq > 0) await db.setMetaInt('sync.backfillSeq', _backfillSeq);
        more = json['hasMore'] == true;

        final serverTime = (json['serverTime'] as num?)?.toInt();
        if (serverTime != null) await clock.adopt(serverTime);

        if (json['memberships'] != null) {
          await db.setMeta('sync.memberships', jsonEncode(json['memberships']));
        }
        if (json['workspaces'] != null) {
          await db.setMeta('sync.workspaces', jsonEncode(json['workspaces']));
        }

        final generation = json['generation']?.toString();
        if (generation != null && generation.isNotEmpty) {
          if (_generation != null && _generation != generation) {
            // The server was restored from a backup: re-send everything we hold
            // with the clocks we already stored, then read the log again.
            await _reseed();
          }
          _generation = generation;
          await db.setMeta('sync.generation', generation);
        }
      }

      _pending = (await db.pendingOps(limit: 1)).length;
      _lastSync = DateTime.now();
      return SyncResult(applied: applied, pulled: pulled, rejected: rejected, pending: _pending, pages: pages);
    } on ApiException catch (e) {
      _failure = e;
      rethrow;
    } finally {
      _running = false;
      _status.add(null);
    }
  }

  /// After a restore, every stored field is re-emitted with its stored clock so
  /// the server ends up with exactly the state this device has.
  Future<void> _reseed() async {
    final rows = await db.rawAllFields();
    for (final row in rows) {
      await db.queueExistingField(row);
    }
    _cursor = 0;
    await db.setMetaInt('sync.cursor', 0);
  }

  static String _randomId() {
    final random = Stopwatch()..start();
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final mix = (stamp * 31 + random.elapsedMicroseconds) & 0xFFFFFFFFFFFF;
    return '${stamp.toRadixString(16)}${mix.toRadixString(16).padLeft(12, '0')}';
  }

  // ---- live updates ------------------------------------------------------

  StreamSubscription<String>? _liveSubscription;
  Timer? _reconnect;
  bool _live = false;
  bool _liveStopped = false;
  int _backoffSeconds = 1;

  bool get isLive => _live;

  /// Subscribes to `GET /api/v1/sync/events?device=…`. The stream carries only a
  /// cursor, so a wake-up costs one exchange; a lost event is harmless because
  /// polling continues.
  Future<void> startLive() async {
    if (_liveSubscription != null) return;
    _liveStopped = false;
    if (_deviceId.isEmpty) _deviceId = await _loadDeviceId();
    try {
      final response = await client.openStream('/api/v1/sync/events', query: {'device': _deviceId});
      if (response.statusCode != 200) {
        _scheduleReconnect();
        return;
      }
      _live = true;
      _backoffSeconds = 1;
      var event = '';
      final buffer = StringBuffer();
      _liveSubscription = response.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
        (line) {
          if (line.startsWith('event:')) {
            event = line.substring(6).trim();
          } else if (line.startsWith('data:')) {
            buffer.write(line.substring(5).trim());
          } else if (line.isEmpty) {
            final data = buffer.toString();
            buffer.clear();
            if (event == 'ops' && data.isNotEmpty) _onWake(data);
            event = '';
          }
        },
        onError: (_) => _closeLive(),
        onDone: _closeLive,
        cancelOnError: true,
      );
      _status.add(null);
    } on Object {
      _scheduleReconnect();
    }
  }

  void _onWake(String data) {
    int? cursor;
    try {
      final decoded = jsonDecode(data);
      if (decoded is Map) cursor = (decoded['cursor'] as num?)?.toInt();
    } on FormatException {
      // a malformed wake-up still means "something changed"
    }
    if (cursor != null && cursor <= _cursor) return; // already read past it
    unawaited(exchange().catchError((Object _) => const SyncResult(
        applied: 0, pulled: 0, rejected: 0, pending: 0, pages: 0)));
  }

  void _closeLive() {
    _liveSubscription?.cancel();
    _liveSubscription = null;
    _live = false;
    _scheduleReconnect();
    _status.add(null);
  }

  void _scheduleReconnect() {
    if (_liveStopped) return;
    _reconnect?.cancel();
    _reconnect = Timer(Duration(seconds: _backoffSeconds), () {
      _backoffSeconds = (_backoffSeconds * 2).clamp(1, 30);
      startLive();
    });
  }

  void stopLive() {
    _liveStopped = true;
    _reconnect?.cancel();
    _reconnect = null;
    _liveSubscription?.cancel();
    _liveSubscription = null;
    _live = false;
  }
}
