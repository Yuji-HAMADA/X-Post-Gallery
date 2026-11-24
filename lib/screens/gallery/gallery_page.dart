import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../l10n/app_localizations.dart';
import '../../models/tweet_item.dart';
import '../../utils/date_helper.dart';
import '../../viewmodels/gallery_viewmodel.dart';
import 'components/append_config_dialog.dart';
import 'components/aspect_ratio_grid_view.dart';
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
  static const int _kTabCount = 3;
  static const int _kLoopCenter = 3000;
  late final PageController _pageController;
  int _currentPage = 0;
  List<TweetItem>? _localItems; // Append後の再フィルタ結果を保持
  bool _isFavRandomChecked = false;
  bool _isUserRandomChecked = false;
  bool _isCandidateRandomChecked = false;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(initialPage: _kLoopCenter + _currentPage);
    if (widget.initialItems != null) {
      // フィルタ済みサブギャラリー：ViewModelには触れず直接表示
    } else {
      _handleInitialLoad();
    }
  }

  @override
  void dispose() {
    _gridController.dispose();
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
      final currentRaw = _pageController.hasClients
          ? (_pageController.page?.round() ?? (_kLoopCenter + _currentPage))
          : (_kLoopCenter + _currentPage);
      final currentLogical =
          ((currentRaw % _kTabCount) + _kTabCount) % _kTabCount;
      final target = currentRaw - currentLogical + page;
      _pageController.jumpToPage(target);
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
    final l10n = AppLocalizations.of(context);
    final vm = context.read<GalleryViewModel>();
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        content: Row(
          children: [
            const CircularProgressIndicator(),
            const SizedBox(width: 16),
            Text(l10n.savingToGist),
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
          title: Text(l10n.saveCompleted),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.saveGistIdNote),
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
              child: Text(l10n.ok),
            ),
          ],
        ),
      );
    } else {
      final msg = vm.errorMessage.isNotEmpty
          ? vm.errorMessage
          : l10n.saveFailed;
      _showErrorSnackBar(msg);
    }
  }

  Future<void> _loadFavoritesFromGist() async {
    final l10n = AppLocalizations.of(context);
    final vm = context.read<GalleryViewModel>();
    final savedId = await vm.loadFavoritesGistId();

    if (!mounted) return;
    final controller = TextEditingController(text: savedId ?? '');
    final gistId = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.loadFromGistTitle),
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
            child: Text(l10n.cancel),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: Text(l10n.load),
          ),
        ],
      ),
    );

    if (gistId == null || gistId.trim().isEmpty || !mounted) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        content: Row(
          children: [
            const CircularProgressIndicator(),
            const SizedBox(width: 16),
            Text(l10n.loadingFromGist),
          ],
        ),
      ),
    );

    final success = await vm.loadFavoritesFromGist(gistId.trim());
    if (!mounted) return;
    Navigator.pop(context);

    if (success) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.loadedFavoritesSuccess),
          backgroundColor: Colors.green,
        ),
      );
    } else {
      _showErrorSnackBar(l10n.loadFailedCheckId);
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
    final isAuthenticated = vm.status == GalleryStatus.authenticated ||
        (vm.status == GalleryStatus.loading && vm.items.isNotEmpty);
    return _buildRootScaffold(vm, isAuthenticated);
  }

  Widget _buildRootScaffold(GalleryViewModel vm, bool isAuthenticated) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _pageController.hasClients) {
        final currentRaw = _pageController.page?.round() ??
            (_kLoopCenter + _currentPage);
        final currentLogical =
            ((currentRaw % _kTabCount) + _kTabCount) % _kTabCount;
        if (currentLogical != _currentPage) {
          final target = currentRaw - currentLogical + _currentPage;
          _pageController.jumpToPage(target);
        }
      }
    });

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
                icon: vm.status == GalleryStatus.loading
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.refresh),
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
                    case 'grid_columns':
                      showGridColumnsDialog(context);
                      break;
                    case 'row_height':
                      showRowHeightDialog(context);
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
                  const PopupMenuDivider(),
                  buildGridColumnsMenuItem(context),
                  buildRowHeightMenuItem(context),
                ],
              ),
            ],
          ],
        ),
        body: !isAuthenticated
            ? const Center(child: Text('Waiting for authentication...'))
            : vm.items.isEmpty
            ? const Center(child: CircularProgressIndicator())
            : PageView.builder(
                controller: _pageController,
                onPageChanged: (rawPage) {
                  final logicalPage =
                      ((rawPage % _kTabCount) + _kTabCount) % _kTabCount;
                  if (_currentPage != logicalPage) {
                    setState(() => _currentPage = logicalPage);
                  }
                },
                itemBuilder: (context, index) {
                  final logicalIndex =
                      ((index % _kTabCount) + _kTabCount) % _kTabCount;
                  final Widget content;
                  switch (logicalIndex) {
                    case 0:
                      content = _buildFavoritesGrid(
                        favoriteItems,
                        vm.userGists,
                        vm.favoriteUsers,
                        vm.userPriorities,
                      );
                      break;
                    case 1:
                      content = _buildUserGroupedGrid(
                        vm.items,
                        vm.userGists,
                        vm.favoriteUsers,
                        vm.userPriorities,
                        isCandidateView: false,
                      );
                      break;
                    case 2:
                    default:
                      content = _buildUserGroupedGrid(
                        vm.items,
                        vm.userGists,
                        vm.favoriteUsers,
                        vm.userPriorities,
                        isCandidateView: true,
                      );
                      break;
                  }
                  return RefreshIndicator(
                    onRefresh: () =>
                        context.read<GalleryViewModel>().reloadGallery(),
                    child: content,
                  );
                },
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

  /// [JA] メインギャラリー表示順の比較関数
  /// 1. ピン留めされているグループ（priority_updated_at > 0）をピン留めされていないグループより優先して上に配置
  /// 2. ピン留め内外それぞれのグループ内において、「最新ポスト（代表アイテム）の時刻の新しい順（降順）」でソート
  /// 3. ポスト時刻が同一または判別不能な場合は元の登録順（降順）で比較
  int _compareUserEntries(
    MapEntry<String, List<TweetItem>> a,
    MapEntry<String, List<TweetItem>> b,
    Map<String, int> userPriorities,
    Map<String, int> originalIndex,
  ) {
    final isPinnedA = (userPriorities[a.key] ?? 0) > 0;
    final isPinnedB = (userPriorities[b.key] ?? 0) > 0;

    // 1. ピン留めグループと非ピン留めグループの分離
    if (isPinnedA != isPinnedB) {
      return isPinnedB ? 1 : -1;
    }

    // 2. ピン留め内外それぞれのグループ内で、最新ポスト（代表アイテム）の投稿日時の新しい順
    final thumbA = _selectThumbnailItem(a.value);
    final thumbB = _selectThumbnailItem(b.value);
    final tweetCmp = compareTweetsByNewest(thumbA, thumbB);
    if (tweetCmp != 0) return tweetCmp;

    // 3. 同一ポスト時刻の場合は元のインデックスで比較
    final idxA = originalIndex[a.key] ?? -1;
    final idxB = originalIndex[b.key] ?? -1;
    return idxB.compareTo(idxA);
  }

  Widget _buildScrollableEmptyPlaceholder(String message) {
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Center(
            child: Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.grey),
            ),
          ),
        ),
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
      if (!isCandidateView) {
        if (vm.isCandidate(key)) {
          continue;
        }
      } else {
        if (favoriteUsers.contains(key)) {
          continue;
        }
        if (!vm.isCandidate(key)) {
          continue;
        }
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
      if (!isCandidateView) {
        if (vm.isCandidate(username)) continue;
      } else {
        if (favoriteUsers.contains(username)) continue;
        if (!vm.isCandidate(username)) continue;
      }
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

    if (!isCandidateView) {
      // Users ギャラリー: お気に入り登録・ピン留め問わず最新ポストの新しい順
      entries.sort((a, b) {
        final thumbA = _selectThumbnailItem(a.value);
        final thumbB = _selectThumbnailItem(b.value);
        final tweetCmp = compareTweetsByNewest(thumbA, thumbB);
        if (tweetCmp != 0) return tweetCmp;

        final idxA = originalIndex[a.key] ?? -1;
        final idxB = originalIndex[b.key] ?? -1;
        return idxB.compareTo(idxA);
      });
    } else {
      // 候補ギャラリー: ピン留めグループ・非ピン留めグループそれぞれ「ポストされた時刻の新しい順」でソート
      entries.sort((a, b) => _compareUserEntries(a, b, userPriorities, originalIndex));
    }

    final userUsernames = entries.map((e) => e.key).toList();

    if (entries.isEmpty && isCandidateView) {
      final l10n = AppLocalizations.of(context);
      return _buildScrollableEmptyPlaceholder(l10n.noCandidatesYet);
    }

    final columnCount = context.watch<GalleryViewModel>().mainGridColumnCount;
    return AspectRatioGridView<MapEntry<String, List<TweetItem>>>(
      scrollController:
          isCandidateView ? _candidateGridController : _gridController,
      physics: const AlwaysScrollableScrollPhysics(),
      columnCount: columnCount,
      padding: const EdgeInsets.all(4),
      items: entries,
      getImageUrl: (entry) => _selectThumbnailItem(entry.value).thumbnailUrl,
      itemBuilder: (context, entry, index) {
        final username = entry.key;
        final userItems = entry.value;
        final thumbItem = _selectThumbnailItem(userItems);
        final isPinned = (userPriorities[username] ?? 0) > 0;
        return UserCard(
          username: username,
          thumbItem: thumbItem,
          isFavorite: favoriteUsers.contains(username),
          isPinned: isPinned,
          columnCount: columnCount,
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
      return _buildScrollableEmptyPlaceholder(l10n.noFavoritesYet);
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

    // ピン留めグループ・非ピン留めグループそれぞれ「ポストされた時刻の新しい順」でソート
    entries.sort((a, b) => _compareUserEntries(a, b, userPriorities, originalIndex));

    // お気に入りページ内でのスワイプスコープ（このグリッドに表示される順）
    final favUsernames = entries.map((e) => e.key).toList();

    final columnCount = context.watch<GalleryViewModel>().mainGridColumnCount;
    return AspectRatioGridView<MapEntry<String, List<TweetItem>>>(
      scrollController: _favGridController,
      physics: const AlwaysScrollableScrollPhysics(),
      columnCount: columnCount,
      padding: const EdgeInsets.all(4),
      items: entries,
      getImageUrl: (entry) => _selectThumbnailItem(entry.value).thumbnailUrl,
      itemBuilder: (context, entry, index) {
        final username = entry.key;
        final userItems = entry.value;
        final thumbItem = _selectThumbnailItem(userItems);
        final isPinned = (userPriorities[username] ?? 0) > 0;
        return UserCard(
          username: username,
          thumbItem: thumbItem,
          isFavorite: true,
          isPinned: isPinned,
          columnCount: columnCount,
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
          (username) => !vm.isCandidate(username),
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
      // グリッドと同じ優先順位降順（最新ポスト順）でユーザー一覧を構築
      final originalKeys = vm.userGists.keys.toList();
      final Map<String, int> originalIndex = {};
      for (int i = 0; i < originalKeys.length; i++) {
        originalIndex[originalKeys[i]] = i;
      }

      final Set<String> registered = {};
      final List<String> list = [];
      for (final u in originalKeys) {
        if (!vm.isCandidate(u)) {
          list.add(u);
          registered.add(u);
        }
      }
      final Map<String, List<TweetItem>> grouped = {};
      for (final item in vm.items) {
        final key = item.extractedUsername ?? '_unknown';
        grouped.putIfAbsent(key, () => []).add(item);
        if (!vm.isCandidate(key) && !registered.contains(key)) {
          list.add(key);
          registered.add(key);
        }
      }

      list.sort((a, b) {
        final itemsA = grouped[a] ?? [];
        final itemsB = grouped[b] ?? [];
        final thumbA = _selectThumbnailItem(itemsA);
        final thumbB = _selectThumbnailItem(itemsB);
        final tweetCmp = compareTweetsByNewest(thumbA, thumbB);
        if (tweetCmp != 0) return tweetCmp;

        final idxA = originalIndex[a] ?? -1;
        final idxB = originalIndex[b] ?? -1;
        return idxB.compareTo(idxA);
      });

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
