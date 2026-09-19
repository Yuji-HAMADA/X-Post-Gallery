import 'package:flutter_test/flutter_test.dart';
import 'package:x_post_gallery/models/tweet_item.dart';

void main() {
  group('TweetItem & Random Gallery Logic Tests', () {
    test('TweetItem should correctly parse from master Gist JSON (slim format)', () {
      final json = {
        'id_str': '123456789',
        'username': 'test_user',
        'media_urls': ['https://pbs.twimg.com/media/test.jpg'],
        'full_text': '@test_user: This is a test tweet #tag',
      };

      final item = TweetItem.fromJson(json);

      expect(item.id, '123456789');
      expect(item.username, 'test_user');
      expect(item.mediaUrls.length, 1);
      expect(item.mediaUrls[0], 'https://pbs.twimg.com/media/test.jpg');
      expect(item.thumbnailUrl, 'https://pbs.twimg.com/media/test.jpg?name=small');
      expect(item.origUrls[0], 'https://pbs.twimg.com/media/test.jpg?name=orig');
    });

    test('TweetItem should fallback to extract username from full_text if username is null', () {
      final json = {
        'id_str': '123456789',
        'media_urls': ['https://pbs.twimg.com/media/test.jpg'],
        'full_text': '@extracted_user: This is a test tweet',
      };

      final item = TweetItem.fromJson(json);
      expect(item.username, isNull);
      expect(item.extractedUsername, 'extracted_user');
    });

    test('All usernames helper logic should properly extract unique list of usernames', () {
      final List<TweetItem> items = [
        TweetItem(
          id: '1',
          fullText: '@userA: post 1',
          createdAt: 'date1',
          mediaUrls: [],
          username: 'userA',
        ),
        TweetItem(
          id: '2',
          fullText: '@userB: post 2',
          createdAt: 'date2',
          mediaUrls: [],
          username: null, // Test fallback on regex
        ),
        TweetItem(
          id: '3',
          fullText: '@userA: post 3',
          createdAt: 'date3',
          mediaUrls: [],
          username: 'userA', // Test deduplication
        ),
        TweetItem(
          id: '4',
          fullText: 'No username here',
          createdAt: 'date4',
          mediaUrls: [],
          username: null, // Test unknown user filter
        ),
      ];

      final Set<String> usernames = {};
      for (final item in items) {
        final key = item.extractedUsername;
        if (key != null && key != '_unknown') {
          usernames.add(key);
        }
      }

      final list = usernames.toList();
      expect(list.length, 2);
      expect(list, containsAll(['userA', 'userB']));
    });
  });
}
