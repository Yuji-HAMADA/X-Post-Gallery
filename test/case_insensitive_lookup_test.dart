import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:x_post_gallery/models/tweet_item.dart';
import 'package:x_post_gallery/services/gallery_repository.dart';
import 'package:x_post_gallery/services/github_service.dart';
import 'package:x_post_gallery/viewmodels/gallery_viewmodel.dart';

class MockGalleryRepoForLookup extends GalleryRepository {
  final Map<String, List<TweetItem>> userItems = {};
  bool clearCacheCalled = false;

  @override
  Future<List<TweetItem>> fetchUserGist(String gistId, String username) async {
    return userItems[username.toLowerCase()] ?? [];
  }

  @override
  Future<String?> getSavedGistId() async => 'master_test';

  @override
  Future<GalleryData> fetchGalleryData(String gistId, {String? remoteUpdatedAt}) async {
    return GalleryData(
      userName: 'test_user',
      items: [],
      userGists: {
        'xaid_AI_illust': 'child_gist_xaid',
        'OtherUser': 'child_gist_other',
      },
      userPriorities: {},
    );
  }

  @override
  Future<void> clearCache() async {
    clearCacheCalled = true;
  }
}

class MockGitHubServiceForLookup extends GitHubService {
  @override
  Future<Map<String, dynamic>> fetchGistMetadata(String gistId) async {
    return {'exists': true, 'updatedAt': '2026-11-11T00:00:00Z'};
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    SharedPreferences.setMockInitialValues({});
    dotenv.loadFromString(envString: 'MASTER_GIST_ID=master_test');
  });

  group('Case-Insensitive Lookup & Reload Tests', () {
    late GalleryViewModel vm;
    late MockGalleryRepoForLookup repo;
    late MockGitHubServiceForLookup gh;

    setUp(() async {
      repo = MockGalleryRepoForLookup();
      gh = MockGitHubServiceForLookup();
      vm = GalleryViewModel(repository: repo, githubService: gh);
      await vm.loadGallery('master_test');
    });

    test('getGistIdForUser retrieves gistId regardless of case', () {
      expect(vm.getGistIdForUser('xaid_AI_illust'), equals('child_gist_xaid'));
      expect(vm.getGistIdForUser('xaid_ai_illust'), equals('child_gist_xaid'));
      expect(vm.getGistIdForUser('XAID_AI_ILLUST'), equals('child_gist_xaid'));
      expect(vm.getGistIdForUser('otheruser'), equals('child_gist_other'));
      expect(vm.getGistIdForUser('nonexistent'), isNull);
    });

    test('getCanonicalUsername returns exact original key case', () {
      expect(vm.getCanonicalUsername('xaid_ai_illust'), equals('xaid_AI_illust'));
      expect(vm.getCanonicalUsername('XAID_AI_ILLUST'), equals('xaid_AI_illust'));
      expect(vm.getCanonicalUsername('otheruser'), equals('OtherUser'));
      expect(vm.getCanonicalUsername('unknown'), isNull);
    });

    test('fetchUserItems queries child gist with canonical name when searched with lower case', () async {
      repo.userItems['xaid_ai_illust'] = [
        const TweetItem(
          id: '123',
          fullText: '@xaid_AI_illust: test tweet',
          createdAt: '',
          mediaUrls: ['https://example.com/img.jpg'],
        ),
      ];

      // 小文字でリクエストしても正しく取得できること
      final items = await vm.fetchUserItems('xaid_ai_illust');
      expect(items.length, equals(1));
      expect(items.first.id, equals('123'));
    });

    test('reloadGallery calls clearCache to force fresh fetch', () async {
      expect(repo.clearCacheCalled, isFalse);
      await vm.reloadGallery();
      expect(repo.clearCacheCalled, isTrue);
    });
  });
}
