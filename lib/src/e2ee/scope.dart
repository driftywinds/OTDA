import 'dart:convert';

import '../data/db.dart';

/// Which entities live in the account's personal scope, the only scope that is
/// ever encrypted.
///
/// This mirrors the web client's resolver: a task follows its project, sections
/// and fields follow their project, comments/attachments/time entries follow
/// their task, and labels/views/preferences stay personal. A project is shared
/// when the synced membership list has more than one member. Shared projects are
/// never encrypted, even on an encrypted account.
class E2eeScope {
  E2eeScope._(this._db, this._sharedProjects);

  final OtdaDb _db;
  final Set<String> _sharedProjects;
  final Map<String, Map<String, Object?>?> _entities = {};

  static Future<E2eeScope> load(OtdaDb db) async {
    final shared = <String>{};
    final raw = await db.meta('sync.memberships');
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final entry in decoded) {
            if (entry is! Map) continue;
            final members = entry['members'];
            final id = entry['projectId']?.toString() ?? '';
            if (id.isNotEmpty && members is List && members.length > 1) shared.add(id);
          }
        }
      } on FormatException {
        // A corrupt cache only means the resolver cannot prove a project shared;
        // the next sync rewrites it.
      }
    }
    return E2eeScope._(db, shared);
  }

  bool projectShared(String? projectId) => projectId != null && _sharedProjects.contains(projectId);

  Future<Map<String, Object?>?> _entity(String entity, String id) async {
    final key = '$entity:$id';
    if (_entities.containsKey(key)) return _entities[key];
    final row = await _db.entity(entity, id);
    _entities[key] = row;
    return row;
  }

  Future<String?> _ref(String entity, String id, String field) async =>
      (await _entity(entity, id))?[field]?.toString();

  Future<bool> personal(String entity, String id) async {
    switch (entity) {
      case 'project':
        return !projectShared(id);
      case 'task':
        return !projectShared(await _ref('task', id, 'project_id'));
      case 'section':
      case 'field':
      case 'rule':
      case 'note':
        return !projectShared(await _ref(entity, id, 'project_id'));
      case 'comment':
      case 'attachment':
      case 'time_entry':
        final taskId = await _ref(entity, id, 'task_id');
        return taskId == null || !projectShared(await _ref('task', taskId, 'project_id'));
      default:
        return true;
    }
  }
}
