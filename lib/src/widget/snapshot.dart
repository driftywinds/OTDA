import '../data/models.dart';
import '../data/recurrence.dart';
import '../data/views.dart';

/// The widget's JSON, built here so the native side never decides what is due.
///
/// Sections follow the blueprint: Overdue, Today, Tomorrow, This week, Later, each
/// only when it has rows. Rows use [upcomingDay], the same function Upcoming uses,
/// so a repeating task completed today is listed on its next occurrence.
Map<String, Object?> buildWidgetSnapshot(
  List<Task> tasks,
  List<Project> projects, {
  String? projectId,
  required String today,
  int limit = 30,
}) {
  final names = {for (final project in projects) project.id: project.name};
  final rows = <(String, String, Task)>[]; // section, day, task
  for (final task in tasks) {
    if (task.isDeleted || task.raw['series_id'] != null) continue;
    if (projectId != null && projectId != 'all' && task.projectId != projectId) continue;
    // Upcoming offers what is *ahead*, so a repeating task due today is projected to
    // tomorrow. A glance surface needs the occurrence in front of you, so the widget
    // takes the current occurrence when it is due today or already overdue and only
    // projects when the series has moved past it.
    final due = task.dueDate;
    final current = isRecurring(task) && !task.isCompleted && due != null && due.compareTo(today) <= 0;
    final day = current ? due : upcomingDay(task, tasks, today) ??
        (task.isCompleted || isRecurring(task) ? null : due);
    if (day == null) {
      // A task added from the widget's own "+" often has no date yet; hiding it
      // would make the widget look like the add did nothing. It waits under
      // Anytime at the end, like the Upcoming view.
      if (inAnytime(task.raw, today)) {
        rows.add(('Anytime', '', task));
      }
      continue;
    }
    rows.add((_sectionFor(day, today), day, task));
  }

  final order = ['Overdue', 'Today', 'Tomorrow', 'This week', 'Later', 'Anytime'];
  rows.sort((a, b) {
    final section = order.indexOf(a.$1).compareTo(order.indexOf(b.$1));
    if (section != 0) return section;
    return '${a.$2}${a.$3.dueTime ?? ''}'.compareTo('${b.$2}${b.$3.dueTime ?? ''}');
  });

  final entries = <Map<String, Object?>>[];
  String? section;
  var more = 0;
  for (final (label, day, task) in rows) {
    if (entries.where((e) => e['t'] == 'task').length >= limit) {
      more++;
      continue;
    }
    if (label != section) {
      section = label;
      entries.add({'t': 'section', 'label': label});
    }
    entries.add({
      't': 'task',
      'id': task.id,
      'day': day,
      'title': task.title.isEmpty ? 'Task' : task.title,
      'right': day.isEmpty ? '' : (day == today ? (task.dueTime ?? '') : _shortDay(day)),
      'overdue': label == 'Overdue',
      'done': task.isCompleted,
      if (names[task.projectId ?? ''] != null) 'project': names[task.projectId ?? ''],
    });
  }

  final project = projectId == null || projectId == 'all' ? null : projects.where((p) => p.id == projectId).firstOrNull;
  return {
    'v': 1,
    'generatedAt': DateTime.now().millisecondsSinceEpoch,
    'today': today,
    'project': project == null
        ? null
        : {'id': project.id, 'name': project.name, 'emoji': '', 'color': project.color ?? '#64748b'},
    'refreshing': false,
    'rows': entries,
    'more': more,
  };
}

/// The project index the native picker reads with the app closed.
List<Map<String, Object?>> projectsIndex(List<Project> projects) => [
      for (final project in projects)
        if (!project.isDeleted)
          {'id': project.id, 'name': project.name, 'emoji': '', 'color': project.color ?? '#64748b'},
    ];

String _sectionFor(String day, String today) {
  if (day.compareTo(today) < 0) return 'Overdue';
  if (day == today) return 'Today';
  if (day == _addDays(today, 1)) return 'Tomorrow';
  if (day.compareTo(_addDays(today, 7)) <= 0) return 'This week';
  return 'Later';
}

String _addDays(String day, int days) {
  final date = DateTime.parse(day);
  final moved = DateTime(date.year, date.month, date.day + days);
  return '${moved.year.toString().padLeft(4, '0')}-'
      '${moved.month.toString().padLeft(2, '0')}-'
      '${moved.day.toString().padLeft(2, '0')}';
}

String _shortDay(String day) {
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  final date = DateTime.tryParse(day);
  if (date == null) return day;
  return '${date.day} ${months[date.month - 1]}';
}
