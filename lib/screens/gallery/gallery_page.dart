import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../detail/detail_page.dart';
import '../../services/github_service.dart';

const String _externalPwRefresh = String.fromEnvironment('PW_REFRESH');

class GalleryPage extends StatefulWidget {
  final List? initialItems;
  final String? title;

  const GalleryPage({super.key, this.initialItems, this.title});

  @override
  State<GalleryPage> createState() => _GalleryPageState();
}

class _GalleryPageState extends State<GalleryPage> {
  bool _isAuthenticated = false;
  List _items = [];
  String _currentUserName = ""; // ★ 追加：JSONから取得したユーザー名を保持
  final ScrollController _gridController = ScrollController();
  final GitHubService _githubService = GitHubService();

  @override
  void initState() {
    super.initState();
    if (widget.initialItems != null) {
      _items = widget.initialItems!;
      _isAuthenticated = true;
    } else {
      // ★ URLパラメータと保存されたIDのチェックを開始
      _handleInitialLoad();
    }
  }

  // --- 追加：初期ロードの優先順位制御 ---
  Future<void> _handleInitialLoad() async {
    // 1. URLパラメータ (?id=xxxx) をチェック
    final String? urlId = Uri.base.queryParameters['id'];

    if (urlId != null && urlId.isNotEmpty) {
      debugPrint("URL parameter 'id' found: $urlId");
      await loadJson(urlId);
      return; // URLにIDがあればここで終了
    }

    // 2. SharedPreferences に保存されたIDをチェック
    final prefs = await SharedPreferences.getInstance();
    final String? savedId = prefs.getString('last_gist_id');

    if (savedId != null && savedId.isNotEmpty) {
      debugPrint("Saved ID found in SharedPreferences: $savedId");
      await loadJson(savedId);
    } else {
      // 3. どちらもなければダイアログを表示
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _showPasswordDialog(),
      );
    }
  }

  // IDをSharedPreferencesに保存するメソッド
  Future<void> _saveGistId(String gistId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('last_gist_id', gistId);
  }

  // --- ロジック：データ更新処理 ---
  static const int _defaultRefreshCount = 18;

  Future<bool> _isRefreshAuthenticated() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool('refresh_authenticated') ?? false;
  }

  /// ショートタップ：初回→認証ダイアログ、2回目以降→デフォルト値でrefresh実行
  Future<void> _handleRefreshTap() async {
    if (await _isRefreshAuthenticated()) {
      await _executeRefresh(_defaultRefreshCount);
    } else {
      await _showRefreshAuthDialog();
    }
  }

  /// ロングプレス：初回→認証ダイアログ、2回目以降→画像数指定ダイアログ→refresh実行
  Future<void> _handleRefreshLongPress() async {
    if (await _isRefreshAuthenticated()) {
      final count = await _showCountDialog();
      if (count != null) {
        await _executeRefresh(count);
      }
    } else {
      await _showRefreshAuthDialog();
    }
  }

  /// 初回認証ダイアログ：パスワードとGist IDを入力
  Future<void> _showRefreshAuthDialog() async {
    final pwController = TextEditingController();
    final gistIdController = TextEditingController();

    final result = await showDialog<Map<String, String>>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('認証'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: pwController,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'パスワード',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: gistIdController,
              decoration: const InputDecoration(
                labelText: 'Gist ID',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('キャンセル'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, {
              'password': pwController.text,
              'gistId': gistIdController.text.trim(),
            }),
            child: const Text('OK'),
          ),
        ],
      ),
    );

    if (result == null) return;

    final password = result['password']!;
    final gistId = result['gistId']!;

    // パスワード検証
    final correctPw = _externalPwRefresh.isNotEmpty
        ? _externalPwRefresh
        : (dotenv.env['PW_REFRESH'] ?? '');
    if (password != correctPw) {
      _showErrorSnackBar('パスワードが正しくありません');
      return;
    }

    // Gist ID存在確認
    final gistExists = await _githubService.validateGistExists(gistId);
    if (!gistExists) {
      _showErrorSnackBar('指定されたGist IDが見つかりません');
      return;
    }

    // SharedPreferencesに認証済みとGist IDを記録
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('refresh_authenticated', true);
    await prefs.setString('last_gist_id', gistId);

    // ギャラリーデータをロード
    await loadJson(gistId);

    // 画像数指定ダイアログ → refresh実行
    final count = await _showCountDialog();
    if (count != null) {
      await _executeRefresh(count);
    }
  }

  /// 画像数入力ダイアログ
  Future<int?> _showCountDialog() async {
    final countController = TextEditingController(text: '$_defaultRefreshCount');

    return showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('更新設定'),
        content: TextField(
          controller: countController,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: const InputDecoration(
            labelText: '取得画像数',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('キャンセル'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(
              context,
              int.tryParse(countController.text) ?? _defaultRefreshCount,
            ),
            child: const Text('実行'),
          ),
        ],
      ),
    );
  }

  /// update_mygist.yml をトリガーし、完了までポーリング
  Future<void> _executeRefresh(int count) async {
    final prefs = await SharedPreferences.getInstance();
    final gistId = prefs.getString('last_gist_id') ?? '';

    if (gistId.isEmpty) {
      _showErrorSnackBar('Gist IDが設定されていません');
      return;
    }

    final triggered = await _githubService.triggerUpdateMygistWorkflow(
      gistId: gistId,
      count: count,
    );

    if (!triggered) {
      _showErrorSnackBar('ワークフローの起動に失敗しました');
      return;
    }

    // 処理中ダイアログ
    if (mounted) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 20),
              const Text('ギャラリーを更新中...', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Text('$count 件取得中', style: const TextStyle(fontSize: 12, color: Colors.grey)),
              const Text('数分かかる場合があります', style: TextStyle(fontSize: 12, color: Colors.grey)),
            ],
          ),
        ),
      );
    }

    // ポーリング
    String status = '';
    int retryCount = 0;
    while (status != 'completed' && retryCount < 120) {
      try {
        await Future.delayed(const Duration(seconds: 10));
        status = await _githubService.getWorkflowStatus();
        debugPrint('Polling... Status: $status (Try $retryCount)');
      } catch (e) {
        status = 'error';
      }
      retryCount++;
    }

    if (mounted) Navigator.pop(context);

    if (status == 'completed') {
      await loadJson(gistId);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('更新完了'), backgroundColor: Colors.green),
        );
      }
    } else {
      _showErrorSnackBar('更新がタイムアウトまたは失敗しました');
    }
  }

  // --- ヘルパーメソッド ---
  void _showErrorSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.redAccent),
    );
  }

  void _restoreScrollPosition() async {
    final prefs = await SharedPreferences.getInstance();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      int? index = prefs.getInt('grid_last_index');
      if (index != null && _gridController.hasClients) {
        double position = (index / 3) * (MediaQuery.of(context).size.width / 3);
        _gridController.jumpTo(
          position.clamp(0.0, _gridController.position.maxScrollExtent),
        );
      }
    });
  }

  Future<void> loadJson(String inputKey) async {
    final String baseUrl =
        'https://gist.githubusercontent.com/Yuji-HAMADA/$inputKey/raw/';

    final cacheBuster = DateTime.now().millisecondsSinceEpoch;
    debugPrint("Fetching from: ${baseUrl}data.json?t=$cacheBuster");

    try {
      var response = await http.get(Uri.parse('${baseUrl}data.json?t=$cacheBuster'));
      // data.json が見つからなければ旧ファイル名にフォールバック
      if (response.statusCode == 404) {
        debugPrint("Falling back to gallary_data.json");
        response = await http.get(Uri.parse('${baseUrl}gallary_data.json?t=$cacheBuster'));
      }
      if (response.statusCode == 200) {
        final data = json.decode(utf8.decode(response.bodyBytes));
        
        // ★ 成功時にIDを保存！ (URLパラメータ経由の場合も保存されます)
        await _saveGistId(inputKey);

        if (mounted) {
          setState(() {
            // ★ 修正：新しいJSON構造に合わせて取得先を変更
            _items = data['tweets'] ?? []; 
            _currentUserName = data['user_screen_name'] ?? "";
            _isAuthenticated = true;
          });
          _restoreScrollPosition();
        }
      } else {
        _showErrorSnackBar("Invalid Password (ID)");
        if (mounted) _showPasswordDialog(canCancel: true);
      }
    } catch (e) {
      debugPrint("Load error: $e");
      _showErrorSnackBar("Network error or invalid ID");
    }
  }

  void _showPasswordDialog({bool canCancel = false}) {
    String input = "";
    showDialog(
      context: context,
      barrierDismissible: canCancel,
      builder: (context) => AlertDialog(
        title: const Text("Secret Key Required"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text("Please enter your Secret Gist ID:"),
            const SizedBox(height: 10),
            TextField(
              obscureText: true,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: "Enter ID here",
              ),
              onChanged: (value) => input = value,
              onSubmitted: (value) {
                Navigator.pop(context);
                loadJson(value);
              },
            ),
          ],
        ),
        actions: [
          if (canCancel)
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("Cancel"),
            ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              loadJson(input);
            },
            child: const Text("Unlock"),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final String currentTitle = widget.title ?? '';
    final bool isUserFilter = currentTitle.contains('@');
    final bool isHashtagFilter = currentTitle.startsWith('#');

    // ★ 修正：タイトル決定ロジック
    String displayTitle = 'X-Post-Gallery'; 
    if (isHashtagFilter) {
      displayTitle = currentTitle;
    } else if (_currentUserName.isNotEmpty) {
      displayTitle = '@$_currentUserName'; // Pythonから来た名前を優先
    } else if (widget.title != null) {
      displayTitle = widget.title!;
    }

    // ★ 修正：twitterId の取得先も displayTitle を参考にするよう改善
    String twitterId = displayTitle.startsWith('@') 
        ? displayTitle.replaceFirst('@', '') 
        : (isUserFilter ? currentTitle.substring(currentTitle.indexOf('@')).replaceFirst('@', '') : '');
    
    final bool showLinkButton = isUserFilter || isHashtagFilter || displayTitle.startsWith('@');
    String hashtagKeyword = isHashtagFilter ? currentTitle.replaceFirst('#', '') : '';

    return Scaffold(
      appBar: AppBar(
        title: showLinkButton
            ? GestureDetector(
                onTap: () => isHashtagFilter ? _launchXHashtag(hashtagKeyword) : _launchX(twitterId),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(child: Text(displayTitle, overflow: TextOverflow.ellipsis)),
                    const SizedBox(width: 4),
                    const Icon(Icons.open_in_new, size: 14, color: Colors.grey),
                  ],
                ),
              )
            : Text(displayTitle),
        actions: [
          IconButton(
            icon: const Icon(Icons.vpn_key_outlined),
            onPressed: () => _showPasswordDialog(canCancel: true),
          ),
          
          GestureDetector(
            onTap: _handleRefreshTap,
            onLongPress: _handleRefreshLongPress,
            child: const Padding(
              padding: EdgeInsets.all(8),
              child: Icon(Icons.refresh),
            ),
          ),
        ],
      ),
      body: !_isAuthenticated
          ? const Center(child: Text("Waiting for authentication..."))
          : (_items.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : _buildGridView()),
    );
  }

  Widget _buildGridView() {
    return GridView.builder(
      controller: _gridController,
      padding: const EdgeInsets.all(4),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 4,
        mainAxisSpacing: 4,
      ),
      itemCount: _items.length,
      itemBuilder: (context, index) => _buildGridItem(index),
    );
  }

  Widget _buildGridItem(int index) {
    final item = _items[index];
    final List<dynamic> mediaUrls = item['media_urls'] ?? [];
    final String imageUrl = mediaUrls.isNotEmpty ? mediaUrls[0] : (item['image_url'] ?? "");

    return GestureDetector(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (context) => DetailPage(items: _items, initialIndex: index)),
      ),
      child: Container(
        decoration: BoxDecoration(color: Colors.grey[900]),
        child: imageUrl.isNotEmpty
            ? Image.network(imageUrl, fit: BoxFit.cover, errorBuilder: (c, e, s) => _buildErrorWidget())
            : _buildErrorWidget(),
      ),
    );
  }

  Widget _buildErrorWidget() => const Center(child: Icon(Icons.broken_image, color: Colors.grey));

  // --- 外部連携ロジック ---
  Future<void> _launchXHashtag(String keyword) async => _openUrl(Uri.parse('https://x.com/search?q=${Uri.encodeComponent('#$keyword')}&src=typed_query&f=media'));
  Future<void> _launchX(String twitterId) async => _openUrl(Uri.parse('https://x.com/$twitterId'));
  Future<void> _openUrl(Uri url) async {
    try {
      if (await canLaunchUrl(url)) {
        await launchUrl(url, mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      _showErrorSnackBar("Link error: $e");
    }
  }
}