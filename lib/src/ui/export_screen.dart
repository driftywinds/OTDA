import 'package:material_ui/material_ui.dart';
import 'package:share_plus/share_plus.dart';

import '../api/api_exception.dart';
import '../app_state.dart';
import '../data/export_service.dart';
import '../e2ee/session.dart';

/// Downloads the account's export and hands it to the system share sheet.
class ExportScreen extends StatefulWidget {
  const ExportScreen({super.key, required this.state});

  final AppState state;

  @override
  State<ExportScreen> createState() => _ExportScreenState();
}

class _ExportScreenState extends State<ExportScreen> {
  static const _service = ExportService();

  ExportFormat _format = ExportFormat.zip;
  bool _busy = false;
  bool _cancelled = false;
  int _received = 0;
  int _total = -1;
  String? _error;
  ExportFile? _done;

  Future<void> _run() async {
    final client = widget.state.client;
    if (client == null) return;
    setState(() {
      _busy = true;
      _cancelled = false;
      _error = null;
      _received = 0;
      _total = -1;
      _done = null;
    });
    try {
      final file = await _service.download(
        client,
        format: _format,
        isCancelled: () => _cancelled,
        onProgress: (received, total) {
          if (!mounted) return;
          setState(() {
            _received = received;
            _total = total;
          });
        },
      );
      if (!mounted) return;
      setState(() => _done = file);
      await _share(file);
    } on ExportCancelled {
      if (mounted) setState(() => _error = 'Export cancelled.');
    } on ApiException catch (e) {
      if (mounted) {
        setState(() => _error = switch (e.code) {
              'network' || 'timeout' => 'Could not reach the server.',
              'insufficient_scope' => 'This token is not allowed to export the account.',
              _ => e.message.isEmpty ? 'The export failed.' : e.message,
            });
      }
    } on Object catch (e) {
      if (mounted) setState(() => _error = 'The export failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _share(ExportFile file) async {
    final encrypted = E2eeSession.instance.enabled;
    await SharePlus.instance.share(ShareParams(
      files: [XFile(file.path, mimeType: file.mime)],
      subject: 'OpenTodo export',
      text: encrypted
          ? 'OpenTodo export (encrypted account: content is ciphertext; the wrapped key is in the file).'
          : 'OpenTodo export',
    ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final encrypted = E2eeSession.instance.enabled;
    final progress = _total > 0 ? (_received / _total).clamp(0.0, 1.0) : null;

    return Scaffold(
      appBar: AppBar(title: const Text('Export')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          Text(
            'Download everything this account holds, then share the file with another app.',
            style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          Card(
            margin: EdgeInsets.zero,
            child: Column(
              children: [
                RadioListTile<ExportFormat>(
                  value: ExportFormat.zip,
                  // ignore: deprecated_member_use
                  groupValue: _format,
                  // ignore: deprecated_member_use
                  onChanged: _busy ? null : (value) => setState(() => _format = value!),
                  title: const Text('ZIP archive'),
                  subtitle: const Text('Tasks, projects and attachment files'),
                ),
                RadioListTile<ExportFormat>(
                  value: ExportFormat.json,
                  // ignore: deprecated_member_use
                  groupValue: _format,
                  // ignore: deprecated_member_use
                  onChanged: _busy ? null : (value) => setState(() => _format = value!),
                  title: const Text('JSON'),
                  subtitle: const Text('One document, no files'),
                ),
              ],
            ),
          ),
          if (encrypted) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: scheme.errorContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Icon(Icons.lock_outline, size: 18, color: scheme.onErrorContainer),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'This account is end-to-end encrypted: the export holds ciphertext and the '
                      'wrapped key record. Keep the passphrase safe; without it the file cannot be read.',
                      style: TextStyle(color: scheme.onErrorContainer, fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 20),
          if (_busy) ...[
            LinearProgressIndicator(value: progress),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    progress != null
                        ? '${(_received / 1024).round()} KB of ${(_total / 1024).round()} KB'
                        : '${(_received / 1024).round()} KB',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                TextButton(
                  onPressed: () => setState(() => _cancelled = true),
                  child: const Text('Cancel'),
                ),
              ],
            ),
          ] else
            FilledButton.icon(
              onPressed: _run,
              icon: const Icon(Icons.download_rounded, size: 18),
              label: const Text('Download and share'),
            ),
          if (_done != null) ...[
            const SizedBox(height: 14),
            Text('Saved as ${_done!.name}', style: theme.textTheme.bodySmall),
            const SizedBox(height: 4),
            Text(
              _done!.path,
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
            TextButton.icon(
              onPressed: () => _share(_done!),
              icon: const Icon(Icons.share_rounded, size: 16),
              label: const Text('Share again'),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: TextStyle(color: scheme.error)),
          ],
        ],
      ),
    );
  }
}
