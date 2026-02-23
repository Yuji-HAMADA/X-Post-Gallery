import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../models/tweet_item.dart';
import '../../viewmodels/gallery_viewmodel.dart';
import '../detail/detail_page.dart';
import '../stats/stats_page.dart';
import 'components/user_id_input_dialog.dart';

class GalleryPage extends StatefulWidget {
  final List<TweetItem>? initialItems;
  final String? title;

  /// ユーザーGistから開いた場合のGist ID（Append/Delete時に使用）
  final String? userGistId;

  /// ユーザーGistから開いた場合のユーザー名（Append/Delete時に使用）
  final String? userGistUsername;

  const GalleryPage({
    super.key,
    this.initialItems,
    this.title,
    this.userGistId,
    this.userGistUsername,
  });

  @override
  State<GalleryPage> createState() => _GalleryPageState();
}

class _GalleryPageState extends State<GalleryPage> {
  final ScrollController _gridController = ScrollController();
  final ScrollController _favGridController = ScrollController();
  final PageController _pageController = PageController();
  int _currentPage = 0;
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

  @override
  void dispose() {
    _pageController.dispose();
    _favGridController.dispose();
    super.dispose();
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
    String gistIdInput = "";
    String passwordInput = "";

    void handleUnlock() {
      Navigator.pop(context);
      final vm = context.read<GalleryViewModel>();

      if (passwordInput.isNotEmpty && vm.checkAdminPassword(passwordInput)) {
        final defaultId = vm.defaultMasterGistId;
        if (defaultId.isNotEmpty) {
          _loadAndRestore(defaultId);
          return;
        } else {
          _showErrorSnackBar('デフォルトのマスターGistIDが設定されていません');
        }
      }

      if (gistIdInput.isNotEmpty) {
        _loadAndRestore(gistIdInput);
      } else {
        _showErrorSnackBar('Gist IDまたは正しいパスワードを入力してください');
        if (mounted) _showPasswordDialog(canCancel: canCancel);
      }
    }

    showDialog(
      context: context,
      barrierDismissible: canCancel,
      builder: (context) => AlertDialog(
        title: const Text("Unlock Gallery"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text("Gist IDを入力するか、パスワードを入力してください:"),
            const SizedBox(height: 10),
            TextField(
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: "Gist ID",
              ),
              onChanged: (value) => gistIdInput = value,
            ),
            const SizedBox(height: 10),
            TextField(
              obscureText: true,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: "Password",
              ),
              onChanged: (value) => passwordInput = value,
              onSubmitted: (_) => handleUnlock(),
            ),
          ],
        ),
        actions: [
          if (canCancel)
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("Cancel"),
            ),
          TextButton(onPressed: handleUnlock, child: const Text("Unlock")),
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

  /// パスワード入力ダイアログ（Refresh / Append 共通）
  Future<String?> _showPasswordInputDialog(String title) async {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          obscureText: true,
          decoration: const InputDecoration(
            labelText: 'パスワード',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (_) => Navigator.pop(context, controller.text),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('キャンセル'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<void> _handleRefresh() async {
    final vm = context.read<GalleryViewModel>();
    if (await vm.isAdminAuthenticated()) {
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

    final result = await _showPasswordInputDialog('認証');
    if (result == null || result.isEmpty) return;

    final masterId = vm.defaultMasterGistId;
    if (masterId.isEmpty) {
      _showErrorSnackBar('マスターGist IDが設定されていません');
      return;
    }

    final success = await vm.authenticateRefresh(
      password: result,
      gistId: masterId,
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

    if (!await vm.isAdminAuthenticated()) {
      final result = await _showPasswordInputDialog('認証');
      if (result == null) return;
      final success = await vm.authenticateAdmin(password: result);
      if (!success) {
        if (mounted) _showErrorSnackBar(vm.errorMessage);
        return;
      }
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
    String mode = 'post_only';

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
                const Text('モード', style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                RadioGroup<String>(
                  groupValue: mode,
                  onChanged: (v) => setDialogState(() => mode = v!),
                  child: Column(
                    children: [
                      RadioListTile<String>(
                        value: 'post_only',
                        title: const Text('投稿のみ'),
                        subtitle: const Text('リポストを除外'),
                        contentPadding: EdgeInsets.zero,
                      ),
                      RadioListTile<String>(
                        value: 'all',
                        title: const Text('すべて'),
                        subtitle: const Text('リポストを含む'),
                        contentPadding: EdgeInsets.zero,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  '重複ポストの処理',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
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
                'mode': mode,
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

  Future<void> _executeAppendWithDialog({
    String? user,
    String? hashtag,
    required String mode,
    required int count,
    required bool stopOnExisting,
  }) async {
    final isUserGist = widget.userGistId != null;
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
              const Text(
                '追加中...',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(
                '$targetLabel / $count 件',
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
              Text(
                stopOnExisting ? 'ストップオンモード' : 'スキップモード',
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
    await vm.executeAppend(
      user: user,
      hashtag: hashtag,
      mode: mode,
      count: count,
      stopOnExisting: stopOnExisting,
      isUserGist: isUserGist,
    );

    if (mounted) Navigator.pop(context);

    if (vm.appendStatus == AppendStatus.completed) {
      if (isUserGist && widget.userGistUsername != null) {
        // ユーザーGist: 追記後のデータを再取得して _localItems を更新
        try {
          final newItems = await vm.fetchUserItems(widget.userGistUsername!);
          if (mounted) setState(() => _localItems = newItems);
        } catch (_) {
          // 取得失敗時は現状維持
        }
      } else {
        _refilterLocalItems(vm); // マスターフィルタサブギャラリーの更新
      }
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

    final currentItems = _localItems ?? widget.initialItems ?? [];
    final deletedIds = Set<String>.from(vm.selectedIds); // 削除前にキャプチャ
    final remainingCount = await vm.deleteSelectedFromUserGist(
      widget.userGistId!,
      widget.userGistUsername!,
      currentItems,
    );

    if (mounted) Navigator.pop(context); // 処理中ダイアログを閉じる

    if (remainingCount != null) {
      if (remainingCount == 0 && widget.userGistUsername != null) {
        // ポストがなくなったユーザーをマスターGistから削除して画面を閉じる
        await vm.removeUserFromMaster(widget.userGistUsername!);
        if (mounted) Navigator.pop(context);
      } else {
        // 削除済みアイテムを _localItems から除外
        setState(() {
          _localItems = currentItems
              .where((item) => !deletedIds.contains(item.id))
              .toList();
        });
      }
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
          : currentTitle
                .substring(currentTitle.indexOf('@'))
                .replaceFirst('@', '');
      final userTag = '@$twitterId';
      final pattern = RegExp(r'@([a-zA-Z0-9_]+)');
      filtered = vm.items.where((item) {
        return pattern
            .allMatches(item.fullText)
            .any((m) => m.group(0)!.toLowerCase() == userTag.toLowerCase());
      }).toList();
    } else if (isHashtagFilter) {
      final hashtagKeyword = currentTitle.replaceFirst('#', '');
      final hashTag = '#$hashtagKeyword';
      final pattern = RegExp(r'#[^\s#]+');
      filtered = vm.items.where((item) {
        return pattern
            .allMatches(item.fullText)
            .any((m) => m.group(0)!.toLowerCase() == hashTag.toLowerCase());
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

  Future<void> _handleSearchUser() async {
    final userIdInput = await showDialog<String>(
      context: context,
      builder: (context) => const UserIdInputDialog(),
    );

    if (userIdInput == null || userIdInput.isEmpty) return;
    if (!mounted) return;

    final vm = context.read<GalleryViewModel>();
    final userIdLower = userIdInput.trim().toLowerCase();

    // 1. userGists から検索 (case-insensitive)
    String? matchedUsername;
    for (final username in vm.userGists.keys) {
      if (username.toLowerCase() == userIdLower) {
        matchedUsername = username;
        break;
      }
    }

    if (matchedUsername != null) {
      _openUserGallery(matchedUsername);
      return;
    }

    // 2. マスターアイテムから検索 (case-insensitive)
    final userRegExp = RegExp(r'^@([^:]+):');
    for (final item in vm.items) {
      final m = userRegExp.firstMatch(item.fullText);
      if (m != null) {
        final username = m.group(1)!.trim();
        if (username.toLowerCase() == userIdLower) {
          matchedUsername = username;
          break;
        }
      }
    }

    if (matchedUsername != null) {
      _openUserGallery(matchedUsername);
    } else {
      _showErrorSnackBar('ユーザー @$userIdInput は見つかりませんでした');
    }
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
    if (widget.initialItems != null) {
      return _buildScaffold(
        items: _localItems ?? widget.initialItems!,
        userName: '',
        isAuthenticated: true,
        isSelectionMode: vm.isSelectionMode,
        selectedIds: vm.selectedIds,
      );
    }

    // ルートギャラリー：メイン / お気に入り を PageView で切り替え
    final isAuthenticated = vm.status == GalleryStatus.authenticated;
    return _buildRootScaffold(vm, isAuthenticated);
  }

  Widget _buildRootScaffold(GalleryViewModel vm, bool isAuthenticated) {
    final isFavPage = _currentPage == 1;
    final favoriteItems = vm.items
        .where((item) {
          final key = item.username ??
              RegExp(r'^@([^:]+):').firstMatch(item.fullText)?.group(1)?.trim();
          return key != null && vm.isFavorite(key);
        })
        .toList();

    return Scaffold(
      appBar: AppBar(
        leading: vm.isSelectionMode
            ? IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => context.read<GalleryViewModel>().clearSelection(),
              )
            : null,
        title: vm.isSelectionMode
            ? Text('${vm.selectedIds.length}件選択中')
            : Text(isFavPage ? 'お気に入り' : 'PostGallery'),
        actions: [
          if (!vm.isSelectionMode) ...[
            if (vm.items.isNotEmpty)
              IconButton(
                icon: const Icon(Icons.format_list_numbered),
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => StatsPage(items: vm.items),
                  ),
                ),
              ),
            PopupMenuButton<String>(
              icon: const Icon(Icons.menu),
              onSelected: (value) {
                switch (value) {
                  case 'key':
                    _showPasswordDialog(canCancel: true);
                  case 'refresh':
                    _handleRefresh();
                  case 'search_user':
                    _handleSearchUser();
                }
              },
              itemBuilder: (context) => [
                const PopupMenuItem(
                  value: 'search_user',
                  child: ListTile(
                    leading: Icon(Icons.person_search),
                    title: Text('ユーザー検索'),
                    dense: true,
                  ),
                ),
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
                    leading: Icon(Icons.auto_awesome),
                    title: Text('ForYou'),
                    dense: true,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
      body: !isAuthenticated
          ? const Center(child: Text('Waiting for authentication...'))
          : vm.items.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : PageView(
              controller: _pageController,
              onPageChanged: (page) => setState(() => _currentPage = page),
              children: [
                _buildUserGroupedGrid(vm.items, vm.userGists, vm.favoriteUsers),
                _buildFavoritesGrid(favoriteItems, vm.userGists, vm.favoriteUsers),
              ],
            ),
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
          if (isSelectionMode && widget.userGistId != null)
            IconButton(
              icon: const Icon(Icons.delete, color: Colors.redAccent),
              onPressed: _showDeleteConfirmDialog,
            )
          else if (isUserFilter || isHashtagFilter) ...[
            // ユーザー／ハッシュタグフィルター画面: ハート（ユーザーのみ）＋ 追加ボタン
            if (isUserFilter && widget.userGistUsername != null)
              Consumer<GalleryViewModel>(
                builder: (context, vm, _) => IconButton(
                  icon: Icon(
                    vm.isFavorite(widget.userGistUsername!)
                        ? Icons.favorite
                        : Icons.favorite_border,
                    color: vm.isFavorite(widget.userGistUsername!)
                        ? Colors.redAccent
                        : null,
                  ),
                  onPressed: () =>
                      vm.toggleFavorite(widget.userGistUsername!),
                ),
              ),
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
                  case 'search_user':
                    _handleSearchUser();
                }
              },
              itemBuilder: (context) => [
                const PopupMenuItem(
                  value: 'search_user',
                  child: ListTile(
                    leading: Icon(Icons.person_search),
                    title: Text('ユーザー検索'),
                    dense: true,
                  ),
                ),
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
                    leading: Icon(Icons.auto_awesome),
                    title: Text('ForYou'),
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

  /// ユーザーグループ化したグリッド（メインギャラリー用）
  Widget _buildUserGroupedGrid(
    List<TweetItem> items,
    Map<String, String> userGists,
    Set<String> favoriteUsers,
  ) {
    final userRegExp = RegExp(r'^@([^:]+):');
    final Map<String, List<TweetItem>> grouped = {};
    for (final item in items) {
      final key = item.username ??
          (userRegExp.firstMatch(item.fullText)?.group(1)?.trim() ?? '_unknown');
      grouped.putIfAbsent(key, () => []).add(item);
    }

    // マスター件数降順でソート
    final entries = grouped.entries.toList()
      ..sort((a, b) => b.value.length.compareTo(a.value.length));

    return GridView.builder(
      controller: _gridController,
      padding: const EdgeInsets.all(4),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 4,
        mainAxisSpacing: 4,
      ),
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final username = entries[index].key;
        final userItems = entries[index].value;
        final thumbItem = userItems.firstWhere(
          (i) => i.thumbnailUrl.isNotEmpty,
          orElse: () => userItems.first,
        );
        return _buildUserCard(
          username,
          thumbItem,
          userItems.length,
          favoriteUsers.contains(username),
        );
      },
    );
  }

  /// お気に入りギャラリー（favoriteItems は既にフィルタ済み）
  Widget _buildFavoritesGrid(
    List<TweetItem> favoriteItems,
    Map<String, String> userGists,
    Set<String> favoriteUsers,
  ) {
    if (favoriteItems.isEmpty) {
      return const Center(
        child: Text(
          'お気に入りはまだありません\nユーザーカードのハートをタップして追加',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.grey),
        ),
      );
    }

    final userRegExp = RegExp(r'^@([^:]+):');
    final Map<String, List<TweetItem>> grouped = {};
    for (final item in favoriteItems) {
      final key = item.username ??
          (userRegExp.firstMatch(item.fullText)?.group(1)?.trim() ?? '_unknown');
      grouped.putIfAbsent(key, () => []).add(item);
    }

    final entries = grouped.entries.toList()
      ..sort((a, b) => b.value.length.compareTo(a.value.length));

    return GridView.builder(
      controller: _favGridController,
      padding: const EdgeInsets.all(4),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 4,
        mainAxisSpacing: 4,
      ),
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final username = entries[index].key;
        final userItems = entries[index].value;
        final thumbItem = userItems.firstWhere(
          (i) => i.thumbnailUrl.isNotEmpty,
          orElse: () => userItems.first,
        );
        return _buildUserCard(
          username,
          thumbItem,
          userItems.length,
          true, // お気に入りページなので常にtrue
        );
      },
    );
  }

  Widget _buildUserCard(
    String username,
    TweetItem thumbItem,
    int count,
    bool isFavorite,
  ) {
    return GestureDetector(
      onTap: () => _openUserGallery(username),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Container(
            color: Colors.grey[900],
            child: thumbItem.thumbnailUrl.isNotEmpty
                ? Image.network(
                    thumbItem.thumbnailUrl,
                    fit: BoxFit.cover,
                    alignment: Alignment.topCenter,
                    errorBuilder: (c, e, s) => _buildErrorWidget(),
                  )
                : _buildErrorWidget(),
          ),
          // ハートボタン（右上）
          Positioned(
            top: 2,
            right: 2,
            child: GestureDetector(
              onTap: () =>
                  context.read<GalleryViewModel>().toggleFavorite(username),
              child: Container(
                padding: const EdgeInsets.all(3),
                decoration: const BoxDecoration(
                  color: Colors.black38,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  isFavorite ? Icons.favorite : Icons.favorite_border,
                  color: isFavorite ? Colors.redAccent : Colors.white70,
                  size: 16,
                ),
              ),
            ),
          ),
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Container(
              color: Colors.black54,
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '@$username',
                      style: const TextStyle(fontSize: 10, color: Colors.white),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Text(
                    '$count',
                    style: const TextStyle(fontSize: 10, color: Colors.white70),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openUserGallery(String username) async {
    final vm = context.read<GalleryViewModel>();
    final gistId = vm.userGists[username];

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('読み込み中...'),
          ],
        ),
      ),
    );
    try {
      final userItems = await vm.fetchUserItems(username);
      if (mounted) Navigator.pop(context);
      if (mounted) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => GalleryPage(
              initialItems: userItems,
              title: '@$username',
              userGistId: gistId,
              userGistUsername: username,
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) Navigator.pop(context);
      _showErrorSnackBar('ユーザーギャラリーの読み込みに失敗しました');
    }
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
