import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:x_post_gallery/models/tweet_item.dart';
import 'package:x_post_gallery/screens/gallery/components/dialog_helpers.dart';
import 'package:x_post_gallery/screens/gallery/components/user_card.dart';

void main() {
  final dummyThumb = TweetItem(
    id: '1',
    fullText: 'text',
    createdAt: '',
    mediaUrls: const [],
  );

  group('UserCard Tests', () {
    testWidgets('Heart button tap triggers only onFavoriteTap without bubbling to card onTap', (tester) async {
      int favoriteTapCount = 0;
      int cardTapCount = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 150,
                height: 150,
                child: UserCard(
                  username: 'test_user',
                  thumbItem: dummyThumb,
                  isFavorite: false,
                  onTap: () => cardTapCount++,
                  onFavoriteTap: () => favoriteTapCount++,
                ),
              ),
            ),
          ),
        ),
      );

      // 右上のハートボタンをタップ
      final heartFinder = find.byIcon(Icons.favorite_border);
      expect(heartFinder, findsOneWidget);

      await tester.tap(heartFinder);
      await tester.pumpAndSettle();

      expect(favoriteTapCount, 1, reason: 'Heart tap should trigger onFavoriteTap');
      expect(cardTapCount, 0, reason: 'Heart tap must NOT bubble to card onTap');
    });

    testWidgets('Card body tap triggers onTap', (tester) async {
      int favoriteTapCount = 0;
      int cardTapCount = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 150,
                height: 150,
                child: UserCard(
                  username: 'test_user',
                  thumbItem: dummyThumb,
                  isFavorite: false,
                  onTap: () => cardTapCount++,
                  onFavoriteTap: () => favoriteTapCount++,
                ),
              ),
            ),
          ),
        ),
      );

      // カード中央をタップ
      await tester.tap(find.byType(UserCard));
      await tester.pumpAndSettle();

      expect(cardTapCount, 1);
      expect(favoriteTapCount, 0);
    });

    testWidgets('Favorite state changes heart icon correctly', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 150,
                height: 150,
                child: UserCard(
                  username: 'fav_user',
                  thumbItem: dummyThumb,
                  isFavorite: true,
                  onTap: () {},
                  onFavoriteTap: () {},
                ),
              ),
            ),
          ),
        ),
      );

      expect(find.byIcon(Icons.favorite), findsOneWidget);
    });

    testWidgets('Pin icon is displayed when isPinned is true and hidden when false', (tester) async {
      // 1. isPinned = false: ピンマーク非表示
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 150,
                height: 150,
                child: UserCard(
                  username: 'unpinned_user',
                  thumbItem: dummyThumb,
                  isFavorite: false,
                  isPinned: false,
                  onTap: () {},
                  onFavoriteTap: () {},
                ),
              ),
            ),
          ),
        ),
      );
      expect(find.byIcon(Icons.push_pin), findsNothing);

      // 2. isPinned = true: ピンマーク表示
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 150,
                height: 150,
                child: UserCard(
                  username: 'pinned_user',
                  thumbItem: dummyThumb,
                  isFavorite: false,
                  isPinned: true,
                  onTap: () {},
                  onFavoriteTap: () {},
                ),
              ),
            ),
          ),
        ),
      );
      expect(find.byIcon(Icons.push_pin), findsOneWidget);
    });
  });

  group('Toast Notification UI Tests', () {
    testWidgets('showToastNotification slides in and displays correct message and icon', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () {
                  showToastNotification(
                    context,
                    '@test_user を一番上に移動しました',
                    icon: Icons.push_pin,
                  );
                },
                child: const Text('Show Toast'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Show Toast'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('@test_user を一番上に移動しました'), findsOneWidget);
      expect(find.byIcon(Icons.push_pin), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 2600));
      await tester.pumpAndSettle();

      expect(find.text('@test_user を一番上に移動しました'), findsNothing);
    });

    testWidgets('UserCard displays video indicator (play arrow) in bottom-right across 1, 2, and 3 columns', (tester) async {
      final videoThumb = TweetItem(
        id: 'v1',
        fullText: 'Video tweet',
        createdAt: '2026-01-01',
        mediaUrls: const ['https://example.com/v1.jpg'],
        videoUrls: const ['https://example.com/v1.mp4'],
      );

      for (final cols in [1, 2, 3]) {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 150,
                  height: 150,
                  child: UserCard(
                    username: 'video_user',
                    thumbItem: videoThumb,
                    isFavorite: false,
                    columnCount: cols,
                    onTap: () {},
                    onFavoriteTap: () {},
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        // 下部バー右端の play_arrow アイコン（サイズ 12）が存在すること
        final indicators = tester.widgetList<Icon>(find.byIcon(Icons.play_arrow)).where((i) => i.size == 12);
        expect(indicators.length, 1, reason: 'Column count $cols must display bottom-right video indicator');
      }
    });

    testWidgets('UserCard displays video indicator when thumbItem is image but hasVideo is true', (tester) async {
      final imageThumb = TweetItem(
        id: 'img1',
        fullText: 'Image only tweet',
        createdAt: '2026-01-01',
        mediaUrls: const ['https://example.com/img.jpg'],
        videoUrls: const [],
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 150,
                height: 150,
                child: UserCard(
                  username: 'hina2nd_ai',
                  thumbItem: imageThumb,
                  isFavorite: false,
                  hasVideo: true, // アカウントは過去に動画を保持している
                  onTap: () {},
                  onFavoriteTap: () {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      // サムネイル自体は静止画だが、hasVideo=true により右下インジケーター（サイズ 12）が表示されること
      final indicators = tester.widgetList<Icon>(find.byIcon(Icons.play_arrow)).where((i) => i.size == 12);
      expect(indicators.length, 1);
    });
  });
}
