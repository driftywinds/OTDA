import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../api/api_client.dart';
import '../api/api_exception.dart';
import '../data/models.dart';
import '../data/public_links_service.dart';
import '../data/repo.dart';

/// A task published at `/t/<secret>`: view, reply or tick rights, an optional
/// label and expiry. The link is shown once, when the page is published.
class TaskPageScreen extends StatefulWidget {
  const TaskPageScreen({super.key, required this.repo, required this.task});

  final Repo repo;
  final Task task;

  @override
  State<TaskPageScreen> createState() => _TaskPageScreenState();
}

class _TaskPageScreenState extends State<TaskPageScreen> {
  static const _service = PublicLinksService();

  TaskPage? _page;
  bool _loading = true;
  bool _busy = false;
  String _rights = 'view';
  String _label = '';
  int? _days;

  ApiClient get _client => widget.repo.engine.client;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final page = await _service.taskPage(_client, widget.task.id);
      if (!mounted) return;
      setState(() {
        _page = page;
        _loading = false;
      });
    } on Object {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _explain(ApiException e) => switch (e.code) {
        'page_not_encrypted' => 'This task is served live, so no snapshot should be sent.',
        'limit_reached' => 'You already have 100 active task pages. Revoke one first.',
        'rate_limited' => 'Too many pages published just now. Try again later.',
        'forbidden' => 'Only the task’s owner, or its project’s owner and admins, can publish it.',
        'invalid_input' =>
          e.message.contains('snapshot')
              ? 'This task is end-to-end encrypted. Publishing it needs an unlocked snapshot, which the app does not create yet.'
              : e.message,
        'network' || 'timeout' => 'Connect to the server to publish this task.',
        _ => e.message.isEmpty ? 'That change was not accepted.' : e.message,
      };

  Future<void> _publish() async {
    setState(() => _busy = true);
    try {
      final page = await _service.publishTaskPage(
        _client,
        widget.task.id,
        rights: _rights,
        label: _label,
        expiresInDays: _days,
      );
      if (!mounted) return;
      setState(() => _page = page);
      if (page.link != null) await _showLink(page.link!);
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_explain(e))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _revoke() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Unpublish this task page?'),
        content: const Text('The URL stops working immediately. Replies already received stay in the task.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Keep')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Unpublish')),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _busy = true);
    try {
      await _service.revokeTaskPage(_client, widget.task.id);
      if (!mounted) return;
      setState(() => _page = null);
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_explain(e))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _showLink(String link) => showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Task page ready'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Anyone with this link opens the page without an account.'),
              const SizedBox(height: 10),
              SelectableText(link, style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Text(
                'Copy it now: it will not be shown again.',
                style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 12),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: link));
                if (context.mounted) Navigator.of(context).pop();
              },
              child: const Text('Copy link'),
            ),
            FilledButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Done')),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Task page')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              children: [
                Text(
                  widget.task.title,
                  style: theme.textTheme.titleMedium,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Text(
                  'A page is a read-only view of this task that anyone can open. It is not the app.',
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 18),
                if (_page != null) ...[
                  Card(
                    margin: EdgeInsets.zero,
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(Icons.public_rounded, size: 18, color: theme.colorScheme.primary),
                              const SizedBox(width: 8),
                              Text('Published', style: theme.textTheme.titleSmall),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text('Rights: ${_rightsLabel(_page!.rights)}'),
                          if (_page!.label.isNotEmpty) Text('Label: ${_page!.label}'),
                          if (_page!.expiresAt != null)
                            Text(
                              'Expires ${MaterialLocalizations.of(context).formatShortDate(DateTime.fromMillisecondsSinceEpoch(_page!.expiresAt!))}',
                            ),
                          if (_page!.pendingReplies > 0)
                            Text('${_page!.pendingReplies} repl${_page!.pendingReplies == 1 ? 'y' : 'ies'} waiting'),
                          const SizedBox(height: 4),
                          Text(
                            'The link is not stored by the app, so it cannot be copied again.',
                            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _revoke,
                    icon: const Icon(Icons.link_off_rounded, size: 18),
                    label: const Text('Unpublish'),
                  ),
                ] else ...[
                  DropdownButtonFormField<String>(
                    initialValue: _rights,
                    decoration: const InputDecoration(labelText: 'What can a visitor do?'),
                    items: const [
                      DropdownMenuItem(value: 'view', child: Text('View only')),
                      DropdownMenuItem(value: 'reply', child: Text('View and reply')),
                      DropdownMenuItem(value: 'tick', child: Text('View and tick')),
                    ],
                    onChanged: (value) => setState(() => _rights = value ?? 'view'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    maxLength: 40,
                    decoration: const InputDecoration(
                      labelText: 'Link label (optional)',
                      hintText: 'lowercase-letters-and-hyphens',
                    ),
                    onChanged: (value) => _label = value.trim(),
                  ),
                  const SizedBox(height: 4),
                  DropdownButtonFormField<int>(
                    initialValue: _days ?? 0,
                    decoration: const InputDecoration(labelText: 'Expiry'),
                    items: const [
                      DropdownMenuItem(value: 0, child: Text('No expiry')),
                      DropdownMenuItem(value: 7, child: Text('7 days')),
                      DropdownMenuItem(value: 30, child: Text('30 days')),
                      DropdownMenuItem(value: 90, child: Text('90 days')),
                    ],
                    onChanged: (value) => setState(() => _days = value == 0 ? null : value),
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: _busy ? null : _publish,
                    icon: const Icon(Icons.public_rounded, size: 18),
                    label: const Text('Publish page'),
                  ),
                ],
              ],
            ),
    );
  }

  static String _rightsLabel(String rights) => switch (rights) {
        'reply' => 'View and reply',
        'tick' => 'View and tick',
        _ => 'View only',
      };
}
