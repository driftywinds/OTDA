import '../quickadd_bridge.dart';

/// The composer's values, and who set each one.
///
/// A value can come from the line being typed or from a control the person
/// tapped. That distinction is the whole point: clearing the input must clear
/// everything the line had contributed, but never something set by hand.
class ComposerState {
  ComposerState({String? projectId})
      : projectId = projectId,
        _manual = {if (projectId != null) 'project'};

  String? dueDate;
  String? dueTime;
  int? estimate;
  String? recurrence;
  int priority = 4;
  String? projectId;

  /// Fields a person set, which the parser must not overwrite or clear.
  final Set<String> _manual;

  bool isManual(String field) => _manual.contains(field);

  /// A control was used: from now on the line leaves this field alone.
  void claim(String field) => _manual.add(field);

  /// A control was cleared: the line may fill it again.
  void release(String field) => _manual.remove(field);

  /// Takes what the line now means, for every field nobody set by hand.
  /// Fields the line no longer sets are cleared, so deleting the word
  /// "tomorrow" removes the date.
  void applyParsed(ParsedLine parsed) {
    final fields = parsed.fields;
    if (!isManual('due')) {
      final due = fields['due'];
      dueDate = due is Map ? due['date']?.toString() : null;
      dueTime = due is Map ? due['time']?.toString() : null;
    }
    if (!isManual('estimate')) {
      estimate = (fields['estimate_minutes'] as num?)?.toInt();
    }
    if (!isManual('recurrence')) {
      final rule = fields['recurrence']?.toString();
      recurrence = (rule == null || rule.isEmpty) ? null : rule;
    }
    if (!isManual('priority')) {
      priority = (fields['priority'] as num?)?.toInt() ?? 4;
    }
    if (!isManual('project')) {
      projectId = fields['project_id']?.toString();
    }
  }
}
