import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/tweet_item.dart';

class GalleryData {
  final String userName;
  final List<TweetItem> items;
  final Map<String, String> userGists; // username -> gist_id

  const GalleryData({
    required this.userName,
    required this.items,
    this.userGists = const {},
  });
}

class GalleryRepository {
  static const String _keyGistId = 'last_gist_id';
  static const String _keyAdminAuth = 'admin_authenticated';
  static const String _keyScrollIndex = 'grid_last_index';
  static const String _keyCachedData = 'cached_gist_data';
  static const String _keyCachedUpdatedAt = 'cached_updated_at';

  /// 最後にヒットした Gist ファイル名を記憶（削除時の上書きに使用）
  String? lastGistFilename;

  String _gistRawBaseUrl(String gistId) =>
      'https://gist.githubusercontent.com/Yuji-HAMADA/$gistId/raw/';

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
          return _parseGalleryData(cached);
        }
      }
    }

    final baseUrl = _gistRawBaseUrl(gistId);
    final cacheBuster = DateTime.now().millisecondsSinceEpoch;

    debugPrint("Fetching from: ${baseUrl}data.json?t=$cacheBuster");

    var response = await http.get(
      Uri.parse('${baseUrl}data.json?t=$cacheBuster'),
    );
    String filename = 'data.json';
    if (response.statusCode == 404) {
      debugPrint("Falling back to gallary_data.json");
      response = await http.get(
        Uri.parse('${baseUrl}gallary_data.json?t=$cacheBuster'),
      );
      filename = 'gallary_data.json';
    }

    if (response.statusCode == 200) {
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
      return _parseGalleryData(jsonStr);
    } else {
      throw Exception('Invalid Password (ID)');
    }
  }

  GalleryData _parseGalleryData(String jsonStr) {
    final data = json.decode(jsonStr);
    final tweets = (data['tweets'] as List? ?? [])
        .map((e) => TweetItem.fromJson(e as Map<String, dynamic>))
        .toList();
    final userGistsRaw = data['user_gists'] as Map<String, dynamic>? ?? {};
    final userGists = userGistsRaw.map((k, v) => MapEntry(k, v.toString()));
    return GalleryData(
      userName: data['user_screen_name'] ?? '',
      items: tweets,
      userGists: userGists,
    );
  }

  /// ユーザー別Gistからツイートを取得（階層構造: users -> username -> tweets）
  Future<List<TweetItem>> fetchUserGist(String gistId, String username) async {
    debugPrint('[fetchUserGist] START: username=$username, gistId=$gistId');

    final baseUrl = _gistRawBaseUrl(gistId);
    final cacheBuster = DateTime.now().millisecondsSinceEpoch;

    var url = '${baseUrl}data.json?t=$cacheBuster';
    var response = await http.get(Uri.parse(url));

    if (response.statusCode == 404) {
      url = '${baseUrl}gallary_data.json?t=$cacheBuster';
      response = await http.get(Uri.parse(url));
    }

    if (response.statusCode == 200) {
      final data = json.decode(utf8.decode(response.bodyBytes));

      // 1. 標準の子Gist形式 (users -> username -> tweets)
      final users = data['users'] as Map<String, dynamic>?;
      if (users != null && users.containsKey(username)) {
        final userData = users[username] as Map<String, dynamic>;
        return (userData['tweets'] as List? ?? [])
            .map((e) => TweetItem.fromJson(e as Map<String, dynamic>))
            .toList();
      }

      // 2. フォールバック: 直下に 'tweets' がある形式
      if (data is Map<String, dynamic> && data.containsKey('tweets')) {
        return (data['tweets'] as List? ?? [])
            .map((e) => TweetItem.fromJson(e as Map<String, dynamic>))
            .toList();
      }

      debugPrint('[fetchUserGist] ERROR: User not found in Gist');
      return [];
    }

    throw Exception('Failed to load user gallery ($gistId)');
  }

  /// 更新用の JSON 文字列を構築（マスターGist用）
  String buildGistJson(
    String userName,
    List<TweetItem> items, {
    Map<String, String> userGists = const {},
  }) {
    return json.encode({
      'user_screen_name': userName,
      if (userGists.isNotEmpty) 'user_gists': userGists,
      'tweets': items.map((item) => item.toJson()).toList(),
    });
  }

  /// バッチGist内の対象ユーザーのツイートを更新した全体JSONを返す
  Future<String> buildUserBatchGistJson(
    String gistId,
    String username,
    List<TweetItem> remainingItems,
  ) async {
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
    users[username] = {
      'tweets': remainingItems.map((item) => item.toJson()).toList(),
    };
    data['users'] = users;
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
}
