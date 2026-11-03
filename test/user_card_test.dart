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
  });
}
