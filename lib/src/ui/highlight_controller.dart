import 'package:material_ui/material_ui.dart';

import '../quickadd_bridge.dart';

/// The colour each kind of understood phrase is drawn in while it is typed.
///
/// Mid-tone hues that hold up on both the light and the dark surface; the text takes
/// the colour itself and the background a faint wash of it.
const Map<String, Color> highlightColors = {
  'date': Color(0xFF3B82F6),
  'time': Color(0xFFF59E0B),
  'recurrence': Color(0xFF8B5CF6),
  'reminder': Color(0xFFEC4899),
  'deadline': Color(0xFFEF4444),
  'evening': Color(0xFF6366F1),
  'daypart': Color(0xFF6366F1),
  'someday': Color(0xFF14B8A6),
  'sector': Color(0xFF14B8A6),
  'project': Color(0xFF22C55E),
  'label': Color(0xFF06B6D4),
  'priority': Color(0xFFF97316),
  'energy': Color(0xFF84CC16),
  'estimate': Color(0xFFD4A017),
  'spent': Color(0xFFD4A017),
};

Color highlightColor(String kind) => highlightColors[kind] ?? const Color(0xFF64748B);

/// A text controller that paints the phrases the quick-add parser understood, the way
/// TickTick does: each kind in its own colour, live as the line is typed.
///
/// Parsing is debounced, so the highlights always describe slightly older text. A
/// highlight is drawn only while the line still reads the same at its position, so
/// typing after a phrase leaves it coloured and editing inside it drops the colour
/// until the next parse.
class HighlightingController extends TextEditingController {
  HighlightingController({super.text});

  List<ParseHighlight> _highlights = const [];

  List<ParseHighlight> get highlights => _highlights;

  set highlights(List<ParseHighlight> value) {
    _highlights = value;
    notifyListeners();
  }

  /// The highlights that still match the current text.
  List<ParseHighlight> get liveHighlights {
    final t = text;
    return [
      for (final h in _highlights)
        if (h.start >= 0 && h.end <= t.length && h.start < h.end && t.substring(h.start, h.end) == h.text) h,
    ];
  }

  @override
  TextSpan buildTextSpan({required BuildContext context, TextStyle? style, required bool withComposing}) {
    final live = liveHighlights;
    final composing = withComposing && value.composing.isValid && !value.composing.isCollapsed ? value.composing : null;
    if (live.isEmpty) return super.buildTextSpan(context: context, style: style, withComposing: withComposing);

    final t = text;
    final cuts = <int>{0, t.length};
    for (final h in live) {
      cuts..add(h.start)..add(h.end);
    }
    if (composing != null) {
      cuts..add(composing.start.clamp(0, t.length))..add(composing.end.clamp(0, t.length));
    }
    final points = cuts.toList()..sort();

    final children = <InlineSpan>[];
    for (var i = 0; i + 1 < points.length; i++) {
      final a = points[i];
      final b = points[i + 1];
      if (a == b) continue;
      ParseHighlight? hit;
      for (final h in live) {
        if (h.start <= a && b <= h.end) {
          hit = h;
          break;
        }
      }
      var segment = const TextStyle();
      if (hit != null) {
        final color = highlightColor(hit.kind);
        segment = segment.copyWith(
          color: color,
          backgroundColor: color.withValues(alpha: 0.16),
          fontWeight: FontWeight.w700,
        );
      }
      if (composing != null && a >= composing.start && b <= composing.end) {
        segment = segment.copyWith(decoration: TextDecoration.underline);
      }
      children.add(TextSpan(text: t.substring(a, b), style: segment));
    }
    return TextSpan(style: style, children: children);
  }
}
