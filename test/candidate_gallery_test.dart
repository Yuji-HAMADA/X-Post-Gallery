import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:x_post_gallery/models/user_gist_entry.dart';
import 'package:x_post_gallery/services/gallery_repository.dart';
import 'package:x_post_gallery/services/github_service.dart';
import 'package:x_post_gallery/viewmodels/gallery_viewmodel.dart';

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({'saved_gist_id': 'master_123'});
    dotenv.loadFromString(envString: 'MASTER_GIST_ID=master_123');
  });

  group('Candidate Gallery & UserGistEntry Tests', () {
    test('UserGistEntry parses is_candidate flag correctly', () {
      final entry1 = UserGistEntry.fromDynamic({
        'gist_id': 'gist123',
        'priority_updated_at': 1000,
        'is_candidate': true,
      });
      expect(entry1.gistId, 'gist123');
      expect(entry1.priorityUpdatedAt, 1000);
      expect(entry1.isCandidate, isTrue);

      final entry2 = UserGistEntry.fromDynamic({
        'gist_id': 'gist456',
        'priority_updated_at': 2000,
      });
      expect(entry2.isCandidate, isFalse);

      final entryLegacy = UserGistEntry.fromDynamic('gist789');
      expect(entryLegacy.gistId, 'gist789');
      expect(entryLegacy.isCandidate, isFalse);
    });

    test('UserGistEntry toJson includes is_candidate when true', () {
      const entryCandidate = UserGistEntry(
        gistId: 'gist123',
        priorityUpdatedAt: 1000,
        isCandidate: true,
      );
      final jsonCandidate = entryCandidate.toJson();
      expect(jsonCandidate['is_candidate'], isTrue);
      expect(jsonCandidate['gist_id'], 'gist123');

      const entryRegular = UserGistEntry(
        gistId: 'gist456',
        priorityUpdatedAt: 2000,
        isCandidate: false,
      );
      final jsonRegular = entryRegular.toJson();
      expect(jsonRegular.containsKey('is_candidate'), isFalse);
    });

    test('GalleryRepository buildMasterGistJson preserves isCandidate state', () {
      final repo = GalleryRepository();
      const entryCandidate = UserGistEntry(
        gistId: 'cand_gist',
        priorityUpdatedAt: 500,
        isCandidate: true,
      );
      const entryUser = UserGistEntry(
        gistId: 'user_gist',
        priorityUpdatedAt: 100,
        isCandidate: false,
      );

      final jsonStr = repo.buildMasterGistJson(
        [],
        userName: 'test_owner',
        userGists: {
          'candidate_user': 'cand_gist',
          'regular_user': 'user_gist',
        },
        userPriorities: {
          'candidate_user': 500,
          'regular_user': 100,
        },
        userGistEntries: {
          'candidate_user': entryCandidate,
          'regular_user': entryUser,
        },
      );

      expect(jsonStr.contains('"candidate_user"'), isTrue);
      expect(jsonStr.contains('"is_candidate":true'), isTrue);
    });

    test('Candidate user moves to favorite via toggleFavorite, candidate attribute is cleared permanently and master gist updated', () async {
      final repo = _MockRepoForCandidateTest();
      final github = _MockGitHubServiceForCandidateTest();
      final vm = GalleryViewModel(repository: repo, githubService: github);

      await vm.loadGallery('master_123');

      // 初期状態: cand_user は candidate
      expect(vm.isCandidate('cand_user'), isTrue);
      expect(vm.isFavorite('cand_user'), isFalse);
      github.lastUpdatedContent = null;

      // cand_user をお気に入りに追加
      await vm.toggleFavorite('cand_user');

      // お気に入りになり、candidate 属性が解除されていること
      expect(vm.isFavorite('cand_user'), isTrue);
      expect(vm.isCandidate('cand_user'), isFalse);

      // Gist が更新され、cand_user の is_candidate が含まれなくなっていること
      expect(github.lastUpdatedContent, isNotNull);
      expect(github.lastUpdatedContent!.contains('"cand_user"'), isTrue);
      expect(github.lastUpdatedContent!.contains('"is_candidate":true'), isFalse);

      // お気に入りを解除しても、二度と candidate には戻らない
      github.lastUpdatedContent = null;
      await vm.toggleFavorite('cand_user');
      expect(vm.isFavorite('cand_user'), isFalse);
      expect(vm.isCandidate('cand_user'), isFalse);
    });

    test('cleanupCandidateFlagsForFavorites clears isCandidate for existing favorite users on load and updates Gist', () async {
      final repo = _MockRepoForCandidateTest(initialFavorites: {'cand_user'});
      final github = _MockGitHubServiceForCandidateTest();
      final vm = GalleryViewModel(repository: repo, githubService: github);

      // ロード実行
      await vm.loadGallery('master_123');

      // 既存でお気に入りになっている cand_user はロード時に自動的に candidate 属性が解除される
      expect(vm.isFavorite('cand_user'), isTrue);
      expect(vm.isCandidate('cand_user'), isFalse);

      // Gist 更新が呼び出されたことを確認
      expect(github.lastUpdatedContent, isNotNull);
      expect(github.lastUpdatedContent!.contains('"is_candidate":true'), isFalse);
    });
  });
}

class _MockRepoForCandidateTest extends GalleryRepository {
  final Set<String> _favs;
  _MockRepoForCandidateTest({Set<String>? initialFavorites})
      : _favs = initialFavorites ?? {};

  @override
  Future<String?> getSavedGistId() async => 'master_123';

  @override
  Future<void> clearCache() async {}

  @override
  Future<GalleryData> fetchGalleryData(String gistId, {String? remoteUpdatedAt}) async {
    return GalleryData(
      userName: 'test_owner',
      items: [],
      userGists: {
        'cand_user': 'gist_cand',
        'reg_user': 'gist_reg',
      },
      userPriorities: {
        'cand_user': 0,
        'reg_user': 0,
      },
      userGistEntries: {
        'cand_user': const UserGistEntry(
          gistId: 'gist_cand',
          priorityUpdatedAt: 0,
          isCandidate: true,
        ),
        'reg_user': const UserGistEntry(
          gistId: 'gist_reg',
          priorityUpdatedAt: 0,
          isCandidate: false,
        ),
      },
    );
  }

  @override
  Future<Set<String>> loadFavoriteUsers() async => Set.from(_favs);

  @override
  Future<void> saveFavoriteUsers(Set<String> users) async {
    _favs.clear();
    _favs.addAll(users);
  }

  @override
  Future<Map<String, int>> loadUserPriorities() async => {};
  @override
  Future<void> saveUserPriorities(Map<String, int> priorities) async {}
}

class _MockGitHubServiceForCandidateTest extends GitHubService {
  String? lastUpdatedContent;

  @override
  Future<bool> updateGistFile({
    required String gistId,
    required String filename,
    required String content,
  }) async {
    lastUpdatedContent = content;
    return true;
  }

  @override
  Future<Map<String, dynamic>> fetchGistMetadata(String gistId) async {
    return {'exists': true, 'updatedAt': '2026-11-18T00:00:00Z'};
  }
}
