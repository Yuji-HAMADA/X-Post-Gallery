import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../models/tweet_item.dart';
import '../../viewmodels/gallery_viewmodel.dart';
import 'components/append_config_dialog.dart';
import 'components/tweet_grid_view.dart';
import 'components/user_card.dart';
import 'components/user_id_input_dialog.dart';
import 'user_gallery_swipe_page.dart';

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

  Future<void> _showFetchQueueSheet() async {
    final vm = context.read<GalleryViewModel>();

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(width: 16),
            Text('読込中...'),
          ],
        ),
      ),
    );

    final users = await vm.fetchFetchQueue();
    if (!mounted) return;
    Navigator.pop(context);

    if (users == null) {
      _showErrorSnackBar('キューの取得に失敗しました');
      return;
    }

    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        return SizedBox(
          height: MediaQuery.of(context).size.height * 0.7,
          child: Column(
            children: [
              const SizedBox(height: 8),
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  '取得キュー (${users.length}件)',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
              ),
              Expanded(
                child: ListView.builder(
                  itemCount: users.length,
                  itemBuilder: (context, index) {
                    final user = users[index];
                    final username = user['user'] as String;
                    final count = user['count'] as int?;
                    final isFetched = vm.userGists.containsKey(username);
                    return ListTile(
                      title: Text('@$username'),
                      subtitle: count != null ? Text('$count 件') : null,
                      trailing: isFetched
                          ? const Icon(
                              Icons.check_circle,
                              color: Colors.green,
                            )
                          : null,
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
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

  // --- お気に入り Gist 保存・読込 ---

  Future<void> _saveFavoritesToGist() async {
    final vm = context.read<GalleryViewModel>();
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Row(
          children: [
            CircularProgressIndicator(),
            SizedBox(width: 16),
            Text('Gistに保存中...'),
          ],
        ),
      ),
    );

    final gistId = await vm.saveFavoritesToGist();
    if (!mounted) return;
    Navigator.pop(context);

    if (gistId != null) {
      showDialog(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('保存完了'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Gist IDをメモしておくと再インストール後に復元できます：'),
              const SizedBox(height: 8),
              SelectableText(
                gistId,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    } else {
      _showErrorSnackBar('Gistへの保存に失敗しました');
    }
  }

  Future<void> _loadFavoritesFromGist() async {
    final vm = context.read<GalleryViewModel>();
    final savedId = await vm.loadFavoritesGistId();

    if (!mounted) return;
    final controller = TextEditingController(text: savedId ?? '');
    final gistId = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Gistから読込'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            labelText: 'Gist ID',
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
            child: const Text('読込'),
          ),
        ],
      ),
    );

    if (gistId == null || gistId.trim().isEmpty || !mounted) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Row(
          children: [
            CircularProgressIndicator(),
            SizedBox(width: 16),
            Text('読込中...'),
          ],
        ),
      ),
    );

    final success = await vm.loadFavoritesFromGist(gistId.trim());
    if (!mounted) return;
    Navigator.pop(context);

    if (success) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('お気に入りを読み込みました'),
          backgroundColor: Colors.green,
        ),
      );
    } else {
      _showErrorSnackBar('読込に失敗しました。Gist IDを確認してください');
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
    final count = await AppendConfigDialog.show(context);
    if (count == null) return;

    if (!await vm.isAdminAuthenticated()) {
      final result = await _showPasswordInputDialog('認証');
      if (result == null) return;
      final success = await vm.authenticateAdmin(password: result);
      if (!success) {
        if (mounted) _showErrorSnackBar(vm.errorMessage);
        return;
      }
    }

    final targetUser = user ?? hashtag ?? '';
    final success = await vm.queueUserForFetch(targetUser, count: count);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(success ? '取得キューに追加しました' : 'キューへの追加に失敗しました'),
          backgroundColor: success ? Colors.green : Colors.redAccent,
        ),
      );
    }
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
      return;
    }

    // 3. マスターGistに存在しない → Xで存在確認してから新規追加へ
    final username = userIdInput.trim();
    if (mounted) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => const AlertDialog(
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('Xで確認中...'),
            ],
          ),
        ),
      );
    }

    final exists = await vm.checkUserExistsOnX(username);
    if (mounted) Navigator.pop(context);
    if (!mounted) return;

    if (!exists) {
      _showErrorSnackBar('ユーザー @$username は見つかりませんでした');
      return;
    }

    await _handleAddNewUser(username);
  }

  /// マスターGistに存在しない新規ユーザーを追加する
  Future<void> _handleAddNewUser(String username) async {
    final count = await AppendConfigDialog.show(context);
    if (count == null || !mounted) return;

    final vm = context.read<GalleryViewModel>();
    if (!await vm.isAdminAuthenticated()) {
      final result = await _showPasswordInputDialog('認証');
      if (result == null) return;
      final success = await vm.authenticateAdmin(password: result);
      if (!success) {
        if (mounted) _showErrorSnackBar(vm.errorMessage);
        return;
      }
    }

    final success = await vm.queueUserForFetch(username, count: count);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(success ? '取得キューに追加しました: @$username' : 'キューへの追加に失敗しました'),
          backgroundColor: success ? Colors.green : Colors.redAccent,
        ),
      );
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
    final favoriteItems = vm.items.where((item) {
      final key =
          item.username ??
          RegExp(r'^@([^:]+):').firstMatch(item.fullText)?.group(1)?.trim();
      return key != null && vm.isFavorite(key);
    }).toList();

    return Scaffold(
      appBar: AppBar(
        leading: vm.isSelectionMode
            ? IconButton(
                icon: const Icon(Icons.close),
                onPressed: () =>
                    context.read<GalleryViewModel>().clearSelection(),
              )
            : null,
        title: vm.isSelectionMode
            ? Text('${vm.selectedIds.length}件選択中')
            : Text(isFavPage ? 'お気に入り' : 'PostGallery'),
        actions: [
          if (!vm.isSelectionMode) ...[
            if (isFavPage) ...[
              IconButton(
                icon: const Icon(Icons.cloud_upload),
                tooltip: 'Gistに保存',
                onPressed: _saveFavoritesToGist,
              ),
              IconButton(
                icon: const Icon(Icons.cloud_download),
                tooltip: 'Gistから読込',
                onPressed: _loadFavoritesFromGist,
              ),
            ],
            if (!isFavPage)
              IconButton(
                icon: const Icon(Icons.refresh),
                tooltip: '再読み込み',
                onPressed: vm.status == GalleryStatus.loading
                    ? null
                    : () => context.read<GalleryViewModel>().reloadGallery(),
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
                  case 'fetch_queue':
                    _showFetchQueueSheet();
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
                  value: 'fetch_queue',
                  child: ListTile(
                    leading: Icon(Icons.format_list_bulleted),
                    title: Text('取得キュー'),
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
                _buildFavoritesGrid(
                  favoriteItems,
                  vm.userGists,
                  vm.favoriteUsers,
                ),
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
                  onPressed: () => vm.toggleFavorite(widget.userGistUsername!),
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
            // 通常画面: 再読み込み + ハンバーガーメニュー
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: '再読み込み',
              onPressed: () =>
                  context.read<GalleryViewModel>().reloadGallery(),
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
                  case 'fetch_queue':
                    _showFetchQueueSheet();
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
                  value: 'fetch_queue',
                  child: ListTile(
                    leading: Icon(Icons.format_list_bulleted),
                    title: Text('取得キュー'),
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
                : TweetGridView(
                    items: items,
                    selectedIds: selectedIds,
                    scrollController: _gridController,
                  )),
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
      final key =
          item.username ??
          (userRegExp.firstMatch(item.fullText)?.group(1)?.trim() ??
              '_unknown');
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
        return UserCard(
          username: username,
          thumbItem: thumbItem,
          count: userItems.length,
          isFavorite: favoriteUsers.contains(username),
          onTap: () => _openUserGallery(username),
          onFavoriteTap: () =>
              context.read<GalleryViewModel>().toggleFavorite(username),
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
      final key =
          item.username ??
          (userRegExp.firstMatch(item.fullText)?.group(1)?.trim() ??
              '_unknown');
      grouped.putIfAbsent(key, () => []).add(item);
    }

    final entries = grouped.entries.toList()
      ..sort((a, b) => b.value.length.compareTo(a.value.length));

    // お気に入りページ内でのスワイプスコープ（このグリッドに表示される順）
    final favUsernames = entries.map((e) => e.key).toList();

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
        return UserCard(
          username: username,
          thumbItem: thumbItem,
          count: userItems.length,
          isFavorite: true,
          onTap: () => _openUserGallery(username, scope: favUsernames),
          onFavoriteTap: () =>
              context.read<GalleryViewModel>().toggleFavorite(username),
        );
      },
    );
  }

  Future<void> _openUserGallery(String username, {List<String>? scope}) async {
    final vm = context.read<GalleryViewModel>();

    List<String> sortedUsernames;
    if (scope != null) {
      // お気に入りなど呼び出し元が既に順序を決めているケース
      sortedUsernames = scope;
    } else {
      // グリッドと同じ順序（マスター件数降順）でユーザー一覧を構築
      final userRegExp = RegExp(r'^@([^:]+):');
      final Map<String, int> countMap = {};
      for (final item in vm.items) {
        final key =
            item.username ??
            (userRegExp.firstMatch(item.fullText)?.group(1)?.trim() ??
                '_unknown');
        countMap[key] = (countMap[key] ?? 0) + 1;
      }
      sortedUsernames = countMap.keys.toList()
        ..sort((a, b) => countMap[b]!.compareTo(countMap[a]!));
    }

    final initialIndex = sortedUsernames.indexWhere(
      (u) => u.toLowerCase() == username.toLowerCase(),
    );
    final safeIndex = initialIndex < 0 ? 0 : initialIndex;

    final gistIds = sortedUsernames.map((u) => vm.userGists[u]).toList();

    if (mounted) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => UserGallerySwipePage(
            usernames: sortedUsernames,
            userGistIds: gistIds,
            initialIndex: safeIndex,
          ),
        ),
      );
    }
  }
}
