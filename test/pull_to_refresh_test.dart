import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:x_post_gallery/l10n/app_localizations.dart';
import 'package:x_post_gallery/models/tweet_item.dart';
import 'package:x_post_gallery/models/user_gist_entry.dart';
import 'package:x_post_gallery/screens/gallery/gallery_page.dart';
import 'package:x_post_gallery/services/gallery_repository.dart';
import 'package:x_post_gallery/services/github_service.dart';
import 'package:x_post_gallery/viewmodels/gallery_viewmodel.dart';

class _MockRepoForRefreshTest extends GalleryRepository {
  int fetchCallCount = 0;
  int clearCacheCount = 0;

  @override
  Future<String?> getSavedGistId() async => 'dummy_master';

  @override
  Future<void> clearCache() async {
    clearCacheCount++;
  }

  @override
  Future<GalleryData> fetchGalleryData(String gistId, {String? remoteUpdatedAt}) async {
    fetchCallCount++;
    return GalleryData(
      userName: 'test_owner',
      items: [
        TweetItem(
          id: '101',
          fullText: '@fav_user: test post',
          createdAt: '2026-11-18 12:00:00 JST',
          mediaUrls: ['https://example.com/fav.jpg'],
        ),
      ],
      userGists: {'fav_user': 'g_fav'},
      userPriorities: {'fav_user': 0},
      userGistEntries: {
        'fav_user': const UserGistEntry(gistId: 'g_fav', priorityUpdatedAt: 0, isCandidate: false),
      },
    );
  }

  @override
  Future<Set<String>> loadFavoriteUsers() async => {'fav_user'};

  @override
  Future<Map<String, int>> loadUserPriorities() async => {};
}

class _MockGitHubServiceForRefreshTest extends GitHubService {
  @override
  Future<Map<String, dynamic>> fetchGistMetadata(String gistId) async {
    return {'exists': true, 'updatedAt': '2026-11-18T12:00:00Z'};
  }
}

void main() {
  setUpAll(() {
    SharedPreferences.setMockInitialValues({'saved_gist_id': 'dummy_master'});
    dotenv.loadFromString(envString: 'MASTER_GIST_ID=dummy_master');
  });

  testWidgets('Pull-to-refresh triggers reloadGallery on main gallery tab', (tester) async {
    final mockRepo = _MockRepoForRefreshTest();
    final mockGh = _MockGitHubServiceForRefreshTest();
    final vm = GalleryViewModel(repository: mockRepo, githubService: mockGh);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<GalleryViewModel>.value(value: vm),
        ],
        child: const MaterialApp(
          localizationsDelegates: [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: [Locale('ja'), Locale('en')],
          home: GalleryPage(),
        ),
      ),
    );

    await tester.pumpAndSettle();

    // 初期ロードが行われたことを確認
    expect(mockRepo.fetchCallCount, 1);
    expect(find.byType(RefreshIndicator), findsWidgets);

    // 下スワイプして RefreshIndicator をトリガー
    await tester.fling(find.byType(RefreshIndicator).first, const Offset(0, 300), 1000);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();

    // reloadGallery が呼ばれ、clearCache と再 fetch が行われたことを確認
    expect(mockRepo.clearCacheCount, 1);
    expect(mockRepo.fetchCallCount, 2);
  });
}
