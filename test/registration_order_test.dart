import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:x_post_gallery/models/tweet_item.dart';
import 'package:x_post_gallery/models/user_gist_entry.dart';
import 'package:x_post_gallery/services/gallery_repository.dart';

void main() {
  group('UserGistEntry Model Tests', () {
    test('Parses legacy string format correctly with default priority 0', () {
      final entry = UserGistEntry.fromDynamic('gist_legacy_123');
      expect(entry.gistId, 'gist_legacy_123');
      expect(entry.priorityUpdatedAt, 0);
    });

    test('Parses new dict format with int priority', () {
      final entry = UserGistEntry.fromDynamic({
        'gist_id': 'gist_new_456',
        'priority_updated_at': 1712345678000,
      });
      expect(entry.gistId, 'gist_new_456');
      expect(entry.priorityUpdatedAt, 1712345678000);
    });

    test('Parses new dict format with ISO8601 string priority', () {
      final entry = UserGistEntry.fromDynamic({
        'gist_id': 'gist_iso_789',
        'priority_updated_at': '2024-01-01T00:00:00.000Z',
      });
      expect(entry.gistId, 'gist_iso_789');
      expect(entry.priorityUpdatedAt, 1704067200000);
    });

    test('Parses dict with missing priority as 0', () {
      final entry = UserGistEntry.fromDynamic({
        'gist_id': 'gist_no_priority',
      });
      expect(entry.gistId, 'gist_no_priority');
      expect(entry.priorityUpdatedAt, 0);
    });

    test('toJson always includes gist_id and priority_updated_at', () {
      const entry = UserGistEntry(gistId: 'my_gist', priorityUpdatedAt: 0);
      final json = entry.toJson();
      expect(json, {
        'gist_id': 'my_gist',
        'priority_updated_at': 0,
      });
    });
  });

  group('GalleryRepository Schema & Serialization Tests', () {
    final repo = GalleryRepository();

    test('buildMasterGistJson unifies all user_gists into structured objects with priority_updated_at', () {
      final items = [
        TweetItem(id: '1', fullText: '@userA: tweet', createdAt: '', mediaUrls: ['u1']),
      ];
      final userGists = {
        'userA': 'gistA',
        'userB': 'gistB',
      };
      final userPriorities = {
        'userA': 1712345678000,
        // userB は未操作（未指定）
      };

      final jsonStr = repo.buildMasterGistJson(
        items,
        userName: 'owner',
        userGists: userGists,
        userPriorities: userPriorities,
      );

      final decoded = json.decode(jsonStr) as Map<String, dynamic>;
      final decodedUserGists = decoded['user_gists'] as Map<String, dynamic>;

      // userA は指定タイムスタンプ
      expect(decodedUserGists['userA'], {
        'gist_id': 'gistA',
        'priority_updated_at': 1712345678000,
      });
      // 未操作の userB にはデフォルト値 0 が付与され、スキーマが統一されていること
      expect(decodedUserGists['userB'], {
        'gist_id': 'gistB',
        'priority_updated_at': 0,
      });
    });
  });

  group('Priority Sort Logic Tests (LIFO / Recently Active First)', () {
    test('Requirement Scenario: A long-pressed -> C added -> B long-pressed results in [B, C, A]', () {
      // 既存アカウント: A, B (登録順: A, B)
      final userGists = {
        'A': 'gist_A',
        'B': 'gist_B',
      };
      final Map<String, int> userPriorities = {
        'A': 0,
        'B': 0,
      };

      // 1. A を長押し -> A の priority を t1 (100) に更新
      userPriorities['A'] = 100;

      // 2. 新規 C を追加 -> C の priority を t2 (200) に設定
      userGists['C'] = 'gist_C';
      userPriorities['C'] = 200;

      // 3. B を長押し -> B の priority を t3 (300) に更新
      userPriorities['B'] = 300;

      // ソートロジックの適用
      final originalKeys = userGists.keys.toList();
      final Map<String, int> originalIndex = {};
      for (int i = 0; i < originalKeys.length; i++) {
        originalIndex[originalKeys[i]] = i;
      }

      final list = List<String>.from(originalKeys);
      list.sort((a, b) {
        final pA = userPriorities[a] ?? 0;
        final pB = userPriorities[b] ?? 0;
        final cmp = pB.compareTo(pA);
        if (cmp != 0) return cmp;

        final idxA = originalIndex[a] ?? -1;
        final idxB = originalIndex[b] ?? -1;
        return idxB.compareTo(idxA);
      });

      // 要件通りの並び順 [B, C, A] になること
      expect(list, ['B', 'C', 'A']);
    });

    test('Unmodified accounts with priority 0 keep registration reverse order (LIFO)', () {
      // 登録順: user1, user2, user3 (未操作のため priority は全て 0)
      final userGists = {
        'user1': 'g1',
        'user2': 'g2',
        'user3': 'g3',
      };
      final Map<String, int> userPriorities = {
        'user1': 0,
        'user2': 0,
        'user3': 0,
      };

      final originalKeys = userGists.keys.toList();
      final Map<String, int> originalIndex = {};
      for (int i = 0; i < originalKeys.length; i++) {
        originalIndex[originalKeys[i]] = i;
      }

      final list = List<String>.from(originalKeys);
      list.sort((a, b) {
        final pA = userPriorities[a] ?? 0;
        final pB = userPriorities[b] ?? 0;
        final cmp = pB.compareTo(pA);
        if (cmp != 0) return cmp;

        final idxA = originalIndex[a] ?? -1;
        final idxB = originalIndex[b] ?? -1;
        return idxB.compareTo(idxA);
      });

      // 全て未操作の場合は最新登録順（user3, user2, user1）
      expect(list, ['user3', 'user2', 'user1']);

      // ここで user1 がハート長押しされた場合
      userPriorities['user1'] = 500;
      final updatedList = List<String>.from(originalKeys);
      updatedList.sort((a, b) {
        final pA = userPriorities[a] ?? 0;
        final pB = userPriorities[b] ?? 0;
        final cmp = pB.compareTo(pA);
        if (cmp != 0) return cmp;

        final idxA = originalIndex[a] ?? -1;
        final idxB = originalIndex[b] ?? -1;
        return idxB.compareTo(idxA);
      });

      // 操作された user1 が最先頭になり、未操作のものは登録逆順を維持
      expect(updatedList, ['user1', 'user3', 'user2']);
    });

    test('User gallery grouped entries sort correctly with tweet items', () {
      final userGists = {
        'user_old': 'g_old',
        'user_mid': 'g_mid',
        'user_new': 'g_new',
      };
      final userPriorities = {
        'user_old': 1000, // 古い登録だが直近長押しされた
        'user_mid': 0,
        'user_new': 500,  // 新規登録
      };
      final favoriteUsers = {'fav_user'};

      final List<TweetItem> items = [
        TweetItem(id: '1', fullText: '@user_old: post 1', createdAt: '', mediaUrls: ['url1']),
        TweetItem(id: '2', fullText: '@user_mid: post 1', createdAt: '', mediaUrls: ['url2']),
        TweetItem(id: '3', fullText: '@user_new: post 1', createdAt: '', mediaUrls: ['url3']),
        TweetItem(id: '4', fullText: '@fav_user: post 1', createdAt: '', mediaUrls: ['url4']),
      ];

      final Map<String, List<TweetItem>> grouped = {};
      for (final item in items) {
        final key = item.extractedUsername ?? '_unknown';
        if (favoriteUsers.contains(key)) continue;
        grouped.putIfAbsent(key, () => []).add(item);
      }

      final originalKeys = userGists.keys.toList();
      final Map<String, int> originalIndex = {};
      for (int i = 0; i < originalKeys.length; i++) {
        originalIndex[originalKeys[i]] = i;
      }

      final List<MapEntry<String, List<TweetItem>>> entries = [];
      final Set<String> addedUsers = {};

      for (final username in originalKeys) {
        if (favoriteUsers.contains(username)) continue;
        final userItems = grouped[username] ?? [];
        entries.add(MapEntry(username, userItems));
        addedUsers.add(username);
      }

      for (final entry in grouped.entries) {
        if (!addedUsers.contains(entry.key)) {
          entries.add(entry);
          addedUsers.add(entry.key);
        }
      }

      entries.sort((a, b) {
        final pA = userPriorities[a.key] ?? 0;
        final pB = userPriorities[b.key] ?? 0;
        final cmp = pB.compareTo(pA);
        if (cmp != 0) return cmp;

        final idxA = originalIndex[a.key] ?? -1;
        final idxB = originalIndex[b.key] ?? -1;
        return idxB.compareTo(idxA);
      });

      final resultUsernames = entries.map((e) => e.key).toList();

      // user_old (priority 1000) -> user_new (priority 500) -> user_mid (priority 0)
      expect(resultUsernames, ['user_old', 'user_new', 'user_mid']);
    });

    test('Favorite gallery entries sort correctly with priority_updated_at', () {
      final favoriteUsers = {'fav_a', 'fav_b', 'fav_c'};
      final userPriorities = {
        'fav_a': 100, // 最初にピン留め
        'fav_b': 0,   // 未操作
        'fav_c': 300, // 最も新しくピン留め
      };

      final List<TweetItem> items = [
        TweetItem(id: '1', fullText: '@fav_a: tweet', createdAt: '', mediaUrls: ['url1']),
        TweetItem(id: '2', fullText: '@fav_b: tweet', createdAt: '', mediaUrls: ['url2']),
        TweetItem(id: '3', fullText: '@fav_c: tweet', createdAt: '', mediaUrls: ['url3']),
      ];

      final Map<String, List<TweetItem>> grouped = {};
      for (final item in items) {
        final key = item.extractedUsername ?? '_unknown';
        grouped.putIfAbsent(key, () => []).add(item);
      }

      final favList = favoriteUsers.toList();
      final Map<String, int> originalIndex = {};
      for (int i = 0; i < favList.length; i++) {
        originalIndex[favList[i]] = i;
      }

      final List<MapEntry<String, List<TweetItem>>> entries = [];
      for (final username in favList) {
        final userItems = grouped[username];
        if (userItems != null && userItems.isNotEmpty) {
          entries.add(MapEntry(username, userItems));
        }
      }

      entries.sort((a, b) {
        final pA = userPriorities[a.key] ?? 0;
        final pB = userPriorities[b.key] ?? 0;
        final cmp = pB.compareTo(pA);
        if (cmp != 0) return cmp;

        final idxA = originalIndex[a.key] ?? -1;
        final idxB = originalIndex[b.key] ?? -1;
        return idxB.compareTo(idxA);
      });

      final resultUsernames = entries.map((e) => e.key).toList();

      // 最も新しい fav_c (300) -> 次に fav_a (100) -> 未操作 fav_b (0)
      expect(resultUsernames, ['fav_c', 'fav_a', 'fav_b']);
    });
  });
}
