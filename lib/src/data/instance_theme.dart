/// Reads `GET /api/v1/themes/instance` and returns the seeds of the default
/// light and dark theme when each names an `instance:<id>` theme.
///
/// The server's default can also be `""` (OpenTodo's own) or `builtin:<id>`;
/// those keep the app's palette, because the built-in documents are not part of
/// this response.
({Map<String, dynamic>? light, Map<String, dynamic>? dark}) instanceThemeSeeds(Map<String, dynamic> json) {
  final defaults = (json['default'] as Map?)?.cast<String, dynamic>() ?? const {};
  final themes = [
    for (final raw in (json['themes'] as List?) ?? const [])
      if (raw is Map) raw.cast<String, dynamic>(),
  ];

  Map<String, dynamic>? seedsFor(String side) {
    final choice = defaults[side]?.toString() ?? '';
    const prefix = 'instance:';
    if (!choice.startsWith(prefix)) return null;
    final id = choice.substring(prefix.length);
    for (final theme in themes) {
      if (theme['id']?.toString() != id) continue;
      final seeds = theme['seeds'];
      if (seeds is Map) return seeds.cast<String, dynamic>();
    }
    return null;
  }

  return (light: seedsFor('light'), dark: seedsFor('dark'));
}
