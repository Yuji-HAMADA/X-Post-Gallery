import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:x_post_gallery/l10n/app_localizations.dart';
import 'package:x_post_gallery/models/tweet_item.dart';
import 'package:x_post_gallery/models/user_gist_entry.dart';
import 'package:x_post_gallery/screens/detail/detail_image_item.dart';
import 'package:x_post_gallery/screens/gallery/random_gallery_swipe_page.dart';
import 'package:x_post_gallery/screens/gallery/user_gallery_swipe_page.dart';
import 'package:x_post_gallery/services/gallery_repository.dart';
import 'package:x_post_gallery/services/github_service.dart';
import 'package:x_post_gallery/viewmodels/gallery_viewmodel.dart';

class _FakeRandomRepo extends GalleryRepository {
  final GalleryData masterData;
  final Map<String, List<TweetItem>> itemsByUser;
  final List<String> fetchedUsers = [];

  _FakeRandomRepo({
    required this.masterData,
    required this.itemsByUser,
  });

  @override
  Future<GalleryData> fetchGalleryData(
    String gistId, {
    String? remoteUpdatedAt,
  }) async =>
      masterData;

  @override
  Future<List<TweetItem>> fetchUserGist(String gistId, String username) async {
    fetchedUsers.add(username);
    return List<TweetItem>.from(itemsByUser[username] ?? const []);
  }
}

class _FakeRandomGitHub extends GitHubService {
  _FakeRandomGitHub()
      : super(
          token: '',
          owner: 'tester',
          fetchQueueGistId: '',
          igFetchQueueGistId: '',
          tiktokFetchQueueGistId: '',
        );

  @override
  Future<Map<String, dynamic>> fetchGistMetadata(String gistId) async => {
        'exists': true,
        'updatedAt': '2026-11-28T06:00:00Z',
      };
}

Widget _wrapApp(GalleryViewModel vm, Widget home) {
  return ChangeNotifierProvider<GalleryViewModel>.value(
    value: vm,
    child: MaterialApp(
      locale: const Locale('ja'),
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: home,
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    dotenv.loadFromString(envString: 'MASTER_GIST_ID=master_123');
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('動画限定ランダムは hasVideo ユーザーから動画のみ抽出し、AppBar ミュートがデフォルト ON でトグルできる',
      (tester) async {
    final photoPost = TweetItem(
      id: 'p1',
      fullText: '@photo_user: photo only',
      createdAt: '2026-11-28 08:00:00 JST',
      mediaUrls: const ['https://example.com/p1.jpg'],
      username: 'photo_user',
    );
    final videoPost = TweetItem(
      id: 'v1',
      fullText: '@video_user: video post',
      createdAt: '2026-11-28 09:00:00 JST',
      mediaUrls: const ['https://example.com/v1_thumb.jpg'],
      videoUrls: const ['https://example.com/v1.mp4'],
      username: 'video_user',
    );

    final repo = _FakeRandomRepo(
      masterData: GalleryData(
        userName: 'Master',
        items: [photoPost, videoPost],
        userGists: const {'photo_user': 'g_photo', 'video_user': 'g_video'},
        userGistEntries: const {
          'photo_user': UserGistEntry(gistId: 'g_photo', hasVideo: false),
          'video_user': UserGistEntry(gistId: 'g_video', hasVideo: true),
        },
      ),
      itemsByUser: {
        'photo_user': [photoPost],
        'video_user': [photoPost.copyWith(id: 'v_img', username: 'video_user'), videoPost],
      },
    );

    final vm = GalleryViewModel(
      repository: repo,
      githubService: _FakeRandomGitHub(),
    );
    await vm.loadGallery('master_123');

    await tester.pumpWidget(
      _wrapApp(
        vm,
        const RandomGallerySwipePage(
          usernames: ['photo_user', 'video_user'],
          title: 'ランダム選択（動画のみ）',
          videosOnly: true,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // hasVideo=true の video_user のみが優先フェッチされること
    expect(repo.fetchedUsers, isNotEmpty);
    expect(repo.fetchedUsers.every((u) => u == 'video_user'), isTrue);

    // 動画表示中は AppBar にミュートボタンがデフォルト MUTE ON (volume_off) で表示されること
    expect(find.byIcon(Icons.volume_off), findsOneWidget);
    expect(find.byIcon(Icons.volume_up), findsNothing);

    // タップで MUTE OFF (volume_up) に切り替わること
    await tester.tap(find.byIcon(Icons.volume_off));
    await tester.pump();
    expect(find.byIcon(Icons.volume_up), findsOneWidget);
  });

  testWidgets('アカウント画面メニューにすべて/動画のみのランダム選択があり、動画0件なら SnackBar 通知する',
      (tester) async {
    final photoPost = TweetItem(
      id: 'p1',
      fullText: '@photo_only_user: photo',
      createdAt: '2026-11-28 08:00:00 JST',
      mediaUrls: const ['https://example.com/p1.jpg'],
      username: 'photo_only_user',
    );
    final repo = _FakeRandomRepo(
      masterData: GalleryData(
        userName: 'Master',
        items: [photoPost],
        userGists: const {'photo_only_user': 'g1'},
      ),
      itemsByUser: {
        'photo_only_user': [photoPost],
      },
    );
    final vm = GalleryViewModel(
      repository: repo,
      githubService: _FakeRandomGitHub(),
    );
    await vm.loadGallery('master_123');

    await tester.pumpWidget(
      _wrapApp(
        vm,
        const UserGallerySwipePage(
          usernames: ['photo_only_user'],
          userGistIds: ['g1'],
          initialIndex: 0,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();

    expect(find.text('ランダム選択（すべて）'), findsOneWidget);
    expect(find.text('ランダム選択（動画のみ）'), findsOneWidget);

    await tester.tap(find.text('ランダム選択（動画のみ）'));
    await tester.pumpAndSettle();

    expect(find.text('動画が見つかりませんでした'), findsOneWidget);
    expect(find.byType(RandomGallerySwipePage), findsNothing);

    // ランダム選択（すべて）は preloadedItems の静止画でも initState 例外なく即表示されること
    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ランダム選択（すべて）'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byType(RandomGallerySwipePage), findsOneWidget);
    expect(find.byType(DetailImageItem), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
