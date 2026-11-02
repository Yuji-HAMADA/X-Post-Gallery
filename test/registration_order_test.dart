import 'package:flutter_test/flutter_test.dart';
import 'package:x_post_gallery/models/tweet_item.dart';

void main() {
  group('Registration Order Display Logic Tests (Latest Registered First)', () {
    test('Favorites should display latest registered users first regardless of tweet count', () {
      // 登録順: user_first, user_second, user_third (user_third が最新)
      final favoriteUsers = {'user_first', 'user_second', 'user_third'};

      // ツイート件数は user_first(5件), user_second(2件), user_third(1件)
      final List<TweetItem> favoriteItems = [
        TweetItem(id: '1', fullText: '@user_first: post 1', createdAt: '', mediaUrls: ['url1']),
        TweetItem(id: '2', fullText: '@user_first: post 2', createdAt: '', mediaUrls: ['url2']),
        TweetItem(id: '3', fullText: '@user_second: post 1', createdAt: '', mediaUrls: ['url3']),
        TweetItem(id: '4', fullText: '@user_third: post 1', createdAt: '', mediaUrls: ['url4']),
      ];

      final Map<String, List<TweetItem>> grouped = {};
      for (final item in favoriteItems) {
        final key = item.extractedUsername ?? '_unknown';
        grouped.putIfAbsent(key, () => []).add(item);
      }

      // 最新登録順（逆順）ロジックのシミュレーション
      final List<MapEntry<String, List<TweetItem>>> entries = [];
      for (final username in favoriteUsers.toList().reversed) {
        final userItems = grouped[username];
        if (userItems != null && userItems.isNotEmpty) {
          entries.add(MapEntry(username, userItems));
        }
      }
      for (final entry in grouped.entries) {
        if (!favoriteUsers.contains(entry.key)) {
          entries.add(entry);
        }
      }

      final resultUsernames = entries.map((e) => e.key).toList();

      // 件数順（first, second, third）ではなく、最新登録順（third, second, first）になっていること
      expect(resultUsernames, ['user_third', 'user_second', 'user_first']);
    });

    test('User gallery should display latest registered userGists first regardless of tweet count', () {
      // マスターGist登録順: alpha, beta, gamma (gamma が最新)
      final Map<String, String> userGists = {
        'alpha': 'gist_alpha',
        'beta': 'gist_beta',
        'gamma': 'gist_gamma',
      };
      final Set<String> favoriteUsers = {};

      // items は件数で alpha(5件), beta(3件), gamma(1件)
      final List<TweetItem> items = [
        TweetItem(id: '1', fullText: '@alpha: post 1', createdAt: '', mediaUrls: ['url1']),
        TweetItem(id: '2', fullText: '@alpha: post 2', createdAt: '', mediaUrls: ['url2']),
        TweetItem(id: '3', fullText: '@beta: post 1', createdAt: '', mediaUrls: ['url3']),
        TweetItem(id: '4', fullText: '@gamma: post 1', createdAt: '', mediaUrls: ['url4']),
      ];

      final Map<String, List<TweetItem>> grouped = {};
      for (final item in items) {
        final key = item.extractedUsername ?? '_unknown';
        if (favoriteUsers.contains(key)) continue;
        grouped.putIfAbsent(key, () => []).add(item);
      }

      final List<MapEntry<String, List<TweetItem>>> entries = [];
      for (final username in userGists.keys.toList().reversed) {
        if (favoriteUsers.contains(username)) continue;
        final userItems = grouped[username];
        if (userItems != null && userItems.isNotEmpty) {
          entries.add(MapEntry(username, userItems));
        }
      }
      for (final entry in grouped.entries) {
        if (!userGists.containsKey(entry.key)) {
          entries.add(entry);
        }
      }

      final resultUsernames = entries.map((e) => e.key).toList();

      // 件数降順（alpha, beta, gamma）ではなく、最新登録順（gamma, beta, alpha）になっていること
      expect(resultUsernames, ['gamma', 'beta', 'alpha']);
    });
  });
}
