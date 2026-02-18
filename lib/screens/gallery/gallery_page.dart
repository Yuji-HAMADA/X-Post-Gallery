import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../models/tweet_item.dart';
import '../../viewmodels/gallery_viewmodel.dart';
import '../detail/detail_page.dart';
import '../stats/stats_page.dart';

class GalleryPage extends StatefulWidget {
  final List<TweetItem>? initialItems;
  final String? title;

  const GalleryPage({super.key, this.initialItems, this.title});

  @override
  State<GalleryPage> createState() => _GalleryPageState();
}

class _GalleryPageState extends State<GalleryPage> {
  final ScrollController _gridController = ScrollController();
  List<TweetItem>? _localItems; // Append後の再フィルタ結果を保持

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
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _showPasswordDialog(),
      );
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

  Future<void> _handleRefresh() async {
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
    final countController = TextEditingController(
      text: '${GalleryViewModel.defaultRefreshCount}',
    );

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

  // --- Append 関連 ---

  Future<void> _handleAppend({String? user, String? hashtag}) async {
    final vm = context.read<GalleryViewModel>();
    final config = await _showAppendConfigDialog();
    if (config == null) return;

    if (!await vm.isAppendAuthenticated()) {
      final authed = await _showAppendAuthDialog();
      if (!authed) return;
    }

    await _executeAppendWithDialog(
      user: user,
      hashtag: hashtag,
      mode: config['mode'] as String,
      count: config['count'] as int,
      stopOnExisting: config['stopOnExisting'] as bool,
    );
  }

  Future<Map<String, dynamic>?> _showAppendConfigDialog() async {
    final countController = TextEditingController(text: '100');
    bool stopOnExisting = true;

    return showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('追加設定'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('重複ポストの処理', style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                RadioGroup<bool>(
                  groupValue: stopOnExisting,
                  onChanged: (v) => setDialogState(() => stopOnExisting = v!),
                  child: Column(
                    children: [
                      RadioListTile<bool>(
                        value: true,
                        title: const Text('ストップオンモード'),
                        subtitle: const Text('既存IDに当たったら停止'),
                        contentPadding: EdgeInsets.zero,
                      ),
                      RadioListTile<bool>(
                        value: false,
                        title: const Text('スキップモード'),
                        subtitle: const Text('既存IDをスキップして続行'),
                        contentPadding: EdgeInsets.zero,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: countController,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(
                    labelText: '取得件数',
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('キャンセル'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, {
                'mode': 'post_only',
                'count': int.tryParse(countController.text) ?? 100,
                'stopOnExisting': stopOnExisting,
              }),
              child: const Text('実行'),
            ),
          ],
        ),
      ),
    );
  }

  Future<bool> _showAppendAuthDialog() async {
    final vm = context.read<GalleryViewModel>();
    final pwController = TextEditingController();

    final result = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('認証'),
        content: TextField(
          controller: pwController,
          obscureText: true,
          decoration: const InputDecoration(
            labelText: 'パスワード',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (_) => Navigator.pop(context, pwController.text),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('キャンセル'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, pwController.text),
            child: const Text('OK'),
          ),
        ],
      ),
    );

    if (result == null) return false;

    final success = await vm.authenticateAppend(password: result);
    if (!success) {
      _showErrorSnackBar(vm.errorMessage);
    }
    return success;
  }

  Future<void> _executeAppendWithDialog({
    String? user,
    String? hashtag,
    required String mode,
    required int count,
    required bool stopOnExisting,
  }) async {
    final targetLabel = user != null ? '@$user' : '#$hashtag';
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
              const Text('追加中...', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Text('$targetLabel / $count 件', style: const TextStyle(fontSize: 12, color: Colors.grey)),
              Text(
                stopOnExisting ? 'ストップオンモード' : 'スキップモード',
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
              const Text('数分かかる場合があります', style: TextStyle(fontSize: 12, color: Colors.grey)),
            ],
          ),
        ),
      );
    }

    final vm = context.read<GalleryViewModel>();
    await vm.executeAppend(
      user: user,
      hashtag: hashtag,
      mode: mode,
      count: count,
      stopOnExisting: stopOnExisting,
    );

    if (mounted) Navigator.pop(context);

    if (vm.appendStatus == AppendStatus.completed) {
      _refilterLocalItems(vm); // 画面遷移なしで追加後の状態に更新
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('追加完了'), backgroundColor: Colors.green),
        );
      }
    } else if (vm.appendStatus == AppendStatus.failed) {
      _showErrorSnackBar(vm.errorMessage);
    }
    vm.clearAppendStatus();
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
              const Text(
                'ギャラリーを更新中...',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(
                '$count 件取得中',
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
              const Text(
                '数分かかる場合があります',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
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

  Future<void> _showDeleteConfirmDialog() async {
    final vm = context.read<GalleryViewModel>();
    final count = vm.selectedCount;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('削除確認'),
        content: Text('$count 件の画像を削除しますか？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('キャンセル'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('削除'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    // 処理中インジケータ
    if (mounted) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => const AlertDialog(
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('削除中...'),
            ],
          ),
        ),
      );
    }

    final success = await vm.deleteSelected();

    if (mounted) Navigator.pop(context); // 処理中ダイアログを閉じる

    if (success) {
      _refilterLocalItems(vm); // サブギャラリーの表示をGist削除後の状態に更新
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('$count 件を削除しました'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } else {
      _showErrorSnackBar(vm.errorMessage);
    }
  }

  /// vm.items をタイトルのフィルタ条件で絞り込み _localItems を更新する
  void _refilterLocalItems(GalleryViewModel vm) {
    if (widget.initialItems == null) return;
    final currentTitle = widget.title ?? '';
    final isUserFilter = currentTitle.contains('@');
    final isHashtagFilter = currentTitle.startsWith('#');

    List<TweetItem> filtered;
    if (isUserFilter) {
      final twitterId = currentTitle.startsWith('@')
          ? currentTitle.replaceFirst('@', '')
          : currentTitle.substring(currentTitle.indexOf('@')).replaceFirst('@', '');
      final userTag = '@$twitterId';
      final pattern = RegExp(r'@([a-zA-Z0-9_]+)');
      filtered = vm.items.where((item) {
        return pattern.allMatches(item.fullText).any(
          (m) => m.group(0)!.toLowerCase() == userTag.toLowerCase(),
        );
      }).toList();
    } else if (isHashtagFilter) {
      final hashtagKeyword = currentTitle.replaceFirst('#', '');
      final hashTag = '#$hashtagKeyword';
      final pattern = RegExp(r'#[^\s#]+');
      filtered = vm.items.where((item) {
        return pattern.allMatches(item.fullText).any(
          (m) => m.group(0)!.toLowerCase() == hashTag.toLowerCase(),
        );
      }).toList();
    } else {
      filtered = vm.items;
    }
    setState(() => _localItems = filtered);
  }

  void _showErrorSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.redAccent),
    );
  }

  // --- 外部連携 ---
  Future<void> _launchXHashtag(String keyword) async => _openUrl(
    Uri.parse(
      'https://x.com/search?q=${Uri.encodeComponent('#$keyword')}&src=typed_query&f=media',
    ),
  );
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
    final vm = context.watch<GalleryViewModel>();

    // フィルタ済みサブギャラリー：アイテムは静的リスト（Append後は _localItems）
    // 選択・削除状態は ViewModel を共有する
    if (widget.initialItems != null) {
      return _buildScaffold(
        items: _localItems ?? widget.initialItems!,
        userName: '',
        isAuthenticated: true,
        isSelectionMode: vm.isSelectionMode,
        selectedIds: vm.selectedIds,
      );
    }

    return _buildScaffold(
      items: vm.items,
      userName: vm.userName,
      isAuthenticated: vm.status == GalleryStatus.authenticated,
      isSelectionMode: vm.isSelectionMode,
      selectedIds: vm.selectedIds,
    );
  }

  Widget _buildScaffold({
    required List<TweetItem> items,
    required String userName,
    required bool isAuthenticated,
    required bool isSelectionMode,
    required Set<String> selectedIds,
  }) {
    final String currentTitle = widget.title ?? '';
    final bool isUserFilter = currentTitle.contains('@');
    final bool isHashtagFilter = currentTitle.startsWith('#');

    String displayTitle = 'PostGallery';
    if (isHashtagFilter) {
      displayTitle = currentTitle;
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
    String hashtagKeyword = isHashtagFilter
        ? currentTitle.replaceFirst('#', '')
        : '';

    return Scaffold(
      appBar: AppBar(
        leading: isSelectionMode
            ? IconButton(
                icon: const Icon(Icons.close),
                onPressed: () =>
                    context.read<GalleryViewModel>().clearSelection(),
              )
            : null,
        title: isSelectionMode
            ? Text('${selectedIds.length}件選択中')
            : (showLinkButton
                  ? GestureDetector(
                      onTap: () => isHashtagFilter
                          ? _launchXHashtag(hashtagKeyword)
                          : _launchX(twitterId),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: Text(
                              displayTitle,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 4),
                          const Icon(
                            Icons.open_in_new,
                            size: 14,
                            color: Colors.grey,
                          ),
                        ],
                      ),
                    )
                  : Text(displayTitle)),
        actions: [
          if (isSelectionMode)
            IconButton(
              icon: const Icon(Icons.delete, color: Colors.redAccent),
              onPressed: _showDeleteConfirmDialog,
            )
          else if (isUserFilter || isHashtagFilter) ...[
            // ユーザー／ハッシュタグフィルター画面: 追加ボタンのみ
            IconButton(
              icon: const Icon(Icons.add),
              tooltip: '追加',
              onPressed: () => _handleAppend(
                user: isUserFilter ? twitterId : null,
                hashtag: isHashtagFilter ? hashtagKeyword : null,
              ),
            ),
          ] else ...[
            // 通常画面: リスト統計 + ハンバーガーメニュー
            if (items.isNotEmpty)
              IconButton(
                icon: const Icon(Icons.format_list_numbered),
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => StatsPage(items: items),
                    ),
                  );
                },
              ),
            PopupMenuButton<String>(
              icon: const Icon(Icons.menu),
              onSelected: (value) {
                switch (value) {
                  case 'key':
                    _showPasswordDialog(canCancel: true);
                  case 'refresh':
                    _handleRefresh();
                }
              },
              itemBuilder: (context) => [
                const PopupMenuItem(
                  value: 'key',
                  child: ListTile(
                    leading: Icon(Icons.vpn_key_outlined),
                    title: Text('Gist ID'),
                    dense: true,
                  ),
                ),
                const PopupMenuItem(
                  value: 'refresh',
                  child: ListTile(
                    leading: Icon(Icons.refresh),
                    title: Text('更新'),
                    dense: true,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
      body: !isAuthenticated
          ? const Center(child: Text("Waiting for authentication..."))
          : (items.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : _buildGridView(items, selectedIds)),
    );
  }

  Widget _buildGridView(List<TweetItem> items, Set<String> selectedIds) {
    return GridView.builder(
      controller: _gridController,
      padding: const EdgeInsets.all(4),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 4,
        mainAxisSpacing: 4,
      ),
      itemCount: items.length,
      itemBuilder: (context, index) =>
          _buildGridItem(items, index, selectedIds),
    );
  }

  Widget _buildGridItem(
    List<TweetItem> items,
    int index,
    Set<String> selectedIds,
  ) {
    final item = items[index];
    final String imageUrl = item.thumbnailUrl;
    final bool isSelected = selectedIds.contains(item.id);
    final bool isSelectionMode = selectedIds.isNotEmpty;

    return GestureDetector(
      onTap: () {
        if (isSelectionMode) {
          context.read<GalleryViewModel>().toggleSelection(item.id);
        } else {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) =>
                  DetailPage(items: items, initialIndex: index),
            ),
          );
        }
      },
      onLongPress: () {
        context.read<GalleryViewModel>().toggleSelection(item.id);
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          Container(
            decoration: BoxDecoration(color: Colors.grey[900]),
            child: imageUrl.isNotEmpty
                ? Image.network(
                    imageUrl,
                    fit: BoxFit.cover,
                    alignment: Alignment.topCenter,
                    errorBuilder: (c, e, s) => _buildErrorWidget(),
                  )
                : _buildErrorWidget(),
          ),
          if (isSelected)
            Container(
              color: Colors.blue.withValues(alpha: 0.4),
              child: const Align(
                alignment: Alignment.topRight,
                child: Padding(
                  padding: EdgeInsets.all(4),
                  child: Icon(
                    Icons.check_circle,
                    color: Colors.white,
                    size: 24,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildErrorWidget() =>
      const Center(child: Icon(Icons.broken_image, color: Colors.grey));
}
