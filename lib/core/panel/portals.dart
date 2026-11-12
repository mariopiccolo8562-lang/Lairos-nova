class PortalRotation {
  static String normalizeHost(String value) {
    var raw = value.trim();
    if (raw.isEmpty) return '';
    if (!raw.startsWith('http://') && !raw.startsWith('https://')) {
      raw = 'http://$raw';
    }
    final uri = Uri.tryParse(raw);
    if (uri == null || uri.host.isEmpty) return '';
    return Uri(
      scheme: uri.scheme,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
    ).toString().replaceFirst(RegExp(r'/+$'), '');
  }

  static String hostKey(String value) => normalizeHost(value)
      .replaceFirst(RegExp(r'^https?://', caseSensitive: false), '')
      .toLowerCase();

  static String originOf(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null || uri.host.isEmpty) return '';
    return normalizeHost(uri.origin);
  }

  static List<String> candidates({
    required String host,
    required String url,
    required List<String> alts,
  }) {
    final main = normalizeHost(host.isNotEmpty ? host : originOf(url));
    if (main.isEmpty) return const [];
    final result = <String>[main];
    final seen = <String>{hostKey(main)};
    for (final value in alts) {
      final candidate = normalizeHost(value);
      if (candidate.isNotEmpty && seen.add(hostKey(candidate))) result.add(candidate);
    }
    return result;
  }

  static int offset(String code, int length) {
    if (length <= 0) return 0;
    var hash = 0x811C9DC5.toSigned(32);
    for (final unit in code.codeUnits) {
      hash = ((hash ^ unit) * 0x01000193).toSigned(32);
    }
    return ((hash % length) + length) % length;
  }

  static List<String> order(List<String> candidates, String code) {
    if (candidates.isEmpty) return const [];
    final start = offset(code, candidates.length);
    return [...candidates.skip(start), ...candidates.take(start)];
  }

  static bool _bad(String host, Map<String, int> badUntil, int nowMs) =>
      (badUntil[hostKey(host)] ?? 0) > nowMs;

  static String select({
    required String mode,
    required List<String> candidates,
    required String code,
    String savedChoice = '',
    Map<String, int> badUntil = const {},
    int? nowMs,
  }) {
    if (candidates.isEmpty) return '';
    final main = candidates.first;
    if (mode == 'main') return main;
    if (mode == 'alt') return candidates.length > 1 ? candidates[1] : main;
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    if (savedChoice.isNotEmpty && !_bad(savedChoice, badUntil, now)) {
      final key = hostKey(savedChoice);
      for (final candidate in candidates) {
        if (hostKey(candidate) == key) return candidate;
      }
    }
    final ordered = mode == 'rot' ? order(candidates, code) : candidates;
    for (final candidate in ordered) {
      if (!_bad(candidate, badUntil, now)) return candidate;
    }
    return main;
  }

  static String? next({
    required String mode,
    required List<String> candidates,
    required String code,
    required String current,
    Map<String, int> badUntil = const {},
    int? nowMs,
  }) {
    if ((mode != 'auto' && mode != 'rot') || candidates.length <= 1) return null;
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final ordered = mode == 'rot' ? order(candidates, code) : candidates;
    final currentKey = hostKey(current);
    final index = ordered.indexWhere((candidate) => hostKey(candidate) == currentKey);
    for (var step = 1; step < ordered.length; step++) {
      final candidate = ordered[(index + step + ordered.length) % ordered.length];
      if (hostKey(candidate) != currentKey && !_bad(candidate, badUntil, now)) return candidate;
    }
    return null;
  }

  static bool isXtreamGetUrl(String value) {
    final uri = Uri.tryParse(value);
    return uri != null &&
        uri.path.toLowerCase().endsWith('/get.php') &&
        (uri.queryParameters['username']?.isNotEmpty ?? false) &&
        (uri.queryParameters['password']?.isNotEmpty ?? false);
  }

  static String replaceOrigin(String value, String host) {
    final uri = Uri.tryParse(value);
    final base = Uri.tryParse(normalizeHost(host));
    if (uri == null || uri.host.isEmpty || base == null || base.host.isEmpty) return value;
    return Uri(
      scheme: base.scheme,
      userInfo: uri.userInfo,
      host: base.host,
      port: base.hasPort ? base.port : null,
      path: uri.path,
      query: uri.hasQuery ? uri.query : null,
      fragment: uri.hasFragment ? uri.fragment : null,
    ).toString();
  }

  static String pathAndQuery(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null) return value;
    return '${uri.path}${uri.hasQuery ? '?${uri.query}' : ''}';
  }

  static bool signaturesMatch(String? stored, String current, String legacy) =>
      stored == current || stored == legacy;
}
