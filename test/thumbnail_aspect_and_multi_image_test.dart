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
import 'package:x_post_gallery/services/gallery_repository.dart';
import 'package:x_post_gallery/services/github_service.dart';
import 'package:x_post_gallery/utils/image_aspect_ratio_manager.dart';
import 'package:x_post_gallery/viewmodels/gallery_viewmodel.dart';

class _MockRepoForAspectTest extends GalleryRepository {
  @override
  Future<String?> getSavedGistId() async => 'dummy_master';
  @override
  Future<int> loadGridColumnCount() async => 2;
}

void main() {
  setUpAll(() {
    SharedPreferences.setMockInitialValues({'saved_gist_id': 'dummy_master'});
    dotenv.loadFromString(envString: 'MASTER_GIST_ID=dummy_master');
  });

  tearDown(() {
    ImageAspectRatioManager.instance.clear();
  });

  group('Thumbnail Aspect Ratio Tests', () {
    test('ImageAspectRatioManager caches and returns aspect ratio', () {
      final manager = ImageAspectRatioManager.instance;
      expect(manager.getAspectRatio('https://example.com/test.jpg'), isNull);

      manager.setAspectRatio('https://example.com/test.jpg', 1.5);
      expect(manager.getAspectRatio('https://example.com/test.jpg'), 1.5);
    });

    testWidgets('Row height matches the tallest image by default in 2-column view', (tester) async {
      // url1: 縦長 (比率 0.5 = 1000x2000, 最も縦が大きい)
      // url2: 横長 (比率 2.0 = 2000x1000)
      ImageAspectRatioManager.instance.setAspectRatio('https://example.com/tall.jpg', 0.5);
      ImageAspectRatioManager.instance.setAspectRatio('https://example.com/wide.jpg', 2.0);

      final items = [
        'https://example.com/tall.jpg',
        'https://example.com/wide.jpg',
      ];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AspectRatioGridView<String>(
              items: items,
              columnCount: 2,
              scrollController: ScrollController(),
              getImageUrl: (item) => item,
              itemBuilder: (context, item, index) => Container(key: ValueKey(item)),
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // デフォルトで行のセルアスペクト比が縦長画像 (0.5) に合致していることを確認
      final aspectRatios = tester.widgetList<AspectRatio>(find.byType(AspectRatio));
      expect(aspectRatios.isNotEmpty, isTrue);
      for (final ar in aspectRatios) {
        expect(ar.aspectRatio, 0.5);
      }
    });

    testWidgets('1-column view uses original image aspect ratio', (tester) async {
      // url1: 比率 1.6
      ImageAspectRatioManager.instance.setAspectRatio('https://example.com/img1.jpg', 1.6);

      final items = ['https://example.com/img1.jpg'];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AspectRatioGridView<String>(
              items: items,
              columnCount: 1,
              scrollController: ScrollController(),
              getImageUrl: (item) => item,
              itemBuilder: (context, item, index) => Container(key: ValueKey(item)),
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      final aspectRatios = tester.widgetList<AspectRatio>(find.byType(AspectRatio));
      expect(aspectRatios.first.aspectRatio, 1.6);
    });
  });

  group('Account Gallery Multi-Image in 1-column view Tests', () {
    testWidgets('Multi-image post in 1-column view shows page indicator and allows swiping when mostly visible', (tester) async {
      tester.view.physicalSize = const Size(600, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final multiImageItem = TweetItem(
        id: '201',
        fullText: 'Multi image post',
        createdAt: '2026-11-20 10:00:00 JST',
        mediaUrls: [
          'https://example.com/photo1.jpg',
          'https://example.com/photo2.jpg',
        ],
      );

      final vm = GalleryViewModel(
        repository: _MockRepoForAspectTest(),
        githubService: GitHubService(),
      );
      await vm.setAccountGridColumnCount(1);

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<GalleryViewModel>.value(value: vm),
          ],
          child: MaterialApp(
            localizationsDelegates: const [
              AppLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            home: Scaffold(
              body: TweetGridView(
                items: [multiImageItem],
                selectedIds: const {},
                scrollController: ScrollController(),
              ),
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // 複数画像インジケータ「1/2」が表示されていること
      expect(find.text('1/2'), findsOneWidget);

      // PageView が存在すること
      expect(find.byType(PageView), findsOneWidget);

      // 右矢印をタップして 2枚目に切り替え
      final rightArrow = find.byIcon(Icons.chevron_right);
      if (rightArrow.evaluate().isNotEmpty) {
        await tester.tap(rightArrow);
        await tester.pumpAndSettle();
        expect(find.text('2/2'), findsOneWidget);
      }
    });

    testWidgets('Account gallery 1-column view uses high-resolution (orig) image URL', (tester) async {
      final singleItem = TweetItem(
        id: 'single_1',
        fullText: 'Single image post',
        createdAt: '2026-11-20 10:00:00 JST',
        mediaUrls: ['https://pbs.twimg.com/media/sample.jpg'],
      );

      final vm = GalleryViewModel(
        repository: _MockRepoForAspectTest(),
        githubService: GitHubService(),
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
                items: [singleItem],
                selectedIds: const {},
                scrollController: ScrollController(),
              ),
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      final imageFinder = find.byType(Image);
      expect(imageFinder, findsOneWidget);
      final imageWidget = tester.widget<Image>(imageFinder);
      final networkImage = imageWidget.image as NetworkImage;
      expect(networkImage.url, contains('name=orig'));
    });
  });
}
