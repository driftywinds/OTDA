import 'package:material_ui/material_ui.dart';

/// A compact, tappable action inside a settings card: icon, title, optional
/// explanation and a chevron. Every card uses this instead of mixing filled,
/// outlined and text buttons at different widths.
class SettingsAction extends StatelessWidget {
  const SettingsAction({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.subtitleColor,
    this.onTap,
    this.destructive = false,
    this.trailing,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Color? subtitleColor;
  final VoidCallback? onTap;
  final bool destructive;

  /// Replaces the chevron, for an inline action such as "Turn off".
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final color = destructive ? scheme.error : scheme.primary;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 11),
        child: Row(
          children: [
            Icon(icon, size: 20, color: color),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: destructive ? scheme.error : null,
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(color: subtitleColor ?? scheme.onSurfaceVariant),
                    ),
                  ],
                ],
              ),
            ),
            if (trailing != null)
              Padding(padding: const EdgeInsets.only(left: 8), child: trailing)
            else if (onTap != null)
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Icon(Icons.chevron_right_rounded, size: 18, color: scheme.onSurfaceVariant),
              ),
          ],
        ),
      ),
    );
  }
}

/// A small On/Off/Unlocked badge used by the security cards.
class SettingsStatusBadge extends StatelessWidget {
  const SettingsStatusBadge({super.key, required this.text, this.good = true});

  final String text;
  final bool good;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = good ? scheme.primary : scheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(999)),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color, fontWeight: FontWeight.w700),
      ),
    );
  }
}

/// A setting: a label and a value that ends on the same line as every other
/// value in the card.
///
/// The split is by flex, never by a fixed width, so the same row reads correctly
/// on a small phone and a tablet. The trailing space matches the chevron of
/// [SettingsChoiceRow], which is what made the two kinds look ragged before.
class SettingsRow extends StatelessWidget {
  const SettingsRow({super.key, required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodyMedium?.copyWith(fontSize: 13);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Expanded(
            flex: 5,
            child: Text(label, style: style, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 6,
            child: Text(
              value,
              textAlign: TextAlign.right,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: style?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          const SizedBox(width: 24),
        ],
      ),
    );
  }
}

/// A row whose value is picked from a short list.
class SettingsChoiceRow extends StatelessWidget {
  const SettingsChoiceRow({
    super.key,
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  final String label;
  final String value;
  final Map<String, String> options;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodyMedium?.copyWith(fontSize: 13);
    return InkWell(
      onTap: () async {
        final chosen = await showModalBottomSheet<String>(
          context: context,
          showDragHandle: true,
          builder: (context) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final entry in options.entries)
                  ListTile(
                    title: Text(entry.value),
                    trailing: entry.key == value
                        ? Icon(Icons.check_rounded, color: theme.colorScheme.primary)
                        : null,
                    onTap: () => Navigator.of(context).pop(entry.key),
                  ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        );
        if (chosen != null) onChanged(chosen);
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Expanded(
              flex: 5,
              child: Text(label, style: style, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 6,
              child: Text(
                options[value] ?? value,
                textAlign: TextAlign.right,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: style?.copyWith(color: theme.colorScheme.primary, fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(width: 6),
            Icon(Icons.chevron_right_rounded, size: 18, color: theme.colorScheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}
