import 'package:material_ui/material_ui.dart';

import '../api/api_exception.dart';
import '../app_state.dart';
import '../data/models.dart';
import '../data/repo.dart';
import '../data/workspace_service.dart';
import 'widgets.dart';
import 'workspace_icon.dart';

/// The workspace directory: switch, create, rename, see members and groups,
/// move projects between workspaces, and leave or transfer one.
///
/// Reads come from the sync exchange; only the changes use the workspace routes.
/// Popping returns the id of a workspace to switch to, or null.
class WorkspacesScreen extends StatefulWidget {
  const WorkspacesScreen({super.key, required this.state, this.activeId});

  final AppState state;
  final String? activeId;

  @override
  State<WorkspacesScreen> createState() => _WorkspacesScreenState();
}

class _WorkspacesScreenState extends State<WorkspacesScreen> {
  static const _service = WorkspaceService();

  List<Workspace> _workspaces = const [];
  List<Project> _projects = const [];
  bool _loading = true;
  bool _busy = false;

  Repo? get _repo => widget.state.repo;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final repo = _repo;
    if (repo == null) return;
    final workspaces = await repo.workspaces();
    final projects = await repo.allProjects();
    if (!mounted) return;
    setState(() {
      _workspaces = workspaces;
      _projects = [for (final project in projects) if (!project.isDeleted) project];
      _loading = false;
    });
  }

  String get _defaultId =>
      _workspaces.where((w) => w.isDefault).map((w) => w.id).firstOrNull ??
      (_workspaces.isEmpty ? '' : _workspaces.first.id);

  Future<void> _syncAndLoad() async {
    await widget.state.syncNow();
    await _load();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
      await _syncAndLoad();
    } on ApiException catch (e) {
      _say(_explain(e));
    } on Object catch (e) {
      _say('$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _say(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  String _explain(ApiException e) => switch (e.code) {
        'default_workspace' => 'The default workspace cannot be left, shared or renamed.',
        'owner_must_transfer' => 'Transfer this workspace to another member before leaving it.',
        'forbidden' => 'Your role in this workspace does not allow that change.',
        'not_found' => 'That workspace no longer exists.',
        'limit_reached' => 'The server limit for workspaces is reached.',
        'workspace_not_empty' => e.message,
        'network' || 'timeout' => 'Connect to the server to change a workspace.',
        _ => e.message.isEmpty ? 'That change was not accepted.' : e.message,
      };

  Future<void> _create() async {
    final name = await _askName('New workspace', '');
    if (name == null || name.isEmpty) return;
    final client = widget.state.client;
    if (client == null) return;
    await _run(() => _service.create(client, name: name));
  }

  Future<void> _rename(Workspace workspace) async {
    if (workspace.isDefault) {
      _say('The default workspace cannot be renamed.');
      return;
    }
    final name = await _askName('Rename workspace', workspace.name);
    if (name == null || name == workspace.name) return;
    final client = widget.state.client;
    if (client == null) return;
    await _run(() => _service.rename(client, workspace.id, name));
  }

  Future<String?> _askName(String title, String initial) async {
    final controller = TextEditingController(text: initial);
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(labelText: 'Name'),
          onSubmitted: (text) => Navigator.of(context).pop(text.trim()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    return value;
  }

  Future<void> _leave(Workspace workspace) async {
    if (workspace.isDefault) {
      _say('The default workspace cannot be left.');
      return;
    }
    if (workspace.isOwner) {
      _say('Transfer ownership to another member first.');
      await _transfer(workspace);
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Leave “${workspace.name}”?'),
        content: const Text('Its projects disappear from this device until you are added back.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Stay')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Leave')),
        ],
      ),
    );
    if (confirmed != true) return;
    final client = widget.state.client;
    if (client == null) return;
    final wasActive = workspace.id == widget.activeId;
    await _run(() => _service.leave(client, workspace.id));
    if (wasActive && mounted) Navigator.of(context).pop();
  }

  Future<void> _transfer(Workspace workspace) async {
    if (!workspace.isOwner) return;
    final others = workspace.members.where((member) => member.userId != widget.state.account?.userId).toList();
    if (others.isEmpty) {
      _say('Add another member before transferring ownership.');
      return;
    }
    final chosen = await showModalBottomSheet<WorkspaceMember>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text('Transfer “${workspace.name}”', style: Theme.of(context).textTheme.titleMedium),
              subtitle: const Text('The new owner can then remove or change members.'),
            ),
            const Divider(height: 1),
            for (final member in others)
              ListTile(
                leading: CircleAvatar(child: Text(_initials(member.name))),
                title: Text(member.name.isEmpty ? member.userId : member.name),
                subtitle: Text(member.role),
                onTap: () => Navigator.of(context).pop(member),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    final client = widget.state.client;
    if (chosen == null || client == null) return;
    await _run(() => _service.transfer(client, workspace.id, chosen.userId));
  }

  Future<void> _members(Workspace workspace) => showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        builder: (context) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.only(bottom: 16),
            children: [
              ListTile(
                title: Text('Members of “${workspace.name}”', style: Theme.of(context).textTheme.titleMedium),
                subtitle: Text('${workspace.memberCount} member(s)'),
              ),
              const Divider(height: 1),
              for (final member in workspace.members)
                ListTile(
                  leading: CircleAvatar(child: Text(_initials(member.name))),
                  title: Text(member.name.isEmpty ? member.userId : member.name),
                  subtitle: Text(member.role),
                  trailing: member.userId == widget.state.account?.userId ? const Text('You') : null,
                ),
            ],
          ),
        ),
      );

  Future<void> _groups(Workspace workspace) => showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        builder: (context) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.only(bottom: 16),
            children: [
              ListTile(
                title: Text('Groups in “${workspace.name}”', style: Theme.of(context).textTheme.titleMedium),
                subtitle: const Text('Groups are used for project grants.'),
              ),
              const Divider(height: 1),
              if (workspace.groups.isEmpty)
                const ListTile(title: Text('No groups yet.')),
              for (final group in workspace.groups)
                ListTile(
                  leading: const Icon(Icons.groups_outlined),
                  title: Text(group.name),
                  subtitle: Text(
                    group.members.isEmpty
                        ? 'No members'
                        : group.members
                            .map((id) => workspace.members
                                .where((member) => member.userId == id)
                                .map((member) => member.name.isEmpty ? id : member.name)
                                .firstOrNull ??
                                id)
                            .join(', '),
                  ),
                ),
            ],
          ),
        ),
      );

  Future<void> _moveProject(Workspace from, Project project) async {
    final targets = _workspaces.where((workspace) => workspace.id != from.id).toList();
    if (targets.isEmpty) {
      _say('Create another workspace first.');
      return;
    }
    final chosen = await showModalBottomSheet<Workspace>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text('Move “${project.name}”', style: Theme.of(context).textTheme.titleMedium),
              subtitle: const Text('Its tasks and sections move with it.'),
            ),
            const Divider(height: 1),
            for (final workspace in targets)
              ListTile(
                leading: const Icon(Icons.workspaces_outline),
                title: Text(workspace.name),
                onTap: () => Navigator.of(context).pop(workspace),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (chosen == null) return;
    await _run(() => _repo!.setField(
          'project',
          project.id,
          'workspace_id',
          chosen.isDefault ? null : chosen.id,
        ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Workspaces'),
        actions: [
          IconButton(
            tooltip: 'New workspace',
            onPressed: _busy ? null : _create,
            icon: const Icon(Icons.add_rounded),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: [
                Text(
                  'A workspace groups projects. Tap one to make it the active workspace; its projects and tasks are what the lists show.',
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 12),
                for (final workspace in _workspaces)
                  if ((workspace.workspaceProjects(_projects, _defaultId)).isEmpty)
                    _workspaceCard(context, workspace, const [])
                  else
                    _workspaceCard(
                      context,
                      workspace,
                      workspace.workspaceProjects(_projects, _defaultId),
                    ),
                const SizedBox(height: 8),
                Center(
                  child: TextButton.icon(
                    onPressed: _busy ? null : _create,
                    icon: const Icon(Icons.add_rounded, size: 18),
                    label: const Text('New workspace'),
                  ),
                ),
              ],
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: _busy ? null : _create,
        tooltip: 'New workspace',
        child: const Icon(Icons.add_rounded),
      ),
    );
  }

  Widget _workspaceCard(BuildContext context, Workspace workspace, List<Project> projects) {
    final theme = Theme.of(context);
    final accent = parseHexColor(workspace.color) ?? theme.colorScheme.primary;
    final active = workspace.id == widget.activeId;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            onTap: () => Navigator.of(context).pop(workspace.id),
            leading: Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(workspaceIcon(workspace.icon), size: 19, color: accent),
            ),
            title: Row(
              children: [
                Expanded(child: Text(workspace.name, maxLines: 1, overflow: TextOverflow.ellipsis)),
                if (workspace.isDefault)
                  Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: Text('Default', style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                  ),
              ],
            ),
            subtitle: Text(
              '${workspace.role.isEmpty ? 'member' : workspace.role} · ${workspace.memberCount} member'
              '${workspace.memberCount == 1 ? '' : 's'} · ${projects.length} project'
              '${projects.length == 1 ? '' : 's'}',
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (active) Icon(Icons.check_circle_rounded, color: theme.colorScheme.primary, size: 20),
                PopupMenuButton<String>(
                  tooltip: 'Workspace actions',
                  enabled: !_busy,
                  onSelected: (value) {
                    switch (value) {
                      case 'rename':
                        _rename(workspace);
                      case 'members':
                        _members(workspace);
                      case 'groups':
                        _groups(workspace);
                      case 'leave':
                        _leave(workspace);
                      case 'transfer':
                        _transfer(workspace);
                    }
                  },
                  itemBuilder: (context) => [
                    if (!workspace.isDefault && (workspace.role == 'owner' || workspace.role == 'admin'))
                      const PopupMenuItem(value: 'rename', child: Text('Rename')),
                    const PopupMenuItem(value: 'members', child: Text('Members')),
                    const PopupMenuItem(value: 'groups', child: Text('Groups')),
                    if (workspace.isOwner && !workspace.isDefault)
                      const PopupMenuItem(value: 'transfer', child: Text('Transfer ownership…')),
                    if (!workspace.isDefault)
                      const PopupMenuItem(value: 'leave', child: Text('Leave workspace')),
                  ],
                ),
              ],
            ),
          ),
          if (projects.isNotEmpty) ...[
            const Divider(height: 1),
            for (final project in projects)
              ListTile(
                dense: true,
                contentPadding: const EdgeInsets.fromLTRB(54, 0, 4, 0),
                leading: Icon(Icons.folder_outlined, size: 18, color: parseHexColor(project.color) ?? theme.colorScheme.onSurfaceVariant),
                title: Text(project.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                trailing: _workspaces.length < 2
                    ? null
                    : PopupMenuButton<String>(
                        tooltip: 'Move project',
                        enabled: !_busy,
                        onSelected: (_) => _moveProject(workspace, project),
                        itemBuilder: (context) => const [
                          PopupMenuItem(value: 'move', child: Text('Move to another workspace…')),
                        ],
                      ),
              ),
          ],
        ],
      ),
    );
  }

  static String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+')).where((part) => part.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return (parts.first.substring(0, 1) + parts.last.substring(0, 1)).toUpperCase();
  }
}

extension on Workspace {
  /// The projects shown under this workspace: its own id, or the default id
  /// when a project has no explicit workspace.
  List<Project> workspaceProjects(List<Project> projects, String defaultId) => [
        for (final project in projects)
          if ((project.workspaceId ?? defaultId) == id) project,
      ];
}
