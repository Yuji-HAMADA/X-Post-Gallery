import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:x_post_gallery/models/tweet_item.dart';
import 'package:x_post_gallery/services/gallery_repository.dart';
import 'package:x_post_gallery/utils/date_helper.dart';
import 'package:x_post_gallery/viewmodels/gallery_viewmodel.dart';

class _FakeGalleryRepository extends GalleryRepository {
  final Map<String, List<TweetItem>> userTweets = {};

  @override
  Future<List<TweetItem>> fetchUserGist(String gistId, String username) async {
    final list = userTweets[username] ?? [];
    list.sort(compareTweetsByNewest);
    return list;
  }
}

void main() {
  setUpAll(() {
    SharedPreferences.setMockInitialValues({});
    dotenv.loadFromString(envString: 'MASTER_GIST_ID=master_123');
  });

  group('date_helper & JST formatting tests', () {
    test('formatToJst converts ISO-8601 UTC to JST correctly', () {
      final utcIso = '2026-11-15T08:30:00.000Z';
      final jst = formatToJst(utcIso);
      expect(jst, equals('2026-11-15 17:30:00 JST'));
    });

    test('formatToJst converts Twitter API RFC 2822 style to JST correctly', () {
      final twitterDate = 'Wed Oct 10 20:19:24 +0000 2018';
      final jst = formatToJst(twitterDate);
      expect(jst, equals('2018-10-11 05:19:24 JST'));
    });

    test('formatToJst preserves already formatted JST string', () {
      final jstStr = '2026-11-15 17:30:00 JST';
      expect(formatToJst(jstStr), equals(jstStr));
    });

    test('formatToJst falls back gracefully for invalid or empty dates', () {
      expect(formatToJst(''), equals(''));
      expect(formatToJst('Unknown'), equals('Unknown'));
      expect(formatToJst('not-a-date'), equals('not-a-date'));
    });

    test('TweetItem.fromJson converts created_at to JST', () {
      final json = {
        'id_str': '10001',
        'full_text': 'test tweet',
        'created_at': '2026-11-15T00:00:00.000Z',
        'media_urls': ['https://example.com/test.jpg'],
      };
      final item = TweetItem.fromJson(json);
      expect(item.createdAt, equals('2026-11-15 09:00:00 JST'));
      expect(item.formattedCreatedAt, equals('2026-11-15 09:00:00 JST'));
    });
  });

  group('Account gallery sorting (newest first) tests', () {
    test('compareTweetsByNewest sorts tweets by date descending', () {
      final olderPost = TweetItem(
        id: '100',
        fullText: 'older post',
        createdAt: '2026-11-10T00:00:00.000Z',
        mediaUrls: ['url1'],
      );
      final newerPost = TweetItem(
        id: '200',
        fullText: 'newer post',
        createdAt: '2026-11-15T00:00:00.000Z',
        mediaUrls: ['url2'],
      );
      // ピン留めされていた古いポスト（スクレイピング結果の先頭にあったケース）
      final pinnedOldPost = TweetItem(
        id: '50',
        fullText: 'pinned old post',
        createdAt: '2025-01-01T00:00:00.000Z',
        mediaUrls: ['url0'],
      );

      final list = [pinnedOldPost, olderPost, newerPost];
      list.sort(compareTweetsByNewest);

      // 新しい順に並ぶこと
      expect(list[0].id, equals('200'));
      expect(list[1].id, equals('100'));
      expect(list[2].id, equals('50'));
    });

    test('compareTweetsByNewest falls back to Snowflake ID descending when dates are equal', () {
      final postA = TweetItem(
        id: '1000000000000000002',
        fullText: 'post A',
        createdAt: '2026-11-15T00:00:00.000Z',
        mediaUrls: ['urlA'],
      );
      final postB = TweetItem(
        id: '1000000000000000001',
        fullText: 'post B',
        createdAt: '2026-11-15T00:00:00.000Z',
        mediaUrls: ['urlB'],
      );

      final list = [postB, postA];
      list.sort(compareTweetsByNewest);

      expect(list[0].id, equals('1000000000000000002'));
      expect(list[1].id, equals('1000000000000000001'));
    });

    test('GalleryViewModel.fetchUserItems sorts items newest first', () async {
      final fakeRepo = _FakeGalleryRepository();
      fakeRepo.userTweets['testuser'] = [
        TweetItem(
          id: '1',
          fullText: '@testuser: old post',
          createdAt: '2026-11-01T00:00:00.000Z',
          mediaUrls: ['u1'],
        ),
        TweetItem(
          id: '2',
          fullText: '@testuser: new post',
          createdAt: '2026-11-10T00:00:00.000Z',
          mediaUrls: ['u2'],
        ),
      ];

      final vm = GalleryViewModel(repository: fakeRepo);
      await vm.registerUser('testuser', gistId: 'gist_123');

      final result = await vm.fetchUserItems('testuser');
      expect(result.length, equals(2));
      expect(result[0].id, equals('2'));
      expect(result[1].id, equals('1'));
    });
  });
}
