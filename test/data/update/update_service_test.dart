// Тесты UpdateService (§5): semver-сравнение, выбор релева, обработка
// ответов GitHub Releases API на фейковом http.Client (сеть не трогается).
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kopilka/data/update/update_service.dart';

/// Фейковый клиент: перехватывает запрос, отвечает заготовкой.
http.Client fakeClient(
  Future<http.Response> Function(http.Request request) handler,
) =>
    MockClient(handler);

http.Response releasesResponse(List<Map<String, dynamic>> releases) =>
    http.Response(jsonEncode(releases), 200, headers: <String, String>{
      'content-type': 'application/json; charset=utf-8',
    });

Map<String, dynamic> release({
  required String tag,
  String name = 'Kopilka',
  String body = '',
  bool draft = false,
  bool prerelease = false,
  String url = 'https://github.com/kolesnikov-studio/kopilka/releases/tag/x',
}) =>
    <String, dynamic>{
      'tag_name': tag,
      'name': name,
      'body': body,
      'html_url': url,
      'published_at': '2026-09-24T12:00:00Z',
      'draft': draft,
      'prerelease': prerelease,
    };

void main() {
  group('parseSemver', () {
    test('читает v-префикс и отбрасывает прагмы', () {
      expect(parseSemver('v1.2.3'), (major: 1, minor: 2, patch: 3));
      expect(parseSemver('1.2.3-beta.1'), (major: 1, minor: 2, patch: 3));
      expect(parseSemver(' 0.1.0 '), (major: 0, minor: 1, patch: 0));
    });

    test('некорректные строки дают null', () {
      expect(parseSemver('не версия'), isNull);
      expect(parseSemver('1.2'), isNull);
      expect(parseSemver('1.2.x'), isNull);
    });
  });

  group('latestUpdate', () {
    test('выбирает строго новее текущей', () {
      final UpdateAvailable? update = latestUpdate(
        releases: <ReleaseInfo>[
          ReleaseInfo.fromJson(release(tag: 'v0.1.0')),
          ReleaseInfo.fromJson(release(tag: 'v0.2.0')),
        ],
        currentVersion: '0.1.0',
      );
      expect(update?.version, 'v0.2.0');
    });

    test('актуальная версия — null', () {
      expect(
        latestUpdate(
          releases: <ReleaseInfo>[ReleaseInfo.fromJson(release(tag: 'v0.1.0'))],
          currentVersion: '0.1.0',
        ),
        isNull,
      );
      // Старее текущей тоже не предлагается.
      expect(
        latestUpdate(
          releases: <ReleaseInfo>[ReleaseInfo.fromJson(release(tag: 'v0.0.9'))],
          currentVersion: '0.1.0',
        ),
        isNull,
      );
    });

    test('черновики и пререлизы пропускаются', () {
      expect(
        latestUpdate(
          releases: <ReleaseInfo>[
            ReleaseInfo.fromJson(release(tag: 'v0.2.0', draft: true)),
            ReleaseInfo.fromJson(release(tag: 'v0.3.0-rc1', prerelease: true)),
          ],
          currentVersion: '0.1.0',
        ),
        isNull,
      );
    });

    test('тег без semver не роняет выбор', () {
      expect(
        latestUpdate(
          releases: <ReleaseInfo>[
            ReleaseInfo.fromJson(release(tag: 'праздник')),
            ReleaseInfo.fromJson(release(tag: 'v0.2.0')),
          ],
          currentVersion: '0.1.0',
        )?.version,
        'v0.2.0',
      );
    });

    test('из нескольких кандидатов берётся самый новый', () {
      expect(
        latestUpdate(
          releases: <ReleaseInfo>[
            ReleaseInfo.fromJson(release(tag: 'v0.2.0')),
            ReleaseInfo.fromJson(release(tag: 'v0.10.0')),
            ReleaseInfo.fromJson(release(tag: 'v0.9.0')),
          ],
          currentVersion: '0.1.0',
        )?.version,
        // semver, не лексикографика: 0.10.0 новее 0.9.0.
        'v0.10.0',
      );
    });
  });

  group('UpdateService.check', () {
    test('новый релиз → UpdateFound с данными диалога', () async {
      late Uri requestedUrl;
      final UpdateCheckResult result = await UpdateService(
        client: fakeClient((http.Request request) async {
          requestedUrl = request.url;
          return releasesResponse(<Map<String, dynamic>>[
            release(
              tag: 'v0.2.0',
              name: 'Kopilka 0.2',
              body: 'Отчёты и бюджеты',
              url: 'https://github.com/kolesnikov-studio/kopilka/releases/tag/v0.2.0',
            ),
          ]);
        }),
      ).check(currentVersion: '0.1.0');

      expect(requestedUrl.host, 'api.github.com');
      expect(requestedUrl.path, '/repos/kolesnikov-studio/kopilka/releases');
      expect(result, isA<UpdateFound>());
      final UpdateAvailable update = (result as UpdateFound).update;
      expect(update.version, 'v0.2.0');
      expect(update.changelog, 'Отчёты и бюджеты');
      expect(update.releaseUrl, contains('/tag/v0.2.0'));
    });

    test('актуальная версия → UpdateNotNeeded', () async {
      final UpdateCheckResult result = await UpdateService(
        client: fakeClient(
          (http.Request request) async =>
              releasesResponse(<Map<String, dynamic>>[]),
        ),
      ).check(currentVersion: '0.1.0');
      expect(result, isA<UpdateNotNeeded>());
    });

    test('не-2xx → UpdateCheckOffline', () async {
      final UpdateCheckResult result = await UpdateService(
        client: fakeClient(
          (http.Request request) async =>
              http.Response('rate limited', 403),
        ),
      ).check(currentVersion: '0.1.0');
      expect(result, isA<UpdateCheckOffline>());
    });

    test('не-JSON ответ → UpdateCheckFailed', () async {
      final UpdateCheckResult result = await UpdateService(
        client: fakeClient(
          (http.Request request) async => http.Response('<html>', 200),
        ),
      ).check(currentVersion: '0.1.0');
      expect(result, isA<UpdateCheckFailed>());
    });

    test('сетевая ошибка → UpdateCheckOffline', () async {
      final UpdateCheckResult result = await UpdateService(
        client: fakeClient(
          (http.Request request) async => throw http.ClientException('нет сети'),
        ),
      ).check(currentVersion: '0.1.0');
      expect(result, isA<UpdateCheckOffline>());
    });
  });
}
