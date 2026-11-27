import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:markdown/markdown.dart' as md;

/// Markdown notes with tappable checklists.
///
/// OpenTodo's rich editor stores notes twice: `description` is the Markdown
/// projection and `notes_doc` is the Yjs document. A plain-text editor writes
/// `description`; the rich client folds a newer description into `notes_doc`
/// (reconcileNote in OpenTodo's ops.ts), which is the compatibility path this
/// field follows. The document is never erased from here.
class NotesField extends StatefulWidget {
  const NotesField({super.key, required this.controller, required this.onSave});

  final TextEditingController controller;
  final Future<void> Function() onSave;

  @override
  State<NotesField> createState() => _NotesFieldState();
}

class _NotesFieldState extends State<NotesField> {
  late bool _editing = widget.controller.text.trim().isEmpty;
  Timer? _saveTimer;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    widget.controller.removeListener(_onTextChanged);
    // The sheet can close inside the 600 ms debounce; keep the last keystrokes.
    unawaited(widget.onSave());
    super.dispose();
  }

  void _onTextChanged() {
    if (!mounted) return;
    setState(() {});
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 600), () {
      unawaited(widget.onSave());
    });
  }

  Future<void> _toggleChecklist(int index) async {
    final text = widget.controller.text;
    final pattern = RegExp(r'^(\s*(?:[-*+]|\d+[.)])\s+\[)([ xX])(\])', multiLine: true);
    var seen = 0;
    final changed = text.replaceAllMapped(pattern, (match) {
      if (seen++ != index) return match[0]!;
      final checked = match[2]!.toLowerCase() == 'x';
      return '${match[1]}${checked ? ' ' : 'x'}${match[3]}';
    });
    if (changed == text) return;
    widget.controller.value = TextEditingValue(
      text: changed,
      selection: widget.controller.selection,
    );
    await widget.onSave();
  }

  void _insert(String before, [String after = '']) {
    final value = widget.controller.value;
    final selection = value.selection;
    final start = selection.start < 0 ? value.text.length : selection.start;
    final end = selection.end < 0 ? start : selection.end;
    final selected = value.text.substring(start, end);
    final replacement = '$before$selected$after';
    widget.controller.value = TextEditingValue(
      text: value.text.replaceRange(start, end, replacement),
      selection: TextSelection.collapsed(offset: start + before.length + selected.length),
    );
    _onTextChanged();
  }

  void _startEditing() {
    setState(() => _editing = true);
  }

  Future<void> _showPreview() async {
    _saveTimer?.cancel();
    await widget.onSave();
    if (!mounted) return;
    setState(() => _editing = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final text = widget.controller.text;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
            child: Row(
              children: [
                Text(
                  'NOTES',
                  style: theme.textTheme.labelSmall?.copyWith(
                    letterSpacing: 1.1,
                    fontWeight: FontWeight.w800,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const Spacer(),
                if (_editing)
                  TextButton(onPressed: _showPreview, child: const Text('Preview'))
                else
                  IconButton(
                    tooltip: 'Edit notes',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.edit_outlined, size: 20),
                    onPressed: _startEditing,
                  ),
              ],
            ),
          ),
          if (_editing) ...[
            _Toolbar(onInsert: _insert),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
              child: TextField(
                controller: widget.controller,
                minLines: 6,
                maxLines: 18,
                keyboardType: TextInputType.multiline,
                inputFormatters: const [MarkdownListFormatter()],
                decoration: const InputDecoration(
                  hintText: 'Write notes. Markdown works: # heading, - list, - [ ] checklist, **bold**.',
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.zero,
                ),
                onTapOutside: (_) => unawaited(widget.onSave()),
              ),
            ),
          ] else
            InkWell(
              borderRadius: BorderRadius.circular(20),
              onTap: _startEditing,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: text.trim().isEmpty
                    ? Row(
                        children: [
                          Icon(Icons.notes_rounded, size: 20, color: scheme.onSurfaceVariant),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Add notes — Markdown and checklists supported',
                              style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                            ),
                          ),
                        ],
                      )
                    : _MarkdownView(
                        data: text,
                        onToggleChecklist: _toggleChecklist,
                      ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Continues Markdown list markers when Enter is pressed, and removes the
/// marker when Enter is pressed again on an empty item.
///
/// This mirrors the behaviour of the editor on OpenTodo's web app: `- item`
/// becomes `- item\n- `, `1. item` becomes `2. `, and a checklist continues
/// unchecked. A second Enter on the empty item exits the list instead of
/// creating an endless run of markers.
class MarkdownListFormatter extends TextInputFormatter {
  const MarkdownListFormatter();

  static final _checklist = RegExp(r'^(\s*)([-*+])\s+\[([ xX])\]\s+(.*)$');
  static final _numbered = RegExp(r'^(\s*)(\d+)([.)])\s+(.*)$');
  static final _bullet = RegExp(r'^(\s*)([-*+])\s+(.*)$');

  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    // Only a single newline insertion is ours. Pasting text, deleting text and
    // IME composition keep their normal behaviour.
    if (newValue.composing.isValid) return newValue;
    if (oldValue.selection.isValid == false || newValue.selection.isValid == false) return newValue;
    if (newValue.text.length != oldValue.text.length + 1) return newValue;
    final cursor = newValue.selection.baseOffset;
    if (cursor <= 0 || cursor > newValue.text.length) return newValue;
    if (newValue.text[cursor - 1] != '\n') return newValue;
    if (newValue.text.replaceRange(cursor - 1, cursor, '') != oldValue.text) return newValue;
    if (oldValue.selection.baseOffset != cursor - 1) return newValue;

    final before = oldValue.text.substring(0, cursor - 1);
    final lineStart = before.lastIndexOf('\n') + 1;
    final lineEnd = oldValue.text.indexOf('\n', cursor - 1);
    final end = lineEnd < 0 ? oldValue.text.length : lineEnd;
    final line = oldValue.text.substring(lineStart, end);
    final offsetInLine = cursor - 1 - lineStart;

    final checklist = _checklist.firstMatch(line);
    final numbered = _numbered.firstMatch(line);
    final bullet = _bullet.firstMatch(line);
    if (checklist == null && numbered == null && bullet == null) return newValue;

    final String prefix;
    final String next;
    if (checklist != null) {
      final indent = checklist[1]!;
      final marker = checklist[2]!;
      final content = checklist[4]!;
      final prefixEnd = line.length - content.length;
      prefix = line.substring(0, prefixEnd);
      next = '$indent$marker [ ] ';
    } else if (numbered != null) {
      final content = numbered[4]!;
      final prefixEnd = line.length - content.length;
      prefix = line.substring(0, prefixEnd);
      final number = int.tryParse(numbered[2]!) ?? 1;
      next = '${numbered[1]}${number + 1}${numbered[3]} ';
    } else {
      final content = bullet![3]!;
      final prefixEnd = line.length - content.length;
      prefix = line.substring(0, prefixEnd);
      next = '${bullet[1]}${bullet[2]} ';
    }

    // A line that is only its marker: pressing Enter leaves the list and
    // restores the blank line that was there before the marker appeared.
    if (line.substring(prefix.length).trim().isEmpty && offsetInLine >= prefix.length) {
      final cleaned = oldValue.text.replaceRange(lineStart, lineStart + prefix.length, '');
      return TextEditingValue(
        text: cleaned,
        selection: TextSelection.collapsed(offset: lineStart),
      );
    }

    final value = newValue.text.replaceRange(cursor, cursor, next);
    return TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: cursor + next.length),
    );
  }
}

class _Toolbar extends StatelessWidget {
  const _Toolbar({required this.onInsert});

  final void Function(String before, [String after]) onInsert;

  @override
  Widget build(BuildContext context) {
    final buttons = <Widget>[
      _button(Icons.check_box_outlined, 'Checklist', () => onInsert('- [ ] ')),
      _button(Icons.format_list_bulleted_rounded, 'Bullet list', () => onInsert('- ')),
      _button(Icons.format_list_numbered_rounded, 'Numbered list', () => onInsert('1. ')),
      _button(Icons.title_rounded, 'Heading', () => onInsert('## ')),
      _button(Icons.format_bold_rounded, 'Bold', () => onInsert('**', '**')),
      _button(Icons.format_italic_rounded, 'Italic', () => onInsert('_', '_')),
      _button(Icons.format_quote_rounded, 'Quote', () => onInsert('> ')),
      _button(Icons.code_rounded, 'Code', () => onInsert('`', '`')),
      _button(Icons.link_rounded, 'Link', () => onInsert('[', '](https://)')),
    ];
    return SizedBox(
      height: 42,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        children: buttons,
      ),
    );
  }

  Widget _button(IconData icon, String tooltip, VoidCallback onTap) => IconButton(
        tooltip: tooltip,
        visualDensity: VisualDensity.compact,
        icon: Icon(icon, size: 20),
        onPressed: onTap,
      );
}

class _MarkdownView extends StatelessWidget {
  const _MarkdownView({required this.data, required this.onToggleChecklist});

  final String data;
  final Future<void> Function(int index) onToggleChecklist;

  @override
  Widget build(BuildContext context) {
    final document = md.Document(extensionSet: md.ExtensionSet.gitHubFlavored).parse(data);
    final render = _Renderer(context, onToggleChecklist);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final node in document)
          ?render.block(node),
      ],
    );
  }
}

class _Renderer {
  _Renderer(this.context, this.onToggleChecklist);

  final BuildContext context;
  final Future<void> Function(int index) onToggleChecklist;
  int _checkboxes = 0;

  ThemeData get theme => Theme.of(context);

  Widget? block(md.Node node) {
    if (node is md.Text) {
      final text = node.text.trim();
      return text.isEmpty ? null : Text(text, style: theme.textTheme.bodyMedium);
    }
    if (node is! md.Element) return null;
    switch (node.tag) {
      case 'p':
        final spans = inline(node.children ?? const []);
        return spans.isEmpty
            ? const SizedBox.shrink()
            : Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text.rich(TextSpan(children: spans), style: theme.textTheme.bodyMedium?.copyWith(height: 1.45)),
              );
      case 'h1':
      case 'h2':
      case 'h3':
      case 'h4':
        final size = switch (node.tag) {
          'h1' => theme.textTheme.titleLarge,
          'h2' => theme.textTheme.titleMedium,
          _ => theme.textTheme.titleSmall,
        };
        return Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 6),
          child: Text.rich(
            TextSpan(children: inline(node.children ?? const [])),
            style: size?.copyWith(fontWeight: FontWeight.w800),
          ),
        );
      case 'ul':
      case 'ol':
        return _list(node);
      case 'blockquote':
        return Container(
          margin: const EdgeInsets.symmetric(vertical: 6),
          padding: const EdgeInsets.only(left: 12),
          decoration: BoxDecoration(
            border: Border(left: BorderSide(color: theme.colorScheme.primary, width: 3)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final child in node.children ?? const [])
                ?block(child),
            ],
          ),
        );
      case 'pre':
        final code = node.textContent.trimRight();
        return Container(
          width: double.infinity,
          margin: const EdgeInsets.symmetric(vertical: 6),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
          ),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Text(code, style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace')),
          ),
        );
      case 'hr':
        return Divider(height: 18, color: theme.colorScheme.outlineVariant);
      case 'table':
        return _table(node);
      case 'li':
        return _listItem(node);
      case 'input':
        return _checkbox(node);
      default:
        final spans = inline(node.children ?? const []);
        return spans.isEmpty ? null : Text.rich(TextSpan(children: spans));
    }
  }

  Widget _list(md.Element node) {
    final ordered = node.tag == 'ol';
    var number = 1;
    final rows = <Widget>[];
    for (final child in node.children ?? const []) {
      if (child is! md.Element || child.tag != 'li') continue;
      final inputs = (child.children ?? const []).whereType<md.Element>().where((e) => e.tag == 'input').toList();
      final rest = (child.children ?? const []).where((e) => e is! md.Element || e.tag != 'input').toList();
      final content = <Widget>[
        for (final item in rest)
          ?block(item),
      ];
      final marker = ordered ? '${number++}.' : '•';
      rows.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 3),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (inputs.isNotEmpty)
                _checkbox(inputs.first)
              else
                SizedBox(
                  width: 22,
                  child: Text(marker, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: content,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: rows),
    );
  }

  Widget _listItem(md.Element node) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final child in node.children ?? const [])
            ?block(child),
        ],
      );

  Widget _checkbox(md.Element node) {
    final checked = node.attributes['checked'] == 'true';
    final index = _checkboxes++;
    return Semantics(
      button: true,
      checked: checked,
      label: checked ? 'Checked checklist item' : 'Unchecked checklist item',
      child: InkResponse(
        onTap: () => unawaited(onToggleChecklist(index)),
        radius: 16,
        child: Padding(
          padding: const EdgeInsets.only(right: 4, top: 2),
          child: Icon(
            checked ? Icons.check_box_rounded : Icons.check_box_outline_blank_rounded,
            size: 20,
            color: checked ? theme.colorScheme.primary : theme.colorScheme.outline,
          ),
        ),
      ),
    );
  }

  Widget _table(md.Element node) {
    final rows = <TableRow>[];
    for (final section in (node.children ?? const []).whereType<md.Element>()) {
      for (final row in (section.children ?? const []).whereType<md.Element>()) {
        if (row.tag != 'tr') continue;
        final cells = <Widget>[];
        for (final cell in (row.children ?? const []).whereType<md.Element>()) {
          cells.add(
            Padding(
              padding: const EdgeInsets.all(6),
              child: Text.rich(
                TextSpan(children: inline(cell.children ?? const [])),
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: cell.tag == 'th' ? FontWeight.w700 : null,
                ),
              ),
            ),
          );
        }
        if (cells.isNotEmpty) rows.add(TableRow(children: cells));
      }
    }
    if (rows.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Table(
        border: TableBorder.all(color: theme.colorScheme.outlineVariant),
        defaultColumnWidth: const IntrinsicColumnWidth(),
        children: rows,
      ),
    );
  }

  List<InlineSpan> inline(List<md.Node> nodes, {TextStyle? style}) {
    final spans = <InlineSpan>[];
    for (final node in nodes) {
      if (node is md.Text) {
        spans.add(TextSpan(text: node.text, style: style));
      } else if (node is md.Element) {
        switch (node.tag) {
          case 'strong':
            spans.addAll(inline(node.children ?? const [], style: (style ?? const TextStyle()).merge(const TextStyle(fontWeight: FontWeight.w700))));
          case 'em':
            spans.addAll(inline(node.children ?? const [], style: (style ?? const TextStyle()).merge(const TextStyle(fontStyle: FontStyle.italic))));
          case 'code':
            spans.add(TextSpan(
              text: node.textContent,
              style: (style ?? const TextStyle()).merge(TextStyle(
                fontFamily: 'monospace',
                backgroundColor: theme.colorScheme.surfaceContainerHighest,
              )),
            ));
          case 'a':
            spans.addAll(inline(node.children ?? const [],
              style: (style ?? const TextStyle()).merge(TextStyle(
                color: theme.colorScheme.primary,
                decoration: TextDecoration.underline,
              )),
            ));
          case 'br':
            spans.add(const TextSpan(text: '\n'));
          case 'softbreak':
            spans.add(const TextSpan(text: ' '));
          case 'input':
            break;
          default:
            spans.addAll(inline(node.children ?? const [], style: style));
        }
      }
    }
    return spans;
  }
}
