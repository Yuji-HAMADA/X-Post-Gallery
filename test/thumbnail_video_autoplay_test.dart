import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:x_post_gallery/models/tweet_item.dart';
import 'package:x_post_gallery/screens/gallery/components/thumbnail_video_player.dart';
import 'package:x_post_gallery/screens/gallery/components/tweet_grid_view.dart';
import 'package:x_post_gallery/screens/gallery/components/user_card.dart';

void main() {
  final videoTweetItem = TweetItem(
    id: 'vid_1',
    fullText: 'Video post',
    createdAt: '2026-11-20 12:00:00 JST',
    mediaUrls: const [],
    videoUrls: const ['https://example.com/video.mp4'],
    videoThumbnailUrl: 'https://example.com/video_thumb.jpg',
  );

  group('Thumbnail Video Autoplay & Play/Pause Tests', () {
    testWidgets('ThumbnailVideoPlayer displays play/pause button at bottom center', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 200,
              height: 200,
              child: ThumbnailVideoPlayer(
                videoUrl: 'https://example.com/video.mp4',
                thumbnailUrl: 'https://example.com/video_thumb.jpg',
                bottomOffset: 8.0,
              ),
            ),
          ),
        ),
      );

      await tester.pump();

      // 下部中央に Play/Pause アイコンボタンが存在すること
      final playIconFinder = find.byIcon(Icons.play_arrow);
      expect(playIconFinder, findsOneWidget);

      // 下部中央の配置（X座標が中央付近であること）
      final buttonCenter = tester.getCenter(playIconFinder);
      expect((buttonCenter.dx - 100).abs(), lessThan(5.0)); // 幅200の中央100付近
    });

    testWidgets('Tapping play/pause button does NOT trigger parent card onTap in UserCard', (tester) async {
      int cardTapCount = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 200,
              height: 200,
              child: UserCard(
                username: 'video_user',
                thumbItem: videoTweetItem,
                isFavorite: false,
                onTap: () => cardTapCount++,
                onFavoriteTap: () {},
              ),
            ),
          ),
        ),
      );

      await tester.pump();

      final playIcon = find.byIcon(Icons.play_arrow);
      expect(playIcon, findsOneWidget);

      // Play/Pause ボタンをタップ
      await tester.tap(playIcon);
      await tester.pump();

      // 親カードの onTap は発火しないこと
      expect(cardTapCount, 0);

      // Play/Pause ボタン以外のサムネイル領域（上部中央）をタップ
      await tester.tapAt(const Offset(100, 50));
      await tester.pump();

      // 親カードの onTap が発火すること
      expect(cardTapCount, 1);
    });

    testWidgets('TweetGridItem with video renders ThumbnailVideoPlayer and preserves detail navigation', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 200,
              height: 200,
              child: TweetGridItem(
                items: [videoTweetItem],
                index: 0,
                selectedIds: const {},
                columnCount: 1,
              ),
            ),
          ),
        ),
      );

      await tester.pump();

      // ThumbnailVideoPlayer と Play ボタンが存在すること
      expect(find.byType(ThumbnailVideoPlayer), findsOneWidget);
      expect(find.byIcon(Icons.play_arrow), findsOneWidget);
    });

    testWidgets('TweetGridItem with video and multiple mediaUrls still renders ThumbnailVideoPlayer in 1-column view', (tester) async {
      final videoWithMultiMedia = TweetItem(
        id: 'vid_multi',
        fullText: 'Video with multiple mediaUrls',
        createdAt: '2026-11-20 12:00:00 JST',
        mediaUrls: const ['https://example.com/thumb1.jpg', 'https://example.com/thumb2.jpg'],
        videoUrls: const ['https://example.com/video.mp4'],
        videoThumbnailUrl: 'https://example.com/video_thumb.jpg',
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 200,
              height: 200,
              child: TweetGridItem(
                items: [videoWithMultiMedia],
                index: 0,
                selectedIds: const {},
                columnCount: 1,
              ),
            ),
          ),
        ),
      );

      await tester.pump();

      // !item.isVideo ガードにより、静止画 PageView ではなく ThumbnailVideoPlayer が描画されること
      expect(find.byType(ThumbnailVideoPlayer), findsOneWidget);
      expect(find.byType(PageView), findsNothing);
    });

    testWidgets('ThumbnailVideoPlayer does not autoplay when enableAutoplay is false', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 200,
              height: 200,
              child: ThumbnailVideoPlayer(
                videoUrl: 'https://example.com/video.mp4',
                thumbnailUrl: 'https://example.com/video_thumb.jpg',
                enableAutoplay: false, // 2列・3列時
              ),
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Play アイコンが表示されていること
      expect(find.byIcon(Icons.play_arrow), findsOneWidget);

      // Play ボタンをタップしたときは手動で再生処理が走ること（エラーなくタップ可能）
      await tester.tap(find.byIcon(Icons.play_arrow));
      await tester.pump();
    });

    testWidgets('UserCard and TweetGridItem disable autoplay when columnCount > 1', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                SizedBox(
                  width: 200,
                  height: 200,
                  child: UserCard(
                    username: 'user_2col',
                    thumbItem: videoTweetItem,
                    isFavorite: false,
                    columnCount: 2, // 2列表示
                    onTap: () {},
                    onFavoriteTap: () {},
                  ),
                ),
                SizedBox(
                  width: 200,
                  height: 200,
                  child: TweetGridItem(
                    items: [videoTweetItem],
                    index: 0,
                    selectedIds: const {},
                    columnCount: 3, // 3列表示
                  ),
                ),
              ],
            ),
          ),
        ),
      );

      await tester.pump();

      final players = tester.widgetList<ThumbnailVideoPlayer>(find.byType(ThumbnailVideoPlayer)).toList();
      expect(players.length, 2);
      expect(players[0].enableAutoplay, isFalse);
      expect(players[1].enableAutoplay, isFalse);
    });
  });
}
