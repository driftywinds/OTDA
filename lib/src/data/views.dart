/// The view rules, ported from `web/src/lib/views.ts` and `inbox.ts` (and their
/// Go twins), so OTDA lists exactly what the web app lists. The Inbox and
/// Anytime/Someday cases are pinned by `test/fixtures/*.vectors.json`.
library;

bool _completed(Map<String, Object?> t) => t['completed_at'] != null;
bool _deleted(Map<String, Object?> t) => t['deleted_at'] != null;

bool hasDue(Map<String, Object?> t) => t['due'] is Map && (t['due'] as Map)['date'] != null;

String _dueDate(Map<String, Object?> t) =>
    t['due'] is Map ? ((t['due'] as Map)['date']?.toString() ?? '') : '';

String start(Map<String, Object?> t) => t['start']?.toString() ?? '';
String sector(Map<String, Object?> t) => t['sector']?.toString() ?? '';
String deadline(Map<String, Object?> t) => t['deadline']?.toString() ?? '';

// ---- Inbox (inbox.ts) ---------------------------------------------------

/// A do-on date, a start date, Someday or a time sector.
bool scheduled(Map<String, Object?> t) => hasDue(t) || start(t).isNotEmpty || sector(t).isNotEmpty;

/// A project or a schedule: a place outside the Inbox.
bool placed(Map<String, Object?> t) =>
    (t['project_id']?.toString() ?? '').isNotEmpty || scheduled(t);

/// The web client's Inbox predicate, kept for the shared view vectors. The app's
/// Inbox is a consolidated all-project list now; [home_screen] does not use this.
bool inInbox(Map<String, Object?> task, {List<Map<String, Object?>> parents = const []}) {
  if (_completed(task) || _deleted(task) || placed(task)) return false;
  for (final parent in parents) {
    if (placed(parent)) return false;
  }
  return true;
}

/// Walks a subtask's ancestors through [byId] and applies [inInbox].
bool inInboxOf(Map<String, Object?> task, Map<String, Map<String, Object?>> byId) {
  final parents = <Map<String, Object?>>[];
  var parent = task['parent_id']?.toString() ?? '';
  for (var depth = 0; parent.isNotEmpty && depth < 64; depth++) {
    final found = byId[parent];
    if (found == null) break; // an unknown parent ends the walk
    parents.add(found);
    parent = found['parent_id']?.toString() ?? '';
  }
  return inInbox(task, parents: parents);
}

// ---- Today, Someday, Anytime (views.ts) ---------------------------------

/// Parked in Someday.
bool isSomeday(Map<String, Object?> t) => start(t) == 'someday';

/// A start date still in the future.
bool isDeferred(Map<String, Object?> t, String today) =>
    start(t).isNotEmpty && start(t) != 'someday' && start(t).compareTo(today) > 0;

/// A start date that has come: the task stays in Today until handled.
bool isStarted(Map<String, Object?> t, String today) =>
    start(t).isNotEmpty && start(t) != 'someday' && start(t).compareTo(today) <= 0;

/// Neither parked nor deferred.
bool isActive(Map<String, Object?> t, String today) => !isSomeday(t) && !isDeferred(t, today);

/// A due date or deadline today or earlier: wins over deferral and parking.
bool _hardDate(Map<String, Object?> t, String today) =>
    (_dueDate(t).isNotEmpty && _dueDate(t).compareTo(today) <= 0) ||
    (deadline(t).isNotEmpty && deadline(t).compareTo(today) <= 0);

/// Open, due today or earlier, deadline passed, or the start date has come.
bool inToday(Map<String, Object?> t, String today) {
  if (_completed(t)) return false;
  return _hardDate(t, today) || isStarted(t, today);
}

/// Open, active, with no date of any kind and no start.
bool inAnytime(Map<String, Object?> t, String today) =>
    !_completed(t) &&
    !_deleted(t) &&
    isActive(t, today) &&
    !hasDue(t) &&
    deadline(t).isEmpty &&
    start(t).isEmpty &&
    sector(t).isEmpty;

/// The sidebar count: open and active.
bool countsAsOpen(Map<String, Object?> t, String today) => !_completed(t) && isActive(t, today);

/// Someday, for the Someday view: open and parked.
bool inSomedayView(Map<String, Object?> t) => !_completed(t) && isSomeday(t);
