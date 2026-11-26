import 'models.dart';

/// Whether a task is "kept": open, live, and under a completed ancestor. These are
/// the subtasks left open by the account's `complete_subtasks = keep` preference.
/// They stay in their parent's Subtasks section, but not in lists, search, counts,
/// reminders or the widget.
bool isKept(Task task, Map<String, Task> byId) {
  if (task.isCompleted || task.isDeleted) return false;
  var parentId = task.raw['parent_id']?.toString() ?? '';
  if (parentId.isEmpty) return false;
  final seen = <String>{task.id};
  for (var depth = 0; parentId.isNotEmpty && depth < 64; depth++) {
    if (!seen.add(parentId)) return false; // damaged cycle
    final parent = byId[parentId];
    if (parent == null || parent.isDeleted) return false;
    if (parent.isCompleted) return true;
    parentId = parent.raw['parent_id']?.toString() ?? '';
  }
  return false;
}

Set<String> keptIds(Iterable<Task> tasks) {
  final byId = {for (final task in tasks) task.id: task};
  return {
    for (final task in tasks)
      if (isKept(task, byId)) task.id,
  };
}

/// The tasks a list may show. The parent task's own Subtasks section uses
/// `childrenOf` directly, so kept children remain visible there.
List<Task> withoutKept(List<Task> tasks) {
  final kept = keptIds(tasks);
  return kept.isEmpty ? tasks : [for (final task in tasks) if (!kept.contains(task.id)) task];
}
