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

/// A file or link attached to a task. The bytes live outside the replica: an
/// encrypted account's personal file is stored as an `OTAT1` envelope.
class Attachment {
  Attachment(this.raw);

  final Map<String, dynamic> raw;

  String get id => raw['id']?.toString() ?? '';
  String get taskId => raw['task_id']?.toString() ?? '';
  String get name => raw['name']?.toString() ?? '';
  String get mime => raw['mime']?.toString() ?? 'application/octet-stream';
  int get size => (raw['size'] as num?)?.toInt() ?? 0;
  String get sha256 => raw['sha256']?.toString() ?? '';
  bool get encrypted => raw['encrypted'] == true;
  String get url => raw['url']?.toString() ?? '';
  String get authorId => raw['author_id']?.toString() ?? '';
  String get fileId => raw['file_id']?.toString() ?? '';
  int get createdAt => (raw['created_at'] as num?)?.toInt() ?? 0;
  int? get uploadedAt => (raw['uploaded_at'] as num?)?.toInt();
  bool get isDeleted => raw['deleted_at'] != null;

  /// A link rather than stored bytes.
  bool get isLink => url.isNotEmpty;

  /// The id the bytes are stored and encrypted under (a copy shares the original).
  String get fileKey => fileId.isEmpty ? id : fileId;

  /// uploaded_at is the server's word that the file is stored. A link needs no
  /// upload.
  bool get isAvailable => isLink || uploadedAt != null;
}

class Label {  Label(this.id, this.raw);

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

/// One person in a workspace, from the sync directory.
class WorkspaceMember {
  const WorkspaceMember(this.userId, this.name, this.role);

  final String userId;
  final String name;

  /// owner, admin or member.
  final String role;

  static WorkspaceMember fromJson(Map<String, dynamic> json) => WorkspaceMember(
        json['userId']?.toString() ?? '',
        json['name']?.toString() ?? '',
        json['role']?.toString() ?? 'member',
      );
}

/// A named group of workspace members, for project grants.
class WorkspaceGroup {
  const WorkspaceGroup(this.id, this.name, this.members);

  final String id;
  final String name;
  final List<String> members;

  static WorkspaceGroup fromJson(Map<String, dynamic> json) => WorkspaceGroup(
        json['id']?.toString() ?? '',
        json['name']?.toString() ?? '',
        [for (final member in (json['members'] as List?) ?? const []) member.toString()],
      );
}

/// One person on a shared project.
class ProjectMember {
  const ProjectMember({
    required this.userId,
    required this.name,
    required this.email,
    required this.role,
    this.avatarVersion = 0,
    this.via = const [],
  });

  final String userId;
  final String name;
  final String email;

  /// owner, admin, editor or viewer.
  final String role;
  final int avatarVersion;

  /// Groups the role comes from; empty for a direct grant.
  final List<WorkspaceGroup> via;

  static ProjectMember fromJson(Map<String, dynamic> json) => ProjectMember(
        userId: json['userId']?.toString() ?? '',
        name: json['name']?.toString() ?? '',
        email: json['email']?.toString() ?? '',
        role: json['role']?.toString() ?? '',
        avatarVersion: (json['avatarVersion'] as num?)?.toInt() ?? 0,
        via: [
          for (final raw in (json['via'] as List?) ?? const [])
            if (raw is Map)
              WorkspaceGroup(
                raw['id']?.toString() ?? '',
                raw['name']?.toString() ?? '',
                const [],
              ),
        ],
      );
}

/// One group grant on a project.
class ProjectGrant {
  const ProjectGrant(this.groupId, this.name, this.role);
  final String groupId;
  final String name;
  final String role;

  static ProjectGrant fromJson(Map<String, dynamic> json) => ProjectGrant(
        json['groupId']?.toString() ?? '',
        json['name']?.toString() ?? '',
        json['role']?.toString() ?? '',
      );
}

/// The caller's view of one shared project: role, owner and members.
class ProjectMembership {
  ProjectMembership(this.raw);
  final Map<String, dynamic> raw;

  String get projectId => raw['projectId']?.toString() ?? '';
  String get role => raw['role']?.toString() ?? '';
  String get ownerId => raw['ownerId']?.toString() ?? '';
  bool get isOwner => role == 'owner';
  bool get canManage => role == 'owner' || role == 'admin';

  /// A project is shared once somebody besides its owner is on it; the server
  /// never encrypts a shared project, even after encryption is enabled.
  bool get isShared => members.length > 1;

  List<ProjectMember> get members => [
        for (final raw in (this.raw['members'] as List?) ?? const [])
          if (raw is Map) ProjectMember.fromJson(raw.cast<String, dynamic>()),
      ];
  List<ProjectGrant> get grants => [
        for (final raw in (this.raw['grants'] as List?) ?? const [])
          if (raw is Map) ProjectGrant.fromJson(raw.cast<String, dynamic>()),
      ];

  /// Open e-mail invitations, when the caller manages the project.
  List<PendingMember> get pending => [
        for (final raw in (this.raw['pending'] as List?) ?? const [])
          if (raw is Map) PendingMember.fromJson(raw.cast<String, dynamic>()),
      ];
}

/// A project's public link: anyone with the URL reads the list, and with the
/// `tick` right may also complete items.
class PublicLink {
  const PublicLink({
    required this.id,
    required this.projectId,
    required this.rights,
    required this.layout,
    required this.name,
    required this.createdByName,
    required this.expiresAt,
    required this.link,
  });

  final String id;
  final String projectId;

  /// view or tick.
  final String rights;

  /// list or board.
  final String layout;
  final String name;
  final String createdByName;
  final int? expiresAt;

  /// Present only in the create response; the list route never repeats the
  /// secret.
  final String? link;

  static PublicLink fromJson(Map<String, dynamic> json) => PublicLink(
        id: json['id']?.toString() ?? '',
        projectId: json['projectId']?.toString() ?? '',
        rights: json['rights']?.toString() ?? '',
        layout: json['layout']?.toString() ?? 'list',
        name: json['name']?.toString() ?? '',
        createdByName: json['createdByName']?.toString() ?? '',
        expiresAt: (json['expiresAt'] as num?)?.toInt(),
        link: json['link']?.toString(),
      );
}

/// A task published as a page at `/t/<secret>`.
class TaskPage {
  const TaskPage({
    required this.id,
    required this.taskId,
    required this.rights,
    required this.label,
    required this.encrypted,
    required this.expiresAt,
    required this.publishedAt,
    required this.replies,
    required this.ticks,
    required this.pendingReplies,
    required this.link,
  });

  final String id;
  final String taskId;

  /// view, reply or tick.
  final String rights;
  final String label;
  final bool encrypted;
  final int? expiresAt;
  final int? publishedAt;
  final int replies;
  final int ticks;
  final int pendingReplies;

  /// Present only in the publish response.
  final String? link;

  static TaskPage fromJson(Map<String, dynamic> json) => TaskPage(
        id: json['id']?.toString() ?? '',
        taskId: json['taskId']?.toString() ?? '',
        rights: json['rights']?.toString() ?? '',
        label: json['label']?.toString() ?? '',
        encrypted: json['encrypted'] == true,
        expiresAt: (json['expiresAt'] as num?)?.toInt(),
        publishedAt: (json['publishedAt'] as num?)?.toInt(),
        replies: (json['replies'] as num?)?.toInt() ?? 0,
        ticks: (json['ticks'] as num?)?.toInt() ?? 0,
        pendingReplies: (json['pendingReplies'] as num?)?.toInt() ?? 0,
        link: json['link']?.toString(),
      );
}

/// An invitation addressed to me: to a project or a workspace.
class MemberInvitation {
  const MemberInvitation({
    required this.id,
    required this.kind,
    required this.targetId,
    required this.targetName,
    required this.role,
    required this.inviterName,
    required this.expiresAt,
  });

  final String id;

  /// project or workspace.
  final String kind;
  final String targetId;
  final String targetName;
  final String role;
  final String inviterName;
  final int expiresAt;

  bool get isProject => kind == 'project';
  String get kindLabel => isProject ? 'Project' : 'Workspace';

  static MemberInvitation fromJson(Map<String, dynamic> json) => MemberInvitation(
        id: json['id']?.toString() ?? '',
        kind: json['kind']?.toString() ?? '',
        targetId: json['targetId']?.toString() ?? '',
        targetName: json['targetName']?.toString() ?? '',
        role: json['role']?.toString() ?? '',
        inviterName: json['inviterName']?.toString() ?? '',
        expiresAt: (json['expiresAt'] as num?)?.toInt() ?? 0,
      );
}

/// One open invitation on a project or workspace, as its managers see it.
class PendingMember {
  const PendingMember({
    required this.id,
    required this.email,
    required this.role,
    required this.invitedBy,
    required this.expiresAt,
  });

  final String id;
  final String email;
  final String role;
  final String invitedBy;
  final int expiresAt;

  static PendingMember fromJson(Map<String, dynamic> json) => PendingMember(
        id: json['id']?.toString() ?? '',
        email: json['email']?.toString() ?? '',
        role: json['role']?.toString() ?? '',
        invitedBy: json['invitedBy']?.toString() ?? '',
        expiresAt: (json['expiresAt'] as num?)?.toInt() ?? 0,
      );
}

/// A directory entry from the sync exchange: projects, labels and views live in
/// one, and a person can be in several.
class Workspace {
  Workspace(this.raw);

  final Map<String, dynamic> raw;

  String get id => raw['id']?.toString() ?? '';
  String get name => raw['name']?.toString() ?? '';
  bool get isDefault => raw['default'] == true;

  /// The caller's role: owner, admin or member.
  String get role => raw['role']?.toString() ?? '';
  String get ownerId => raw['ownerId']?.toString() ?? '';
  bool get isOwner => role == 'owner';

  /// A name from OpenTodo's icon catalogue, e.g. `briefcase`; empty when unset.
  String get icon => raw['icon']?.toString() ?? '';

  /// The workspace's accent colour, as the server stores it (`#rrggbb`).
  String get color => raw['color']?.toString() ?? '';

  /// The workspace's feature switches (`calendar`, `reviews`, …). Missing keys
  /// mean on; the server only stores the ones that were switched off.
  Map<String, dynamic> get features {
    final value = raw['features'];
    return value is Map ? value.cast<String, dynamic>() : const {};
  }

  bool featureEnabled(String name) => features[name] != false;

  List<WorkspaceMember> get members => [
        for (final raw in (this.raw['members'] as List?) ?? const [])
          if (raw is Map) WorkspaceMember.fromJson(raw.cast<String, dynamic>()),
      ];
  List<WorkspaceGroup> get groups => [
        for (final raw in (this.raw['groups'] as List?) ?? const [])
          if (raw is Map) WorkspaceGroup.fromJson(raw.cast<String, dynamic>()),
      ];
  int get memberCount => members.length;
}
