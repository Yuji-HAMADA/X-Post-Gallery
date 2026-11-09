import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:x_post_gallery/models/tweet_item.dart';
import 'package:x_post_gallery/screens/detail/detail_page.dart';
import 'package:x_post_gallery/screens/detail/horizontal_detail_page.dart';

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

void main() {
  setUpAll(() {
    HttpOverrides.global = _TestHttpOverrides();
  });

  group('DetailPage & HorizontalDetailPage Layout Tests', () {
    final multiImageItem = TweetItem(
      id: 'tweet_multi',
      fullText: '複数画像の投稿テキスト #test',
      createdAt: '2025-01-01',
      mediaUrls: [
        'https://example.com/img1.jpg',
        'https://example.com/img2.jpg',
        'https://example.com/img3.jpg',
      ],
    );

    final singleImageItem = TweetItem(
      id: 'tweet_single',
      fullText: '単一画像の投稿テキスト',
      createdAt: '2025-01-01',
      mediaUrls: [
        'https://example.com/single.jpg',
      ],
    );

    testWidgets('複数画像の投稿では切り替えボタンが表示され、タップで横方向画面に遷移できる', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: DetailPage(
            items: [multiImageItem],
            initialIndex: 0,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // デフォルト画面: 切り替えボタンが存在すること
      final switchButton = find.byIcon(Icons.view_carousel_outlined);
      expect(switchButton, findsOneWidget);

      // デフォルト画面: テキストが表示されていること
      expect(find.textContaining('複数画像の投稿テキスト'), findsOneWidget);

      // 切り替えボタンをタップして横方向構成画面へ遷移
      await tester.tap(switchButton);
      await tester.pumpAndSettle();

      // HorizontalDetailPage が表示されていること
      expect(find.byType(HorizontalDetailPage), findsOneWidget);

      // 横方向画面の背景色が白色であること
      final scaffold = tester.widget<Scaffold>(
        find.descendant(
          of: find.byType(HorizontalDetailPage),
          matching: find.byType(Scaffold),
        ),
      );
      expect(scaffold.backgroundColor, Colors.white);

      // インジケータ（1 / 3 など）が表示されていないこと
      expect(find.text('1 / 3'), findsNothing);

      // 横スクロール可能な SingleChildScrollView が存在すること
      final horizontalScroll = find.descendant(
        of: find.byType(HorizontalDetailPage),
        matching: find.byWidgetPredicate(
          (w) => w is SingleChildScrollView && w.scrollDirection == Axis.horizontal,
        ),
      );
      expect(horizontalScroll, findsOneWidget);

      // 横方向構成画面ではテキストは非表示であること
      expect(find.textContaining('複数画像の投稿テキスト'), findsNothing);

      // 戻るボタン（←）をタップ
      final backButton = find.descendant(
        of: find.byType(HorizontalDetailPage),
        matching: find.byIcon(Icons.arrow_back),
      );
      expect(backButton, findsOneWidget);
      await tester.tap(backButton);
      await tester.pumpAndSettle();

      // 元のデフォルト画面に戻り、テキストが再表示されていること
      expect(find.byType(HorizontalDetailPage), findsNothing);
      expect(find.textContaining('複数画像の投稿テキスト'), findsOneWidget);
    });

    testWidgets('単一画像の投稿でも切り替えボタンが表示され、タップで横方向画面に遷移できる', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: DetailPage(
            items: [singleImageItem],
            initialIndex: 0,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 単一画像でも切り替えボタンが存在すること
      final switchButton = find.byIcon(Icons.view_carousel_outlined);
      expect(switchButton, findsOneWidget);

      // デフォルト画面のテキストは表示されていること
      expect(find.textContaining('単一画像の投稿テキスト'), findsOneWidget);

      // タップで横方向画面に遷移できること
      await tester.tap(switchButton);
      await tester.pumpAndSettle();
      expect(find.byType(HorizontalDetailPage), findsOneWidget);
    });

    testWidgets('横方向画面で隙間切り替えトグルをタップすると画像間のパディングが変化する', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: HorizontalDetailPage(
            items: [multiImageItem],
            initialIndex: 0,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // トグルボタンが存在すること
      final toggleButton = find.byIcon(Icons.view_column_outlined);
      expect(toggleButton, findsOneWidget);

      // 初期状態: 画像間に 4.0 のパディングが存在すること
      expect(
        find.byWidgetPredicate(
          (w) => w is Padding && w.padding == const EdgeInsets.only(right: 4.0),
        ),
        findsWidgets,
      );

      // トグルボタンをタップ
      await tester.tap(toggleButton);
      await tester.pumpAndSettle();

      // 隙間ゼロ状態: 4.0 のパディングがなくなり 0.0 になること
      expect(
        find.byWidgetPredicate(
          (w) => w is Padding && w.padding == const EdgeInsets.only(right: 4.0),
        ),
        findsNothing,
      );
    });

    testWidgets('横方向モード中に上下スワイプで前後の投稿へ移動し、戻るボタンでその投稿に復帰する', (tester) async {
      final post1 = TweetItem(
        id: 'post_1',
        fullText: '最初の投稿テキスト',
        createdAt: '2025-01-01',
        mediaUrls: ['https://example.com/p1_1.jpg', 'https://example.com/p1_2.jpg'],
      );
      final post2 = TweetItem(
        id: 'post_2',
        fullText: '次の投稿テキスト',
        createdAt: '2025-01-02',
        mediaUrls: ['https://example.com/p2_1.jpg', 'https://example.com/p2_2.jpg'],
      );

      await tester.pumpWidget(
        MaterialApp(
          home: DetailPage(
            items: [post1, post2],
            initialIndex: 0,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // post1 の横方向モードを開く
      final switchButton = find.byIcon(Icons.view_carousel_outlined);
      await tester.tap(switchButton);
      await tester.pumpAndSettle();
      expect(find.byType(HorizontalDetailPage), findsOneWidget);

      // 上方向へスワイプ（画面を下から上へドラッグして次の投稿 post2 へ移動）
      await tester.drag(find.byType(HorizontalDetailPage), const Offset(0, -600));
      await tester.pumpAndSettle();

      // post2 の横方向画像ビューが表示されていること
      expect(find.byKey(const ValueKey('post_2')), findsOneWidget);

      // 戻るボタンをタップ
      final backButton = find.descendant(
        of: find.byType(HorizontalDetailPage),
        matching: find.byIcon(Icons.arrow_back),
      );
      await tester.tap(backButton);
      await tester.pumpAndSettle();

      // デフォルト画面に戻ったとき、移動先の post2 の投稿テキストが表示されていること（同期復帰）
      expect(find.byType(HorizontalDetailPage), findsNothing);
      expect(find.textContaining('次の投稿テキスト'), findsOneWidget);
      expect(find.textContaining('最初の投稿テキスト'), findsNothing);
    });
  });
}
