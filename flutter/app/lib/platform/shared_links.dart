/// Matches the core's share/mirror post URL forms; arbitrary websites, profile
/// pages, credentials and non-web schemes are never sent to the download flow.
List<String> parseSharedPostLinks(String text) {
  final candidates = RegExp(
    r'(?<![a-z0-9_.@/])(?:https?://)?(?:(?:www|mobile|m)\.)?(?:twitter\.com|x\.com|fxtwitter\.com|fixupx\.com|vxtwitter\.com|fixvx\.com)/[^\s<>()]+',
    caseSensitive: false,
  );
  const hosts = {
    'twitter.com',
    'x.com',
    'fxtwitter.com',
    'fixupx.com',
    'vxtwitter.com',
    'fixvx.com',
  };
  final result = <String>{};
  for (final match in candidates.allMatches(text)) {
    try {
      final value = match.group(0)!;
      final uri = Uri.tryParse(
        value.contains('://') ? value : 'https://$value',
      );
      if (uri == null || uri.userInfo.isNotEmpty || uri.hasPort) continue;
      final host = uri.host.toLowerCase().replaceFirst(
        RegExp(r'^(www|mobile|m)\.'),
        '',
      );
      if (!hosts.contains(host)) continue;
      final parts = uri.pathSegments;
      String? user;
      String? rawId;
      if (parts.length >= 4 && parts.take(3).join('/') == 'i/web/status') {
        user = 'i';
        rawId = parts[3];
      } else if (parts.length >= 3 && parts[0] == 'i' && parts[1] == 'status') {
        user = 'i';
        rawId = parts[2];
      } else if (parts.length >= 3 &&
          const ['status', 'statuses'].contains(parts[1].toLowerCase())) {
        user = parts[0];
        rawId = parts[2];
      }
      if (user == null || !RegExp(r'^[A-Za-z0-9_]+$').hasMatch(user)) continue;
      final id = RegExp(r'^[0-9]+').firstMatch(rawId!)?.group(0);
      if (id == null || id.length > 20) continue;
      result.add('https://x.com/$user/status/$id');
    } on FormatException {
      continue;
    }
  }
  return result.toList(growable: false);
}
