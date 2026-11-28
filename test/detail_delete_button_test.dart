import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:x_post_gallery/l10n/app_localizations.dart';
import 'package:x_post_gallery/models/tweet_item.dart';
import 'package:x_post_gallery/screens/detail/detail_page.dart';
import 'package:x_post_gallery/screens/detail/horizontal_detail_page.dart';
import 'package:x_post_gallery/screens/gallery/random_gallery_swipe_page.dart';
import 'package:x_post_gallery/services/gallery_repository.dart';
import 'package:x_post_gallery/services/github_service.dart';
import 'package:x_post_gallery/viewmodels/gallery_viewmodel.dart';

const _transparentImage = <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49,
  0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06,
  0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44,
  0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00, 0x05, 0x00, 0x01, 0x0D,
  0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42,
  0x60, 0x82,
];

class _MockHttpClient extends Fake implements HttpClient {
  @override
  bool autoUncompress = true;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async => _MockHttpClientRequest();

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async =>
      _MockHttpClientRequest();
}

class _MockHttpClientRequest extends Fake implements HttpClientRequest {
  @override
  final HttpHeaders headers = _MockHttpHeaders();

  @override
  Future<HttpClientResponse> close() async => _MockHttpClientResponse();
}

class _MockHttpHeaders extends Fake implements HttpHeaders {
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}
}

class _MockHttpClientResponse extends Fake implements HttpClientResponse {
  @override
  int get statusCode => 200;

  @override
  int get contentLength => _transparentImage.length;

  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return Stream<List<int>>.value(_transparentImage).listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }
}

class _TestHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) => _MockHttpClient();
}

class _FakeGitHubService extends GitHubService {
  final Map<String, String> gistContents;
  final List<Map<String, String>> updatedFiles = [];

  _FakeGitHubService(this.gistContents)
      : super(
          token: 'fake_token',
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

  @override
  Future<String?> fetchGistContent(String gistId, String filename) async =>
      gistContents[gistId];

  @override
  Future<bool> updateGistFile({
    required String gistId,
    required String filename,
    required String content,
  }) async {
    gistContents[gistId] = content;
    updatedFiles.add({
      'gistId': gistId,
      'filename': filename,
      'content': content,
    });
    return true;
  }
}

class _FakeGalleryRepository extends GalleryRepository {
  final GalleryData initialMaster;
  final Map<String, List<TweetItem>> userItemsMap;

  _FakeGalleryRepository(this.initialMaster, this.userItemsMap);

  @override
  Future<GalleryData> fetchGalleryData(
    String gistId, {
    String? remoteUpdatedAt,
  }) async =>
      initialMaster;

  @override
  Future<List<TweetItem>> fetchUserGist(String gistId, String username) async =>
      List<TweetItem>.from(userItemsMap[username] ?? const []);
}

void main() {
  setUpAll(() {
    HttpOverrides.global = _TestHttpOverrides();
    dotenv.loadFromString(
      envString: 'MASTER_GIST_ID=master_gist_1\nGITHUB_USERNAME=tester',
    );
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  TweetItem makePost(String id, String text, {String username = 'sample_user'}) =>
      TweetItem(
        id: id,
        fullText: '@$username: $text',
        createdAt: '2026-11-28 10:00:00 JST',
        mediaUrls: ['https://example.com/$id.jpg'],
        username: username,
      );

  Future<({GalleryViewModel vm, _FakeGitHubService github})> createVm(
    List<TweetItem> posts,
  ) async {
    final childJson = jsonEncode({
      'users': {
        'sample_user': {'tweets': posts.map((e) => e.toJson()).toList()},
      },
    });
    final github = _FakeGitHubService({'child_gist_1': childJson});
    final repo = _FakeGalleryRepository(
      GalleryData(
        userName: 'Master',
        items: posts.isNotEmpty ? [posts.first] : const [],
        userGists: const {'sample_user': 'child_gist_1'},
      ),
      {'sample_user': posts},
    );
    final vm = GalleryViewModel(repository: repo, githubService: github);
    await vm.loadGallery('master_gist_1');
    return (vm: vm, github: github);
  }

  testWidgets('DetailPage の削除ボタンで確認後に投稿を削除し、次投稿表示・最終1件削除で画面を閉じる', (
    tester,
  ) async {
    final post1 = makePost('101', 'first post');
    final post2 = makePost('102', 'second post');
    final env = await createVm([post1, post2]);
    final deletedLog = <(String, int)>[];
    bool? popResult;

    await tester.pumpWidget(
      ChangeNotifierProvider<GalleryViewModel>.value(
        value: env.vm,
        child: MaterialApp(
          locale: const Locale('ja'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => Scaffold(
              body: ElevatedButton(
                onPressed: () async {
                  popResult = await Navigator.push<bool>(
                    context,
                    MaterialPageRoute(
                      builder: (_) => DetailPage(
                        items: [post1, post2],
                        initialIndex: 0,
                        username: 'sample_user',
                        userGistId: 'child_gist_1',
                        onItemDeleted: (id, rem) => deletedLog.add((id, rem)),
                      ),
                    ),
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.delete_outline), findsOneWidget);
    expect(find.textContaining('first post'), findsOneWidget);

    // 1回目: キャンセルすると削除されない
    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();
    await tester.tap(find.text('キャンセル'));
    await tester.pumpAndSettle();
    expect(deletedLog, isEmpty);
    expect(find.textContaining('first post'), findsOneWidget);

    // 2回目: 削除を確定 → post1 が削除され、post2 が表示される
    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();
    await tester.tap(find.text('削除'));
    await tester.pumpAndSettle();

    expect(deletedLog, [('101', 1)]);
    expect(find.textContaining('second post'), findsOneWidget);
    final childAfterFirst =
        jsonDecode(env.github.gistContents['child_gist_1']!)
            as Map<String, dynamic>;
    expect(childAfterFirst['deleted_ids'], contains('101'));

    // 3回目: 最後の1件(post2)を削除 → 画面が閉じ、popResult == true
    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();
    await tester.tap(find.text('削除'));
    await tester.pumpAndSettle();

    expect(deletedLog, [('101', 1), ('102', 0)]);
    expect(find.byType(DetailPage), findsNothing);
    expect(popResult, isTrue);
    expect(env.vm.userGists.containsKey('sample_user'), isFalse);
  });

  testWidgets('HorizontalDetailPage からも削除でき、DetailPage と同期される', (
    tester,
  ) async {
    final post1 = makePost('201', 'horiz one');
    final post2 = makePost('202', 'horiz two');
    final env = await createVm([post1, post2]);
    final deletedIds = <String>[];

    await tester.pumpWidget(
      ChangeNotifierProvider<GalleryViewModel>.value(
        value: env.vm,
        child: MaterialApp(
          locale: const Locale('ja'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: DetailPage(
            items: [post1, post2],
            initialIndex: 0,
            username: 'sample_user',
            userGistId: 'child_gist_1',
            onItemDeleted: (id, _) => deletedIds.add(id),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 横方向表示画面へ遷移
    await tester.tap(find.byIcon(Icons.view_carousel_outlined));
    await tester.pumpAndSettle();
    expect(find.byType(HorizontalDetailPage), findsOneWidget);

    final horizDelete = find.descendant(
      of: find.byType(HorizontalDetailPage),
      matching: find.byIcon(Icons.delete_outline),
    );
    expect(horizDelete, findsOneWidget);

    await tester.tap(horizDelete);
    await tester.pumpAndSettle();
    await tester.tap(find.text('削除'));
    await tester.pumpAndSettle();

    expect(deletedIds, ['201']);

    // 戻ると DetailPage でも post2 が表示されていること
    final backBtn = find.descendant(
      of: find.byType(HorizontalDetailPage),
      matching: find.byIcon(Icons.arrow_back),
    );
    await tester.tap(backBtn);
    await tester.pumpAndSettle();
    expect(find.byType(HorizontalDetailPage), findsNothing);
    expect(find.textContaining('horiz two'), findsOneWidget);
  });

  testWidgets('RandomGallerySwipePage の削除ボタンで削除しても他投稿を消失させず次へ進む', (
    tester,
  ) async {
    final post1 = makePost('301', 'random one');
    final post2 = makePost('302', 'random two');
    final env = await createVm([post1, post2]);
    final deletedIds = <String>[];

    await tester.pumpWidget(
      ChangeNotifierProvider<GalleryViewModel>.value(
        value: env.vm,
        child: MaterialApp(
          locale: const Locale('ja'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: RandomGallerySwipePage(
            usernames: const ['sample_user'],
            title: '@sample_user',
            // 部分リスト（1件だけ）を渡してもユーザー全投稿を再取得して安全に削除すること
            preloadedItems: [post1],
            allowOpenUserGallery: false,
            onItemDeleted: (id, _) => deletedIds.add(id),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.delete_outline), findsOneWidget);
    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();
    await tester.tap(find.text('削除'));
    await tester.pumpAndSettle();

    expect(deletedIds, ['301']);
    final updatedChild =
        jsonDecode(env.github.gistContents['child_gist_1']!)
            as Map<String, dynamic>;
    final remainingTweets =
        (updatedChild['users']['sample_user']['tweets'] as List);
    // post2 が消えずに残っていること
    expect(remainingTweets.length, 1);
    expect(remainingTweets.first['id_str'], '302');
  });

  test('deleteSingleTweetItem: allUserItems 未指定かつ取得結果が空の場合は誤全削除せず失敗を返す', () async {
    final post1 = makePost('401', 'only post');
    final github = _FakeGitHubService({
      'child_gist_1': jsonEncode({
        'users': {
          'sample_user': {'tweets': [post1.toJson()]},
        },
      }),
    });
    final repo = _FakeGalleryRepository(
      GalleryData(
        userName: 'Master',
        items: [post1],
        userGists: const {'sample_user': 'child_gist_1'},
      ),
      const {'sample_user': []},
    );
    final vm = GalleryViewModel(repository: repo, githubService: github);
    await vm.loadGallery('master_gist_1');

    final res = await vm.deleteSingleTweetItem(post1);
    expect(res, isNull);
    expect(github.updatedFiles, isEmpty);
  });
}
