import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../models/tweet_item.dart';
import '../../viewmodels/gallery_viewmodel.dart';
import '../detail/detail_page.dart';

class GalleryPage extends StatefulWidget {
  final List<TweetItem>? initialItems;
  final String? title;

  const GalleryPage({super.key, this.initialItems, this.title});

  @override
  State<GalleryPage> createState() => _GalleryPageState();
}

class _GalleryPageState extends State<GalleryPage> {
  final ScrollController _gridController = ScrollController();

  @override
  void initState() {
    super.initState();
    if (widget.initialItems != null) {
      // フィルタ済みサブギャラリー：ViewModelには触れず直接表示
    } else {
      _handleInitialLoad();
    }
  }

  Future<void> _handleInitialLoad() async {
    final vm = context.read<GalleryViewModel>();
    final found = await vm.handleInitialLoad();
    if (!found && mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _showPasswordDialog());
    }
    if (found) {
      _restoreScrollPosition();
    }
  }

  void _restoreScrollPosition() async {
    final vm = context.read<GalleryViewModel>();
    final index = await vm.getSavedScrollIndex();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (index != null && _gridController.hasClients) {
        final position = (index / 3) * (MediaQuery.of(context).size.width / 3);
        _gridController.jumpTo(
          position.clamp(0.0, _gridController.position.maxScrollExtent),
        );
      }
    });
  }

  // --- ダイアログ系（BuildContext必要なのでウィジェットに残す） ---

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
                _loadAndRestore(value);
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
              _loadAndRestore(input);
            },
            child: const Text("Unlock"),
          ),
        ],
      ),
    );
  }

  Future<void> _loadAndRestore(String gistId) async {
    final vm = context.read<GalleryViewModel>();
    await vm.loadGallery(gistId);
    if (vm.status == GalleryStatus.error) {
      _showErrorSnackBar(vm.errorMessage);
      if (mounted) _showPasswordDialog(canCancel: true);
    } else {
      _restoreScrollPosition();
    }
  }

  Future<void> _handleRefreshTap() async {
    final vm = context.read<GalleryViewModel>();
    if (await vm.isRefreshAuthenticated()) {
      await _executeRefreshWithDialog(GalleryViewModel.defaultRefreshCount);
    } else {
      await _showRefreshAuthDialog();
    }
  }

  Future<void> _handleRefreshLongPress() async {
    final vm = context.read<GalleryViewModel>();
    if (await vm.isRefreshAuthenticated()) {
      final count = await _showCountDialog();
      if (count != null) {
        await _executeRefreshWithDialog(count);
      }
    } else {
      await _showRefreshAuthDialog();
    }
  }

  Future<void> _showRefreshAuthDialog() async {
    final vm = context.read<GalleryViewModel>();
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

    final success = await vm.authenticateRefresh(
      password: result['password']!,
      gistId: result['gistId']!,
    );

    if (!success) {
      _showErrorSnackBar(vm.errorMessage);
      return;
    }

    final count = await _showCountDialog();
    if (count != null) {
      await _executeRefreshWithDialog(count);
    }
  }

  Future<int?> _showCountDialog() async {
    final countController =
        TextEditingController(text: '${GalleryViewModel.defaultRefreshCount}');

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
              int.tryParse(countController.text) ??
                  GalleryViewModel.defaultRefreshCount,
            ),
            child: const Text('実行'),
          ),
        ],
      ),
    );
  }

  Future<void> _executeRefreshWithDialog(int count) async {
    // 処理中ダイアログを表示
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
              const Text('ギャラリーを更新中...',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Text('$count 件取得中',
                  style: const TextStyle(fontSize: 12, color: Colors.grey)),
              const Text('数分かかる場合があります',
                  style: TextStyle(fontSize: 12, color: Colors.grey)),
            ],
          ),
        ),
      );
    }

    final vm = context.read<GalleryViewModel>();
    await vm.executeRefresh(count);

    if (mounted) Navigator.pop(context); // ダイアログを閉じる

    if (vm.refreshStatus == RefreshStatus.completed) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('更新完了'), backgroundColor: Colors.green),
        );
      }
    } else if (vm.refreshStatus == RefreshStatus.failed) {
      _showErrorSnackBar(vm.errorMessage);
    }
    vm.clearRefreshStatus();
  }

  void _showErrorSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.redAccent),
    );
  }

  // --- 外部連携 ---
  Future<void> _launchXHashtag(String keyword) async => _openUrl(Uri.parse(
      'https://x.com/search?q=${Uri.encodeComponent('#$keyword')}&src=typed_query&f=media'));
  Future<void> _launchX(String twitterId) async =>
      _openUrl(Uri.parse('https://x.com/$twitterId'));
  Future<void> _openUrl(Uri url) async {
    try {
      if (await canLaunchUrl(url)) {
        await launchUrl(url, mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      _showErrorSnackBar("Link error: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    // フィルタ済みサブギャラリーの場合はViewModelを使わない
    if (widget.initialItems != null) {
      return _buildScaffold(
        items: widget.initialItems!,
        userName: '',
        isAuthenticated: true,
      );
    }

    final vm = context.watch<GalleryViewModel>();
    return _buildScaffold(
      items: vm.items,
      userName: vm.userName,
      isAuthenticated: vm.status == GalleryStatus.authenticated,
    );
  }

  Widget _buildScaffold({
    required List<TweetItem> items,
    required String userName,
    required bool isAuthenticated,
  }) {
    final String currentTitle = widget.title ?? '';
    final bool isUserFilter = currentTitle.contains('@');
    final bool isHashtagFilter = currentTitle.startsWith('#');

    String displayTitle = 'X-Post-Gallery';
    if (isHashtagFilter) {
      displayTitle = currentTitle;
    } else if (userName.isNotEmpty) {
      displayTitle = '@$userName';
    } else if (widget.title != null) {
      displayTitle = widget.title!;
    }

    String twitterId = displayTitle.startsWith('@')
        ? displayTitle.replaceFirst('@', '')
        : (isUserFilter
            ? currentTitle
                .substring(currentTitle.indexOf('@'))
                .replaceFirst('@', '')
            : '');

    final bool showLinkButton =
        isUserFilter || isHashtagFilter || displayTitle.startsWith('@');
    String hashtagKeyword =
        isHashtagFilter ? currentTitle.replaceFirst('#', '') : '';

    return Scaffold(
      appBar: AppBar(
        title: showLinkButton
            ? GestureDetector(
                onTap: () => isHashtagFilter
                    ? _launchXHashtag(hashtagKeyword)
                    : _launchX(twitterId),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                        child: Text(displayTitle,
                            overflow: TextOverflow.ellipsis)),
                    const SizedBox(width: 4),
                    const Icon(Icons.open_in_new,
                        size: 14, color: Colors.grey),
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
      body: !isAuthenticated
          ? const Center(child: Text("Waiting for authentication..."))
          : (items.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : _buildGridView(items)),
    );
  }

  Widget _buildGridView(List<TweetItem> items) {
    return GridView.builder(
      controller: _gridController,
      padding: const EdgeInsets.all(4),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 4,
        mainAxisSpacing: 4,
      ),
      itemCount: items.length,
      itemBuilder: (context, index) => _buildGridItem(items, index),
    );
  }

  Widget _buildGridItem(List<TweetItem> items, int index) {
    final item = items[index];
    final String imageUrl = item.thumbnailUrl;

    return GestureDetector(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => DetailPage(
            items: items,
            initialIndex: index,
          ),
        ),
      ),
      child: Container(
        decoration: BoxDecoration(color: Colors.grey[900]),
        child: imageUrl.isNotEmpty
            ? Image.network(imageUrl,
                fit: BoxFit.cover,
                errorBuilder: (c, e, s) => _buildErrorWidget())
            : _buildErrorWidget(),
      ),
    );
  }

  Widget _buildErrorWidget() =>
      const Center(child: Icon(Icons.broken_image, color: Colors.grey));
}
