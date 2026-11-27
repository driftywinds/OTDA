import 'package:material_ui/material_ui.dart';

import '../app_state.dart';
import 'theme.dart';

/// `#RRGGBB` (or `RRGGBB`) to a colour; null for anything else, so a project
/// with no colour, or a name the server invented, falls back quietly.
Color? parseHexColor(String? value) {
  if (value == null) return null;
  var hex = value.trim();
  if (hex.startsWith('#')) hex = hex.substring(1);
  if (hex.length != 6) return null;
  final rgb = int.tryParse(hex, radix: 16);
  return rgb == null ? null : Color(0xFF000000 | rgb);
}

/// The round completion control: a ring in the task's priority colour that
/// fills with a tick when done. The tap area is larger than the ring.
class TaskCheck extends StatelessWidget {
  const TaskCheck({super.key, required this.done, required this.priority, required this.onChanged});

  final bool done;
  final int priority;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = priorityColor(priority, scheme);
    return Semantics(
      button: true,
      checked: done,
      label: done ? 'Mark not done' : 'Mark done',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onChanged,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: done ? color : color.withValues(alpha: priority < 4 ? 0.1 : 0),
              border: Border.all(color: color.withValues(alpha: done ? 1 : 0.85), width: 2),
            ),
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 140),
              opacity: done ? 1 : 0,
              child: const Icon(Icons.check, size: 15, color: Colors.white),
            ),
          ),
        ),
      ),
    );
  }
}

/// One option in a [showChoiceSheet].
class ChoiceItem<T> {
  const ChoiceItem(this.value, this.label, {this.icon});

  final T value;
  final String label;
  final IconData? icon;
}

/// A list of options in a bottom sheet; the chosen value, or null when the sheet
/// is dismissed (so an option that means "none" needs a value of its own).
///
/// This replaces menus anchored to a button. An anchored menu is placed once, so
/// when it took the keyboard down and the composer slid with it, the menu stayed
/// where the button used to be.
Future<T?> showChoiceSheet<T>(
  BuildContext context, {
  required String title,
  required List<ChoiceItem<T>> items,
  T? selected,
}) {
  return showModalBottomSheet<T>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) {
      final theme = Theme.of(context);
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(title, style: theme.textTheme.titleMedium),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final item in items)
                    ListTile(
                      leading: item.icon == null ? null : Icon(item.icon),
                      title: Text(item.label),
                      selected: item.value == selected,
                      trailing: item.value == selected ? const Icon(Icons.check_rounded) : null,
                      onTap: () => Navigator.of(context).pop(item.value),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      );
    },
  );
}

/// The look of one property icon: a quiet glyph when the property is empty, the
/// accent colour on a soft wash when it holds a value. It draws only; wrap it in
/// a [PropIconButton] to make it tappable, or in a `PopupMenuButton`.
class PropIcon extends StatelessWidget {
  const PropIcon({super.key, required this.icon, this.active = false, this.color});

  final IconData icon;
  final bool active;

  /// Accent for the active state; the theme's primary when null.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = color ?? scheme.primary;
    return Container(
      width: 40,
      height: 40,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: active ? accent.withValues(alpha: 0.13) : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Icon(icon, size: 22, color: active ? accent : scheme.onSurfaceVariant),
    );
  }
}

/// One property of a task as an icon: tap to set or change it. The value itself
/// is shown by a [ValueChip] once there is one, so the bar stays a row of icons
/// however many properties a task has.
class PropIconButton extends StatelessWidget {
  const PropIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.active,
    this.onTap,
    this.onLongPress,
    this.color,
  });

  final IconData icon;
  final String tooltip;
  final bool active;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          onLongPress: onLongPress,
          child: Opacity(
            opacity: onTap == null ? 0.38 : 1,
            child: PropIcon(icon: icon, active: active, color: color),
          ),
        ),
      ),
    );
  }
}

/// A grid of property icons, [columns] to a row, each centred in an equal cell so
/// the rows line up whatever the screen width.
class PropIconBar extends StatelessWidget {
  const PropIconBar({super.key, required this.children, this.columns = 6});

  final List<Widget> children;
  final int columns;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.isFinite ? constraints.maxWidth : columns * 48.0;
        // Rounded down so the cells can never add up to a hair more than the row
        // and push the last one onto a line of its own.
        final cell = (width / columns).floorToDouble();
        return Wrap(
          runSpacing: 4,
          children: [
            for (final child in children)
              SizedBox(width: cell, child: Center(child: child)),
          ],
        );
      },
    );
  }
}

/// A property's value as a small chip: tap it to change the value, tap the cross
/// to clear it. [muted] is the neutral look for a value that is always there (the
/// project, even when it is the Inbox).
class ValueChip extends StatelessWidget {
  const ValueChip({
    super.key,
    required this.label,
    this.icon,
    this.color,
    this.muted = false,
    this.dropdown = false,
    this.onTap,
    this.onClear,
  });

  final String label;
  final IconData? icon;
  final Color? color;
  final bool muted;

  /// A small chevron after the label, for a chip that opens a menu.
  final bool dropdown;
  final VoidCallback? onTap;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tint = muted ? scheme.onSurfaceVariant : (color ?? scheme.primary);
    final shape = BorderRadius.circular(10);
    return Material(
      color: muted ? scheme.field : tint.withValues(alpha: 0.12),
      borderRadius: shape,
      child: InkWell(
        borderRadius: shape,
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.fromLTRB(10, 6, onClear != null || dropdown ? 6 : 10, 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 15, color: tint),
                const SizedBox(width: 6),
              ],
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelLarge?.copyWith(color: tint),
                ),
              ),
              if (onClear != null) ...[
                const SizedBox(width: 2),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: onClear,
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Icon(Icons.close_rounded, size: 15, color: tint),
                  ),
                ),
              ] else if (dropdown)
                Icon(Icons.expand_more_rounded, size: 16, color: tint),
            ],
          ),
        ),
      ),
    );
  }
}

/// A small read-only detail under a subtask: icon and text on a wash of the
/// detail's own colour.
class DetailChip extends StatelessWidget {
  const DetailChip({super.key, required this.label, required this.icon, required this.color});

  final String label;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: color,
                    fontWeight: FontWeight.w700,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Section label above a group of rows.
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key, this.color, this.count, this.icon});

  final String text;
  final Color? color;
  final int? count;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tint = color ?? theme.colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 18, 16, 6),
      child: Row(
        children: [
          if (icon != null) ...[
            Icon(icon, size: 14, color: tint),
            const SizedBox(width: 6),
          ],
          Text(
            text.toUpperCase(),
            style: theme.textTheme.labelSmall?.copyWith(
              color: tint,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.1,
            ),
          ),
          if (count != null) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: tint.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text('$count', style: theme.textTheme.labelSmall?.copyWith(color: tint)),
            ),
          ],
        ],
      ),
    );
  }
}

/// The signed-in account's picture, or its initials in the brand gradient when it
/// has none. A picture is fetched once per version by [AppState]; this widget only
/// draws what is there.
class AccountAvatar extends StatelessWidget {
  const AccountAvatar({super.key, required this.state, this.size = 30});

  final AppState state;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bytes = state.avatarBytes;
    if (bytes != null && bytes.isNotEmpty) {
      return ClipOval(
        child: Image.memory(
          bytes,
          width: size,
          height: size,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          // A corrupt picture must not take the screen down with it.
          errorBuilder: (context, _, _) => _initials(context, scheme),
        ),
      );
    }
    return _initials(context, scheme);
  }

  Widget _initials(BuildContext context, ColorScheme scheme) {
    final name = state.account?.displayName ?? '';
    final initial = name.isEmpty ? '?' : name.substring(0, 1).toUpperCase();
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(gradient: scheme.brandGradient, shape: BoxShape.circle),
      child: Text(
        initial,
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: scheme.onPrimary,
              fontSize: size * 0.42,
            ),
      ),
    );
  }
}

/// The OTDA logo on its own dark tile. The logo is a bare check that runs edge
/// to edge of its artwork, so it is inset inside the tile to leave the same
/// breathing room the launcher icon has.
class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.size = 64});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A),
        borderRadius: BorderRadius.circular(size * 0.22),
        border: Border.all(color: const Color(0x1FFFFFFF)),
        boxShadow: const [
          BoxShadow(color: Color(0x330F172A), blurRadius: 16, offset: Offset(0, 6)),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: EdgeInsets.all(size * 0.2),
        child: Image.asset(
          'assets/logo.png',
          fit: BoxFit.contain,
          filterQuality: FilterQuality.high,
          semanticLabel: 'OTDA logo',
          errorBuilder: (_, _, _) => const SizedBox.shrink(),
        ),
      ),
    );
  }
}
