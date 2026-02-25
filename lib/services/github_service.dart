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

  /// キューGistにユーザーを追加する
  Future<bool> addUserToFetchQueue(String username, {int? count}) async {
    if (fetchQueueGistId.isEmpty) {
      debugPrint('FETCH_QUEUE_GIST_ID is not set');
      return false;
    }

    final content = await fetchGistContent(
      fetchQueueGistId,
      'fetch_queue.json',
    );
    if (content == null) return false;

    final data = jsonDecode(content) as Map<String, dynamic>;
    final users = (data['users'] as List).cast<Map<String, dynamic>>();

    // 重複チェック
    final alreadyExists = users.any(
      (u) => (u['user'] as String).toLowerCase() == username.toLowerCase(),
    );
    if (alreadyExists) return true; // 既に存在

    // 末尾に追加
    final newEntry = <String, dynamic>{'user': username};
    if (count != null) newEntry['count'] = count;
    users.add(newEntry);
    data['users'] = users;

    return updateGistFile(
      gistId: fetchQueueGistId,
      filename: 'fetch_queue.json',
      content: jsonEncode(data),
    );
  }
}
