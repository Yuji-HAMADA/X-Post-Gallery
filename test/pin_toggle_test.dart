import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:x_post_gallery/services/gallery_repository.dart';
import 'package:x_post_gallery/services/github_service.dart';
import 'package:x_post_gallery/viewmodels/gallery_viewmodel.dart';

class MockGitHubServiceForPin extends GitHubService {
  final Map<String, Map<String, String>> gistStorage = {};

  @override
  Future<bool> updateGistFile({
    required String gistId,
    required String filename,
    required String content,
  }) async {
    gistStorage.putIfAbsent(gistId, () => {})[filename] = content;
    return true;
  }
}

class MockGalleryRepositoryForPin extends GalleryRepository {
  @override
  Future<String?> getSavedGistId() async => 'master_gist_test';

  @override
  Future<void> clearCache() async {}
}

void main() {
  setUpAll(() {
    dotenv.loadFromString(envString: 'MASTER_GIST_ID=master_123');
  });

  group('GalleryViewModel Pin Toggle Tests', () {
    test('isPinned returns true only when priority > 0', () {
      final vm = GalleryViewModel(
        repository: MockGalleryRepositoryForPin(),
        githubService: MockGitHubServiceForPin(),
      );

      expect(vm.isPinned('user1'), isFalse);
    });

    test('togglePin toggles between pinned (priority > 0) and unpinned (priority == 0)', () async {
      final vm = GalleryViewModel(
        repository: MockGalleryRepositoryForPin(),
        githubService: MockGitHubServiceForPin(),
      );

      // 初期状態
      expect(vm.isPinned('userA'), isFalse);
      expect(vm.userPriorities['userA'], isNull);

      // 1回目のタップ: ピン留め（最上位へ）
      final res1 = await vm.togglePin('userA');
      expect(res1, isTrue);
      expect(vm.isPinned('userA'), isTrue);
      expect(vm.userPriorities['userA'], greaterThan(0));

      // 2回目のタップ: ピン留め解除（デフォルト位置へ）
      final res2 = await vm.togglePin('userA');
      expect(res2, isTrue);
      expect(vm.isPinned('userA'), isFalse);
      expect(vm.userPriorities['userA'], equals(0));
    });

    test('registerUser initializes priority to 0 (unpinned by default)', () async {
      final vm = GalleryViewModel(
        repository: MockGalleryRepositoryForPin(),
        githubService: MockGitHubServiceForPin(),
      );

      await vm.registerUser('new_user', gistId: 'child_gist');
      expect(vm.userGists['new_user'], equals('child_gist'));
      expect(vm.isPinned('new_user'), isFalse);
      expect(vm.userPriorities['new_user'], equals(0));
    });
  });
}
