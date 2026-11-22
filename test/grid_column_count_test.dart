import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:x_post_gallery/l10n/app_localizations.dart';
import 'package:x_post_gallery/models/tweet_item.dart';
import 'package:x_post_gallery/screens/gallery/gallery_page.dart';
import 'package:x_post_gallery/screens/gallery/user_gallery_swipe_page.dart';
import 'package:x_post_gallery/services/gallery_repository.dart';
import 'package:x_post_gallery/services/github_service.dart';
import 'package:x_post_gallery/viewmodels/gallery_viewmodel.dart';

class MockGalleryRepoForGrid extends GalleryRepository {
  int _storedCount = 3;

  @override
  Future<int> loadGridColumnCount() async => _storedCount;

  @override
  Future<void> saveGridColumnCount(int count) async {
    _storedCount = count;
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

class MockGitHubServiceForGrid extends GitHubService {}

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
    test('GalleryRepository defaults to 3 and persists column changes', () async {
      final repo = GalleryRepository();
      expect(await repo.loadGridColumnCount(), 3);

      await repo.saveGridColumnCount(2);
      expect(await repo.loadGridColumnCount(), 2);

      await repo.saveGridColumnCount(1);
      expect(await repo.loadGridColumnCount(), 1);
    });

    test('GalleryViewModel updates gridColumnCount and persists change', () async {
      final repo = MockGalleryRepoForGrid();
      final vm = GalleryViewModel(
        repository: repo,
        githubService: MockGitHubServiceForGrid(),
      );

      expect(vm.gridColumnCount, 3);

      bool notified = false;
      vm.addListener(() => notified = true);

      await vm.setGridColumnCount(2);
      expect(vm.gridColumnCount, 2);
      expect(notified, isTrue);
      expect(await repo.loadGridColumnCount(), 2);
    });
  });

  group('Grid Column Count UI Integration Tests', () {
    testWidgets('UserGallerySwipePage menu contains column count options and switches columns', (tester) async {
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

      // 初期状態のグリッドは3列
      final gridFinder = find.byType(GridView);
      expect(gridFinder, findsOneWidget);
      final gridWidget = tester.widget<GridView>(gridFinder);
      final delegate = gridWidget.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
      expect(delegate.crossAxisCount, 3);

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

      // 2列をタップ
      await tester.tap(find.text('2列'), warnIfMissed: false);
      await tester.pumpAndSettle();

      // グリッドが2列に切り替わっていること
      final updatedGridWidget = tester.widget<GridView>(gridFinder);
      final updatedDelegate = updatedGridWidget.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
      expect(updatedDelegate.crossAxisCount, 2);
      expect(vm.gridColumnCount, 2);
    });

    testWidgets('GalleryPage menu contains column count options and switches columns', (tester) async {
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

      await tester.pump();

      // ハンバーガーメニューを開く
      final menuButton = find.byIcon(Icons.menu);
      expect(menuButton, findsOneWidget);
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

      // 1列をタップ
      await tester.tap(find.text('1列'), warnIfMissed: false);
      await tester.pumpAndSettle();

      expect(vm.gridColumnCount, 1);
    });
  });
}
