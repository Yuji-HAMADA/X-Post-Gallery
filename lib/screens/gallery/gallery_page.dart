import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../l10n/app_localizations.dart';
import '../../models/tweet_item.dart';
import '../../viewmodels/gallery_viewmodel.dart';
import 'components/append_config_dialog.dart';
import 'components/dialog_helpers.dart';
import 'components/tweet_grid_view.dart';
import 'components/user_card.dart';
import 'components/user_id_input_dialog.dart';
import 'user_gallery_swipe_page.dart';
import 'random_gallery_swipe_page.dart';

/// [JA] メインギャラリー画面（お気に入り・ユーザー一覧・Gist連携）
/// [EN] Main gallery screen (Favorites, Users list, Gist synchronization)
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
  final ScrollController _candidateGridController = ScrollController();
  final PageController _pageController = PageController();
  int _currentPage = 0;
  List<TweetItem>? _localItems; // Append後の再フィルタ結果を保持
  bool _isFavRandomChecked = false;
  bool _isUserRandomChecked = false;
  bool _isCandidateRandomChecked = false;

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
    _candidateGridController.dispose();
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
      _applyInitialTab();
    }
  }

  void _applyInitialTab() {
    final t = Uri.base.queryParameters['t'];
    if (t == null) return;
    const pageMap = {
      'favorite': 0,
      'user': 1,
      'candidate': 2,
    };
    final page = pageMap[t.toLowerCase()];
    if (page == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _pageController.jumpToPage(page);
      setState(() => _currentPage = page);
    });
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

    void handleUnlock() {
      Navigator.pop(context);
      if (gistIdInput.isNotEmpty) {
        _loadAndRestore(gistIdInput);
      } else {
        _showErrorSnackBar('Gist IDを入力してください');
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
            const Text("Gist IDを入力してください:"),
            const SizedBox(height: 10),
            TextField(
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: "Gist ID",
              ),
              onChanged: (value) => gistIdInput = value,
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

  // --- Append 関連 ---

  Future<void> _handleAppend({String? user}) async {
    final username = user ?? '';
    if (username.isEmpty) return;

    final l10n = AppLocalizations.of(context);
    final vm = context.read<GalleryViewModel>();
    final result = await AppendConfigDialog.show(context);
    debugPrint('_handleAppend: AppendConfigDialog result=$result');
    if (result == null) return;

    if (!await vm.isAdminAuthenticated()) {
      debugPrint('_handleAppend: Admin NOT authenticated');
      if (mounted) _showErrorSnackBar(l10n.pleaseLoginWithMasterGist);
      return;
    }

    debugPrint(
      '_handleAppend: Queueing user @$username with count=${result.count}, stopOnExisting=${result.stopOnExisting}, fromScratch=${result.fromScratch}',
    );
    final success = await vm.queueUserForFetch(
      username,
      count: result.count,
      stopOnExisting: result.stopOnExisting,
      fromScratch: result.fromScratch,
    );
    debugPrint('_handleAppend: queueUserForFetch success=$success');
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            success ? l10n.addedToQueue(username) : l10n.failedToAddToQueue,
          ),
          backgroundColor: success ? Colors.green : Colors.redAccent,
        ),
      );
    }
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

    int? remainingCount;
    if (widget.userGistId != null && widget.userGistUsername != null) {
      // ユーザーGist削除
      remainingCount = await vm.deleteSelectedFromUserGist(
        widget.userGistId!,
        widget.userGistUsername!,
        currentItems,
      );
    }

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

  /// 削除確認ダイアログの共通処理
  Future<void> _confirmDelete({
    required String title,
    required Future<bool> Function() onDelete,
    required String successMessage,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: const Text('全てのデータが削除されます'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('削除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    showProgressDialog(context);

    final success = await onDelete();
    if (mounted) Navigator.pop(context);
    if (mounted) {
      if (success) {
        showSuccessSnackBar(context, successMessage);
      } else {
        showErrorSnackBar(context, '削除に失敗しました');
      }
    }
  }

  Future<void> _confirmDeleteUser(String username) => _confirmDelete(
    title: 'ユーザー @$username を削除しますか？',
    onDelete: () => context.read<GalleryViewModel>().deleteUser(username),
    successMessage: '@$username を削除しました',
  );

  Future<void> _handleSearchUser() async {
    final userIdInput = await showDialog<String>(
      context: context,
      builder: (context) => const UserIdInputDialog(),
    );

    if (userIdInput == null || userIdInput.isEmpty) return;
    if (!mounted) return;

    final vm = context.read<GalleryViewModel>();
    var inputTrimmed = userIdInput.trim();
    if (inputTrimmed.startsWith('@')) {
      inputTrimmed = inputTrimmed.substring(1).trim();
    }
    final inputLower = inputTrimmed.toLowerCase();

    // 1. userGists から検索 (case-insensitive)
    String? matchedUsername;
    for (final username in vm.userGists.keys) {
      if (username.toLowerCase() == inputLower) {
        matchedUsername = username;
        break;
      }
    }

    if (matchedUsername != null) {
      _openUserGallery(matchedUsername);
      return;
    }

    // 2. マスターアイテムから検索 (case-insensitive)
    for (final item in vm.items) {
      final username = item.extractedUsername;
      if (username != null) {
        if (username.toLowerCase() == inputLower) {
          matchedUsername = username;
          break;
        }
      }
    }

    if (matchedUsername != null) {
      _openUserGallery(matchedUsername);
      return;
    }

    // 3. 見つからない場合 → Xで存在確認して新規追加
    final username = inputTrimmed;
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

  /// ピン留め短押し時: アカウントの優先順位を最上位に更新しトースト通知を表示
  Future<void> _handlePriorityTap(String username) async {
    final vm = context.read<GalleryViewModel>();
    await pinAccountToTop(context, vm, username);
  }

  /// マスターGistに存在しない新規ユーザーを追加する
  Future<void> _handleAddNewUser(String username) async {
    final l10n = AppLocalizations.of(context);
    final result = await AppendConfigDialog.show(context);
    if (result == null || !mounted) return;

    final vm = context.read<GalleryViewModel>();
    if (!await vm.isAdminAuthenticated()) {
      if (mounted) _showErrorSnackBar(l10n.pleaseLoginWithMasterGist);
      return;
    }

    final success = await vm.queueUserForFetch(
      username,
      count: result.count,
      stopOnExisting: result.stopOnExisting,
      fromScratch: result.fromScratch,
    );
    if (success) {
      await vm.registerUser(username);
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            success ? l10n.addedToQueue(username) : l10n.failedToAddToQueue,
          ),
          backgroundColor: success ? Colors.green : Colors.redAccent,
        ),
      );
    }
  }

  // --- 外部連携 ---
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
      final baseItems = _localItems ?? widget.initialItems!;
      return _buildScaffold(
        items: baseItems,
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
    final l10n = AppLocalizations.of(context);
    final isFavPage = _currentPage == 0;
    final isUserPage = _currentPage == 1;
    final isCandidatePage = _currentPage == 2;
    final favoriteItems = vm.items.where((item) {
      final key = item.extractedUsername;
      return key != null && vm.isFavorite(key);
    }).toList();

    final pageTitles = [l10n.tabFavorites, l10n.tabUsers, l10n.tabCandidate];
    final currentTitle = vm.isSelectionMode
        ? l10n.selectedCount(vm.selectedIds.length)
        : pageTitles[_currentPage];

    // モバイルブラウザのスワイプbackでアプリが終了しないよう、
    // ルートページでは pop を無効化する。
    return PopScope(
      canPop: false,
      child: Scaffold(
        appBar: AppBar(
          leading: vm.isSelectionMode
              ? IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () =>
                      context.read<GalleryViewModel>().clearSelection(),
                )
              : null,
          title: Text(currentTitle),
          actions: [
            if (!vm.isSelectionMode) ...[
              if (isFavPage) ...[
                IconButton(
                  icon: const Icon(Icons.cloud_upload),
                  tooltip: l10n.tooltipSaveToGist,
                  onPressed: _saveFavoritesToGist,
                ),
                IconButton(
                  icon: const Icon(Icons.cloud_download),
                  tooltip: l10n.tooltipLoadFromGist,
                  onPressed: _loadFavoritesFromGist,
                ),
              ],
              IconButton(
                icon: const Icon(Icons.refresh),
                tooltip: l10n.reload,
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
                      break;
                    case 'search_user':
                      _handleSearchUser();
                      break;
                    case 'random_fav':
                      _toggleFavRandomMode();
                      break;
                    case 'random_user':
                      _toggleUserRandomMode();
                      break;
                    case 'random_candidate':
                      _toggleCandidateRandomMode();
                      break;
                  }
                },
                itemBuilder: (context) => [
                  if (isFavPage)
                    CheckedPopupMenuItem<String>(
                      value: 'random_fav',
                      checked: _isFavRandomChecked,
                      child: Text(l10n.randomSelection),
                    ),
                  if (isUserPage)
                    CheckedPopupMenuItem<String>(
                      value: 'random_user',
                      checked: _isUserRandomChecked,
                      child: Text(l10n.randomSelection),
                    ),
                  if (isCandidatePage)
                    CheckedPopupMenuItem<String>(
                      value: 'random_candidate',
                      checked: _isCandidateRandomChecked,
                      child: Text(l10n.randomSelection),
                    ),
                  PopupMenuItem(
                    value: 'search_user',
                    child: ListTile(
                      leading: const Icon(Icons.person_search),
                      title: Text(l10n.userSearch),
                      dense: true,
                    ),
                  ),
                  PopupMenuItem(
                    value: 'key',
                    child: const ListTile(
                      leading: Icon(Icons.vpn_key_outlined),
                      title: Text('Gist ID'),
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
                onPageChanged: (page) {
                  setState(() => _currentPage = page);
                },
                children: [
                  _buildFavoritesGrid(
                    favoriteItems,
                    vm.userGists,
                    vm.favoriteUsers,
                    vm.userPriorities,
                  ),
                  _buildUserGroupedGrid(
                    vm.items,
                    vm.userGists,
                    vm.favoriteUsers,
                    vm.userPriorities,
                    isCandidateView: false,
                  ),
                  _buildUserGroupedGrid(
                    vm.items,
                    vm.userGists,
                    vm.favoriteUsers,
                    vm.userPriorities,
                    isCandidateView: true,
                  ),
                ],
              ),
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
    final l10n = AppLocalizations.of(context);
    final String currentTitle = widget.title ?? '';
    final bool isUserFilter = currentTitle.contains('@');

    String displayTitle = widget.title ?? 'PostGallery';

    String twitterId = displayTitle.startsWith('@')
        ? displayTitle.replaceFirst('@', '')
        : (isUserFilter
              ? currentTitle
                    .substring(currentTitle.indexOf('@'))
                    .replaceFirst('@', '')
              : '');

    final bool showLinkButton =
        isUserFilter || displayTitle.startsWith('@');

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
            ? Text(l10n.selectedCount(selectedIds.length))
            : (showLinkButton
                  ? GestureDetector(
                      onTap: () => _launchX(twitterId),
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
          else if (isUserFilter) ...[
            if (widget.userGistUsername != null) ...[
              Consumer<GalleryViewModel>(
                builder: (context, vm, _) {
                  final isPinned = vm.isPinned(widget.userGistUsername!);
                  final isFav = vm.isFavorite(widget.userGistUsername!);
                  return Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: Icon(
                          isPinned ? Icons.push_pin : Icons.push_pin_outlined,
                          color: isPinned ? Colors.amber : null,
                        ),
                        tooltip: isPinned
                            ? l10n.tooltipUnpin
                            : l10n.tooltipPinToTop,
                        onPressed: () =>
                            _handlePriorityTap(widget.userGistUsername!),
                      ),
                      IconButton(
                        icon: Icon(
                          isFav ? Icons.favorite : Icons.favorite_border,
                          color: isFav ? Colors.redAccent : null,
                        ),
                        onPressed: () =>
                            vm.toggleFavorite(widget.userGistUsername!),
                      ),
                    ],
                  );
                },
              ),
            ],
            IconButton(
              icon: const Icon(Icons.add),
              tooltip: l10n.add,
              onPressed: () => _handleAppend(
                user: twitterId,
              ),
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

  /// 優先順位（priority_updated_at 降順）および元の登録順（降順/LIFO）でユーザーを比較する
  int _compareUserPriority(
    String userA,
    String userB,
    Map<String, int> userPriorities,
    Map<String, int> originalIndex,
  ) {
    final pA = userPriorities[userA] ?? 0;
    final pB = userPriorities[userB] ?? 0;
    final cmp = pB.compareTo(pA);
    if (cmp != 0) return cmp;

    final idxA = originalIndex[userA] ?? -1;
    final idxB = originalIndex[userB] ?? -1;
    return idxB.compareTo(idxA);
  }

  /// ユーザーのツイート一覧からサムネイル付きの代表アイテムを選択する
  TweetItem _selectThumbnailItem(List<TweetItem> userItems) {
    return userItems.firstWhere(
      (i) => i.thumbnailUrl.isNotEmpty,
      orElse: () => userItems.isNotEmpty
          ? userItems.first
          : TweetItem(
              id: '',
              fullText: '',
              createdAt: '',
              mediaUrls: const [],
            ),
    );
  }

  /// ユーザーグループ化したグリッド（メイン / 候補ギャラリー用）
  Widget _buildUserGroupedGrid(
    List<TweetItem> items,
    Map<String, String> userGists,
    Set<String> favoriteUsers,
    Map<String, int> userPriorities, {
    bool isCandidateView = false,
  }) {
    final vm = context.read<GalleryViewModel>();
    final Map<String, List<TweetItem>> grouped = {};
    for (final item in items) {
      final key = item.extractedUsername ?? '_unknown';
      if (favoriteUsers.contains(key)) {
        continue;
      }
      if (vm.isCandidate(key) != isCandidateView) {
        continue;
      }
      grouped.putIfAbsent(key, () => []).add(item);
    }

    // 元の登録順序（userGists のキー順）のインデックスを保持
    final originalKeys = userGists.keys.toList();
    final Map<String, int> originalIndex = {};
    for (int i = 0; i < originalKeys.length; i++) {
      originalIndex[originalKeys[i]] = i;
    }

    final List<MapEntry<String, List<TweetItem>>> entries = [];
    final Set<String> addedUsers = {};

    for (final username in originalKeys) {
      if (favoriteUsers.contains(username)) continue;
      if (vm.isCandidate(username) != isCandidateView) continue;
      final userItems = grouped[username] ?? [];
      entries.add(MapEntry(username, userItems));
      addedUsers.add(username);
    }

    for (final entry in grouped.entries) {
      if (!addedUsers.contains(entry.key)) {
        entries.add(entry);
        addedUsers.add(entry.key);
      }
    }

    // priority_updated_at の降順（新しい順）でソート
    entries.sort((a, b) => _compareUserPriority(a.key, b.key, userPriorities, originalIndex));

    final userUsernames = entries.map((e) => e.key).toList();

    if (entries.isEmpty && isCandidateView) {
      final l10n = AppLocalizations.of(context);
      return Center(
        child: Text(
          l10n.noCandidatesYet,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.grey),
        ),
      );
    }

    return GridView.builder(
      controller: isCandidateView ? _candidateGridController : _gridController,
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
        final thumbItem = _selectThumbnailItem(userItems);
        return UserCard(
          username: username,
          thumbItem: thumbItem,
          isFavorite: favoriteUsers.contains(username),
          onTap: () => _openUserGallery(username, scope: userUsernames),
          onFavoriteTap: () =>
              context.read<GalleryViewModel>().toggleFavorite(username),
          onLongPress: () => _confirmDeleteUser(username),
        );
      },
    );
  }

  /// お気に入りギャラリー（favoriteItems は既にフィルタ済み）
  Widget _buildFavoritesGrid(
    List<TweetItem> favoriteItems,
    Map<String, String> userGists,
    Set<String> favoriteUsers,
    Map<String, int> userPriorities,
  ) {
    if (favoriteItems.isEmpty) {
      final l10n = AppLocalizations.of(context);
      return Center(
        child: Text(
          l10n.noFavoritesYet,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.grey),
        ),
      );
    }

    final Map<String, List<TweetItem>> grouped = {};
    for (final item in favoriteItems) {
      final key = item.extractedUsername ?? '_unknown';
      grouped.putIfAbsent(key, () => []).add(item);
    }

    final favList = favoriteUsers.toList();
    final Map<String, int> originalIndex = {};
    for (int i = 0; i < favList.length; i++) {
      originalIndex[favList[i]] = i;
    }

    final List<MapEntry<String, List<TweetItem>>> entries = [];
    final Set<String> addedUsers = {};

    for (final username in favList) {
      final userItems = grouped[username];
      if (userItems != null && userItems.isNotEmpty) {
        entries.add(MapEntry(username, userItems));
        addedUsers.add(username);
      }
    }
    // grouped に存在するが favoriteUsers に含まれない場合のフォールバック
    for (final entry in grouped.entries) {
      if (!addedUsers.contains(entry.key)) {
        entries.add(entry);
        addedUsers.add(entry.key);
      }
    }

    // priority_updated_at の降順（新しい順）でソート
    entries.sort((a, b) => _compareUserPriority(a.key, b.key, userPriorities, originalIndex));

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
        final thumbItem = _selectThumbnailItem(userItems);
        return UserCard(
          username: username,
          thumbItem: thumbItem,
          isFavorite: true,
          onTap: () => _openUserGallery(username, scope: favUsernames),
          onFavoriteTap: () =>
              context.read<GalleryViewModel>().toggleFavorite(username),
          onLongPress: () => _confirmDeleteUser(username),
        );
      },
    );
  }

  List<String> _getAllUsernames(List<TweetItem> items) {
    final Set<String> usernames = {};
    for (final item in items) {
      final key = item.extractedUsername;
      if (key != null && key != '_unknown') {
        usernames.add(key);
      }
    }
    return usernames.toList();
  }

  Future<void> _toggleFavRandomMode() async {
    final l10n = AppLocalizations.of(context);
    final vm = context.read<GalleryViewModel>();
    final usernames = vm.favoriteUsers.toList();
    if (usernames.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.noFavoriteUsersRegistered)),
        );
      }
      return;
    }

    setState(() => _isFavRandomChecked = true);

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => RandomGallerySwipePage(
          usernames: usernames,
          title: '${l10n.randomSelection} (${l10n.tabFavorites})',
        ),
      ),
    );

    if (mounted) {
      setState(() => _isFavRandomChecked = false);
    }
  }

  Future<void> _toggleUserRandomMode() async {
    final l10n = AppLocalizations.of(context);
    final vm = context.read<GalleryViewModel>();
    final usernames = _getAllUsernames(vm.items)
        .where(
          (username) =>
              !vm.favoriteUsers.contains(username) && !vm.isCandidate(username),
        )
        .toList();
    if (usernames.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.userNotFound)),
        );
      }
      return;
    }

    setState(() => _isUserRandomChecked = true);

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => RandomGallerySwipePage(
          usernames: usernames,
          title: '${l10n.randomSelection} (${l10n.tabUsers})',
        ),
      ),
    );

    if (mounted) {
      setState(() => _isUserRandomChecked = false);
    }
  }

  Future<void> _toggleCandidateRandomMode() async {
    final l10n = AppLocalizations.of(context);
    final vm = context.read<GalleryViewModel>();
    final usernames = _getAllUsernames(vm.items)
        .where(
          (username) =>
              !vm.favoriteUsers.contains(username) && vm.isCandidate(username),
        )
        .toList();
    if (usernames.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.noCandidatesYet)),
        );
      }
      return;
    }

    setState(() => _isCandidateRandomChecked = true);

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => RandomGallerySwipePage(
          usernames: usernames,
          title: '${l10n.randomSelection} (${l10n.tabCandidate})',
        ),
      ),
    );

    if (mounted) {
      setState(() => _isCandidateRandomChecked = false);
    }
  }

  Future<void> _openUserGallery(String username, {List<String>? scope}) async {
    final vm = context.read<GalleryViewModel>();

    List<String> sortedUsernames;
    if (scope != null) {
      // お気に入りなど呼び出し元が既に順序を決めているケース
      sortedUsernames = scope;
    } else {
      // グリッドと同じ優先順位降順（最新操作/登録順）でユーザー一覧を構築
      final originalKeys = vm.userGists.keys.toList();
      final Map<String, int> originalIndex = {};
      for (int i = 0; i < originalKeys.length; i++) {
        originalIndex[originalKeys[i]] = i;
      }

      final Set<String> registered = {};
      final List<String> list = [];
      for (final u in originalKeys) {
        if (!vm.favoriteUsers.contains(u)) {
          list.add(u);
          registered.add(u);
        }
      }
      for (final item in vm.items) {
        final key = item.extractedUsername ?? '_unknown';
        if (!vm.favoriteUsers.contains(key) && !registered.contains(key)) {
          list.add(key);
          registered.add(key);
        }
      }

      list.sort((a, b) => _compareUserPriority(a, b, vm.userPriorities, originalIndex));

      sortedUsernames = list;
    }

    int initialIndex = sortedUsernames.indexWhere(
      (u) => u.toLowerCase() == username.toLowerCase(),
    );
    if (initialIndex < 0) {
      final canonical = vm.getCanonicalUsername(username) ?? username;
      sortedUsernames = List.from(sortedUsernames)..insert(0, canonical);
      initialIndex = 0;
    }

    final gistIds = sortedUsernames.map((u) => vm.getGistIdForUser(u)).toList();

    if (mounted) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => UserGallerySwipePage(
            usernames: sortedUsernames,
            userGistIds: gistIds,
            initialIndex: initialIndex,
          ),
        ),
      );
    }
  }
}
