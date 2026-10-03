const String libraryInviteScheme = 'kazumi-library';

class LibraryInvite {
  const LibraryInvite({required this.server, required this.key});

  final String server;
  final String key;

  /// Accepts the app link the invite page opens and the https invite link
  /// itself, so a pasted link works when the app link can't be used.
  static LibraryInvite? parse(String text) {
    final match = RegExp(
      '($libraryInviteScheme://\\S+|https?://\\S+/join#k=\\S+)',
    ).firstMatch(text.trim());
    if (match == null) return null;
    final uri = Uri.tryParse(match.group(0)!);
    if (uri == null) return null;

    if (uri.scheme == libraryInviteScheme) {
      final server = uri.queryParameters['server'] ?? '';
      final key = uri.queryParameters['key'] ?? '';
      if (!server.startsWith('https://') && !server.startsWith('http://')) {
        return null;
      }
      return key.isEmpty ? null : LibraryInvite(server: server, key: key);
    }

    final key = Uri.splitQueryString(uri.fragment)['k'] ?? '';
    if (key.isEmpty) return null;
    return LibraryInvite(server: uri.origin, key: key);
  }

  String get webLink => '$server/join#k=${Uri.encodeComponent(key)}';
}
