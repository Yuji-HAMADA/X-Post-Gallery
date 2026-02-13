import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../detail/detail_page.dart';
import '../../services/github_service.dart';
import 'components/update_dialogs.dart';

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
  final ScrollController _gridController = ScrollController();
  final GitHubService _githubService = GitHubService();

  @override
  void initState() {
    super.initState();
    if (widget.initialItems != null) {
      _items = widget.initialItems!;
      _isAuthenticated = true;
    } else {
      // 起動時に保存されたIDをチェック
      _checkSavedGistId();
    }
  }

  // 1. 保存されたIDを確認するメソッド
  Future<void> _checkSavedGistId() async {
    final prefs = await SharedPreferences.getInstance();
    final String? savedId = prefs.getString('last_gist_id');

    if (savedId != null && savedId.isNotEmpty) {
      // 保存されたIDがあれば自動でロード
      loadJson(savedId);
    } else {
      // なければダイアログを表示
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _showPasswordDialog(),
      );
    }
  }

  // 2. IDをSharedPreferencesに保存するメソッド
  Future<void> _saveGistId(String gistId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('last_gist_id', gistId);
  }

  // --- ロジック：データ更新処理 ---
  Future<void> _handleUpdateData() async {
    final config = await UpdateDialogs.showUpdateConfigDialog(context);
    if (config == null) return;

    final String targetUser = config['user'];
    final int count = config['count'];
    final String selectedMode = config['mode'];

    bool triggered = await _githubService.triggerWorkflow(
      count: count,
      user: targetUser,
      mode: selectedMode,
    );

    if (!triggered) {
      _showErrorSnackBar("Failed to trigger update.");
      return;
    }

    UpdateDialogs.showProcessingDialog(
      context, 
      count: count, 
      user: targetUser, 
      mode: selectedMode
    );

    String status = "";
    int retryCount = 0;
    while (status != "completed" && retryCount < 120) {
      try {
        await Future.delayed(const Duration(seconds: 10));
        status = await _githubService.getWorkflowStatus();
        print("Polling... Status: $status (Try $retryCount)");
      } catch (e) {
        status = "error"; 
      }
      retryCount++;
    }

    if (mounted) Navigator.pop(context);

    if (status == "completed") {
      String? newId = await _githubService.fetchLatestGistId();
      if (newId != null) {
        UpdateDialogs.showSuccessDialog(context, newId);
        loadJson(newId);
      }
    } else {
      _showErrorSnackBar("Update timed out or failed.");
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
    final String url =
        'https://gist.githubusercontent.com/Yuji-HAMADA/$inputKey/raw/gallary_data.json';
    try {
      final response = await http.get(Uri.parse(url));
      if (response.statusCode == 200) {
        final data = json.decode(utf8.decode(response.bodyBytes));
        
        // ★ 成功時にIDを保存！
        await _saveGistId(inputKey);

        setState(() {
          _items = data;
          _isAuthenticated = true;
        });
        _restoreScrollPosition();
      } else {
        _showErrorSnackBar("Invalid Password (ID)");
        // 失敗した場合はID入力を再度促す
        _showPasswordDialog(canCancel: true);
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
    final bool showLinkButton = isUserFilter || isHashtagFilter;

    String twitterId = isUserFilter 
        ? currentTitle.substring(currentTitle.indexOf('@')).replaceFirst('@', '') 
        : '';
    String hashtagKeyword = isHashtagFilter ? currentTitle.replaceFirst('#', '') : '';

    return Scaffold(
      appBar: AppBar(
        title: Text(isHashtagFilter ? hashtagKeyword : (widget.title ?? 'X-Post-Gallery')),
        actions: [
          if (showLinkButton)
            IconButton(
              icon: Icon(isHashtagFilter ? Icons.tag : Icons.alternate_email),
              onPressed: () => isHashtagFilter ? _launchXHashtag(hashtagKeyword) : _launchX(twitterId),
            ),
          if (!showLinkButton)
            IconButton(
              icon: const Icon(Icons.vpn_key_outlined),
              onPressed: () => _showPasswordDialog(canCancel: true),
            ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _handleUpdateData,
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
  Future<void> _launchXHashtag(String keyword) async => _openUrl(Uri.parse('https://x.com/hashtag/${Uri.encodeComponent(keyword)}'));
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