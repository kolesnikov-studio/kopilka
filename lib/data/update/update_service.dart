import 'dart:convert';

import 'package:http/http.dart' as http;

// Проверка обновлений (ARCHITECTURE.md §5): GET GitHub Releases API,
// сравнение semver с версией приложения. Единственный сетевой вызов в
// приложении; телеметрии нет.
//
// Сервис не знает про UI: исход — машиночитаемый [UpdateCheckResult],
// тексты подбирает экран. Тестируется с фейковым http.Client.

/// Разбирает строку semver «major.minor.patch» (префикс `v`, прагмы после
/// дефиса игнорируются: релизы проекта — простые трёхчастные теги).
/// Некорректная строка — null (не падение: имя релиза может быть любым,
/// версия парсится из тега, а не из имени).
({int major, int minor, int patch})? parseSemver(String raw) {
  String value = raw.trim();
  if (value.startsWith('v')) {
    value = value.substring(1);
  }
  // Обрезаем прагмы: 1.2.3-beta → 1.2.3.
  final int dash = value.indexOf('-');
  if (dash >= 0) {
    value = value.substring(0, dash);
  }
  final List<String> parts = value.split('.');
  if (parts.length != 3) {
    return null;
  }
  final List<int> numbers = <int>[];
  for (final String part in parts) {
    final int? number = int.tryParse(part);
    if (number == null) {
      return null;
    }
    numbers.add(number);
  }
  return (major: numbers[0], minor: numbers[1], patch: numbers[2]);
}

/// Сравнение semver: > 0, если [a] новее [b].
int compareSemver(
  ({int major, int minor, int patch}) a,
  ({int major, int minor, int patch}) b,
) {
  int by(int x, int y) => x.compareTo(y);
  return by(a.major, b.major) != 0
      ? by(a.major, b.major)
      : by(a.minor, b.minor) != 0
          ? by(a.minor, b.minor)
          : by(a.patch, b.patch);
}

/// Выбранный релиз: самый новый релиз с парсируемым тегом, строго новее
/// текущей версии (черновики и пререлизы не предлагаются).
UpdateAvailable? latestUpdate({
  required List<ReleaseInfo> releases,
  required String currentVersion,
}) {
  final ({int major, int minor, int patch})? current =
      parseSemver(currentVersion);
  if (current == null) {
    return null;
  }
  UpdateAvailable? best;
  for (final ReleaseInfo release in releases) {
    if (release.draft || release.prerelease) {
      continue;
    }
    final ({int major, int minor, int patch})? candidate =
        parseSemver(release.tagName);
    if (candidate == null || compareSemver(candidate, current) <= 0) {
      continue;
    }
    if (best == null || compareSemver(candidate, best.semver) > 0) {
      best = UpdateAvailable(
        version: release.tagName,
        releaseName: release.name,
        changelog: release.body,
        releaseUrl: release.htmlUrl,
        publishedAt: release.publishedAt,
        semver: candidate,
      );
    }
  }
  return best;
}

/// Релиз GitHub Releases API (`GET /repos/{owner}/{repo}/releases`).
class ReleaseInfo {
  const ReleaseInfo({
    required this.tagName,
    required this.name,
    required this.body,
    required this.htmlUrl,
    required this.publishedAt,
    this.draft = false,
    this.prerelease = false,
  });

  factory ReleaseInfo.fromJson(Map<String, dynamic> json) => ReleaseInfo(
        tagName: json['tag_name'] as String? ?? '',
        name: json['name'] as String? ?? '',
        body: json['body'] as String? ?? '',
        htmlUrl: json['html_url'] as String? ?? '',
        publishedAt: switch (json['published_at']) {
          final String value => DateTime.tryParse(value)?.toUtc(),
          _ => null,
        },
        draft: json['draft'] == true,
        prerelease: json['prerelease'] == true,
      );

  final String tagName;
  final String name;
  final String body;
  final String htmlUrl;
  final DateTime? publishedAt;
  final bool draft;
  final bool prerelease;
}

/// Обновление найдено: что показать в диалоге (§5).
class UpdateAvailable {
  const UpdateAvailable({
    required this.version,
    required this.releaseName,
    required this.changelog,
    required this.releaseUrl,
    required this.publishedAt,
    required this.semver,
  });

  /// Тег релиза (как на странице релиза).
  final String version;
  final String releaseName;
  final String changelog;
  final String releaseUrl;
  final DateTime? publishedAt;

  /// Разобранная версия — для сравнения кандидатов.
  final ({int major, int minor, int patch}) semver;
}

/// Исход проверки обновлений (машиночитаемый, без текстов).
sealed class UpdateCheckResult {
  const UpdateCheckResult();
}

/// Обновление есть.
class UpdateFound extends UpdateCheckResult {
  const UpdateFound(this.update);

  final UpdateAvailable update;
}

/// Версия актуальна.
class UpdateNotNeeded extends UpdateCheckResult {
  const UpdateNotNeeded();
}

/// Сеть недоступна или API недоступен (не 2xx).
class UpdateCheckOffline extends UpdateCheckResult {
  const UpdateCheckOffline();
}

/// API ответил, но формат неожиданный — не падаем, сообщаем как отказ.
class UpdateCheckFailed extends UpdateCheckResult {
  const UpdateCheckFailed();
}

/// Сервис проверки обновлений (§5): один GET к GitHub Releases API.
///
/// owner/repo — публичный репозиторий проекта:
/// https://github.com/kolesnikov-studio/kopilka. Если репозиторий
/// переедет, константы правятся здесь одни
class UpdateService {
  UpdateService({
    http.Client? client,
    this.owner = 'kolesnikov-studio',
    this.repo = 'kopilka',
  }) : _client = client ?? http.Client();

  final http.Client _client;
  final String owner;
  final String repo;

  /// Проверяет наличие новой версии. Текущая версия передаётся вызывающим
  /// кодом: package_info_plus — платформенный канал, в чистых dart-тестах
  /// его нет, поэтому контроллер подставляет версию из него, тесты — строку.
  Future<UpdateCheckResult> check({required String currentVersion}) async {
    final Uri url = Uri.https('api.github.com', '/repos/$owner/$repo/releases');
    try {
      final http.Response response = await _client.get(
        url,
        headers: const <String, String>{
          'Accept': 'application/vnd.github+json',
        },
      );
      if (response.statusCode != 200) {
        return const UpdateCheckOffline();
      }
      final Object? decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! List) {
        return const UpdateCheckFailed();
      }
      final List<ReleaseInfo> releases = <ReleaseInfo>[
        for (final dynamic item in decoded)
          if (item is Map<String, dynamic>) ReleaseInfo.fromJson(item),
      ];
      final UpdateAvailable? update = latestUpdate(
        releases: releases,
        currentVersion: currentVersion,
      );
      return update == null
          ? const UpdateNotNeeded()
          : UpdateFound(update);
    } on FormatException {
      return const UpdateCheckFailed();
    } on Exception {
      // Сеть недоступна, таймаут, не-JSON: для пользователя это «не удалось
      // проверить» в любом случае.
      return const UpdateCheckOffline();
    }
  }
}
