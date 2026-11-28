import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../l10n/app_localizations.dart';
import '../../models/data_source.dart';
import '../../models/tweet_item.dart';
import '../../utils/date_helper.dart';
import '../../viewmodels/gallery_viewmodel.dart';
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
    final l10n = AppLocalizations.of(context);
    String gistIdInput = "";

    void handleUnlock() {
      Navigator.pop(context);
      if (gistIdInput.isNotEmpty) {
        _loadAndRestore(gistIdInput);
      } else {
        showErrorSnackBar(context, l10n.enterGistIdError);
        if (mounted) _showPasswordDialog(canCancel: canCancel);
      }
    }

    showDialog(
      context: context,
      barrierDismissible: canCancel,
      builder: (context) => AlertDialog(
        title: Text(l10n.unlockGalleryTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(l10n.enterGistIdPrompt),
            const SizedBox(height: 10),
            TextField(
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                labelText: l10n.gistIdLabel,
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
              child: Text(l10n.cancel),
            ),
          TextButton(onPressed: handleUnlock, child: Text(l10n.unlock)),
        ],
      ),
    );
  }

  Future<void> _loadAndRestore(String gistId) async {
    final vm = context.read<GalleryViewModel>();
    await vm.loadGallery(gistId);
    if (!mounted) return;
    if (vm.status == GalleryStatus.error) {
      showErrorSnackBar(context, vm.errorMessage);
      _showPasswordDialog(canCancel: true);
    } else {
      _restoreScrollPosition();
    }
  }

  // --- お気に入り Gist 保存・読込 ---

  Future<void> _saveFavoritesToGist() async {
    final l10n = AppLocalizations.of(context);
    final vm = context.read<GalleryViewModel>();
    showProgressDialog(context, message: l10n.savingToGist);

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
      showErrorSnackBar(context, msg);
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
          decoration: InputDecoration(
            labelText: l10n.gistIdLabel,
            border: const OutlineInputBorder(),
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
    controller.dispose();

    if (gistId == null || gistId.trim().isEmpty || !mounted) return;

    showProgressDialog(context, message: l10n.loadingFromGist);

    final success = await vm.loadFavoritesFromGist(gistId.trim());
    if (!mounted) return;
    Navigator.pop(context);

    if (success) {
      showSuccessSnackBar(context, l10n.loadedFavoritesSuccess);
    } else {
      showErrorSnackBar(context, l10n.loadFailedCheckId);
    }
  }

  // --- Append 関連 ---

  Future<void> _handleAppend({String? user}) =>
      queueUserWithConfigDialog(context, user ?? '');

  Future<void> _showDeleteConfirmDialog() async {
    final l10n = AppLocalizations.of(context);
    final vm = context.read<GalleryViewModel>();
    final count = vm.selectedCount;

    if (!await showDeleteConfirmDialog(context, count) || !mounted) return;

    showProgressDialog(context);

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
        showSuccessSnackBar(context, l10n.deletedCount(count));
      }
    } else if (mounted) {
      showErrorSnackBar(context, vm.errorMessage);
    }
  }

  /// 削除確認ダイアログの共通処理
  Future<void> _confirmDelete({
    required String title,
    required Future<bool> Function() onDelete,
    required String successMessage,
  }) async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(l10n.deleteAllDataWarning),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.delete, style: const TextStyle(color: Colors.red)),
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
        showErrorSnackBar(context, l10n.deleteFailedGeneric);
      }
    }
  }

  Future<void> _confirmDeleteUser(String username) {
    final l10n = AppLocalizations.of(context);
    return _confirmDelete(
      title: l10n.deleteUserConfirmTitle(username),
      onDelete: () => context.read<GalleryViewModel>().deleteUser(username),
      successMessage: l10n.deletedUserSuccess(username),
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

    // 3. 見つからない場合 → 対象プラットフォームで存在確認して新規追加
    final l10n = AppLocalizations.of(context);
    final username = inputTrimmed;
    showProgressDialog(
      context,
      message: l10n.verifyingOnSource(vm.currentSource.displayName),
    );

    final exists = await vm.checkUserExistsOnX(username);
    if (mounted) Navigator.pop(context);
    if (!mounted) return;

    if (!exists) {
      showErrorSnackBar(
        context,
        l10n.userNotFoundOnSource(username, vm.currentSource.displayName),
      );
      return;
    }

    await queueUserWithConfigDialog(context, username, registerOnSuccess: true);
  }

  Future<void> _handleSwitchDataSource(DataSource newSource) async {
    final vm = context.read<GalleryViewModel>();
    if (vm.currentSource == newSource) return;
    final l10n = AppLocalizations.of(context);
    final loaded = await vm.switchSource(newSource);
    if (!mounted) return;
    if (loaded) {
      if (vm.status == GalleryStatus.error) {
        showErrorSnackBar(context, vm.errorMessage);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.switchedDataSource(newSource.displayName)),
            duration: const Duration(seconds: 2),
          ),
        );
        _restoreScrollPosition();
      }
    } else {
      _showPasswordDialog(canCancel: true);
    }
  }

  /// ピン留め短押し時: アカウントの優先順位を最上位に更新しトースト通知を表示
  Future<void> _handlePriorityTap(String username) async {
    final vm = context.read<GalleryViewModel>();
    await pinAccountToTop(context, vm, username);
  }

  // --- 外部連携 ---
  Future<void> _launchX(String username) {
    final source = context.read<GalleryViewModel>().currentSource;
    return launchExternalUrl(context, source.profileUrl(username));
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

  int _toLogicalTab(int rawPage) =>
      ((rawPage % _kTabCount) + _kTabCount) % _kTabCount;

  Widget _buildDataSourceButton(GalleryViewModel vm, AppLocalizations l10n) {
    final Color badgeFill;
    final Color badgeBorder;
    switch (vm.currentSource) {
      case DataSource.instagram:
        badgeFill = Colors.pinkAccent.withValues(alpha: 0.22);
        badgeBorder = Colors.pinkAccent;
        break;
      case DataSource.tiktok:
        badgeFill = Colors.cyanAccent.withValues(alpha: 0.22);
        badgeBorder = Colors.cyanAccent;
        break;
      case DataSource.x:
        badgeFill = Colors.white12;
        badgeBorder = Colors.white30;
        break;
    }

    return PopupMenuButton<DataSource>(
      tooltip: l10n.tooltipSwitchDataSource,
      onSelected: _handleSwitchDataSource,
      itemBuilder: (_) => DataSource.values
          .map(
            (source) => CheckedPopupMenuItem<DataSource>(
              value: source,
              checked: vm.currentSource == source,
              child: Text(source.displayName),
            ),
          )
          .toList(),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: badgeFill,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: badgeBorder),
          ),
          child: Text(
            vm.currentSource.shortLabel,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
          ),
        ),
      ),
    );
  }

  Widget _buildRootScaffold(GalleryViewModel vm, bool isAuthenticated) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _pageController.hasClients) {
        final currentRaw = _pageController.page?.round() ??
            (_kLoopCenter + _currentPage);
        final currentLogical = _toLogicalTab(currentRaw);
        if (currentLogical != _currentPage) {
          final target = currentRaw - currentLogical + _currentPage;
          _pageController.jumpToPage(target);
        }
      }
    });

    final l10n = AppLocalizations.of(context);
    final isFavPage = _currentPage == 0;
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
              _buildDataSourceButton(vm, l10n),
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
                    case 'random_all':
                      _openCurrentTabRandomMode(videosOnly: false);
                      break;
                    case 'random_video':
                      _openCurrentTabRandomMode(videosOnly: true);
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
                  PopupMenuItem(
                    value: 'random_all',
                    child: ListTile(
                      leading: const Icon(Icons.shuffle),
                      title: Text(l10n.randomSelectionAll),
                      dense: true,
                    ),
                  ),
                  PopupMenuItem(
                    value: 'random_video',
                    child: ListTile(
                      leading: const Icon(Icons.videocam_outlined),
                      title: Text(l10n.randomSelectionVideos),
                      dense: true,
                    ),
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
                    child: ListTile(
                      leading: const Icon(Icons.vpn_key_outlined),
                      title: Text(l10n.gistIdLabel),
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
            ? Center(child: Text(l10n.waitingForAuthentication))
            : vm.items.isEmpty
            ? const Center(child: CircularProgressIndicator())
            : PageView.builder(
                controller: _pageController,
                onPageChanged: (rawPage) {
                  final logicalPage = _toLogicalTab(rawPage);
                  if (_currentPage != logicalPage) {
                    setState(() => _currentPage = logicalPage);
                  }
                },
                itemBuilder: (context, index) {
                  final logicalIndex = _toLogicalTab(index);
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
          ? Center(child: Text(l10n.waitingForAuthentication))
          : (items.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : TweetGridView(
                    items: items,
                    selectedIds: selectedIds,
                    scrollController: _gridController,
                    username: widget.userGistUsername,
                    userGistId: widget.userGistId,
                    onItemDeleted: (deletedId, _) {
                      final currentItems =
                          _localItems ?? widget.initialItems ?? [];
                      setState(() {
                        _localItems = currentItems
                            .where((item) => item.id != deletedId)
                            .toList();
                      });
                    },
                    onUserEmptied: () {
                      if (widget.userGistUsername != null && mounted) {
                        Navigator.pop(context);
                      }
                    },
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

  /// [JA] ユーザーごとのグループ化＆ソート済みエントリを構築する共通ヘルパー
  /// [EN] Shared helper to group items by user and sort entries consistently
  List<MapEntry<String, List<TweetItem>>> _buildOrderedUserEntries({
    required List<TweetItem> items,
    required List<String> seedUsernames,
    required Map<String, int> userPriorities,
    required bool prioritizePinned,
    bool includeEmptySeedUsers = true,
    bool Function(String username)? userFilter,
  }) {
    final Map<String, List<TweetItem>> grouped = {};
    for (final item in items) {
      final key = item.extractedUsername ?? '_unknown';
      if (userFilter != null && !userFilter(key)) continue;
      grouped.putIfAbsent(key, () => []).add(item);
    }

    final Map<String, int> originalIndex = {
      for (int i = 0; i < seedUsernames.length; i++) seedUsernames[i]: i,
    };

    final List<MapEntry<String, List<TweetItem>>> entries = [];
    final Set<String> addedUsers = {};

    for (final username in seedUsernames) {
      if (userFilter != null && !userFilter(username)) continue;
      final userItems = grouped[username] ?? [];
      if (!includeEmptySeedUsers && userItems.isEmpty) continue;
      entries.add(MapEntry(username, userItems));
      addedUsers.add(username);
    }

    for (final entry in grouped.entries) {
      if (!addedUsers.contains(entry.key)) {
        entries.add(entry);
        addedUsers.add(entry.key);
      }
    }

    entries.sort((a, b) {
      if (prioritizePinned) {
        return _compareUserEntries(a, b, userPriorities, originalIndex);
      }
      final tweetCmp = compareTweetsByNewest(
        _selectThumbnailItem(a.value),
        _selectThumbnailItem(b.value),
      );
      if (tweetCmp != 0) return tweetCmp;
      final idxA = originalIndex[a.key] ?? -1;
      final idxB = originalIndex[b.key] ?? -1;
      return idxB.compareTo(idxA);
    });

    return entries;
  }

  /// [JA] UserCard グリッドの共通レンダラー（Users / Candidate / Favorites 共通）
  /// [EN] Shared AspectRatioGridView renderer for user cards
  Widget _buildUserCardsGrid({
    required List<MapEntry<String, List<TweetItem>>> entries,
    required ScrollController scrollController,
    required Set<String> favoriteUsers,
    required Map<String, int> userPriorities,
    bool forceFavorite = false,
  }) {
    final scopeUsernames = entries.map((e) => e.key).toList();
    final columnCount = context.watch<GalleryViewModel>().mainGridColumnCount;

    return AspectRatioGridView<MapEntry<String, List<TweetItem>>>(
      scrollController: scrollController,
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
        final vm = context.read<GalleryViewModel>();
        final hasVideo = (vm.userGistEntries[username]?.hasVideo ?? false) ||
            userItems.any((i) => i.isVideo);
        return UserCard(
          username: username,
          thumbItem: thumbItem,
          isFavorite: forceFavorite || favoriteUsers.contains(username),
          isPinned: isPinned,
          columnCount: columnCount,
          hasVideo: hasVideo,
          onTap: () => _openUserGallery(username, scope: scopeUsernames),
          onFavoriteTap: () => vm.toggleFavorite(username),
          onLongPress: () => _confirmDeleteUser(username),
        );
      },
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
    final entries = _buildOrderedUserEntries(
      items: items,
      seedUsernames: userGists.keys.toList(),
      userPriorities: userPriorities,
      prioritizePinned: isCandidateView,
      userFilter: (u) => isCandidateView
          ? !favoriteUsers.contains(u) && vm.isCandidate(u)
          : !vm.isCandidate(u),
    );

    if (entries.isEmpty && isCandidateView) {
      final l10n = AppLocalizations.of(context);
      return _buildScrollableEmptyPlaceholder(l10n.noCandidatesYet);
    }

    return _buildUserCardsGrid(
      entries: entries,
      scrollController:
          isCandidateView ? _candidateGridController : _gridController,
      favoriteUsers: favoriteUsers,
      userPriorities: userPriorities,
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

    final entries = _buildOrderedUserEntries(
      items: favoriteItems,
      seedUsernames: favoriteUsers.toList(),
      userPriorities: userPriorities,
      prioritizePinned: true,
      includeEmptySeedUsers: false,
    );

    return _buildUserCardsGrid(
      entries: entries,
      scrollController: _favGridController,
      favoriteUsers: favoriteUsers,
      userPriorities: userPriorities,
      forceFavorite: true,
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

  Future<void> _openRandomMode({
    required List<String> usernames,
    required String emptyMessage,
    required String tabTitle,
    required bool videosOnly,
  }) async {
    final l10n = AppLocalizations.of(context);
    if (usernames.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(emptyMessage)),
        );
      }
      return;
    }

    final modeLabel =
        videosOnly ? l10n.randomSelectionVideos : l10n.randomSelectionAll;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => RandomGallerySwipePage(
          usernames: usernames,
          title: '$modeLabel ($tabTitle)',
          videosOnly: videosOnly,
        ),
      ),
    );
  }

  /// [JA] 現在アクティブなタブ（Favorites / Users / Candidates）のユーザーからランダム選択を開く
  /// [EN] Opens random selection scoped to the currently active root gallery tab
  Future<void> _openCurrentTabRandomMode({required bool videosOnly}) {
    final l10n = AppLocalizations.of(context);
    final vm = context.read<GalleryViewModel>();
    if (_currentPage == 0) {
      return _openRandomMode(
        usernames: vm.favoriteUsers.toList(),
        emptyMessage: l10n.noFavoriteUsersRegistered,
        tabTitle: l10n.tabFavorites,
        videosOnly: videosOnly,
      );
    }
    if (_currentPage == 1) {
      final usernames = _getAllUsernames(vm.items)
          .where((username) => !vm.isCandidate(username))
          .toList();
      return _openRandomMode(
        usernames: usernames,
        emptyMessage: l10n.userNotFound,
        tabTitle: l10n.tabUsers,
        videosOnly: videosOnly,
      );
    }
    final usernames = _getAllUsernames(vm.items)
        .where(
          (username) =>
              !vm.favoriteUsers.contains(username) && vm.isCandidate(username),
        )
        .toList();
    return _openRandomMode(
      usernames: usernames,
      emptyMessage: l10n.noCandidatesYet,
      tabTitle: l10n.tabCandidate,
      videosOnly: videosOnly,
    );
  }

  Future<void> _openUserGallery(String username, {List<String>? scope}) async {
    final vm = context.read<GalleryViewModel>();

    List<String> sortedUsernames;
    if (scope != null) {
      // お気に入りなど呼び出し元が既に順序を決めているケース
      sortedUsernames = scope;
    } else {
      // グリッドと同じ最新ポスト順でユーザー一覧を構築
      sortedUsernames = _buildOrderedUserEntries(
        items: vm.items,
        seedUsernames: vm.userGists.keys.toList(),
        userPriorities: vm.userPriorities,
        prioritizePinned: false,
        userFilter: (u) => !vm.isCandidate(u),
      ).map((e) => e.key).toList();
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
