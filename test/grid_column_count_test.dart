import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:x_post_gallery/l10n/app_localizations.dart';
import 'package:x_post_gallery/models/tweet_item.dart';
import 'package:x_post_gallery/screens/gallery/components/aspect_ratio_grid_view.dart';
import 'package:x_post_gallery/screens/gallery/gallery_page.dart';
import 'package:x_post_gallery/screens/gallery/user_gallery_swipe_page.dart';
import 'package:x_post_gallery/services/gallery_repository.dart';
import 'package:x_post_gallery/services/github_service.dart';
import 'package:x_post_gallery/viewmodels/gallery_viewmodel.dart';

class MockGalleryRepoForGrid extends GalleryRepository {
  int _storedMainCount = 2;
  int _storedAccountCount = 2;

  @override
  Future<int> loadMainGridColumnCount() async => _storedMainCount;

  @override
  Future<void> saveMainGridColumnCount(int count) async {
    _storedMainCount = count;
  }

  @override
  Future<int> loadAccountGridColumnCount() async => _storedAccountCount;

  @override
  Future<void> saveAccountGridColumnCount(int count) async {
    _storedAccountCount = count;
  }

  @override
  Future<GalleryData> fetchGalleryData(String gistId, {String? remoteUpdatedAt}) async {
    return GalleryData(
      userName: 'test_user',
      items: [
        TweetItem(
          id: '1',
          fullText: 'test post',
          createdAt: '2026-01-01',
          mediaUrls: const ['https://example.com/1.jpg'],
          username: 'userA',
        ),
      ],
      userGists: {'userA': 'gist_a'},
    );
  }
}

class MockViewModelForGrid extends GalleryViewModel {
  MockViewModelForGrid({required super.repository, required super.githubService});

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
}

class MockGitHubServiceForGrid extends GitHubService {
  @override
  Future<Map<String, dynamic>> fetchGistMetadata(String gistId) async {
    return {'exists': true, 'updatedAt': '2026-01-01T00:00:00Z'};
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    SharedPreferences.setMockInitialValues({});
    dotenv.loadFromString(envString: 'MASTER_GIST_ID=master_123');
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('Grid Column Count Unit Tests', () {
    test('GalleryRepository defaults to 2 for both main and account galleries', () async {
      final repo = GalleryRepository();
      expect(await repo.loadMainGridColumnCount(), 2);
      expect(await repo.loadAccountGridColumnCount(), 2);

      await repo.saveMainGridColumnCount(3);
      await repo.saveAccountGridColumnCount(1);

      expect(await repo.loadMainGridColumnCount(), 3);
      expect(await repo.loadAccountGridColumnCount(), 1);
    });

    test('GalleryViewModel maintains separate main and account column counts', () async {
      final repo = MockGalleryRepoForGrid();
      final vm = GalleryViewModel(
        repository: repo,
        githubService: MockGitHubServiceForGrid(),
      );

      expect(vm.mainGridColumnCount, 2);
      expect(vm.accountGridColumnCount, 2);

      await vm.setMainGridColumnCount(3);
      expect(vm.mainGridColumnCount, 3);
      expect(vm.accountGridColumnCount, 2); // アカウントギャラリー側は影響を受けない
      expect(await repo.loadMainGridColumnCount(), 3);
      expect(await repo.loadAccountGridColumnCount(), 2);

      await vm.setAccountGridColumnCount(1);
      expect(vm.mainGridColumnCount, 3);
      expect(vm.accountGridColumnCount, 1);
      expect(await repo.loadAccountGridColumnCount(), 1);
    });
  });

  group('Grid Column Count UI Integration Tests', () {
    testWidgets('UserGallerySwipePage menu switches account gallery columns (default 2)', (tester) async {
      tester.view.physicalSize = const Size(800, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final repo = MockGalleryRepoForGrid();
      final vm = MockViewModelForGrid(
        repository: repo,
        githubService: MockGitHubServiceForGrid(),
      );

      await tester.pumpWidget(
        ChangeNotifierProvider<GalleryViewModel>.value(
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
            home: UserGallerySwipePage(
              usernames: ['userA'],
              userGistIds: ['gistA'],
              initialIndex: 0,
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // 初期状態のアカウントグリッドは2列
      final gridFinder = find.byType(AspectRatioGridView<TweetItem>);
      expect(gridFinder, findsOneWidget);
      final gridWidget = tester.widget<AspectRatioGridView<TweetItem>>(gridFinder);
      expect(gridWidget.columnCount, 2);

      // ハンバーガーメニューを開く
      final menuButton = find.byIcon(Icons.menu);
      await tester.tap(menuButton);
      await tester.pumpAndSettle();

      // メニュー内の「列数」をタップしてダイアログを開く
      expect(find.text('列数'), findsOneWidget);
      await tester.tap(find.text('列数'));
      await tester.pumpAndSettle();

      // ラジオボタン選択肢として 3列、2列、1列 がダイアログ内に存在すること
      expect(find.text('3列'), findsOneWidget);
      expect(find.text('2列'), findsOneWidget);
      expect(find.text('1列'), findsOneWidget);

      // 3列をタップ
      await tester.tap(find.text('3列'), warnIfMissed: false);
      await tester.pumpAndSettle();

      // グリッドが3列に切り替わっていること
      final updatedGridWidget = tester.widget<AspectRatioGridView<TweetItem>>(gridFinder);
      expect(updatedGridWidget.columnCount, 3);
      expect(vm.accountGridColumnCount, 3);
      expect(vm.mainGridColumnCount, 2); // メインギャラリー側は維持されること
    });

    testWidgets('GalleryPage menu switches main gallery columns (default 2)', (tester) async {
      tester.view.physicalSize = const Size(800, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final repo = MockGalleryRepoForGrid();
      final vm = GalleryViewModel(
        repository: repo,
        githubService: MockGitHubServiceForGrid(),
      );
      await vm.loadGallery('master_123');

      await tester.pumpWidget(
        ChangeNotifierProvider<GalleryViewModel>.value(
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

      // 初期状態のメインギャラリーは2列
      expect(vm.mainGridColumnCount, 2);

      // ハンバーガーメニューを開く
      final menuButton = find.byIcon(Icons.menu);
      expect(menuButton, findsOneWidget);
      await tester.tap(menuButton);
      await tester.pumpAndSettle();

      // メニュー内の「列数」をタップしてダイアログを開く
      expect(find.text('列数'), findsOneWidget);
      await tester.tap(find.text('列数'));
      await tester.pumpAndSettle();

      // 1列をタップ
      await tester.tap(find.text('1列'), warnIfMissed: false);
      await tester.pumpAndSettle();

      expect(vm.mainGridColumnCount, 1);
      expect(vm.accountGridColumnCount, 2); // アカウントギャラリー側は影響を受けないこと
    });
  });
}
