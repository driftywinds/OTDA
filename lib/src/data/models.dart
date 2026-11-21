/// Read models over the local replica's field maps.
///
/// A row is a bag of JSON values keyed by the server's op field names, so a new
/// server field needs no migration here: it just appears in [raw].
class Task {
  Task(this.id, this.raw);

  final String id;
  final Map<String, Object?> raw;

  String get title => raw['title']?.toString() ?? '';

  /// When the task was made, for ordering search results.
  int? get createdAt => (raw['created_at'] as num?)?.toInt();
  bool get isCompleted => raw['completed_at'] != null;
  bool get isDeleted => raw['deleted_at'] != null;
  int get priority => (raw['priority'] as num?)?.toInt() ?? 4;
  String? get projectId => raw['project_id']?.toString();
  String? get sectionId => raw['section_id']?.toString();
  String? get parentId => raw['parent_id']?.toString();
  int? get estimateMinutes => (raw['estimate_minutes'] as num?)?.toInt();

  /// `{date: "YYYY-MM-DD", time?: "HH:MM"}` or null.
  Map<String, Object?>? get due {
    final value = raw['due'];
    return value is Map ? value.cast<String, Object?>() : null;
  }

  String? get dueDate => due?['date']?.toString();
  String? get dueTime => due?['time']?.toString();
  String? get deadline => raw['deadline']?.toString();
  String? get startDate {
    final value = raw['start']?.toString();
    return value == null || value.isEmpty || value == 'someday' ? null : value;
  }

  bool get isSomeday => raw['start']?.toString() == 'someday';
  bool get isEvening => raw['evening'] == true;

  /// When the task was completed, Unix ms, or null while it is open.
  int? get completedAt => (raw['completed_at'] as num?)?.toInt();
  List<String> get labels => ((raw['labels'] as List?) ?? const []).map((e) => e.toString()).toList();

  /// The day this task should surface on, if it has one.
  String? get dayKey => dueDate;
}

class Project {
  Project(this.id, this.raw);

  final String id;
  final Map<String, Object?> raw;

  String get name => raw['name']?.toString() ?? '';
  String? get color => raw['color']?.toString();
  String get icon => raw['icon']?.toString() ?? '';
  String? get parentId => raw['parent_id']?.toString();
  bool get isArchived => raw['archived'] == true;
  bool get isDeleted => raw['deleted_at'] != null;
  double get position => (raw['position'] as num?)?.toDouble() ?? 0;

  /// The workspace the project lives in; null means the account's default one.
  String? get workspaceId => raw['workspace_id']?.toString();
}

class Label {
  Label(this.id, this.raw);

  final String id;
  final Map<String, Object?> raw;

  String get name => raw['name']?.toString() ?? '';
  String? get color => raw['color']?.toString();
  bool get isDeleted => raw['deleted_at'] != null;
  double get position => (raw['position'] as num?)?.toDouble() ?? 0;
}

/// A list of tasks inside one project (OpenTodo's `section` entity).
class Section {
  Section(this.id, this.raw);

  final String id;
  final Map<String, Object?> raw;

  String get name => raw['name']?.toString() ?? '';
  String? get projectId => raw['project_id']?.toString();
  bool get isDeleted => raw['deleted_at'] != null;
  double get position => (raw['position'] as num?)?.toDouble() ?? 0;
}

/// A directory entry from the sync exchange: projects, labels and views live in
/// one, and a person can be in several.
class Workspace {
  Workspace(this.raw);

  final Map<String, dynamic> raw;

  String get id => raw['id']?.toString() ?? '';
  String get name => raw['name']?.toString() ?? '';
  bool get isDefault => raw['default'] == true;

  /// A name from OpenTodo's icon catalogue, e.g. `briefcase`; empty when unset.
  String get icon => raw['icon']?.toString() ?? '';

  /// The workspace's accent colour, as the server stores it (`#rrggbb`).
  String get color => raw['color']?.toString() ?? '';
  int get memberCount => (raw['members'] as List?)?.length ?? 0;
}
