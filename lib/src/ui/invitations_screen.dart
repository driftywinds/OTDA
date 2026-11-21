import 'package:material_ui/material_ui.dart';

import '../api/api_exception.dart';
import '../app_state.dart';
import '../data/invitation_service.dart';
import '../data/models.dart';

/// Invitations addressed to this account: accept or decline.
class InvitationsScreen extends StatefulWidget {
  const InvitationsScreen({super.key, required this.state});

  final AppState state;

  @override
  State<InvitationsScreen> createState() => _InvitationsScreenState();
}

class _InvitationsScreenState extends State<InvitationsScreen> {
  static const _service = InvitationService();

  List<MemberInvitation> _invitations = const [];
  bool _loading = true;
  final Set<String> _working = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final client = widget.state.client;
    if (client == null) return;
    try {
      final list = await _service.list(client);
      if (!mounted) return;
      setState(() {
        _invitations = list;
        _loading = false;
      });
    } on ApiException {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _answer(MemberInvitation invitation, bool accept) async {
    final client = widget.state.client;
    if (client == null || _working.contains(invitation.id)) return;
    setState(() => _working.add(invitation.id));
    try {
      if (accept) {
        await _service.accept(client, invitation.id);
        await widget.state.syncNow();
      } else {
        await _service.decline(client, invitation.id);
      }
      await _load();
      if (mounted && accept) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Joined ${invitation.targetName}.')),
        );
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      final message = switch (e.code) {
        'invitation_stale' =>
          'This invitation can no longer be accepted. Ask ${invitation.inviterName.isEmpty ? 'the person who invited you' : invitation.inviterName} to add you again.',
        'already_member' => 'You are already a member.',
        'not_found' => 'That invitation no longer exists.',
        _ => e.message.isEmpty ? 'That invitation could not be answered.' : e.message,
      };
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
      await _load();
    } finally {
      if (mounted) setState(() => _working.remove(invitation.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Invitations')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _invitations.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text(
                      'No invitations are waiting.',
                      style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                  children: [
                    Text(
                      'Accepting adds the project or workspace to this account on the next sync.',
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 12),
                    for (final invitation in _invitations)
                      Card(
                        margin: const EdgeInsets.only(bottom: 10),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(
                                    invitation.isProject ? Icons.folder_outlined : Icons.workspaces_outline,
                                    size: 18,
                                    color: theme.colorScheme.primary,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      invitation.targetName.isEmpty ? invitation.kindLabel : invitation.targetName,
                                      style: theme.textTheme.titleSmall,
                                    ),
                                  ),
                                  Text(
                                    invitation.kindLabel,
                                    style: theme.textTheme.labelSmall?.copyWith(
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '${invitation.inviterName.isEmpty ? 'Someone' : invitation.inviterName} invited '
                                'you as ${invitation.role}.',
                                style: theme.textTheme.bodySmall,
                              ),
                              if (invitation.expiresAt > 0)
                                Text(
                                  'Expires ${MaterialLocalizations.of(context).formatShortDate(DateTime.fromMillisecondsSinceEpoch(invitation.expiresAt))}',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.end,
                                children: [
                                  TextButton(
                                    onPressed: _working.contains(invitation.id)
                                        ? null
                                        : () => _answer(invitation, false),
                                    child: const Text('Decline'),
                                  ),
                                  const SizedBox(width: 4),
                                  FilledButton(
                                    onPressed: _working.contains(invitation.id)
                                        ? null
                                        : () => _answer(invitation, true),
                                    child: _working.contains(invitation.id)
                                        ? const SizedBox(
                                            width: 16,
                                            height: 16,
                                            child: CircularProgressIndicator(strokeWidth: 2),
                                          )
                                        : const Text('Accept'),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
    );
  }
}
