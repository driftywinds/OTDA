import 'package:material_ui/material_ui.dart';

import '../api/api_exception.dart';
import '../app_state.dart';
import '../auth/auth_service.dart';
import '../data/admin_api.dart';

/// The Server tab: everyone on this instance, invitations, the audit log and
/// backups. Owner and admins only.
///
/// Every write is a step-up route, so the first change asks for the password (or
/// a 6-digit code) once and the server trusts it for ten minutes.
class AdminView extends StatefulWidget {
  const AdminView({super.key, required this.state});

  final AppState state;

  @override
  State<AdminView> createState() => _AdminViewState();
}

class _AdminViewState extends State<AdminView> {
  late final AdminApi _api = AdminApi(client: widget.state.client!, promptReauth: _confirmPassword);

  List<Map<String, Object?>> _users = const [];
  List<Map<String, Object?>> _invitations = const [];
  List<Map<String, Object?>> _audit = const [];
  Map<String, Object?> _backups = const {};
  Map<String, Object?> _storage = const {};
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final users = await _api.users();
      final invitations = await _api.invitations();
      final audit = await _api.audit();
      final backups = await _api.backups();
      final storage = await _api.storage();
      if (!mounted) return;
      setState(() {
        _users = users;
        _invitations = invitations;
        _audit = audit;
        _backups = backups;
        _storage = storage;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.isForbidden ? 'Your account cannot manage this server.' : e.message;
      });
    }
  }

  /// Step-up: the password, or a six-digit code when the account has a second
  /// factor and the person would rather use it.
  Future<bool> _confirmPassword() async {
    final controller = TextEditingController();
    final answer = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Confirm it is you'),
        content: TextField(
          controller: controller,
          autofocus: true,
          obscureText: true,
          decoration: const InputDecoration(
            labelText: 'Password or 6-digit code',
            helperText: 'The server asks for this before account changes.',
          ),
          onSubmitted: (text) => Navigator.of(context).pop(text),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(context).pop(controller.text), child: const Text('Confirm')),
        ],
      ),
    );
    final value = answer?.trim() ?? '';
    controller.dispose();
    if (value.isEmpty) return false;
    final isCode = RegExp(r'^\d{6}$').hasMatch(value);
    try {
      await const AuthService().reauth(widget.state.client!, password: isCode ? null : value, code: isCode ? value : null);
      return true;
    } on ApiException catch (e) {
      if (mounted) _toast(e.message);
      return false;
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _run(Future<void> Function() action, String done) async {
    try {
      await action();
      _toast(done);
      await _load();
    } on ApiException catch (e) {
      _toast(e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.lock_outline, color: theme.colorScheme.error),
              const SizedBox(height: 8),
              Text(_error!, textAlign: TextAlign.center),
            ],
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          _section(theme, 'This server', [
            _row('Version', widget.state.server?.version ?? ''),
            _row('Storage', _bytes(_storage['database_bytes'])),
            _row('Free space', _bytes(_storage['free_bytes'])),
            _row('Backups', _backups['enabled'] == true ? (_backups['destination']?.toString() ?? 'on') : 'off'),
          ]),
          _section(theme, 'People (${_users.length})', [
            for (final user in _users) _userRow(user),
          ]),
          _section(theme, 'Invitations (${_invitations.length})', [
            for (final invitation in _invitations) _invitationRow(invitation),
            if (_invitations.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Text('Nobody is waiting for an invitation.', style: theme.textTheme.bodyMedium),
              ),
            ListTile(
              leading: const Icon(Icons.person_add_alt),
              title: const Text('Invite someone'),
              onTap: _invite,
            ),
          ]),
          _section(theme, 'Recent activity (${_audit.length})', [
            for (final event in _audit.take(15)) _auditRow(event),
          ]),
          _section(theme, 'Backups', [
            ListTile(
              leading: const Icon(Icons.cloud_upload_outlined),
              title: const Text('Run a backup now'),
              subtitle: Text(_backups['lastRun'] == null
                  ? 'No backup has run yet'
                  : 'Last run ${_ago(_backups['lastRun'])}'),
              onTap: () => _run(_api.runBackup, 'Backup started'),
            ),
          ]),
        ],
      ),
    );
  }

  Widget _section(ThemeData theme, String title, List<Widget> children) => Padding(
        padding: const EdgeInsets.only(top: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 8),
              child: Text(
                title.toUpperCase(),
                style: theme.textTheme.labelSmall?.copyWith(
                  letterSpacing: 1.2,
                  fontWeight: FontWeight.w700,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            Card(margin: EdgeInsets.zero, child: Column(children: children)),
          ],
        ),
      );

  Widget _row(String label, String value) => ListTile(
        dense: true,
        title: Text(label),
        trailing: Text(value, style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            )),
      );

  Widget _userRow(Map<String, Object?> user) {
    final id = user['id']?.toString() ?? '';
    final name = user['name']?.toString().isNotEmpty == true ? user['name'].toString() : user['email']?.toString() ?? '';
    final role = user['role']?.toString() ?? 'member';
    final active = user['status']?.toString() != 'deactivated';
    return ListTile(
      leading: CircleAvatar(child: Text(name.isEmpty ? '?' : name.substring(0, 1).toUpperCase())),
      title: Text(name),
      subtitle: Text('${user['email'] ?? ''} · $role${active ? '' : ' · deactivated'}'),
      trailing: PopupMenuButton<String>(
        onSelected: (choice) {
          switch (choice) {
            case 'admin':
            case 'member':
            case 'owner':
              _run(() => _api.setRole(id, choice), 'Role changed');
            case 'deactivate':
              _run(() => _api.deactivate(id), 'Account deactivated');
            case 'reactivate':
              _run(() => _api.reactivate(id), 'Account reactivated');
            case 'reset':
              _run(() => _api.sendPasswordReset(id), 'Reset link sent');
          }
        },
        itemBuilder: (_) => [
          const PopupMenuItem(value: 'admin', child: Text('Make admin')),
          const PopupMenuItem(value: 'member', child: Text('Make member')),
          const PopupMenuItem(value: 'owner', child: Text('Transfer ownership')),
          const PopupMenuDivider(),
          if (active)
            const PopupMenuItem(value: 'deactivate', child: Text('Deactivate'))
          else
            const PopupMenuItem(value: 'reactivate', child: Text('Reactivate')),
          const PopupMenuItem(value: 'reset', child: Text('Send password reset')),
        ],
      ),
    );
  }

  Widget _invitationRow(Map<String, Object?> invitation) {
    final expires = (invitation['expiresAt'] as num?)?.toInt();
    final status = invitation['status']?.toString() ?? '';
    return ListTile(
      leading: Icon(
        status == 'pending' ? Icons.mail_outline : Icons.mark_email_read_outlined,
        color: status == 'pending' ? null : Theme.of(context).colorScheme.onSurfaceVariant,
      ),
      title: Text(invitation['email']?.toString() ?? 'Open invitation'),
      subtitle: Text([
        status,
        if (expires != null) 'expires ${_date(expires)}',
      ].where((s) => s.isNotEmpty).join(' · ')),
      // Only a pending invitation can be revoked; the server keeps the others as
      // a record.
      trailing: status != 'pending'
          ? null
          : IconButton(
              tooltip: 'Revoke',
              icon: const Icon(Icons.close),
              onPressed: () => _run(() => _api.revokeInvitation(invitation['id'].toString()), 'Invitation revoked'),
            ),
    );
  }

  Widget _auditRow(Map<String, Object?> event) {
    final who = event['actorEmail']?.toString() ?? 'system';
    return ListTile(
      dense: true,
      leading: Icon(
        event['outcome']?.toString() == 'failure' ? Icons.error_outline : Icons.check_circle_outline,
        size: 18,
        color: event['outcome']?.toString() == 'failure' ? Colors.red : null,
      ),
      title: Text(event['name']?.toString() ?? ''),
      subtitle: Text('$who · ${_ago(event['ts'])}'),
    );
  }

  Future<void> _invite() async {
    final controller = TextEditingController();
    final email = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Invite someone'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.emailAddress,
          decoration: const InputDecoration(labelText: 'Email'),
          onSubmitted: (text) => Navigator.of(context).pop(text),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(context).pop(controller.text), child: const Text('Create')),
        ],
      ),
    );
    controller.dispose();
    if (email == null || email.trim().isEmpty) return;
    try {
      final created = await _api.invite(email: email.trim());
      // With outgoing mail off the server cannot send it; show the link so it can
      // be handed over.
      final secret = created['link']?.toString() ?? created['url']?.toString();
      if (mounted) {
        _toast(secret == null ? 'Invitation created' : 'Invitation: $secret');
      }
      await _load();
    } on ApiException catch (e) {
      _toast(e.message);
    }
  }

  static String _bytes(Object? value) {
    final bytes = (value as num?)?.toDouble();
    if (bytes == null) return '—';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  static String _date(int millis) {
    final date = DateTime.fromMillisecondsSinceEpoch(millis);
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }

  static String _ago(Object? value) {
    final millis = (value as num?)?.toInt();
    if (millis == null) return 'never';
    final when = DateTime.fromMillisecondsSinceEpoch(millis);
    final d = DateTime.now().difference(when);
    if (d.inSeconds < 60) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes}m ago';
    if (d.inHours < 24) return '${d.inHours}h ago';
    return '${d.inDays}d ago';
  }
}
