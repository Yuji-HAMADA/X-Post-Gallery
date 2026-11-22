import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:x_post_gallery/l10n/app_localizations.dart';
import 'package:x_post_gallery/models/tweet_item.dart';
import 'package:x_post_gallery/screens/gallery/user_gallery_swipe_page.dart';
import 'package:x_post_gallery/services/gallery_repository.dart';
import 'package:x_post_gallery/services/github_service.dart';
import 'package:x_post_gallery/viewmodels/gallery_viewmodel.dart';

class MockGalleryRepoForSwipe extends GalleryRepository {
  @override
  Future<List<TweetItem>> fetchUserGist(String gistId, String username) async => [];
}

class MockGitHubServiceForSwipe extends GitHubService {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    SharedPreferences.setMockInitialValues({});
    dotenv.loadFromString(envString: 'MASTER_GIST_ID=master_123');
  });

  testWidgets('UserGallerySwipePage has hamburger menu with fetch and delete user options', (tester) async {
    final vm = GalleryViewModel(
      repository: MockGalleryRepoForSwipe(),
      githubService: MockGitHubServiceForSwipe(),
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
            usernames: ['test_user'],
            userGistIds: ['test_gist'],
            initialIndex: 0,
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    // ハンバーガーメニューアイコンが存在すること
    final menuButton = find.byIcon(Icons.menu);
    expect(menuButton, findsOneWidget);

    // AppBar上に直接 add や close アイコンがないこと
    expect(find.byIcon(Icons.add), findsNothing);
    expect(find.byIcon(Icons.close), findsNothing);

    // ハンバーガーメニューをタップして開く
    await tester.tap(menuButton);
    await tester.pumpAndSettle();

    // メニュー項目として画像取得(Icons.add)、列数(Icons.grid_view)、ユーザー削除(Icons.close)が表示されていること
    expect(find.byIcon(Icons.add), findsOneWidget);
    expect(find.byIcon(Icons.grid_view), findsOneWidget);
    expect(find.byIcon(Icons.close), findsOneWidget);
    expect(find.text('画像取得'), findsOneWidget);
    expect(find.text('列数'), findsOneWidget);
    expect(find.text('ユーザーを削除'), findsOneWidget);

    // 誤操作防止のためユーザー削除ボタンが最下部に配置されていること
    final deletePos = tester.getCenter(find.text('ユーザーを削除'));
    final colPos = tester.getCenter(find.text('列数'));
    final addPos = tester.getCenter(find.text('画像取得'));
    expect(addPos.dy < colPos.dy, isTrue);
    expect(colPos.dy < deletePos.dy, isTrue);
  });
}
