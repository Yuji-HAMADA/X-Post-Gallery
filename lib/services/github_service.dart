import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../utils/env_helper.dart';

// クラスの外で定義し、const をつけるのがポイント
const String _externalToken = String.fromEnvironment('GITHUB_TOKEN');
const String _externalGithubUsername = String.fromEnvironment(
  'GITHUB_USERNAME',
);
const String _externalFetchQueueGistId = String.fromEnvironment(
  'FETCH_QUEUE_GIST_ID',
);

/// fetch_queue.json の2スロットリングバッファの読み込み結果
class _QueueSlots {
  final Map<String, dynamic> slot0Data;
  final List<Map<String, dynamic>> slot0Users;
  final String? siblingGistId;
  final Map<String, dynamic>? slot1Data;
  final List<Map<String, dynamic>>? slot1Users;

  _QueueSlots({
    required this.slot0Data,
    required this.slot0Users,
    this.siblingGistId,
    this.slot1Data,
    this.slot1Users,
  });

  /// 書き込み先の Gist ID・データ・ユーザーリストを返す
  ({String gistId, Map<String, dynamic> data, List<Map<String, dynamic>> users})
  writeTarget(String primaryGistId) {
    final slot0Status = slot0Data['status'] as String? ?? 'idle';
    final writeToSlot1 =
        slot0Status == 'processing' &&
        siblingGistId != null &&
        siblingGistId!.isNotEmpty;
    return (
      gistId: writeToSlot1 ? siblingGistId! : primaryGistId,
      data: writeToSlot1 ? (slot1Data ?? slot0Data) : slot0Data,
      users: writeToSlot1 ? (slot1Users ?? slot0Users) : slot0Users,
    );
  }
}

class GitHubService {
  // Webビルド時のトークンを優先し、無ければ dotenv から取得
  final String token = resolveEnv(_externalToken, 'GITHUB_TOKEN');
  final String owner = resolveEnv(_externalGithubUsername, 'GITHUB_USERNAME');

  /// キューGist ID
  final String fetchQueueGistId = resolveEnv(
    _externalFetchQueueGistId,
    'FETCH_QUEUE_GIST_ID',
  );

  // ヘッダーをゲッターで定義して、毎回新しいマップを返すようにする
  Map<String, String> get _headers => {
    'Authorization': 'Bearer $token',
    'Accept': 'application/vnd.github.v3+json',
  };

  /// Gist のメタデータ（存在確認 + updated_at）を取得する
  Future<Map<String, dynamic>> fetchGistMetadata(String gistId) async {
    final url = Uri.parse('https://api.github.com/gists/$gistId');
    final response = await http.get(url, headers: _headers);
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      return {'exists': true, 'updatedAt': data['updated_at'] as String?};
    }
    return {'exists': false, 'updatedAt': null};
  }

  /// Gist IDが実際に存在するか検証する
  Future<bool> validateGistExists(String gistId) async {
    final meta = await fetchGistMetadata(gistId);
    return meta['exists'] as bool;
  }

  /// Gist ファイルの内容を更新する
  Future<bool> updateGistFile({
    required String gistId,
    required String filename,
    required String content,
  }) async {
    debugPrint('GitHubService: updateGistFile gistId=$gistId, filename=$filename');
    final url = Uri.parse('https://api.github.com/gists/$gistId');
    final response = await http.patch(
      url,
      headers: _headers,
      body: jsonEncode({
        'files': {
          filename: {'content': content},
        },
      }),
    );
    debugPrint('GitHubService: updateGistFile response status=${response.statusCode}');
    return response.statusCode == 200;
  }

  /// お気に入り用の新規 Gist を作成してIDを返す（secret）
  Future<String?> createGist({
    required String filename,
    required String content,
    required String description,
  }) async {
    final url = Uri.parse('https://api.github.com/gists');
    final response = await http.post(
      url,
      headers: _headers,
      body: jsonEncode({
        'description': description,
        'public': false,
        'files': {
          filename: {'content': content},
        },
      }),
    );
    if (response.statusCode == 201) {
      return (jsonDecode(response.body) as Map<String, dynamic>)['id']
          as String?;
    }
    return null;
  }

  /// Gist から指定ファイルのテキスト内容を取得する
  Future<String?> fetchGistContent(String gistId, String filename) async {
    final url = Uri.parse('https://api.github.com/gists/$gistId');
    final response = await http.get(url, headers: _headers);
    if (response.statusCode != 200) return null;
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final files = body['files'] as Map<String, dynamic>?;
    final fileObj = files?[filename] as Map<String, dynamic>?;
    
    if (fileObj == null) return null;

    final isTruncated = fileObj['truncated'] as bool? ?? false;
    final rawUrl = fileObj['raw_url'] as String?;

    if (isTruncated && rawUrl != null) {
      // truncated されている場合は raw_url から直接取得する
      final rawResponse = await http.get(Uri.parse(rawUrl), headers: _headers);
      if (rawResponse.statusCode == 200) {
        return rawResponse.body;
      }
      return null;
    }

    return fileObj['content'] as String?;
  }

  /// 2スロットリングバッファの読み込み
  Future<_QueueSlots?> _loadQueueSlots() async {
    if (fetchQueueGistId.isEmpty) {
      debugPrint('FETCH_QUEUE_GIST_ID is not set');
      return null;
    }

    final slot0Content = await fetchGistContent(
      fetchQueueGistId,
      'fetch_queue.json',
    );
    if (slot0Content == null) return null;
    final slot0Data = jsonDecode(slot0Content) as Map<String, dynamic>;
    final slot0Users = (slot0Data['users'] as List)
        .cast<Map<String, dynamic>>();

    final siblingGistId = slot0Data['sibling_gist_id'] as String?;
    Map<String, dynamic>? slot1Data;
    List<Map<String, dynamic>>? slot1Users;
    if (siblingGistId != null && siblingGistId.isNotEmpty) {
      final slot1Content = await fetchGistContent(
        siblingGistId,
        'fetch_queue.json',
      );
      if (slot1Content != null) {
        slot1Data = jsonDecode(slot1Content) as Map<String, dynamic>;
        slot1Users = (slot1Data['users'] as List).cast<Map<String, dynamic>>();
      }
    }

    return _QueueSlots(
      slot0Data: slot0Data,
      slot0Users: slot0Users,
      siblingGistId: siblingGistId,
      slot1Data: slot1Data,
      slot1Users: slot1Users,
    );
  }

  /// 両スロットの未処理エントリで重複チェック
  bool _isDuplicateInSlots(_QueueSlots slots, String field, String value) {
    bool check(List<Map<String, dynamic>> users) {
      return users.any(
        (u) =>
            u[field] != null &&
            (u[field] as String).toLowerCase() == value.toLowerCase() &&
            u['done'] != true,
      );
    }

    return check(slots.slot0Users) ||
        (slots.slot1Users != null && check(slots.slot1Users!));
  }

  /// fetch_queue.json にユーザーを追加する（2スロットリングバッファ対応）
  Future<bool> addUserToFetchQueue(
    String username, {
    int? count,
    bool stopOnExisting = true,
    bool fromScratch = false,
  }) async {
    debugPrint('GitHubService: addUserToFetchQueue username=$username');
    final slots = await _loadQueueSlots();
    if (slots == null) {
      debugPrint('GitHubService: addUserToFetchQueue FAILED to load slots');
      return false;
    }

    if (_isDuplicateInSlots(slots, 'user', username)) {
      debugPrint('GitHubService: addUserToFetchQueue DUPLICATE found for $username');
      return true;
    }

    final target = slots.writeTarget(fetchQueueGistId);
    final newEntry = <String, dynamic>{
      'user': username,
      'stop_on_existing': fromScratch ? false : stopOnExisting,
      'from_scratch': fromScratch,
    };
    if (count != null) newEntry['count'] = count;
    target.users.add(newEntry);
    target.data['users'] = target.users;

    debugPrint('GitHubService: addUserToFetchQueue writing to gistId=${target.gistId}');
    return updateGistFile(
      gistId: target.gistId,
      filename: 'fetch_queue.json',
      content: jsonEncode(target.data),
    );
  }

  /// fetch_queue.json からユーザーを削除する（2スロットリングバッファ対応）
  Future<bool> removeUserFromFetchQueue(String username) async {
    debugPrint('GitHubService: removeUserFromFetchQueue username=$username');
    final slots = await _loadQueueSlots();
    if (slots == null) {
      debugPrint('GitHubService: removeUserFromFetchQueue FAILED to load slots');
      return false;
    }

    final targetLower = username.toLowerCase();

    // slot 0 から削除
    final initialCount0 = slots.slot0Users.length;
    slots.slot0Users.removeWhere((u) {
      final uName = (u['user'] as String?)?.toLowerCase();
      return uName == targetLower;
    });
    if (slots.slot0Users.length != initialCount0) {
      slots.slot0Data['users'] = slots.slot0Users;
      await updateGistFile(
        gistId: fetchQueueGistId,
        filename: 'fetch_queue.json',
        content: jsonEncode(slots.slot0Data),
      );
    }

    // slot 1 から削除
    if (slots.slot1Users != null &&
        slots.siblingGistId != null &&
        slots.siblingGistId!.isNotEmpty) {
      final initialCount1 = slots.slot1Users!.length;
      slots.slot1Users!.removeWhere((u) {
        final uName = (u['user'] as String?)?.toLowerCase();
        return uName == targetLower;
      });
      if (slots.slot1Users!.length != initialCount1) {
        slots.slot1Data!['users'] = slots.slot1Users;
        await updateGistFile(
          gistId: slots.siblingGistId!,
          filename: 'fetch_queue.json',
          content: jsonEncode(slots.slot1Data!),
        );
      }
    }

    return true;
  }
}
