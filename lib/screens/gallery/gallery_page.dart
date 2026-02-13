import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../detail/detail_page.dart';
import '../../services/github_service.dart';

class GalleryPage extends StatefulWidget {
  final List? initialItems; // フィルタ済みデータ用
  final String? title; // 表示タイトル用

  const GalleryPage({super.key, this.initialItems, this.title});

  @override
  State<GalleryPage> createState() => _GalleryPageState();
}

class _GalleryPageState extends State<GalleryPage> {
  bool _isAuthenticated = false;
  List _items = [];
  final ScrollController _gridController = ScrollController();

  @override
  void initState() {
    super.initState();
    if (widget.initialItems != null) {
      // フィルタ済みデータが渡された場合（ユーザー名タップ時）
      _items = widget.initialItems!;
      _isAuthenticated = true;
    } else {
      // 通常起動時
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _showPasswordDialog(),
      );
    }
  }

  // スクロール位置の復元
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

  void _showErrorSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.redAccent),
    );
  }

  // github_service.dart をインポートしておくこと
  final GitHubService _githubService = GitHubService();

  // --- 修正版: 更新処理 (入力・選択・実行を一括で行う) ---
  Future<void> _handleUpdateData() async {
    // 入力用のコントローラー
    final TextEditingController userController = TextEditingController(text: "Yuji20359094");
    final TextEditingController countController = TextEditingController(text: "100");
    String selectedMode = 'all'; // デフォルト

    // 1. 複合入力ダイアログを表示
    bool? proceed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder( // ダイアログ内のドロップダウン更新用
        builder: (context, setDialogState) => AlertDialog(
          title: const Text("Update Gallery Data"),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // ユーザー名入力
                TextField(
                  controller: userController,
                  decoration: const InputDecoration(
                    labelText: "Target X User ID",
                    hintText: "e.g. senbee888",
                    prefixText: "@",
                  ),
                ),
                const SizedBox(height: 16),
                // 件数入力 (数字のみ)
                TextField(
                  controller: countController,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(
                    labelText: "Max Item Count",
                    hintText: "100",
                  ),
                ),
                const SizedBox(height: 16),
                // モード選択 (Dropdown)
                DropdownButtonFormField<String>(
                  value: selectedMode,
                  decoration: const InputDecoration(labelText: "Extraction Mode"),
                  items: const [
                    DropdownMenuItem(value: 'all', child: Text("All (Post & RT)")),
                    DropdownMenuItem(value: 'post_only', child: Text("Post Only")),
                    DropdownMenuItem(value: 'repost_only', child: Text("Repost Only")),
                  ],
                  onChanged: (value) {
                    if (value != null) setDialogState(() => selectedMode = value);
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text("Cancel", style: TextStyle(color: Colors.red)),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text("Run Update"),
            ),
          ],
        ),
      ),
    );

    if (proceed != true) return;

    // 入力値の取得
    String targetUser = userController.text.trim();
    int count = int.tryParse(countController.text) ?? 100;

    // 2. GitHub Actions 実行リクエスト (全パラメータを渡す)
    // ※github_service.dart の triggerWorkflow も引数を増やして対応させてください
    bool triggered = await _githubService.triggerWorkflow(
      count: count,
      user: targetUser,
      mode: selectedMode,
    );

    if (!triggered) {
      _showErrorSnackBar("Failed to trigger update.");
      return;
    }

    // --- (ここから下は監視ロジック: 既存コードを維持) ---
    _showProcessingDialog(count, targetUser, selectedMode);

    // 4. 完了を監視するループ
    String status = "";
    int retryCount = 0;
    // 500件の場合、GitHub Actions側で3〜5分かかる場合があるため、最大120回（20分）監視
    while (status != "completed" && retryCount < 120) {
      try {
        await Future.delayed(const Duration(seconds: 10));
        status = await _githubService.getWorkflowStatus();
        print("Polling... Status: $status (Try $retryCount)");
      } catch (e) {
        print("Network error during polling: $e");
        status = "error"; 
      }
      retryCount++;
    }

    // 5. ダイアログを閉じる
    if (mounted) Navigator.pop(context);

    // 6. 完了後のリロード処理
    if (status == "completed") {
      String? newId = await _githubService.fetchLatestGistId();
      if (newId != null) {
        // --- 修正箇所: 成功ダイアログを表示 ---
        _showSuccessDialog(newId);
        loadJson(newId);
      }
    } else {
      _showErrorSnackBar("Update timed out or failed.");
    }
  }

  // 待機中ダイアログ (見栄えを少し調整)
  void _showProcessingDialog(int count, String user, String mode) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 20),
            const Text("Updating Gallery...", style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text("@$user ($mode)", style: const TextStyle(fontSize: 13)),
            Text("Extracting $count items.", style: const TextStyle(fontSize: 12, color: Colors.grey)),
            const Text("This may take a few minutes.", style: const TextStyle(fontSize: 12, color: Colors.grey)),
          ],
        ),
      ),
    );
  }

// --- 修正版: 視認性を高めた成功ダイアログ ---
  void _showSuccessDialog(String gistId) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.check_circle, color: Colors.green),
            SizedBox(width: 10),
            Text("Update Complete"),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text("Latest Gist ID:"),
            const SizedBox(height: 8),
            Container(
              width: double.infinity, // 横幅いっぱい
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                // 背景をあえて暗くして、文字を浮かび上がらせる
                color: Colors.blueGrey[900], 
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.blueAccent, width: 1),
              ),
              child: SelectableText( // コピーしやすいように SelectableText に変更
                gistId,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                  color: Colors.yellowAccent, // 背景が暗いので黄色系が一番見やすい
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              "Copy this ID to your notepad if needed.",
              style: TextStyle(
                fontSize: 12, 
                color: Theme.of(context).hintColor, // テーマに合わせた薄い色
              ),
            ),
          ],
        ),
        actions: [
          ElevatedButton.icon( // ボタンを目立たせるために ElevatedButton に
            icon: const Icon(Icons.copy),
            label: const Text("Copy ID"),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: gistId));
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text("ID copied to clipboard!"),
                  behavior: SnackBarBehavior.floating,
                ),
              );
            },
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("Close"),
          ),
        ],
      ),
    );
  }
  
  // ダイアログ用の選択肢ウィジェット
  Widget _countOption(BuildContext context, int count, String label) {
    return SimpleDialogOption(
      onPressed: () => Navigator.pop(context, count),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8.0),
        child: Text(label, style: const TextStyle(fontSize: 16)),
      ),
    );
  }

  Future<void> loadJson(String inputKey) async {
    final String url =
        'https://gist.githubusercontent.com/Yuji-HAMADA/$inputKey/raw/gallary_data.json';
    try {
      final response = await http.get(Uri.parse(url));
      if (response.statusCode == 200) {
        final data = json.decode(utf8.decode(response.bodyBytes));
        setState(() {
          _items = data;
          _isAuthenticated = true;
        });
        _restoreScrollPosition();
      } else {
        _showErrorSnackBar("Invalid Password (ID)");
      }
    } catch (e) {
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
          if (canCancel) // キャンセルボタン
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
    // 現在のタイトルからユーザーIDを抽出する判定
    final String currentTitle = widget.title ?? '';

    // --- 判定ロジックの追加 ---
    final bool isUserFilter = currentTitle.contains('@');
    final bool isHashtagFilter = currentTitle.startsWith('#');

    // リンクに使用するキーワードを抽出
    String twitterId = '';
    String hashtagKeyword = '';

    if (isUserFilter) {
      // "User: @name" から "@name" を取り出し、さらに "@" を消して ID だけにする
      twitterId = currentTitle
          .substring(currentTitle.indexOf('@'))
          .replaceFirst('@', '');
    } else if (isHashtagFilter) {
      hashtagKeyword = currentTitle.replaceFirst('#', '');
    }

    // どちらかのフィルタが有効ならリンクボタンを表示
    final bool showLinkButton = isUserFilter || isHashtagFilter;

    return Scaffold(
      appBar: AppBar(
        // タイトルが "#toriki" なら "toriki" と表示、それ以外はそのまま
        title: Text(
          isHashtagFilter ? hashtagKeyword : (widget.title ?? 'ReViewGallery'),
        ),
        actions: [
          // 1. リンクボタン（ユーザー/ハッシュタグ時のみ）
          if (showLinkButton)
            Padding(
              padding: const EdgeInsets.only(right: 8.0),
              child: Center(
                child: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: Colors.blueAccent.withAlpha(200),
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 1.5),
                  ),
                  child: IconButton(
                    padding: EdgeInsets.zero,
                    icon: Icon(
                      isHashtagFilter ? Icons.tag : Icons.alternate_email,
                      size: 20,
                      color: Colors.white,
                    ),
                    onPressed: () {
                      if (isHashtagFilter) {
                        _launchXHashtag(hashtagKeyword);
                      } else {
                        _launchX(twitterId);
                      }
                    },
                  ),
                ),
              ),
            ),

          // 2. 鍵ボタン（メイン画面の時だけ表示、フィルタ中は非表示にしたい場合）
          if (!showLinkButton)
            IconButton(
              icon: const Icon(Icons.vpn_key_outlined),
              tooltip: 'Switch Gist ID',
              onPressed: () => _showPasswordDialog(canCancel: true),
            ),

          // 3. 更新ボタン（常に表示！） ★ここを if/else の外に出す
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Extract & Update Gist',
            onPressed: () => _handleUpdateData(),
          ),
        ],
      ),
      body: !_isAuthenticated
          ? const Center(child: Text("Waiting for authentication..."))
          : (_items.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : _buildGridView()), // ★ グリッドのみ表示
    );
  }

  // ハッシュタグ検索を開く
  Future<void> _launchXHashtag(String keyword) async {
    // 日本語タグなどのためにURLエンコードを行う
    final encodedKeyword = Uri.encodeComponent(keyword);
    final url = Uri.parse('https://x.com/hashtag/$encodedKeyword');
    await _openUrl(url);
  }

  // 既存のプロフィールを開く
  Future<void> _launchX(String twitterId) async {
    final cleanId = twitterId.startsWith('@')
        ? twitterId.replaceFirst('@', '')
        : twitterId;
    final url = Uri.parse('https://x.com/$cleanId');
    await _openUrl(url);
  }

  // 共通のURL起動処理
  Future<void> _openUrl(Uri url) async {
    try {
      if (await canLaunchUrl(url)) {
        await launchUrl(url, mode: LaunchMode.externalApplication);
      } else {
        _showErrorSnackBar("Could not launch X");
      }
    } catch (e) {
      _showErrorSnackBar("Link error: $e");
    }
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

    // ★ 複数画像対応：1枚目を表示
    final List<dynamic> mediaUrls = item['media_urls'] ?? [];
    final String imageUrl = mediaUrls.isNotEmpty
        ? mediaUrls[0]
        : (item['image_url'] ?? item['media_url'] ?? "");

    final String itemId = (item['id'] ?? item['id_str'] ?? index).toString();

    return GestureDetector(
      onTap: () => _navigateToDetail(index),
      // ★ Hero を削除して直接 Container を返す
      child: Container(
        decoration: BoxDecoration(color: Colors.grey[900]),
        child: imageUrl.isNotEmpty
            ? Image.network(
                imageUrl,
                fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) =>
                    _buildErrorWidget(),
              )
            : _buildErrorWidget(),
      ),
    );
  }

  void _navigateToDetail(int index) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => DetailPage(items: _items, initialIndex: index),
      ),
    );
  }

  Widget _buildErrorWidget() {
    return const Center(child: Icon(Icons.broken_image, color: Colors.grey));
  }
}
