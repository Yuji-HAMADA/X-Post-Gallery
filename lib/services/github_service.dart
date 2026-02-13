import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter_dotenv/flutter_dotenv.dart';

// クラスの外で定義し、const をつけるのがポイント
const String _externalToken = String.fromEnvironment('GITHUB_TOKEN');

class GitHubService {
  // Webビルド時のトークンを優先し、無ければ dotenv から取得
  final String token = _externalToken.isNotEmpty 
      ? _externalToken 
      : (dotenv.env['GITHUB_TOKEN'] ?? '');

  final String owner = 'Yuji-HAMADA';
  final String repo = 'review_gallery';
  final String workflowId = 'run.yml';

  // --- 修正箇所: 認証ヘッダーの形式を少し現代的に ---
  Map<String, String> get _headers => {
    'Authorization': 'Bearer $token', // 'token $token' でも動きますが、今は Bearer が推奨
    'Accept': 'application/vnd.github.v3+json',
  };

  Future<bool> triggerWorkflow({
    required int count,
    required String user,
    required String mode,
  }) async {
    // デバッグ用: Webコンソールでトークンが読み込まれているか1文字目だけ確認
    if (token.isEmpty) {
      print("🚨 GitHub Token is empty!");
    } else {
      print("🚀 Triggering workflow with token starting with: ${token.substring(0, 1)}...");
    }

    final url = Uri.parse(
      'https://api.github.com/repos/$owner/$repo/actions/workflows/$workflowId/dispatches',
    );
    
    final response = await http.post(
      url,
      headers: _headers,
      body: jsonEncode({
        'ref': 'main',
        'inputs': {
          'num_reposts': count.toString(),
          'target_user': user,
          'mode': mode,
        },
      }),
    );
    
    return response.statusCode == 204;
  }

  Future<String?> fetchLatestGistId() async {
    final url = Uri.parse('https://api.github.com/users/$owner/gists');
    final response = await http.get(url, headers: _headers);

    if (response.statusCode == 200) {
      List gists = jsonDecode(response.body);
      for (var gist in gists) {
        if (gist['files'].containsKey('gallary_data.json')) {
          return gist['id'];
        }
      }
    }
    return null;
  }

  Future<String> getWorkflowStatus() async {
    final url = Uri.parse(
      'https://api.github.com/repos/$owner/$repo/actions/runs?per_page=1',
    );
    final response = await http.get(url, headers: _headers);

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      if (data['workflow_runs'].isNotEmpty) {
        return data['workflow_runs'][0]['status'];
      }
    }
    return 'unknown';
  }
}