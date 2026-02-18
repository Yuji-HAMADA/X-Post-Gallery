import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/tweet_item.dart';

class GalleryData {
  final String userName;
  final List<TweetItem> items;

  const GalleryData({required this.userName, required this.items});
}

class GalleryRepository {
  static const String _keyGistId = 'last_gist_id';
  static const String _keyRefreshAuth = 'refresh_authenticated';
  static const String _keyAppendAuth = 'append_authenticated';
  static const String _keyScrollIndex = 'grid_last_index';
  static const String _keyCachedData = 'cached_gist_data';
  static const String _keyCachedUpdatedAt = 'cached_updated_at';

  /// 最後にヒットした Gist ファイル名を記憶（削除時の上書きに使用）
  String? lastGistFilename;

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

    final String baseUrl =
        'https://gist.githubusercontent.com/Yuji-HAMADA/$gistId/raw/';
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
    return GalleryData(
      userName: data['user_screen_name'] ?? '',
      items: tweets,
    );
  }

  /// 更新用の JSON 文字列を構築
  String buildGistJson(String userName, List<TweetItem> items) {
    final tweets = items
        .map(
          (item) => {
            'full_text': item.fullText,
            'created_at': item.createdAt,
            'media_urls': item.mediaUrls,
            'id_str': item.id,
            if (item.postUrl != null) 'post_url': item.postUrl,
          },
        )
        .toList();

    return json.encode({'user_screen_name': userName, 'tweets': tweets});
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

  Future<bool> isRefreshAuthenticated() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyRefreshAuth) ?? false;
  }

  Future<void> setRefreshAuthenticated(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyRefreshAuth, value);
  }

  Future<bool> isAppendAuthenticated() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyAppendAuth) ?? false;
  }

  Future<void> setAppendAuthenticated(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyAppendAuth, value);
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
