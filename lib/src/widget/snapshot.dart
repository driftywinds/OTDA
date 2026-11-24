import '../data/models.dart';
import '../data/recurrence.dart';
import '../data/views.dart';

/// The widget's JSON, built here so the native side never decides what is due.
///
/// Sections follow the blueprint: Overdue, Today, Tomorrow, This week, Later, each
/// only when it has rows. Rows use [upcomingDay], the same function Upcoming uses,
/// so a repeating task completed today is listed on its next occurrence.
///
/// [ack] is the newest widget tap the app had applied when [tasks] was read. The native
/// side lays every tap newer than that over the rows it draws, which is what keeps a
/// snapshot that took seconds to build from undoing a tap made while it was building.
Map<String, Object?> buildWidgetSnapshot(
  List<Task> tasks,
  List<Project> projects, {
  String? projectId,
  required String today,
  int limit = 30,
  int? ack,
}) =>
    _assemble(_candidates(tasks, today), projects, projectId: projectId, today: today, limit: limit, ack: ack);

/// Every snapshot a push needs ('all' and one per project id), sharing the part that is the same for
/// all of them. Working out which day each task belongs to costs a pass over every task per repeating
/// series, so doing it once per project (as a loop over [buildWidgetSnapshot] would) made a tick on the
/// widget slower the more projects there were.
Map<String, Map<String, Object?>> buildWidgetSnapshots(
  List<Task> tasks,
  List<Project> projects, {
  required Iterable<String> projectIds,
  required String today,
  int limit = 30,
  int? ack,
}) {
  final candidates = _candidates(tasks, today);
  return {
    for (final id in projectIds)
      id: _assemble(candidates, projects, projectId: id == 'all' ? null : id, today: today, limit: limit, ack: ack),
  };
}

/// One task's place in the widget, before any project filter or limit.
class _Candidate {
  const _Candidate(this.section, this.day, this.task);

  final String section;
  final String day;
  final Task task;
}

const _sectionOrder = ['Done today', 'Overdue', 'Today', 'Tomorrow', 'This week', 'Later', 'Anytime'];

List<_Candidate> _candidates(List<Task> tasks, String today) {
  final rows = <_Candidate>[];
  bool finishedToday(Task task) {
    final millis = task.completedAt;
    if (millis == null || task.isDeleted) return false;
    final when = DateTime.fromMillisecondsSinceEpoch(millis);
    final day = '${when.year.toString().padLeft(4, '0')}-'
        '${when.month.toString().padLeft(2, '0')}-'
        '${when.day.toString().padLeft(2, '0')}';
    return day == today;
  }

  for (final task in tasks) {
    if (task.isDeleted) continue;
    // A finished row stays in front of the person who ticked it: today's done
    // tasks get their own section above Overdue and Today, including a repeating
    // task's finished occurrence record.
    if (finishedToday(task)) {
      rows.add(_Candidate('Done today', task.dueDate ?? today, task));
      continue;
    }
    if (task.raw['series_id'] != null) continue;
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
        rows.add(_Candidate('Anytime', '', task));
      }
      continue;
    }
    rows.add(_Candidate(_sectionFor(day, today), day, task));
  }

  rows.sort((a, b) {
    final section = _sectionOrder.indexOf(a.section).compareTo(_sectionOrder.indexOf(b.section));
    if (section != 0) return section;
    if (a.section == 'Done today') {
      // Most recently ticked first.
      return (b.task.completedAt ?? 0).compareTo(a.task.completedAt ?? 0);
    }
    return '${a.day}${a.task.dueTime ?? ''}'.compareTo('${b.day}${b.task.dueTime ?? ''}');
  });
  return rows;
}

Map<String, Object?> _assemble(
  List<_Candidate> candidates,
  List<Project> projects, {
  required String? projectId,
  required String today,
  required int limit,
  required int? ack,
}) {
  final names = {for (final project in projects) project.id: project.name};
  final entries = <Map<String, Object?>>[];
  String? section;
  var shown = 0;
  var more = 0;
  for (final candidate in candidates) {
    final task = candidate.task;
    if (projectId != null && projectId != 'all' && task.projectId != projectId) continue;
    if (shown >= limit) {
      more++;
      continue;
    }
    final label = candidate.section;
    final day = candidate.day;
    if (label != section) {
      section = label;
      entries.add({'t': 'section', 'label': label});
    }
    shown++;
    // A repeating task's tick writes a separate record for that date and moves the series on, so the
    // row you tap (the series) and the row that shows done afterwards (the record) have different
    // ids. `sid` + `occ` name the same occurrence for both, which is how the widget keeps a tap on
    // one attached to the other.
    final recordOf = task.raw['series_id']?.toString();
    final sid = (recordOf != null && recordOf.isNotEmpty) ? recordOf : (isRecurring(task) ? task.id : null);
    final occurrence = task.raw['occurrence_date']?.toString();
    final occ = (occurrence != null && occurrence.isNotEmpty) ? occurrence : (sid != null && day.isNotEmpty ? day : null);
    entries.add({
      't': 'task',
      'id': task.id,
      'day': day,
      'title': task.title.isEmpty ? 'Task' : task.title,
      'right': _right(day, today, task.dueTime),
      'overdue': label == 'Overdue',
      'done': task.isCompleted,
      'sid': ?sid,
      if (sid != null && occ != null) 'occ': occ,
      if (names[task.projectId ?? ''] != null) 'project': names[task.projectId ?? ''],
    });
  }

  final project = projectId == null || projectId == 'all' ? null : projects.where((p) => p.id == projectId).firstOrNull;
  return {
    'v': 1,
    'generatedAt': DateTime.now().millisecondsSinceEpoch,
    'today': today,
    'ack': ?ack,
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

/// The widget's right-hand text: the time today, and the day *and time* for
/// anything later. A task due next Tuesday at 09:00 used to read "24 Nov",
/// losing the time the person had assigned.
String _right(String day, String today, String? time) {
  if (day.isEmpty) return '';
  final clock = (time == null || time.isEmpty) ? null : time;
  if (day == today) return clock ?? '';
  return clock == null ? _shortDay(day) : '${_shortDay(day)} $clock';
}
