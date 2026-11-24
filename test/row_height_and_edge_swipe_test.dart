import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:x_post_gallery/l10n/app_localizations.dart';
import 'package:x_post_gallery/models/tweet_item.dart';
import 'package:x_post_gallery/screens/gallery/components/aspect_ratio_grid_view.dart';
import 'package:x_post_gallery/screens/gallery/components/tweet_grid_view.dart';
import 'package:x_post_gallery/screens/gallery/gallery_page.dart';
import 'package:x_post_gallery/screens/gallery/user_gallery_swipe_page.dart';
import 'package:x_post_gallery/services/gallery_repository.dart';
import 'package:x_post_gallery/services/github_service.dart';
import 'package:x_post_gallery/utils/image_aspect_ratio_manager.dart';
import 'package:x_post_gallery/viewmodels/gallery_viewmodel.dart';

class _MockRepoForRowHeightTest extends GalleryRepository {
  String _savedMode = 'tallest';

  @override
  Future<String?> getSavedGistId() async => 'dummy_master';

  @override
  Future<int> loadGridColumnCount() async => 3;

  @override
  Future<String> loadRowHeightMode() async => _savedMode;

  @override
  Future<void> saveRowHeightMode(String mode) async {
    _savedMode = mode;
  }

  @override
  Future<GalleryData> fetchGalleryData(String gistId, {String? remoteUpdatedAt}) async {
    return GalleryData(
      userName: 'test_owner',
      items: [
        TweetItem(
          id: '1',
          fullText: 'test post',
          createdAt: '2026-01-01',
          mediaUrls: const ['https://example.com/1.jpg'],
          username: 'userA',
        ),
      ],
      userGists: {'userA': 'gistA'},
    );
  }

  @override
  Future<bool> isAdminAuthenticated() async => true;
}

class _MockGitHubServiceForRowHeightTest extends GitHubService {
  @override
  Future<Map<String, dynamic>> fetchGistMetadata(String gistId) async {
    return {'exists': true, 'updatedAt': '2026-01-01T00:00:00Z'};
  }
}

class _MockViewModelForRowHeightTest extends GalleryViewModel {
  _MockViewModelForRowHeightTest({required super.repository, required super.githubService});

  @override
  Future<List<TweetItem>> fetchUserItems(String username) async {
    return [
      TweetItem(
        id: '1',
        fullText: 'test',
        createdAt: '2026-01-01',
        mediaUrls: const ['https://example.com/1.jpg'],
      ),
    ];
  }

  @override
  Future<bool> isAdminAuthenticated() async => true;
}

void main() {
  setUpAll(() {
    SharedPreferences.setMockInitialValues({'saved_gist_id': 'dummy_master'});
    dotenv.loadFromString(envString: 'MASTER_GIST_ID=dummy_master');
  });

  tearDown(() {
    ImageAspectRatioManager.instance.clear();
  });

  group('Row Height Mode Tests', () {
    test('GalleryViewModel loads and saves rowHeightMode correctly', () async {
      final repo = _MockRepoForRowHeightTest();
      final vm = GalleryViewModel(
        repository: repo,
        githubService: _MockGitHubServiceForRowHeightTest(),
      );

      await vm.loadRowHeightMode();
      expect(vm.rowHeightMode, 'tallest');

      await vm.setRowHeightMode('shortest');
      expect(vm.rowHeightMode, 'shortest');
      expect(await repo.loadRowHeightMode(), 'shortest');
    });

    testWidgets('AspectRatioGridView applies shortest vs tallest aspect ratio', (tester) async {
      ImageAspectRatioManager.instance.setAspectRatio('https://example.com/tall.jpg', 0.5);
      ImageAspectRatioManager.instance.setAspectRatio('https://example.com/wide.jpg', 2.0);

      final items = [
        'https://example.com/tall.jpg',
        'https://example.com/wide.jpg',
      ];

      // 1. shortest モード: 最も縦が小さい画像 (比率 2.0) に合わせる
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AspectRatioGridView<String>(
              items: items,
              columnCount: 2,
              rowHeightMode: 'shortest',
              scrollController: ScrollController(),
              getImageUrl: (item) => item,
              itemBuilder: (context, item, index) => Container(key: ValueKey(item)),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      var aspectRatios = tester.widgetList<AspectRatio>(find.byType(AspectRatio));
      expect(aspectRatios.first.aspectRatio, 2.0);

      // 2. tallest モード: 最も縦が大きい画像 (比率 0.5) に合わせる
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AspectRatioGridView<String>(
              items: items,
              columnCount: 2,
              rowHeightMode: 'tallest',
              scrollController: ScrollController(),
              getImageUrl: (item) => item,
              itemBuilder: (context, item, index) => Container(key: ValueKey(item)),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      aspectRatios = tester.widgetList<AspectRatio>(find.byType(AspectRatio));
      expect(aspectRatios.first.aspectRatio, 0.5);
    });

    testWidgets('UserGallerySwipePage menu has row height basis option and delete button is at bottom', (tester) async {
      tester.view.physicalSize = const Size(800, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final repo = _MockRepoForRowHeightTest();
      final vm = _MockViewModelForRowHeightTest(
        repository: repo,
        githubService: _MockGitHubServiceForRowHeightTest(),
      );

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<GalleryViewModel>.value(value: vm),
          ],
          child: const MaterialApp(
            locale: Locale('ja'),
            localizationsDelegates: [
              AppLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            supportedLocales: AppLocalizations.supportedLocales,
            home: UserGallerySwipePage(
              usernames: ['userA'],
              userGistIds: ['gistA'],
              initialIndex: 0,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // ハンバーガーメニューを開く
      final menuButton = find.byIcon(Icons.menu);
      expect(menuButton, findsOneWidget);
      await tester.tap(menuButton);
      await tester.pumpAndSettle();

      // メニュー内に「行の高さ基準」が存在すること
      expect(find.text('行の高さ基準'), findsOneWidget);

      // アカウント削除ボタンが存在すること
      expect(find.text('ユーザーを削除'), findsOneWidget);

      // 行の高さ基準をタップしてダイアログを開く
      await tester.tap(find.text('行の高さ基準'));
      await tester.pumpAndSettle();

      // ダイアログ内に選択肢「最小縦幅」と「最大縦幅」が存在すること
      expect(find.text('最小縦幅'), findsOneWidget);
      expect(find.text('最大縦幅'), findsOneWidget);

      // 「最小縦幅」をタップして切り替え
      await tester.tap(find.text('最小縦幅'));
      await tester.pumpAndSettle();

      expect(vm.rowHeightMode, 'shortest');
    });

    testWidgets('GalleryPage menu has row height basis option', (tester) async {
      tester.view.physicalSize = const Size(800, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final repo = _MockRepoForRowHeightTest();
      final vm = GalleryViewModel(
        repository: repo,
        githubService: _MockGitHubServiceForRowHeightTest(),
      );

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<GalleryViewModel>.value(value: vm),
          ],
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

      // ハンバーガーメニューを開く
      final menuButton = find.byIcon(Icons.menu);
      expect(menuButton, findsOneWidget);
      await tester.tap(menuButton);
      await tester.pumpAndSettle();

      expect(find.text('行の高さ基準'), findsOneWidget);
    });
  });

  group('Multi-Image Edge Swipe Account Navigation Tests', () {
    testWidgets('Swiping past first image triggers onNavigatePreviousAccount', (tester) async {
      tester.view.physicalSize = const Size(600, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      int prevAccountCalls = 0;
      int nextAccountCalls = 0;

      final multiItem = TweetItem(
        id: '1',
        fullText: 'Multi image',
        createdAt: '2026-11-20 12:00:00 JST',
        mediaUrls: ['https://example.com/p1.jpg', 'https://example.com/p2.jpg'],
      );

      final vm = GalleryViewModel(
        repository: _MockRepoForRowHeightTest(),
        githubService: _MockGitHubServiceForRowHeightTest(),
      );
      await vm.setAccountGridColumnCount(1);

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<GalleryViewModel>.value(value: vm),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: TweetGridView(
                items: [multiItem],
                selectedIds: const {},
                scrollController: ScrollController(),
                onNavigatePreviousAccount: () => prevAccountCalls++,
                onNavigateNextAccount: () => nextAccountCalls++,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 1枚目表示中に、前方向（左から右へのドラッグスワイプ）を行う
      await tester.drag(find.byType(PageView), const Offset(150, 0));
      await tester.pumpAndSettle();

      expect(prevAccountCalls, 1);
      expect(nextAccountCalls, 0);

      // 2枚目に移動（右矢印タップ）
      final rightArrow = find.byIcon(Icons.chevron_right);
      await tester.tap(rightArrow);
      await tester.pumpAndSettle();

      // 2枚目（最終枚目）表示中に、次方向（右から左へのドラッグスワイプ）を行う
      await tester.drag(find.byType(PageView), const Offset(-150, 0));
      await tester.pumpAndSettle();

      expect(nextAccountCalls, 1);
    });
  });
}
