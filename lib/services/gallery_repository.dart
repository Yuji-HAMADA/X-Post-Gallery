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
  static const String _keyScrollIndex = 'grid_last_index';

  /// Gist からギャラリーデータを取得
  Future<GalleryData> fetchGalleryData(String gistId) async {
    final String baseUrl =
        'https://gist.githubusercontent.com/Yuji-HAMADA/$gistId/raw/';
    final cacheBuster = DateTime.now().millisecondsSinceEpoch;

    debugPrint("Fetching from: ${baseUrl}data.json?t=$cacheBuster");

    var response =
        await http.get(Uri.parse('${baseUrl}data.json?t=$cacheBuster'));
    if (response.statusCode == 404) {
      debugPrint("Falling back to gallary_data.json");
      response =
          await http.get(Uri.parse('${baseUrl}gallary_data.json?t=$cacheBuster'));
    }

    if (response.statusCode == 200) {
      final data = json.decode(utf8.decode(response.bodyBytes));
      final tweets = (data['tweets'] as List? ?? [])
          .map((e) => TweetItem.fromJson(e as Map<String, dynamic>))
          .toList();
      return GalleryData(
        userName: data['user_screen_name'] ?? '',
        items: tweets,
      );
    } else {
      throw Exception('Invalid Password (ID)');
    }
  }

  // --- SharedPreferences ヘルパー ---

  Future<String?> getSavedGistId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyGistId);
  }

  Future<void> saveGistId(String gistId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyGistId, gistId);
  }

  Future<bool> isRefreshAuthenticated() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyRefreshAuth) ?? false;
  }

  Future<void> setRefreshAuthenticated(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyRefreshAuth, value);
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
