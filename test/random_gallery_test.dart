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

    test('TweetItem should correctly parse video_url and set isVideo=true', () {
      final json = {
        'id_str': '987654321',
        'username': 'video_creator',
        'media_urls': ['https://pbs.twimg.com/media/poster.jpg'],
        'video_url': 'https://video.twimg.com/ext_tw_video/test.mp4',
        'full_text': '@video_creator: Sample video post',
      };

      final item = TweetItem.fromJson(json);

      expect(item.isVideo, isTrue);
      expect(item.videoUrl, 'https://video.twimg.com/ext_tw_video/test.mp4');
      expect(item.thumbnailUrl, 'https://pbs.twimg.com/media/poster.jpg?name=small');

      final serialized = item.toJson();
      expect(serialized['video_url'], 'https://video.twimg.com/ext_tw_video/test.mp4');

      final masterSerialized = item.toMasterJson();
      expect(masterSerialized['video_url'], 'https://video.twimg.com/ext_tw_video/test.mp4');
    });

    test('TweetItem should extract highest bitrate mp4 from extended_entities if video_url is not in root', () {
      final json = {
        'id_str': '55555',
        'tweet': {
          'id_str': '55555',
          'full_text': 'Nested video tweet',
          'extended_entities': {
            'media': [
              {
                'type': 'video',
                'media_url_https': 'https://pbs.twimg.com/media/thumb.jpg',
                'expanded_url': 'https://x.com/user/status/55555/video/1',
                'video_info': {
                  'variants': [
                    {
                      'content_type': 'video/mp4',
                      'bitrate': 256000,
                      'url': 'https://video.twimg.com/low.mp4',
                    },
                    {
                      'content_type': 'video/mp4',
                      'bitrate': 2176000,
                      'url': 'https://video.twimg.com/high.mp4',
                    },
                    {
                      'content_type': 'application/x-mpegURL',
                      'url': 'https://video.twimg.com/playlist.m3u8',
                    },
                  ],
                },
              },
            ],
          },
        },
      };

      final item = TweetItem.fromJson(json);

      expect(item.isVideo, isTrue);
      expect(item.videoUrl, 'https://video.twimg.com/high.mp4');
      expect(item.postUrl, 'https://x.com/user/status/55555');
    });
  });
}
