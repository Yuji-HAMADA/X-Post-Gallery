import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/tweet_item.dart';
import '../models/user_gist_entry.dart';
import '../utils/env_helper.dart';

const String _externalGithubUsername = String.fromEnvironment('GITHUB_USERNAME');

class GalleryData {
  final String userName;
  final List<TweetItem> items;
  final Map<String, String> userGists; // username -> gist_id
  final Map<String, int> userPriorities; // username -> priority_updated_at
  final Map<String, UserGistEntry> userGistEntries; // username -> UserGistEntry

  const GalleryData({
    required this.userName,
    required this.items,
    this.userGists = const {},
    this.userPriorities = const {},
    this.userGistEntries = const {},
  });
}

class GalleryRepository {
  static const String _keyGistId = 'last_gist_id';
  static const String _keyAdminAuth = 'admin_authenticated';
  static const String _keyScrollIndex = 'grid_last_index';
  static const String _keyCachedData = 'cached_gist_data';
  static const String _keyCachedUpdatedAt = 'cached_updated_at';
  static const String _keyFavoriteUsers = 'favorite_users';
  static const String _keyFavoritesGistId = 'favorites_gist_id';
  static const String _keyUserPriorities = 'user_priorities';

  /// 最後にヒットした Gist ファイル名を記憶（削除時の上書きに使用）
  String? lastGistFilename;

  String get owner => resolveEnv(_externalGithubUsername, 'GITHUB_USERNAME');

  String _gistRawBaseUrl(String gistId) {
    if (owner.isNotEmpty) {
      return 'https://gist.githubusercontent.com/$owner/$gistId/raw/';
    }
    return 'https://gist.githubusercontent.com/raw/$gistId/';
  }

  /// data.json → gallary_data.json フォールバック付きで Gist raw を取得
  Future<http.Response> _fetchGistRaw(String gistId) async {
    final baseUrl = _gistRawBaseUrl(gistId);
    final t = DateTime.now().millisecondsSinceEpoch;
    var response = await http.get(Uri.parse('${baseUrl}data.json?t=$t'));
    if (response.statusCode == 404) {
      response = await http.get(Uri.parse('${baseUrl}gallary_data.json?t=$t'));
    }
    return response;
  }

  /// Gist からギャラリーデータを取得（キャッシュ対応）
  Future<GalleryData> fetchGalleryData(
    String gistId, {
    String? remoteUpdatedAt,
  }) async {
    gistId = gistId.trim(); // 余分な空白を除去

    // キャッシュチェック: remoteUpdatedAt が提供されていて保存済みと一致すれば使う
    // Web版は localStorage のサイズ制限があるためキャッシュをスキップ
    if (!kIsWeb && remoteUpdatedAt != null && remoteUpdatedAt.isNotEmpty) {
      final cachedAt = await getCachedUpdatedAt();
      if (cachedAt == remoteUpdatedAt) {
        final cached = await getCachedData();
        if (cached != null) {
          debugPrint("Using cached data (updated_at: $remoteUpdatedAt)");
          final galleryData = _parseGalleryData(cached);
          return await _mergeLocalPriorities(galleryData);
        }
      }
    }

    final response = await _fetchGistRaw(gistId);

    if (response.statusCode == 200) {
      // レスポンスURLからファイル名を判別
      final filename =
          response.request?.url.pathSegments.last.split('?').first ??
          'data.json';
      lastGistFilename = filename;
      final jsonStr = utf8.decode(response.bodyBytes);
      // キャッシュ保存（Web版はスキップ、保存失敗しても続行）
      if (!kIsWeb && remoteUpdatedAt != null && remoteUpdatedAt.isNotEmpty) {
        try {
          await saveCache(jsonStr, remoteUpdatedAt);
          debugPrint("Cache saved: updatedAt=$remoteUpdatedAt");
        } catch (e) {
          debugPrint("Cache save failed: $e");
        }
      }
      final galleryData = _parseGalleryData(jsonStr);
      return await _mergeLocalPriorities(galleryData);
    } else {
      throw Exception('Invalid Password (ID)');
    }
  }

  /// [JA] ローカル SharedPreferences のピン留め状態をマスターデータとマージする
  Future<GalleryData> _mergeLocalPriorities(GalleryData data) async {
    final localPriorities = await loadUserPriorities();
    if (localPriorities.isEmpty) {
      return data;
    }
    final mergedPriorities = Map<String, int>.from(data.userPriorities);
    final localLowerMap = {
      for (final e in localPriorities.entries) e.key.toLowerCase(): e.value,
    };
    for (final key in data.userGists.keys) {
      final lower = key.toLowerCase();
      if (localLowerMap.containsKey(lower)) {
        mergedPriorities[key] = localLowerMap[lower]!;
      }
    }
    return GalleryData(
      userName: data.userName,
      items: data.items,
      userGists: data.userGists,
      userPriorities: mergedPriorities,
      userGistEntries: data.userGistEntries,
    );
  }

  GalleryData _parseGalleryData(String jsonStr) {
    final data = json.decode(jsonStr);
    final tweets = (data['tweets'] as List? ?? [])
        .map((e) => TweetItem.fromJson(e as Map<String, dynamic>))
        .where((item) => item.mediaUrls.isNotEmpty)
        .toList();
    final userGistsRaw = data['user_gists'] as Map<String, dynamic>? ?? {};
    final Map<String, String> userGists = {};
    final Map<String, int> userPriorities = {};
    final Map<String, UserGistEntry> userGistEntries = {};
    for (final entry in userGistsRaw.entries) {
      final userEntry = UserGistEntry.fromDynamic(entry.value);
      userGists[entry.key] = userEntry.gistId;
      userPriorities[entry.key] = userEntry.priorityUpdatedAt;
      userGistEntries[entry.key] = userEntry;
    }
    return GalleryData(
      userName: data['user_screen_name'] ?? '',
      items: tweets,
      userGists: userGists,
      userPriorities: userPriorities,
      userGistEntries: userGistEntries,
    );
  }

  /// ユーザー別Gistからツイートを取得（階層構造: users -> username -> tweets）
  Future<List<TweetItem>> fetchUserGist(String gistId, String username) async {
    debugPrint('[fetchUserGist] START: username=$username, gistId=$gistId');

    final response = await _fetchGistRaw(gistId);

    if (response.statusCode == 200) {
      final data = json.decode(utf8.decode(response.bodyBytes));

      // 1. 標準の子Gist形式 (users -> username -> tweets)
      final users = data['users'] as Map<String, dynamic>?;
      if (users != null) {
        Map<String, dynamic>? userData;
        if (users.containsKey(username)) {
          userData = users[username] as Map<String, dynamic>?;
        } else {
          final targetLower = username.toLowerCase();
          for (final entry in users.entries) {
            if (entry.key.toLowerCase() == targetLower) {
              userData = entry.value as Map<String, dynamic>?;
              break;
            }
          }
        }

        if (userData != null) {
          return (userData['tweets'] as List? ?? [])
              .map((e) => TweetItem.fromJson(e as Map<String, dynamic>))
              .where((item) => item.mediaUrls.isNotEmpty)
              .toList();
        }
      }

      // 2. フォールバック: 直下に 'tweets' がある形式
      if (data is Map<String, dynamic> && data.containsKey('tweets')) {
        return (data['tweets'] as List? ?? [])
            .map((e) => TweetItem.fromJson(e as Map<String, dynamic>))
            .where((item) => item.mediaUrls.isNotEmpty)
            .toList();
      }

      debugPrint('[fetchUserGist] ERROR: User $username not found in Gist ($gistId)');
      return [];
    }

    throw Exception('Failed to load user gallery ($gistId)');
  }

  /// Gist内の全ユーザーのツイートを結合して返す（キーワード検索用）
  Future<List<TweetItem>> fetchAllGistTweets(String gistId) async {
    final response = await _fetchGistRaw(gistId);

    if (response.statusCode != 200) {
      throw Exception('Failed to load gist ($gistId)');
    }

    final data = json.decode(utf8.decode(response.bodyBytes));
    final List<TweetItem> allTweets = [];

    // multi-user形式: users -> username -> tweets を全結合
    final users = data['users'] as Map<String, dynamic>?;
    if (users != null) {
      for (final userData in users.values) {
        final tweets =
            (userData as Map<String, dynamic>)['tweets'] as List? ?? [];
        allTweets.addAll(
          tweets
              .map((e) => TweetItem.fromJson(e as Map<String, dynamic>))
              .where((item) => item.mediaUrls.isNotEmpty),
        );
      }
    }

    // フォールバック: 直下の tweets
    if (allTweets.isEmpty &&
        data is Map<String, dynamic> &&
        data.containsKey('tweets')) {
      allTweets.addAll(
        (data['tweets'] as List? ?? [])
            .map((e) => TweetItem.fromJson(e as Map<String, dynamic>))
            .where((item) => item.mediaUrls.isNotEmpty),
      );
    }

    return allTweets;
  }

  /// マスターGist用のJSON文字列を構築
  String buildMasterGistJson(
    List<TweetItem> items, {
    String userName = '',
    Map<String, String> userGists = const {},
    Map<String, int> userPriorities = const {},
    Map<String, UserGistEntry> userGistEntries = const {},
  }) {
    // スキーマ統一: user_gists の各アカウントデータに必ず priority_updated_at を持たせる
    final lowerPriorityMap = {
      for (final e in userPriorities.entries) e.key.toLowerCase(): e.value,
    };
    final Map<String, dynamic> formattedUserGists = {};
    for (final entry in userGists.entries) {
      final existingEntry = userGistEntries[entry.key];
      final priority = userPriorities[entry.key] ??
          lowerPriorityMap[entry.key.toLowerCase()] ??
          existingEntry?.priorityUpdatedAt ??
          0;
      final isCandidate = existingEntry?.isCandidate ?? false;
      formattedUserGists[entry.key] = UserGistEntry(
        gistId: entry.value,
        priorityUpdatedAt: priority,
        isCandidate: isCandidate,
      ).toJson();
    }

    return json.encode({
      'user_screen_name': userName,
      if (formattedUserGists.isNotEmpty) 'user_gists': formattedUserGists,
      'tweets': items.map((item) => item.toMasterJson()).toList(),
    });
  }

  /// バッチGist内の対象ユーザーのツイートを更新した全体JSONを返す
  Future<String> buildUserBatchGistJson(
    String gistId,
    String username,
    List<TweetItem> remainingItems, {
    Set<String> deletedIds = const {},
  }) async {
    final baseUrl = _gistRawBaseUrl(gistId);
    final cacheBuster = DateTime.now().millisecondsSinceEpoch;
    final response = await http.get(
      Uri.parse('${baseUrl}data.json?t=$cacheBuster'),
    );
    if (response.statusCode != 200) {
      throw Exception('Failed to fetch batch gist ($gistId)');
    }
    final data =
        json.decode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    final users = (data['users'] as Map<String, dynamic>?) ?? {};
    if (remainingItems.isEmpty) {
      users.remove(username);
    } else {
      users[username] = {
        'tweets': remainingItems.map((item) => item.toJson()).toList(),
      };
    }
    data['users'] = users;

    // deleted_ids に追加（重複排除）
    if (deletedIds.isNotEmpty) {
      final existingDeleted = ((data['deleted_ids'] as List?) ?? [])
          .cast<String>()
          .toSet();
      existingDeleted.addAll(deletedIds);
      data['deleted_ids'] = existingDeleted.toList();
    }

    return json.encode(data);
  }

  // --- SharedPreferences ヘルパー ---

  Future<String?> getSavedGistId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyGistId);
  }

  Future<void> saveGistId(String gistId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyGistId, gistId.trim());
  }

  /// Refresh / Append 共通の管理者認証状態（一度通ったら以降は不要）
  Future<bool> isAdminAuthenticated() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyAdminAuth) ?? false;
  }

  Future<void> setAdminAuthenticated(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyAdminAuth, value);
  }

  Future<String?> getCachedData() async {
    if (kIsWeb) return null;
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyCachedData);
  }

  Future<String?> getCachedUpdatedAt() async {
    if (kIsWeb) return null;
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyCachedUpdatedAt);
  }

  Future<void> saveCache(String jsonData, String updatedAt) async {
    if (kIsWeb) return; // Web版はlocalStorageのサイズ制限のためスキップ
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyCachedData, jsonData);
    await prefs.setString(_keyCachedUpdatedAt, updatedAt);
  }

  Future<void> clearCache() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyCachedData);
    await prefs.remove(_keyCachedUpdatedAt);
  }

  Future<int?> getSavedScrollIndex() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_keyScrollIndex);
  }

  Future<void> saveScrollIndex(int index) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keyScrollIndex, index);
  }

  /// X上にユーザーが存在するか確認（404なら不存在、それ以外は存在とみなす）
  Future<bool> checkUserExistsOnX(String username) async {
    try {
      final response = await http
          .get(Uri.parse('https://x.com/$username'))
          .timeout(const Duration(seconds: 8));
      return response.statusCode != 404;
    } catch (e) {
      debugPrint('X user check error: $e');
      return true; // 確認失敗時は存在すると仮定して進める
    }
  }

  Future<Set<String>> loadFavoriteUsers() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(_keyFavoriteUsers) ?? []).toSet();
  }

  Future<void> saveFavoriteUsers(Set<String> users) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_keyFavoriteUsers, users.toList());
  }

  Future<String?> loadFavoritesGistId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyFavoritesGistId);
  }

  Future<void> saveFavoritesGistId(String gistId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyFavoritesGistId, gistId);
  }

  /// [JA] ローカル SharedPreferences からピン留め（優先度）マップを読み込む
  Future<Map<String, int>> loadUserPriorities() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = prefs.getString(_keyUserPriorities);
    if (jsonStr == null || jsonStr.isEmpty) return {};
    try {
      final decoded = json.decode(jsonStr) as Map<String, dynamic>;
      return decoded.map(
        (k, v) => MapEntry(
          k,
          v is num ? v.toInt() : (int.tryParse(v.toString()) ?? 0),
        ),
      );
    } catch (e) {
      debugPrint('Error loading user priorities from SharedPreferences: $e');
      return {};
    }
  }

  /// [JA] ピン留め（優先度）マップをローカル SharedPreferences に保存する
  Future<void> saveUserPriorities(Map<String, int> priorities) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyUserPriorities, json.encode(priorities));
  }
}
