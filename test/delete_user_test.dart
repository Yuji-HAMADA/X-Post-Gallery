import 'dart:convert';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:x_post_gallery/models/tweet_item.dart';
import 'package:x_post_gallery/services/gallery_repository.dart';
import 'package:x_post_gallery/services/github_service.dart';
import 'package:x_post_gallery/viewmodels/gallery_viewmodel.dart';

class MockGitHubServiceForDelete extends GitHubService {
  final Map<String, Map<String, String>> gistStorage = {};
  String? lastRemovedQueueUser;

  @override
  Future<bool> updateGistFile({
    required String gistId,
    required String filename,
    required String content,
  }) async {
    gistStorage.putIfAbsent(gistId, () => {})[filename] = content;
    return true;
  }

  @override
  Future<bool> removeUserFromFetchQueue(String username) async {
    lastRemovedQueueUser = username;
    return true;
  }
}

class MockGalleryRepositoryForDelete extends GalleryRepository {
  String? savedGistId = 'master_gist_saved';

  @override
  Future<String?> getSavedGistId() async => savedGistId;

  @override
  Future<void> clearCache() async {}

  @override
  Future<String> buildUserBatchGistJson(
    String gistId,
    String username,
    List<TweetItem> remainingItems, {
    Set<String> deletedIds = const {},
  }) async {
    // ユーザーを削除したモックJSONを返す
    return jsonEncode({'users': {}});
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    SharedPreferences.setMockInitialValues({});
    dotenv.loadFromString(envString: 'MASTER_GIST_ID=master_123');
  });

  group('GalleryViewModel deleteUser Tests', () {
    test('deleteUser removes user from userGists, items, queue, and saves master gist', () async {
      final mockGithub = MockGitHubServiceForDelete();
      final mockRepo = MockGalleryRepositoryForDelete();

      final vm = GalleryViewModel(
        repository: mockRepo,
        githubService: mockGithub,
      );

      // 初期データをセットアップ
      await vm.registerUser('oreno_musume', gistId: 'child_gist_1');
      expect(vm.userGists.containsKey('oreno_musume'), isTrue);

      final success = await vm.deleteUser('oreno_musume');

      expect(success, isTrue);
      // userGists から削除されていること
      expect(vm.userGists.containsKey('oreno_musume'), isFalse);
      // キューからも削除が呼ばれていること
      expect(mockGithub.lastRemovedQueueUser, 'oreno_musume');
      // 子Gistの更新が行われていること
      expect(mockGithub.gistStorage.containsKey('child_gist_1'), isTrue);
      // マスターGistの更新が行われていること
      expect(mockGithub.gistStorage.containsKey('master_123'), isTrue);
    });

    test('deleteUser handles case-insensitive username correctly', () async {
      final mockGithub = MockGitHubServiceForDelete();
      final mockRepo = MockGalleryRepositoryForDelete();

      final vm = GalleryViewModel(
        repository: mockRepo,
        githubService: mockGithub,
      );

      await vm.registerUser('Oreno_Musume', gistId: 'child_gist_2');
      expect(vm.userGists.containsKey('Oreno_Musume'), isTrue);

      // 小文字で deleteUser を呼んでも大文字小文字を無視して削除されること
      final success = await vm.deleteUser('oreno_musume');

      expect(success, isTrue);
      expect(vm.userGists.containsKey('Oreno_Musume'), isFalse);
      expect(vm.userGists.containsKey('oreno_musume'), isFalse);
    });
  });
}
