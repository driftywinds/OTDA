import 'dart:async';


import 'dart:convert';

import '../api/api_client.dart';
import '../api/api_exception.dart';
import '../e2ee/session.dart';
import 'clock.dart';
import 'db.dart';
import '../util/log.dart';

/// How far a running exchange has got. [total] is the number of operation-log
/// positions the server said were left when the exchange started, or null when
/// the server could not tell us (an older server, or an offline start).
class SyncProgress {
  const SyncProgress({
    required this.pulled,
    required this.pages,
    required this.done,
    required this.total,
  });

  /// Operations applied from the pull so far.
  final int pulled;

  /// Round trips made so far.
  final int pages;

  /// Operation-log positions covered by this exchange.
  final int done;

  /// Operation-log positions this exchange has to cover, when known.
  final int? total;

  /// 0..1, or null while the total is unknown.
  double? get fraction {
    final all = total;
    if (all == null || all <= 0) return null;
    return (done / all).clamp(0.0, 1.0);
  }
}

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

  /// A first copy walks the whole log in one exchange; this is a safety stop,
  /// not a page budget. 5,000 pages is five million operations.
  static const _maxFullSyncPages = 5000;

  int _cursor = 0;
  String? _generation;
  int _backfillSeq = 0;
  bool _running = false;
  DateTime? _lastSync;
  ApiException? _failure;
  int _pending = 0;

  /// True once an exchange has pulled every page up to the server's head and
  /// sent everything this device had queued. The first copy of an account is
  /// not usable until then; later launches read it before touching the network.
  bool _fullSyncDone = false;
  bool get fullSyncDone => _fullSyncDone;

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
    _fullSyncDone = await db.metaInt('sync.full') == 1;
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
  ///
  /// [fullSync] walks the whole log in this one call (the first copy of an
  /// account) instead of stopping after [_maxPages] pages. [onProgress] is
  /// called after every page; a first copy of a 10,000-task account is about
  /// 105,000 operations, so 106 pages, and the gate needs to say how far it is.
  Future<SyncResult> exchange({bool fullSync = false, void Function(SyncProgress)? onProgress}) async {
    if (_deviceId.isEmpty) {
      _deviceId = await _loadDeviceId();
    }
    if (_running) return const SyncResult(applied: 0, pulled: 0, rejected: 0, pending: 0, pages: 0);
    // An encrypted account with no key here must not pull: the batch would land as
    // ciphertext in the replica. The app asks for the passphrase instead.
    _running = true;
    _failure = null;
    _status.add(null);

    var applied = 0;
    var pulled = 0;
    var rejected = 0;
    var pages = 0;
    var more = true;
    final sent = <String>[];
    var startCursor = _cursor;
    // The head is a cheap push-only exchange (no pull). Its cursor is the last
    // position of this account's log, so `head - start` is what this copy has to
    // cover: enough for a progress bar. A server that does not know push_only
    // answers with a page instead; then the total stays unknown.
    final head = fullSync ? await _probeHead() : null;
    final total = head != null && head > startCursor ? head - startCursor : null;

    try {
      final maxPages = fullSync ? _maxFullSyncPages : _maxPages;
      while (pages < maxPages) {
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

        otdaLog('sync: posting page ${pages + 1} with ${ops.length} op(s), cursor=$_cursor');
        final Object? response;
        try {
          response = await client.post('/api/v1/sync', body: body);
        } on Object catch (e) {
          otdaLog('sync: POST failed: $e');
          rethrow;
        }
        final json = response as Map<String, dynamic>;
        pages++;
        otdaLog('sync: page $pages applied=${json['applied']} ops=${(json['ops'] as List?)?.length ?? 0}');

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
        // A first login on a long history is hundreds of pages of ops: give the
        // frame loop a turn between them so the app stays answerable (and is not
        // mistaken for hung while it catches up).
        await Future<void>.delayed(Duration.zero);
        await db.setMetaInt('sync.cursor', _cursor);
        _backfillSeq = (json['backfillSeq'] as num?)?.toInt() ?? 0;
        if (_backfillSeq > 0) await db.setMetaInt('sync.backfillSeq', _backfillSeq);
        more = json['hasMore'] == true;
        // A page can leave the outbox non-empty (more queued than one batch);
        // go round again to send it even when the pull is finished.
        if (!more && await db.outboxCount() > 0) more = true;
        onProgress?.call(SyncProgress(
          pulled: pulled,
          pages: pages,
          done: _cursor - startCursor,
          total: total,
        ));

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
            startCursor = 0;
          }
          _generation = generation;
          await db.setMeta('sync.generation', generation);
        }
        if (!more) break;
      }

      if (more) {
        // The safety stop was reached before the head. A first copy must never
        // claim completeness; a normal exchange simply keeps the cursor and the
        // next tick continues from there.
        if (!fullSync) {
          _pending = await db.outboxCount();
          _lastSync = DateTime.now();
          return SyncResult(applied: applied, pulled: pulled, rejected: rejected, pending: _pending, pages: pages);
        }
        throw ApiException(0, 'sync_incomplete',
            'the server has more history than one pass can carry; try again to continue');
      }
      _fullSyncDone = true;
      await db.setMetaInt('sync.full', 1);
      _pending = await db.outboxCount();
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

  /// The newest position of this account's log, without pulling anything.
  ///
  /// The sync request accepts `push_only`: the server applies the (empty) batch
  /// and answers its head cursor. That is the denominator of the first-copy
  /// progress bar. A server without the feature answers with a page of ops
  /// instead; those are ignored and the total stays unknown, which only costs
  /// the bar, not correctness.
  Future<int?> _probeHead() async {
    try {
      final response = await client.post('/api/v1/sync', body: {
        'device': _deviceId,
        'cursor': _cursor,
        'ops': const <Object>[],
        'features': [..._features, 'push_only'],
      });
      if (response is! Map) return null;
      final ops = response['ops'];
      if (response['hasMore'] == true || (ops is List && ops.isNotEmpty)) return null;
      final cursor = (response['cursor'] as num?)?.toInt();
      return cursor == null || cursor < _cursor ? null : cursor;
    } on Object catch (e) {
      otdaLog('sync: head probe failed: $e');
      return null;
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
    // The restored server's log is a new history, so the copy is not complete
    // until it has been read again.
    _fullSyncDone = false;
    await db.setMetaInt('sync.full', 0);
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
