import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:x_post_gallery/l10n/app_localizations.dart';
import 'package:x_post_gallery/models/tweet_item.dart';
import 'package:x_post_gallery/screens/gallery/gallery_page.dart';
import 'package:x_post_gallery/services/gallery_repository.dart';
import 'package:x_post_gallery/services/github_service.dart';
import 'package:x_post_gallery/viewmodels/gallery_viewmodel.dart';

class _MockRepoForReload extends GalleryRepository {
  bool reloadCalled = false;

  @override
  Future<String?> getSavedGistId() async => 'dummy_master';

  @override
  Future<void> clearCache() async {
    reloadCalled = true;
  }

  @override
  Future<GalleryData> fetchGalleryData(String gistId, {String? remoteUpdatedAt}) async {
    return GalleryData(
      userName: 'test',
      items: [
        TweetItem(
          id: '1',
          fullText: '@user1: test 1',
          createdAt: '2026-11-15 00:00:00 JST',
          mediaUrls: ['https://example.com/1.jpg'],
        ),
        TweetItem(
          id: '2',
          fullText: '@cand1: test 2',
          createdAt: '2026-11-15 01:00:00 JST',
          mediaUrls: ['https://example.com/2.jpg'],
        ),
      ],
      userGists: {
        'user1': 'g1',
        'cand1': 'g2',
      },
      userPriorities: {},
      userGistEntries: {},
    );
  }

  @override
  Future<Set<String>> loadFavoriteUsers() async => {'user1'};

  @override
  Future<Map<String, int>> loadUserPriorities() async => {};
}

class _MockGitHubServiceForReload extends GitHubService {
  @override
  Future<Map<String, dynamic>> fetchGistMetadata(String gistId) async {
    return {'exists': true, 'updatedAt': '2026-11-15T00:00:00Z'};
  }
}

void main() {
  setUpAll(() {
    SharedPreferences.setMockInitialValues({'saved_gist_id': 'dummy_master'});
    dotenv.loadFromString(envString: 'MASTER_GIST_ID=dummy_master');
  });

  testWidgets('Active tab is retained on reload', (tester) async {
    final repo = _MockRepoForReload();
    final github = _MockGitHubServiceForReload();
    final vm = GalleryViewModel(repository: repo, githubService: github);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: vm,
        child: const MaterialApp(
          locale: Locale('ja'),
          localizationsDelegates: [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: GalleryPage(),
        ),
      ),
    );

    // 初回ロード完了を待機
    await tester.pumpAndSettle();

    // 初期タブは「お気に入り」
    expect(find.text('お気に入り'), findsWidgets);

    // 2番目のタブ「ユーザー」（Users）へスワイプ
    final pageView = find.byType(PageView);
    expect(pageView, findsOneWidget);

    await tester.fling(pageView, const Offset(-400, 0), 1000);
    await tester.pumpAndSettle();

    // 「ユーザー」タブになっていることを確認
    expect(find.text('ユーザー'), findsWidgets);

    // 再読み込みボタンをタップ
    final reloadBtn = find.byTooltip('再読み込み');
    expect(reloadBtn, findsOneWidget);
    await tester.tap(reloadBtn);
    await tester.pump();

    // リロード完了
    await tester.pumpAndSettle();

    // リロード後も「ユーザー」タブが維持されていること（お気に入りに戻っていないこと）
    expect(find.text('ユーザー'), findsWidgets);
    expect(repo.reloadCalled, isTrue);

    // さらに「候補」（Candidate）タブへスワイプ
    await tester.fling(pageView, const Offset(-400, 0), 1000);
    await tester.pumpAndSettle();
    expect(find.text('候補'), findsWidgets);

    // 再読み込み
    repo.reloadCalled = false;
    await tester.tap(reloadBtn);
    await tester.pump();
    await tester.pumpAndSettle();

    // リロード後も「候補」タブが維持されていること
    expect(find.text('候補'), findsWidgets);
    expect(repo.reloadCalled, isTrue);
  });

  testWidgets('Cyclic gallery tab navigation (Favorites <-> Users <-> Candidate <-> Favorites)', (tester) async {
    final repo = _MockRepoForReload();
    final github = _MockGitHubServiceForReload();
    final vm = GalleryViewModel(repository: repo, githubService: github);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: vm,
        child: const MaterialApp(
          locale: Locale('ja'),
          localizationsDelegates: [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: GalleryPage(),
        ),
      ),
    );

    await tester.pumpAndSettle();

    // 1. 初期状態: 「お気に入り」
    expect(find.text('お気に入り'), findsWidgets);

    final pageView = find.byType(PageView);
    expect(pageView, findsOneWidget);

    // 2. 「お気に入り」で右スワイプ（左端から引っ張る操作）-> 「候補」へサイクリック遷移
    await tester.fling(pageView, const Offset(400, 0), 1000);
    await tester.pumpAndSettle();
    expect(find.text('候補'), findsWidgets);

    // 3. 「候補」でさらに右スワイプ -> 「ユーザー」へ遷移
    await tester.fling(pageView, const Offset(400, 0), 1000);
    await tester.pumpAndSettle();
    expect(find.text('ユーザー'), findsWidgets);

    // 4. 「ユーザー」でさらに右スワイプ -> 「お気に入り」へ遷移
    await tester.fling(pageView, const Offset(400, 0), 1000);
    await tester.pumpAndSettle();
    expect(find.text('お気に入り'), findsWidgets);

    // 5. 「お気に入り」で左スワイプ（順方向）-> 「ユーザー」へ遷移
    await tester.fling(pageView, const Offset(-400, 0), 1000);
    await tester.pumpAndSettle();
    expect(find.text('ユーザー'), findsWidgets);

    // 6. 「ユーザー」で左スワイプ -> 「候補」へ遷移
    await tester.fling(pageView, const Offset(-400, 0), 1000);
    await tester.pumpAndSettle();
    expect(find.text('候補'), findsWidgets);

    // 7. 「候補」で左スワイプ -> 「お気に入り」へサイクリック遷移
    await tester.fling(pageView, const Offset(-400, 0), 1000);
    await tester.pumpAndSettle();
    expect(find.text('お気に入り'), findsWidgets);
  });
}
