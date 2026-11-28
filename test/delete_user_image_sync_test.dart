import 'dart:convert';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:x_post_gallery/models/tweet_item.dart';
import 'package:x_post_gallery/services/gallery_repository.dart';
import 'package:x_post_gallery/services/github_service.dart';
import 'package:x_post_gallery/viewmodels/gallery_viewmodel.dart';

class _FakeGitHubService extends GitHubService {
  final Map<String, String> gistContents;
  final List<Map<String, String>> updatedFiles = [];

  _FakeGitHubService(this.gistContents)
      : super(
          token: 'fake_token',
          owner: 'tester',
          fetchQueueGistId: '',
          igFetchQueueGistId: '',
          tiktokFetchQueueGistId: '',
        );

  @override
  Future<Map<String, dynamic>> fetchGistMetadata(String gistId) async => {
        'exists': true,
        'updatedAt': '2026-11-28T06:00:00Z',
      };

  @override
  Future<String?> fetchGistContent(String gistId, String filename) async =>
      gistContents[gistId];

  @override
  Future<bool> updateGistFile({
    required String gistId,
    required String filename,
    required String content,
  }) async {
    gistContents[gistId] = content;
    updatedFiles.add({
      'gistId': gistId,
      'filename': filename,
      'content': content,
    });
    return true;
  }
}

class _FakeGalleryRepository extends GalleryRepository {
  final GalleryData initialMaster;
  String? lastRawJsonPassedToFetch;
  String? lastRawJsonPassedToBuild;
  bool cdnFetchCalled = false;

  _FakeGalleryRepository(this.initialMaster);

  @override
  Future<GalleryData> fetchGalleryData(
    String gistId, {
    String? remoteUpdatedAt,
  }) async =>
      initialMaster;

  @override
  Future<List<TweetItem>> fetchUserGist(String gistId, String username) async {
    cdnFetchCalled = true;
    return [];
  }

  @override
  List<TweetItem> parseUserGistJson(String jsonStr, String username) {
    lastRawJsonPassedToFetch = jsonStr;
    return super.parseUserGistJson(jsonStr, username);
  }

  @override
  String buildUserBatchGistJsonFromRaw(
    String rawJsonContent,
    String username,
    List<TweetItem> remainingItems, {
    Set<String> deletedIds = const {},
  }) {
    lastRawJsonPassedToBuild = rawJsonContent;
    return super.buildUserBatchGistJsonFromRaw(
      rawJsonContent,
      username,
      remainingItems,
      deletedIds: deletedIds,
    );
  }
}

void main() {
  setUpAll(() {
    dotenv.loadFromString(
      envString: 'MASTER_GIST_ID=master_gist_1\nGITHUB_USERNAME=tester',
    );
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('1枚目（Master代表サムネイル）削除時に Master Gist を残存最新ポストへ同期し、直後の再取得でAPI最新JSONを使う', () async {
    final post1 = TweetItem(
      id: '2126487031979344290',
      fullText: '@sample_user: newest post',
      createdAt: '2026-11-28 10:00:00 JST',
      mediaUrls: const ['https://example.com/1.jpg'],
      username: 'sample_user',
    );
    final post2 = TweetItem(
      id: '2126420805554676020',
      fullText: '@sample_user: second post',
      createdAt: '2026-11-28 06:00:00 JST',
      mediaUrls: const ['https://example.com/2.jpg'],
    );

    final childGistJson = jsonEncode({
      'users': {
        'Sample_User': {
          'tweets': [post1.toJson(), post2.toJson()],
        },
      },
    });

    final fakeGithub = _FakeGitHubService({'child_gist_1': childGistJson});
    final fakeRepo = _FakeGalleryRepository(
      GalleryData(
        userName: 'Master',
        items: [post1],
        userGists: const {'sample_user': 'child_gist_1'},
      ),
    );

    final vm = GalleryViewModel(repository: fakeRepo, githubService: fakeGithub);
    await vm.loadGallery('master_gist_1');

    // 1枚目を選択して削除
    vm.toggleSelection(post1.id);
    final remaining = await vm.deleteSelectedFromUserGist(
      'child_gist_1',
      'sample_user',
      [post1, post2],
    );

    expect(remaining, 1);
    // 1. 子Gist更新にAPI経由の最新JSONが使われ、大文字小文字揺れでも重複キーを作らないこと
    expect(fakeRepo.lastRawJsonPassedToBuild, isNotNull);
    final updatedChild =
        jsonDecode(fakeGithub.gistContents['child_gist_1']!) as Map<String, dynamic>;
    final usersMap = updatedChild['users'] as Map<String, dynamic>;
    expect(usersMap.keys.toList(), ['Sample_User']);
    expect((usersMap['Sample_User']['tweets'] as List).length, 1);
    expect(updatedChild['deleted_ids'], contains(post1.id));

    // 2. Master Gist の代表アイテムが post2 に差し替えられ、Master Gist も保存されていること
    expect(vm.items.length, 1);
    expect(vm.items.first.id, post2.id);
    expect(vm.items.first.extractedUsername, 'sample_user');
    expect(
      fakeGithub.updatedFiles.any((f) => f['gistId'] == 'master_gist_1'),
      isTrue,
    );

    // 3. 削除直後の fetchUserItems は CDN を経由せず API 最新の JSON を使うこと
    final reloaded = await vm.fetchUserItems('sample_user');
    expect(fakeRepo.lastRawJsonPassedToFetch, isNotNull);
    expect(reloaded.map((e) => e.id).toList(), [post2.id]);
  });

  test('2枚目以降の削除時は Master Gist の代表サムネイルを再保存しない', () async {
    final post1 = TweetItem(
      id: '2126487031979344290',
      fullText: '@sample_user: newest post',
      createdAt: '2026-11-28 10:00:00 JST',
      mediaUrls: const ['https://example.com/1.jpg'],
      username: 'sample_user',
    );
    final post2 = TweetItem(
      id: '2126420805554676020',
      fullText: '@sample_user: second post',
      createdAt: '2026-11-28 06:00:00 JST',
      mediaUrls: const ['https://example.com/2.jpg'],
    );

    final fakeGithub = _FakeGitHubService({
      'child_gist_1': jsonEncode({
        'users': {
          'sample_user': {'tweets': [post1.toJson(), post2.toJson()]},
        },
      }),
    });
    final fakeRepo = _FakeGalleryRepository(
      GalleryData(
        userName: 'Master',
        items: [post1],
        userGists: const {'sample_user': 'child_gist_1'},
      ),
    );

    final vm = GalleryViewModel(repository: fakeRepo, githubService: fakeGithub);
    await vm.loadGallery('master_gist_1');

    vm.toggleSelection(post2.id);
    final remaining = await vm.deleteSelectedFromUserGist(
      'child_gist_1',
      'sample_user',
      [post1, post2],
    );

    expect(remaining, 1);
    expect(vm.items.first.id, post1.id);
    expect(
      fakeGithub.updatedFiles.where((f) => f['gistId'] == 'master_gist_1'),
      isEmpty,
    );
  });
}
