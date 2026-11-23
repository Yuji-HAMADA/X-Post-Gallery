import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:x_post_gallery/services/gallery_repository.dart';
import 'package:x_post_gallery/services/github_service.dart';
import 'package:x_post_gallery/viewmodels/gallery_viewmodel.dart';

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    dotenv.loadFromString(envString: 'GITHUB_TOKEN=mock_token\nFETCH_QUEUE_GIST_ID=mock_queue');
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('GitHubService Error Handling & Rate Limiting Tests', () {
    test('parses rate limit headers and generates descriptive error message in Japanese', () async {
      TestWidgetsFlutterBinding.instance.platformDispatcher.localeTestValue = const Locale('ja');
      addTearDown(() {
        TestWidgetsFlutterBinding.instance.platformDispatcher.clearLocaleTestValue();
      });

      final futureResetEpoch = (DateTime.now().millisecondsSinceEpoch ~/ 1000) + 900; // 15 mins later

      final mockClient = MockClient((request) async {
        if (request.method == 'PATCH') {
          return http.Response(
            jsonEncode({'message': 'API rate limit exceeded for user ID 12345'}),
            403,
            headers: {
              'x-ratelimit-remaining': '0',
              'x-ratelimit-resource': 'gist_update',
              'x-ratelimit-reset': futureResetEpoch.toString(),
            },
          );
        }
        return http.Response('Not Found', 404);
      });

      final service = GitHubService(client: mockClient, token: 'mock_token');
      final result = await service.updateGistFile(
        gistId: 'gist_123',
        filename: 'favorites.json',
        content: '{}',
      );

      expect(result, isFalse);
      expect(service.lastErrorMessage, contains('GitHub APIのレート制限に達しました'));
      expect(service.lastErrorMessage, contains('gist_update'));
      expect(service.lastErrorMessage, contains('解除予定:'));
    });

    test('generates descriptive error message in English when system locale is English', () async {
      TestWidgetsFlutterBinding.instance.platformDispatcher.localeTestValue = const Locale('en');
      addTearDown(() {
        TestWidgetsFlutterBinding.instance.platformDispatcher.clearLocaleTestValue();
      });

      final futureResetEpoch = (DateTime.now().millisecondsSinceEpoch ~/ 1000) + 900;

      final mockClient = MockClient((request) async {
        if (request.method == 'PATCH') {
          return http.Response(
            jsonEncode({'message': 'API rate limit exceeded'}),
            403,
            headers: {
              'x-ratelimit-remaining': '0',
              'x-ratelimit-resource': 'gist_update',
              'x-ratelimit-reset': futureResetEpoch.toString(),
            },
          );
        }
        return http.Response('Not Found', 404);
      });

      final service = GitHubService(client: mockClient, token: 'mock_token');
      final result = await service.updateGistFile(
        gistId: 'gist_123',
        filename: 'favorites.json',
        content: '{}',
      );

      expect(result, isFalse);
      expect(service.lastErrorMessage, contains('GitHub API rate limit exceeded'));
      expect(service.lastErrorMessage, contains('gist_update'));
      expect(service.lastErrorMessage, contains('Resets at'));
    });

    test('handles 401 unauthorized status in both languages', () async {
      final mockClient = MockClient((request) async {
        return http.Response(jsonEncode({'message': 'Bad credentials'}), 401);
      });

      // 日本語
      TestWidgetsFlutterBinding.instance.platformDispatcher.localeTestValue = const Locale('ja');
      final serviceJa = GitHubService(client: mockClient, token: 'invalid_token');
      await serviceJa.updateGistFile(gistId: 'gist_123', filename: 'data.json', content: '{}');
      expect(serviceJa.lastErrorMessage, contains('GitHubの認証に失敗しました'));

      // 英語
      TestWidgetsFlutterBinding.instance.platformDispatcher.localeTestValue = const Locale('en');
      final serviceEn = GitHubService(client: mockClient, token: 'invalid_token');
      await serviceEn.updateGistFile(gistId: 'gist_123', filename: 'data.json', content: '{}');
      expect(serviceEn.lastErrorMessage, contains('GitHub authentication failed'));

      TestWidgetsFlutterBinding.instance.platformDispatcher.clearLocaleTestValue();
    });

    test('handles 404 not found status in both languages', () async {
      final mockClient = MockClient((request) async {
        return http.Response(jsonEncode({'message': 'Not Found'}), 404);
      });

      // 日本語
      TestWidgetsFlutterBinding.instance.platformDispatcher.localeTestValue = const Locale('ja');
      final serviceJa = GitHubService(client: mockClient, token: 'mock_token');
      await serviceJa.updateGistFile(gistId: 'non_existent_gist', filename: 'data.json', content: '{}');
      expect(serviceJa.lastErrorMessage, contains('指定されたGistが見つかりません'));

      // 英語
      TestWidgetsFlutterBinding.instance.platformDispatcher.localeTestValue = const Locale('en');
      final serviceEn = GitHubService(client: mockClient, token: 'mock_token');
      await serviceEn.updateGistFile(gistId: 'non_existent_gist', filename: 'data.json', content: '{}');
      expect(serviceEn.lastErrorMessage, contains('Specified Gist was not found'));

      TestWidgetsFlutterBinding.instance.platformDispatcher.clearLocaleTestValue();
    });
  });

  group('GalleryViewModel saveFavoritesToGist Error Integration', () {
    test('propagates localized rate limit error from GitHubService to viewModel.errorMessage', () async {
      TestWidgetsFlutterBinding.instance.platformDispatcher.localeTestValue = const Locale('en');
      addTearDown(() {
        TestWidgetsFlutterBinding.instance.platformDispatcher.clearLocaleTestValue();
      });

      final futureResetEpoch = (DateTime.now().millisecondsSinceEpoch ~/ 1000) + 600;

      final mockClient = MockClient((request) async {
        if (request.method == 'PATCH') {
          return http.Response(
            jsonEncode({'message': 'API rate limit exceeded'}),
            403,
            headers: {
              'x-ratelimit-remaining': '0',
              'x-ratelimit-resource': 'gist_update',
              'x-ratelimit-reset': futureResetEpoch.toString(),
            },
          );
        }
        return http.Response('{}', 200);
      });

      final repo = GalleryRepository();
      await repo.saveFavoritesGistId('test_fav_gist');

      final githubService = GitHubService(client: mockClient, token: 'mock_token');
      final vm = GalleryViewModel(repository: repo, githubService: githubService);

      final gistId = await vm.saveFavoritesToGist();

      expect(gistId, isNull);
      expect(vm.errorMessage, contains('GitHub API rate limit exceeded'));
      expect(vm.errorMessage, contains('gist_update'));
    });
  });
}
