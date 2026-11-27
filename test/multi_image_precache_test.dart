import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:x_post_gallery/models/tweet_item.dart';
import 'package:x_post_gallery/screens/gallery/components/tweet_grid_view.dart';

void main() {
  testWidgets(
      '1列複数画像ポストの PageView は隣接ページの事前描画 (allowImplicitScrolling) と gaplessPlayback を有効にする',
      (WidgetTester tester) async {
    final item = TweetItem(
      id: 'multi_1',
      fullText: 'multi image post',
      mediaUrls: const [
        'https://example.com/img1.jpg',
        'https://example.com/img2.jpg',
        'https://example.com/img3.jpg',
      ],
      username: 'sample_user',
      createdAt: '2026-11-27 12:00:00 JST',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 360,
            height: 480,
            child: TweetGridItem(
              items: [item],
              index: 0,
              selectedIds: const {},
              columnCount: 1,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final pageView = tester.widget<PageView>(find.byType(PageView));
    expect(pageView.allowImplicitScrolling, isTrue);

    final images = tester.widgetList<Image>(find.byType(Image)).toList();
    expect(images, isNotEmpty);
    expect(images.every((img) => img.gaplessPlayback), isTrue);
  });
}
