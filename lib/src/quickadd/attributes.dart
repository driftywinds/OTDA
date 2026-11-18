// Language-independent attribute tokens: #project, @label, p1–p4 and durations.
// Ported from web/src/lib/nlp/attributes.ts.
import 'vocab/index.dart';

/// The slice of a project the matcher needs; archived and deleted projects are ignored.
class ProjectRef {
  const ProjectRef({
    required this.id,
    required this.name,
    this.archived = false,
    this.deletedAt,
    this.parentId,
  });

  final String id;
  final String name;
  final bool archived;
  final int? deletedAt;

  /// Parent project for nested projects; used only to break ties between equal names.
  final String? parentId;
}

/// Upper bound for an estimate: one week, mirrors `MaxPositiveInt` on the server.
const int maxEstimateMinutes = 10080;

/// Fold a project name or a #token for comparison: no case, diacritics or spaces.
String foldName(String s) => normalize(s).replaceAll(RegExp(r'[\s_-]+'), '');

/// Depth of a project in the visible tree: 0 at the top level. A parent that is
/// missing, archived or deleted ends the walk, and a parent cycle is cut, so this
/// always terminates.
int _depthOf(ProjectRef p, Map<String, ProjectRef> byId) {
  var depth = 0;
  final seen = <String>{p.id};
  var cur = p;
  while (true) {
    final parentId = cur.parentId;
    if (parentId == null) break;
    final parent = byId[parentId];
    if (parent == null || seen.contains(parent.id)) break;
    seen.add(parent.id);
    depth++;
    cur = parent;
  }
  return depth;
}

bool _live(ProjectRef p) => !p.archived && p.deletedAt == null;

/// Resolve a `#name` token against every live project, nested ones included: exact
/// (folded) match first, then a unique prefix. Several projects with exactly the
/// same name resolve to the shallowest one in the tree (then the smallest id). An
/// ambiguous prefix, or no match, returns null and the token stays in the title.
ProjectRef? matchProject(String token, List<ProjectRef> projects) {
  if (!token.startsWith('#') || token.length < 2) return null;
  if (token.contains('/')) return matchProjectPath(token, projects);
  final want = foldName(token.substring(1));
  if (want.isEmpty) return null;
  final live = projects.where(_live).toList();
  final exact = live.where((p) => foldName(p.name) == want).toList();
  if (exact.length == 1) return exact[0];
  if (exact.length > 1) {
    final byId = {for (final p in live) p.id: p};
    final ranked = exact.map((p) => (p: p, depth: _depthOf(p, byId))).toList();
    ranked.sort((a, b) {
      final byDepth = a.depth - b.depth;
      return byDepth != 0 ? byDepth : a.p.id.compareTo(b.p.id);
    });
    return ranked[0].p;
  }
  final prefix = live.where((p) => foldName(p.name).startsWith(want)).toList();
  return prefix.length == 1 ? prefix[0] : null;
}

/// A `#Parent/Child` path (smart-title-tokens D2): every segment matches a project
/// name exactly (folded) and each is the parent of the next. No prefix matching.
ProjectRef? matchProjectPath(String token, List<ProjectRef> projects) {
  final parts = token.substring(1).split('/').map(foldName).toList();
  if (parts.length < 2 || parts.any((x) => x.isEmpty)) return null;
  final live = projects.where(_live).toList();
  final byId = {for (final p in live) p.id: p};
  bool fits(ProjectRef p) {
    ProjectRef? cur = p;
    for (var i = parts.length - 1; i >= 0; i--) {
      if (cur == null || foldName(cur.name) != parts[i]) return false;
      if (i > 0) {
        final parentId = cur.parentId;
        cur = parentId == null ? null : byId[parentId];
      }
    }
    return true;
  }

  final found = live.where(fits).toList();
  if (found.isEmpty) return null;
  found.sort((a, b) {
    final byDepth = _depthOf(a, byId) - _depthOf(b, byId);
    return byDepth != 0 ? byDepth : a.id.compareTo(b.id);
  });
  return found[0];
}

/// Why a `#token` names no project: none starts with it, or several do
/// (smart-title-tokens D4).
({String reason, int? count})? projectMiss(String token, List<ProjectRef> projects) {
  if (!token.startsWith('#') || token.length < 2 || matchProject(token, projects) != null) return null;
  final want = foldName(token.substring(1).split('/').last);
  if (want.isEmpty) return null;
  final n = projects.where((p) => _live(p) && foldName(p.name).startsWith(want)).length;
  return n > 1 && !token.contains('/') ? (reason: 'ambiguous', count: n) : (reason: 'none', count: null);
}

final RegExp _labelTrailing = RegExp(r'[,;]+$');

/// `@name` → `name`, exactly as typed (trailing comma dropped); null otherwise.
String? matchLabel(String token) {
  if (!token.startsWith('@') || token.length < 2) return null;
  final name = token.substring(1).replaceFirst(_labelTrailing, '');
  return name.isNotEmpty && !RegExp(r'\s').hasMatch(name) ? name : null;
}

/// `p1`–`p4` (any case) → priority.
int? matchPriority(String token) {
  final m = RegExp(r'^p([1-4])$', caseSensitive: false).firstMatch(token.replaceFirst(_labelTrailing, ''));
  return m == null ? null : int.parse(m[1]!);
}

/// `~deep`, `~medium`, `~low` or any shorter prefix (`~d`, `~me`), any case, a
/// trailing comma dropped → the energy (task-energy D4); null otherwise, so `~6`
/// stays text.
String? matchEnergy(String token) {
  final m = RegExp(r'^~([a-z]+)$', caseSensitive: false).firstMatch(token.replaceFirst(_labelTrailing, ''));
  if (m == null) return null;
  final w = m[1]!.toLowerCase();
  for (final e in ['deep', 'medium', 'low']) {
    if (e.startsWith(w)) return e;
  }
  return null;
}

const String _spentPart = r'(\d+(?:[.,]\d+)?h(?:\d{1,2}(?:m|min)?)?|\d+(?:m|min|mins|minutes))';
final RegExp _spentRe = RegExp('^' + _spentPart + '/' + _spentPart + r'$');
final RegExp _spentHours = RegExp(r'^(\d+(?:[.,]\d+)?)h(?:(\d{1,2})(?:m|min)?)?$');
final RegExp _spentMinutes = RegExp(r'^(\d+)(?:m|min|mins|minutes)$');

/// One part of a spent token in minutes, or null (both parts carry a unit).
int? _spentPartOf(String s) {
  var m = _spentHours.firstMatch(s);
  int? v;
  if (m != null) {
    final mins = m[2] == null ? 0 : int.parse(m[2]!);
    if (mins > 59) return null;
    v = (double.parse(m[1]!.replaceAll(',', '.')) * 60 + mins).round();
  } else {
    m = _spentMinutes.firstMatch(s);
    if (m != null) v = int.parse(m[1]!);
  }
  return v != null && v >= 1 && v <= maxEstimateMinutes ? v : null;
}

/// Time already spent and an estimate, `<spent>/<estimate>` (time-tracking D10):
/// `30m/2h`, `1h/1h30`, `45min/2h`. Both parts need a unit, so a day-month date
/// such as `30/12` never matches, and there is no `+`.
({int spent, int estimate})? matchSpent(String token) {
  final m = _spentRe.firstMatch(token.replaceFirst(_labelTrailing, '').toLowerCase());
  if (m == null) return null;
  final spent = _spentPartOf(m[1]!);
  final estimate = _spentPartOf(m[2]!);
  return spent != null && estimate != null ? (spent: spent, estimate: estimate) : null;
}

final RegExp _durationHours = RegExp(r'^(\d+(?:[.,]\d+)?)h(?:(\d{1,2})(?:m|min)?)?$');
final RegExp _durationMinutes = RegExp(r'^(\d+)(m|min|mins|minutes)$');
final RegExp _durationBare = RegExp(r'^(\d+)$');

/// Durations. With a leading `+` any of `+30`, `+30m`, `+45min`, `+2h`, `+1.5h`,
/// `+1h30`, `+1h30m` is an estimate in minutes. Without the `+`, `45min` and `2h`
/// are accepted too, except that `2h` is left alone when `bareHourIsTime` is set
/// (an active language writes clock times as "15h"). Out-of-range values do not match.
int? matchDuration(String token, {required bool bareHourIsTime}) {
  final t = token.replaceFirst(_labelTrailing, '').toLowerCase();
  final plus = t.startsWith('+');
  final body = plus ? t.substring(1) : t;
  if (body.isEmpty) return null;
  int? minutes;
  var m = _durationHours.firstMatch(body);
  if (m != null) {
    // 2h, 1.5h, 1h30, 1h30m
    final hours = double.parse(m[1]!.replaceAll(',', '.'));
    final mins = m[2] == null ? 0 : int.parse(m[2]!);
    if (mins > 59) return null;
    if (!plus && (bareHourIsTime || m[2] != null)) return null;
    minutes = (hours * 60 + mins).round();
  } else if ((m = _durationMinutes.firstMatch(body)) != null) {
    if (!plus && m[2] == 'm') return null; // bare "30m" could be metres
    minutes = int.parse(m[1]!);
  } else if (plus && (m = _durationBare.firstMatch(body)) != null) {
    minutes = int.parse(m[1]!);
  }
  if (minutes == null || minutes < 1 || minutes > maxEstimateMinutes) return null;
  return minutes;
}
