/// Which fields carry content and are therefore encrypted. Everything else stays
/// plaintext because the server merges, authorises, sorts or schedules by it: ids,
/// dates, priority, recurrence, positions, relations, timestamps.
///
/// The list follows the server's spec table; a field that is missing here would
/// travel in plaintext and a field wrongly listed would break a server feature.
library;

const _task = {
  'title',
  'description',
  'ical_extra',
  'notes_doc',
  'origin',
  'location',
};

const _project = {'name', 'description', 'notes_doc'};

const _byEntity = <String, Set<String>>{
  'task': _task,
  'project': _project,
  'label': {'name'},
  'section': {'name'},
  'saved_view': {'name', 'query'},
  'comment': {'body'},
  'attachment': {'name', 'mime', 'url'},
  'time_entry': {'note'},
  'review': {'tomorrow_note'},
  'objective': {'title'},
  'memory': {'text'},
  'note': {'title', 'description', 'notes_doc'},
  'routine': {'name'},
  'calendar_frame': {'title'},
  'slot': {'title'},
  'saved_location': {'name', 'address', 'geo'},
  'custom_field': {'name', 'options'},
  'preferences': {'priority_name_1', 'priority_name_2', 'priority_name_3', 'priority_name_4'},
};

/// `fields.<definition id>` on a task: only the string values (text, link, date,
/// choice) are encrypted; numbers and checkboxes stay plaintext because they are
/// sorted and filtered on the server.
bool _isCustomValue(String entity, String field) =>
    entity == 'task' && field.startsWith('fields.') && field.length > 'fields.'.length;

/// `appends.<id>` on a note or a task: text appended to the note.
bool _isAppend(String entity, String field) =>
    (entity == 'note' || entity == 'task') && field.startsWith('appends.');

bool isContentField(String entity, String field) {
  if (_byEntity[entity]?.contains(field) ?? false) return true;
  if (_isCustomValue(entity, field)) return true;
  if (_isAppend(entity, field)) return true;
  return false;
}
