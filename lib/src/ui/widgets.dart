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

/// A small read-only fact on a task row: icon and text in one soft pill.
class MetaPill extends StatelessWidget {
  const MetaPill({super.key, required this.label, this.icon, this.color, this.dot});

  final String label;
  final IconData? icon;

  /// Text and icon colour; the muted default when null.
  final Color? color;

  /// A leading colour dot (a project), drawn instead of [icon].
  final Color? dot;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tint = color ?? scheme.onSurfaceVariant;
    // A coloured pill (due today, overdue) gets a wash of its own colour; the
    // neutral ones sit on the quiet field fill.
    final wash = color != null ? color!.withValues(alpha: 0.12) : scheme.field;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: wash, borderRadius: BorderRadius.circular(8)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (dot != null)
            Container(
              width: 8,
              height: 8,
              margin: const EdgeInsets.only(right: 6),
              decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
            )
          else if (icon != null)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Icon(icon, size: 13, color: tint),
            ),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelMedium?.copyWith(color: tint, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

/// A property control that shows its value. With [onTap] it opens a picker and
/// clears on long-press; without, it is only the look, for use as the child of
/// a [PopupMenuButton] that handles the tap itself.
class PropChip extends StatelessWidget {
  const PropChip({
    super.key,
    required this.icon,
    required this.label,
    required this.active,
    this.onTap,
    this.onClear,
    this.color,
  });

  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback? onTap;
  final VoidCallback? onClear;

  /// Accent for the active state; the theme's primary when null.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = color ?? scheme.primary;
    final foreground = active ? accent : scheme.onSurfaceVariant;
    final shape = BorderRadius.circular(12);
    return Material(
      color: active ? accent.withValues(alpha: 0.12) : scheme.field,
      shape: RoundedRectangleBorder(
        borderRadius: shape,
        side: BorderSide(color: active ? accent.withValues(alpha: 0.35) : Colors.transparent),
      ),
      child: InkWell(
        onTap: onTap,
        onLongPress: onClear,
        borderRadius: shape,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: foreground),
              const SizedBox(width: 6),
              Text(
                label,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(color: foreground),
              ),
              if (active && onClear != null) ...[
                const SizedBox(width: 6),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: onClear,
                  child: Icon(Icons.close, size: 14, color: foreground),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Section label above a group of rows.
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key, this.color, this.count});

  final String text;
  final Color? color;
  final int? count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tint = color ?? theme.colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
      child: Row(
        children: [
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

/// The OTDA mark on its own dark tile. The logo's tray is white, so it needs
/// the tile to sit on whatever theme is chosen; the artwork carries its own
/// margin, so it is drawn edge to edge inside the tile. This is the same
/// picture as the launcher icon.
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
      child: Image.asset(
        'assets/logo.png',
        fit: BoxFit.contain,
        filterQuality: FilterQuality.high,
        semanticLabel: 'OTDA logo',
        errorBuilder: (_, _, _) => const SizedBox.shrink(),
      ),
    );
  }
}
