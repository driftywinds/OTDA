/// The recent-server list after a successful sign-in: [url] first, no
/// duplicates, at most [maxEntries].
List<String> rememberServer(List<String> current, String url, {int maxEntries = 5}) {
  final trimmed = url.trim();
  if (trimmed.isEmpty) return current;
  return [trimmed, ...current.where((entry) => entry != trimmed)].take(maxEntries).toList();
}
