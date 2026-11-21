import 'package:material_ui/material_ui.dart';

import '../api/api_exception.dart';
import '../app_state.dart';
import '../data/models.dart';
import '../data/sharing_service.dart';
import '../e2ee/session.dart';

/// Project members: who is on a project, adding people by email, changing a
/// role and removing someone. The server never encrypts a shared project, so a
/// shared project says so here.
class ProjectSharingScreen extends StatefulWidget {
  const ProjectSharingScreen({
    super.key,
    required this.state,
    required this.projectId,
    required this.projectName,
  });

  final AppState state;
  final String projectId;
  final String projectName;

  @override
  State<ProjectSharingScreen> createState() => _ProjectSharingScreenState();
}

class _ProjectSharingScreenState extends State<ProjectSharingScreen> {
  static const _service = SharingService();
  static const _roles = {'viewer': 'Viewer', 'editor': 'Editor', 'admin': 'Admin'};

  ProjectMembership? _membership;
  bool _loading = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final client = widget.state.client;
    if (client == null) return;
    try {
      final raw = await _service.members(client, widget.projectId);
      if (!mounted) return;
      setState(() {
        _membership = ProjectMembership(raw);
        _loading = false;
        _error = null;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = _explain(e);
      });
    }
  }

  String _explain(ApiException e) => switch (e.code) {
        'encryption_enabled' =>
          'This account uses end-to-end encryption. A personal project cannot be shared while '
              'encryption is on; turn encryption off first.',
        'already_member' => 'That account is already a member of this project.',
        'not_in_workspace' =>
          'That account is not in this project’s workspace. Add them to the workspace first.',
        'owner_must_transfer' => 'Transfer project ownership before leaving.',
        'forbidden' => 'Your role on this project does not allow that change.',
        'not_found' => 'That project or member no longer exists.',
        'project_id_conflict' =>
          'This project cannot be shared because another account has a project with the same id. '
              'Duplicate it and share the copy.',
        'user_not_found' => 'No account with that email was found.',
        'network' || 'timeout' => 'Connect to the server to change who can see this project.',
        _ => e.message.isEmpty ? 'That change was not accepted.' : e.message,
      };

  void _say(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
      await _load();
    } on ApiException catch (e) {
      _say(_explain(e));
    } on Object catch (e) {
      _say('$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _add() async {
    final client = widget.state.client;
    if (client == null) return;
    final result = await showDialog<({String email, String role})>(
      context: context,
      builder: (context) => const _AddMemberDialog(),
    );
    if (result == null) return;
    await _run(() async {
      await _service.add(client, widget.projectId, email: result.email, role: result.role);
      final after = await _service.members(client, widget.projectId);
      final member = ProjectMembership(after);
      final added = member.members.any((m) => m.email.toLowerCase() == result.email.toLowerCase());
      if (!added && mounted) {
        _say('Invitation sent to ${result.email}.');
      }
    });
  }

  Future<void> _changeRole(ProjectMember member) async {
    final client = widget.state.client;
    if (client == null) return;
    final role = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text('Role for ${member.name.isEmpty ? member.email : member.name}'),
              subtitle: Text('Currently ${member.role}'),
            ),
            const Divider(height: 1),
            for (final entry in _roles.entries)
              ListTile(
                leading: Icon(
                  member.role == entry.key ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                  size: 20,
                ),
                title: Text(entry.value),
                onTap: () => Navigator.of(context).pop(entry.key),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (role == null || role == member.role) return;
    await _run(() => _service.setRole(client, widget.projectId, member.userId, role));
  }

  Future<void> _remove(ProjectMember member) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove ${member.name.isEmpty ? member.email : member.name}?'),
        content: const Text('They lose access to this project and its tasks on their next sync.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Keep')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Remove')),
        ],
      ),
    );
    if (confirmed != true) return;
    final client = widget.state.client;
    if (client == null) return;
    await _run(() => _service.remove(client, widget.projectId, member.userId));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final membership = _membership;
    final encrypted = E2eeSession.instance.enabled;
    final shared = membership?.isShared ?? false;
    final canManage = membership?.canManage ?? false;

    return Scaffold(
      appBar: AppBar(title: Text(widget.projectName, overflow: TextOverflow.ellipsis)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null && membership == null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(_error!, textAlign: TextAlign.center),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                  children: [
                    if (shared)
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.secondaryContainer,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.group_outlined, size: 18, color: theme.colorScheme.onSecondaryContainer),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'Shared with ${membership!.members.length} people. Shared projects are never '
                                'end-to-end encrypted.',
                                style: TextStyle(color: theme.colorScheme.onSecondaryContainer, fontSize: 13),
                              ),
                            ),
                          ],
                        ),
                      )
                    else if (encrypted)
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.errorContainer,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.lock_outline, size: 18, color: theme.colorScheme.onErrorContainer),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'End-to-end encryption is on. This personal project cannot be shared until '
                                'encryption is turned off; the server refuses the first share.',
                                style: TextStyle(color: theme.colorScheme.onErrorContainer, fontSize: 13),
                              ),
                            ),
                          ],
                        ),
                      ),
                    if (membership != null) ...[
                      const SizedBox(height: 16),
                      Text('People', style: theme.textTheme.titleSmall),
                      const SizedBox(height: 4),
                      for (final member in membership.members)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: CircleAvatar(
                            child: Text(
                              (member.name.isEmpty ? member.email : member.name).substring(0, 1).toUpperCase(),
                            ),
                          ),
                          title: Text(member.name.isEmpty ? member.email : member.name),
                          subtitle: Text(
                            [
                              member.email,
                              if (member.via.isNotEmpty)
                                'via ${member.via.map((group) => group.name.isEmpty ? group.id : group.name).join(', ')}',
                            ].where((part) => part.isNotEmpty).join(' · '),
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                member.role,
                                style: theme.textTheme.labelMedium?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                              if (canManage && member.role != 'owner' && member.userId != widget.state.account?.userId)
                                PopupMenuButton<String>(
                                  enabled: !_busy,
                                  tooltip: 'Member actions',
                                  onSelected: (value) {
                                    if (value == 'role') {
                                      _changeRole(member);
                                    } else {
                                      _remove(member);
                                    }
                                  },
                                  itemBuilder: (context) => const [
                                    PopupMenuItem(value: 'role', child: Text('Change role…')),
                                    PopupMenuItem(value: 'remove', child: Text('Remove from project')),
                                  ],
                                )
                              else
                                const SizedBox(width: 8),
                            ],
                          ),
                        ),
                      if (canManage && membership.pending.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text('Invitations', style: theme.textTheme.titleSmall),
                        for (final pending in membership.pending)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(Icons.mail_outline),
                            title: Text(pending.email.isEmpty ? 'Invited' : pending.email),
                            subtitle: Text('Waiting for an answer · ${pending.role}'),
                            trailing: IconButton(
                              tooltip: 'Revoke invitation',
                              icon: const Icon(Icons.close_rounded, size: 18),
                              onPressed: _busy
                                  ? null
                                  : () async {
                                      final client = widget.state.client;
                                      if (client == null) return;
                                      await _run(() => _service.cancelInvitation(client, widget.projectId, pending.id));
                                    },
                            ),
                          ),
                      ],
                      if (canManage) ...[
                        const SizedBox(height: 12),
                        FilledButton.icon(
                          onPressed: _busy || (encrypted && !shared) ? null : _add,
                          icon: const Icon(Icons.person_add_alt_1_rounded, size: 18),
                          label: const Text('Add a person by email'),
                        ),
                        if (encrypted && !shared)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(
                              'Turn encryption off to share this project.',
                              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                            ),
                          ),
                      ],
                    ],
                    if (membership != null && membership.grants.isNotEmpty) ...[
                      const SizedBox(height: 22),
                      Text('Group access', style: theme.textTheme.titleSmall),
                      for (final grant in membership.grants)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.groups_outlined),
                          title: Text(grant.name.isEmpty ? grant.groupId : grant.name),
                          trailing: Text(grant.role, style: theme.textTheme.labelMedium),
                        ),
                      Text(
                        'Group grants are managed on the server or in the web app.',
                        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ],
                    if (_error != null && membership != null) ...[
                      const SizedBox(height: 12),
                      Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
                    ],
                  ],
                ),
    );
  }
}

class _AddMemberDialog extends StatefulWidget {
  const _AddMemberDialog();

  @override
  State<_AddMemberDialog> createState() => _AddMemberDialogState();
}

class _AddMemberDialogState extends State<_AddMemberDialog> {
  final _email = TextEditingController();
  String _role = 'editor';
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  void _submit() {
    final email = _email.text.trim();
    if (!email.contains('@') || email.length < 3) {
      setState(() => _error = 'Enter an email address.');
      return;
    }
    Navigator.of(context).pop((email: email, role: _role));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add a person'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _email,
            autofocus: true,
            keyboardType: TextInputType.emailAddress,
            textInputAction: TextInputAction.done,
            decoration: InputDecoration(
              labelText: 'Email',
              errorText: _error,
            ),
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: _role,
            decoration: const InputDecoration(labelText: 'Role'),
            items: const [
              DropdownMenuItem(value: 'viewer', child: Text('Viewer — can read')),
              DropdownMenuItem(value: 'editor', child: Text('Editor — can change tasks')),
              DropdownMenuItem(value: 'admin', child: Text('Admin — can also manage people')),
            ],
            onChanged: (value) => setState(() => _role = value ?? 'editor'),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(onPressed: _submit, child: const Text('Add')),
      ],
    );
  }
}
