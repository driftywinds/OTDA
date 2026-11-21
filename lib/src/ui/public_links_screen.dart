import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../api/api_exception.dart';
import '../app_state.dart';
import '../data/models.dart';
import '../data/public_links_service.dart';

/// A project's public links: create one, copy the URL while it is shown, and
/// revoke it later. The list never repeats the secret, so an existing link
/// cannot be copied again.
class PublicLinksScreen extends StatefulWidget {
  const PublicLinksScreen({
    super.key,
    required this.state,
    required this.projectId,
    required this.projectName,
  });

  final AppState state;
  final String projectId;
  final String projectName;

  @override
  State<PublicLinksScreen> createState() => _PublicLinksScreenState();
}

class _PublicLinksScreenState extends State<PublicLinksScreen> {
  static const _service = PublicLinksService();

  List<PublicLink> _links = const [];
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final client = widget.state.client;
    if (client == null) return;
    try {
      final links = await _service.list(client, widget.projectId);
      if (!mounted) return;
      setState(() {
        _links = links;
        _loading = false;
      });
    } on Object {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _explain(ApiException e) => switch (e.code) {
        'encryption_enabled' =>
          'Public links are not available for a personal project of an account with '
              'end-to-end encryption. Turn encryption off first.',
        'forbidden' => 'Only the project’s owner and admins can manage public links.',
        'rate_limited' => 'Too many links created just now. Try again in a little while.',
        'network' || 'timeout' => 'Connect to the server to manage public links.',
        _ => e.message.isEmpty ? 'That change was not accepted.' : e.message,
      };

  Future<void> _create() async {
    final client = widget.state.client;
    if (client == null) return;
    final options = await showDialog<_LinkOptions>(
      context: context,
      builder: (context) => const _CreateLinkDialog(),
    );
    if (options == null) return;
    setState(() => _busy = true);
    try {
      final link = await _service.create(
        client,
        widget.projectId,
        rights: options.rights,
        layout: options.layout,
        name: options.name,
        expiresInDays: options.expiresInDays,
      );
      await _load();
      if (!mounted) return;
      if (link.link != null) {
        await _showLink(context, link.link!, 'Anyone with this link can ${options.rights == 'tick' ? 'view and tick' : 'view'} this project.');
      }
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_explain(e))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _revoke(PublicLink link) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Revoke this link?'),
        content: const Text('The URL stops working immediately. Anyone using it loses access.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Keep')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Revoke')),
        ],
      ),
    );
    if (confirmed != true) return;
    final client = widget.state.client;
    if (client == null) return;
    setState(() => _busy = true);
    try {
      await _service.revoke(client, widget.projectId, link.id);
      await _load();
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_explain(e))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Public links')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _busy ? null : _create,
        icon: const Icon(Icons.add_link_rounded),
        label: const Text('New link'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
              children: [
                Text(
                  'A public link opens “${widget.projectName}” without an account. The URL is shown '
                  'once when it is created; the list never repeats it, so copy it then.',
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 12),
                if (_links.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 32),
                    child: Center(
                      child: Text(
                        'No public links yet.',
                        style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ),
                  ),
                for (final link in _links)
                  Card(
                    margin: const EdgeInsets.only(bottom: 10),
                    child: ListTile(
                      leading: Icon(link.rights == 'tick' ? Icons.checklist_rounded : Icons.visibility_outlined),
                      title: Text(link.name.isEmpty ? 'Public link' : link.name),
                      subtitle: Text(
                        [
                          link.rights == 'tick' ? 'Can tick' : 'View only',
                          link.layout == 'board' ? 'Board' : 'List',
                          if (link.expiresAt != null)
                            'expires ${MaterialLocalizations.of(context).formatShortDate(DateTime.fromMillisecondsSinceEpoch(link.expiresAt!))}'
                          else
                            'no expiry',
                          if (link.createdByName.isNotEmpty) 'by ${link.createdByName}',
                        ].join(' · '),
                      ),
                      trailing: IconButton(
                        tooltip: 'Revoke',
                        onPressed: _busy ? null : () => _revoke(link),
                        icon: const Icon(Icons.link_off_rounded),
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}

class _LinkOptions {
  const _LinkOptions(this.name, this.rights, this.layout, this.expiresInDays);
  final String name;
  final String rights;
  final String layout;
  final int? expiresInDays;
}

Future<void> _showLink(BuildContext context, String link, String message) async {
  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Link ready'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(message),
          const SizedBox(height: 10),
          SelectableText(link, style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Text(
            'Copy it now: it will not be shown again.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.error),
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
}

class _CreateLinkDialog extends StatefulWidget {
  const _CreateLinkDialog();

  @override
  State<_CreateLinkDialog> createState() => _CreateLinkDialogState();
}

class _CreateLinkDialogState extends State<_CreateLinkDialog> {
  final _name = TextEditingController();
  String _rights = 'view';
  String _layout = 'list';
  int? _days;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New public link'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _name,
              maxLength: 60,
              decoration: const InputDecoration(labelText: 'Name (optional)', hintText: 'Grandma'),
            ),
            const SizedBox(height: 4),
            DropdownButtonFormField<String>(
              initialValue: _rights,
              decoration: const InputDecoration(labelText: 'Rights'),
              items: const [
                DropdownMenuItem(value: 'view', child: Text('View only')),
                DropdownMenuItem(value: 'tick', child: Text('View and tick items')),
              ],
              onChanged: (value) => setState(() => _rights = value ?? 'view'),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _layout,
              decoration: const InputDecoration(labelText: 'Layout'),
              items: const [
                DropdownMenuItem(value: 'list', child: Text('List')),
                DropdownMenuItem(value: 'board', child: Text('Board')),
              ],
              onChanged: (value) => setState(() => _layout = value ?? 'list'),
            ),
            const SizedBox(height: 12),
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
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          onPressed: () => Navigator.of(context).pop((
            name: _name.text.trim(),
            rights: _rights,
            layout: _layout,
            days: _days,
          )),
          child: const Text('Create'),
        ),
      ],
    );
  }
}
