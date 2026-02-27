import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_dotenv/flutter_dotenv.dart';

// クラスの外で定義し、const をつけるのがポイント
const String _externalToken = String.fromEnvironment('GITHUB_TOKEN');
const String _externalGithubUsername = String.fromEnvironment(
  'GITHUB_USERNAME',
);
const String _externalFetchQueueGistId = String.fromEnvironment(
  'FETCH_QUEUE_GIST_ID',
);
class GitHubService {
  // Webビルド時のトークンを優先し、無ければ dotenv から取得
  final String token = _externalToken.isNotEmpty
      ? _externalToken
      : (dotenv.env['GITHUB_TOKEN'] ?? '');

  final String owner = _externalGithubUsername.isNotEmpty
      ? _externalGithubUsername
      : (dotenv.env['GITHUB_USERNAME'] ?? 'Yuji-HAMADA');
  final String repo = 'x-post-gallery';
  final String workflowId = 'run.yml';

  /// キューGist ID
  final String fetchQueueGistId = _externalFetchQueueGistId.isNotEmpty
      ? _externalFetchQueueGistId
      : (dotenv.env['FETCH_QUEUE_GIST_ID'] ?? '');

  // ヘッダーをゲッターで定義して、毎回新しいマップを返すようにする
  Map<String, String> get _headers => {
    'Authorization': 'Bearer $token',
    'Accept': 'application/vnd.github.v3+json',
  };

  /// update_mygist.yml をトリガーする
  Future<bool> triggerUpdateMygistWorkflow({
    required String gistId,
    required int count,
  }) async {
    if (token.isEmpty) {
      debugPrint("GitHub Token is empty!");
    }

    final url = Uri.parse(
      'https://api.github.com/repos/$owner/$repo/actions/workflows/update_mygist.yml/dispatches',
    );

    final response = await http.post(
      url,
      headers: _headers,
      body: jsonEncode({
        'ref': 'main',
        'inputs': {'gist_id': gistId, 'num_posts': count.toString()},
      }),
    );

    return response.statusCode == 204;
  }

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
    return response.statusCode == 200;
  }

  /// append_gist.yml をトリガーする（user と hashtag は排他）
  Future<bool> triggerAppendGistWorkflow({
    required String gistId,
    String? user,
    String? hashtag,
    required int count,
    required bool stopOnExisting,
  }) async {
    if (token.isEmpty) {
      debugPrint("GitHub Token is empty!");
    }

    final url = Uri.parse(
      'https://api.github.com/repos/$owner/$repo/actions/workflows/append_gist.yml/dispatches',
    );

    final response = await http.post(
      url,
      headers: _headers,
      body: jsonEncode({
        'ref': 'main',
        'inputs': {
          'gist_id': gistId,
          'user': user ?? '',
          'hashtag': hashtag ?? '',
          'num_posts': count.toString(),
          'stop_on_existing': stopOnExisting ? 'true' : 'false',
        },
      }),
    );

    return response.statusCode == 204;
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
    final files =
        (jsonDecode(response.body) as Map<String, dynamic>)['files']
            as Map<String, dynamic>?;
    return files?[filename]?['content'] as String?;
  }

  /// fetch_queue.json にユーザーを追加する（2スロットリングバッファ対応）
  /// スロット0が processing ならスロット1に、それ以外はスロット0に書き込む。
  /// 重複チェックは両スロットの未処理エントリに対して行う。
  Future<bool> addUserToFetchQueue(
    String username, {
    int? count,
    bool stopOnExisting = true,
  }) async {
    if (fetchQueueGistId.isEmpty) {
      debugPrint('FETCH_QUEUE_GIST_ID is not set');
      return false;
    }

    // スロット0を読み込み
    final slot0Content =
        await fetchGistContent(fetchQueueGistId, 'fetch_queue.json');
    if (slot0Content == null) return false;
    final slot0Data = jsonDecode(slot0Content) as Map<String, dynamic>;
    final slot0Users =
        (slot0Data['users'] as List).cast<Map<String, dynamic>>();

    // スロット1を読み込み（sibling_gist_id がある場合）
    final siblingGistId = slot0Data['sibling_gist_id'] as String?;
    Map<String, dynamic>? slot1Data;
    List<Map<String, dynamic>>? slot1Users;
    if (siblingGistId != null && siblingGistId.isNotEmpty) {
      final slot1Content =
          await fetchGistContent(siblingGistId, 'fetch_queue.json');
      if (slot1Content != null) {
        slot1Data = jsonDecode(slot1Content) as Map<String, dynamic>;
        slot1Users =
            (slot1Data['users'] as List).cast<Map<String, dynamic>>();
      }
    }

    // 両スロットの未処理エントリで重複チェック
    bool isDuplicate(List<Map<String, dynamic>> users) {
      return users.any(
        (u) =>
            (u['user'] as String).toLowerCase() == username.toLowerCase() &&
            u['done'] != true,
      );
    }
    if (isDuplicate(slot0Users) ||
        (slot1Users != null && isDuplicate(slot1Users))) {
      return true; // 既にキューに存在
    }

    // 書き込み先の決定: スロット0が processing ならスロット1に書き込み
    final slot0Status = slot0Data['status'] as String? ?? 'idle';
    final bool writeToSlot1 =
        slot0Status == 'processing' &&
        siblingGistId != null &&
        siblingGistId.isNotEmpty;

    final targetGistId = writeToSlot1 ? siblingGistId : fetchQueueGistId;
    final targetData = writeToSlot1 ? (slot1Data ?? slot0Data) : slot0Data;
    final targetUsers = writeToSlot1 ? (slot1Users ?? slot0Users) : slot0Users;

    // 新しいエントリを追加
    final newEntry = <String, dynamic>{
      'user': username,
      'stop_on_existing': stopOnExisting,
    };
    if (count != null) newEntry['count'] = count;
    targetUsers.add(newEntry);
    targetData['users'] = targetUsers;

    return updateGistFile(
      gistId: targetGistId,
      filename: 'fetch_queue.json',
      content: jsonEncode(targetData),
    );
  }

  /// scheduled_fetch.yml をトリガーする
  Future<bool> triggerScheduledFetchWorkflow() async {
    final url = Uri.parse(
      'https://api.github.com/repos/$owner/$repo/actions/workflows/scheduled_fetch.yml/dispatches',
    );
    final response = await http.post(
      url,
      headers: _headers,
      body: jsonEncode({'ref': 'main'}),
    );
    return response.statusCode == 204;
  }

  /// 指定ワークフローの最新ランの status / conclusion / created_at を返す
  Future<Map<String, String>> getWorkflowRunInfo(String workflowFile) async {
    final url = Uri.parse(
      'https://api.github.com/repos/$owner/$repo/actions/workflows/$workflowFile/runs?per_page=1',
    );
    final response = await http.get(url, headers: _headers);
    if (response.statusCode == 200) {
      final runs = (jsonDecode(response.body)['workflow_runs'] as List?) ?? [];
      if (runs.isNotEmpty) {
        final run = runs[0] as Map<String, dynamic>;
        return {
          'status': run['status'] as String? ?? '',
          'conclusion': run['conclusion'] as String? ?? '',
          'createdAt': run['created_at'] as String? ?? '',
        };
      }
    }
    return {};
  }

}
