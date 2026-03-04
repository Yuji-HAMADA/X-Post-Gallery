import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../models/tweet_item.dart';
import '../../viewmodels/gallery_viewmodel.dart';
import 'components/append_config_dialog.dart';
import 'components/dialog_helpers.dart';
import 'components/tweet_grid_view.dart';

/// 複数ユーザーギャラリーを左右スワイプで切り替えるページ
class UserGallerySwipePage extends StatefulWidget {
  final List<String> usernames;
  final List<String?> userGistIds;
  final int initialIndex;

  const UserGallerySwipePage({
    super.key,
    required this.usernames,
    required this.userGistIds,
    required this.initialIndex,
  });

  @override
  State<UserGallerySwipePage> createState() => _UserGallerySwipePageState();
}

class _UserGallerySwipePageState extends State<UserGallerySwipePage> {
  late final PageController _pageController;
  late int _currentIndex;

  // ユーザー名 → ロード済みアイテム（null = 未ロード）
  final Map<String, List<TweetItem>?> _loadedItems = {};
  final Map<String, bool> _loading = {};
  final Map<String, ScrollController> _scrollControllers = {};

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: widget.initialIndex);
    _loadPage(_currentIndex);
  }

  @override
  void dispose() {
    _pageController.dispose();
    for (final c in _scrollControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  String get _currentUsername => widget.usernames[_currentIndex];
  String? get _currentGistId => widget.userGistIds[_currentIndex];

  ScrollController _controllerFor(String username) {
    return _scrollControllers.putIfAbsent(username, () => ScrollController());
  }

  Future<void> _loadPage(int index) async {
    final username = widget.usernames[index];
    if (_loadedItems.containsKey(username)) return; // 既にロード済みまたはロード中
    setState(() => _loading[username] = true);

    final vm = context.read<GalleryViewModel>();
    try {
      final items = await vm.fetchUserItems(username);
      if (mounted) setState(() => _loadedItems[username] = items);
    } catch (_) {
      if (mounted) setState(() => _loadedItems[username] = []);
    } finally {
      if (mounted) setState(() => _loading[username] = false);
    }
  }

  void _onPageChanged(int index) {
    context.read<GalleryViewModel>().clearSelection();
    setState(() => _currentIndex = index);
    _loadPage(index);
    // 隣のページをプリロード
    if (index + 1 < widget.usernames.length) _loadPage(index + 1);
    if (index - 1 >= 0) _loadPage(index - 1);
  }

  // --- ダイアログ系 ---

  Future<void> _handleAppend(String username) async {
    final result = await AppendConfigDialog.show(context);
    if (result == null || !mounted) return;

    final vm = context.read<GalleryViewModel>();
    if (!await vm.isAdminAuthenticated()) {
      if (mounted) showErrorSnackBar(context, 'マスターGist IDでログインしてください');
      return;
    }

    final success = await vm.queueUserForFetch(
      username,
      count: result.count,
      stopOnExisting: result.stopOnExisting,
    );
    if (mounted) {
      if (success) {
        showSuccessSnackBar(context, 'キューに追加しました: @$username');
      } else {
        showErrorSnackBar(context, 'キューへの追加に失敗しました');
      }
    }
  }

  Future<void> _showDeleteConfirmDialog(String username) async {
    final vm = context.read<GalleryViewModel>();
    final count = vm.selectedCount;

    if (!await showDeleteConfirmDialog(context, count)) return;
    if (!mounted) return;

    showProgressDialog(context);

    final gistId = widget.userGistIds[_currentIndex]!;
    final currentItems = _loadedItems[username] ?? [];
    final deletedIds = Set<String>.from(vm.selectedIds);
    final remainingCount = await vm.deleteSelectedFromUserGist(
      gistId,
      username,
      currentItems,
    );

    if (mounted) Navigator.pop(context);

    if (remainingCount != null) {
      if (remainingCount == 0) {
        await vm.removeUserFromMaster(username);
        if (mounted) Navigator.pop(context);
      } else {
        setState(() {
          _loadedItems[username] = currentItems
              .where((item) => !deletedIds.contains(item.id))
              .toList();
        });
      }
      if (mounted) showSuccessSnackBar(context, '$count 件を削除しました');
    } else {
      if (mounted) showErrorSnackBar(context, vm.errorMessage);
    }
  }

  Future<void> _launchX(String username) async {
    final url = Uri.parse('https://x.com/$username');
    try {
      if (await canLaunchUrl(url)) {
        await launchUrl(url, mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      if (mounted) showErrorSnackBar(context, 'Link error: $e');
    }
  }

  // --- ビルド ---

  @override
  Widget build(BuildContext context) {
    return Consumer<GalleryViewModel>(
      builder: (context, vm, _) {
        final username = _currentUsername;
        final gistId = _currentGistId;
        final isSelectionMode = vm.isSelectionMode;

        return Scaffold(
          appBar: AppBar(
            leading: isSelectionMode
                ? IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: vm.clearSelection,
                  )
                : null,
            title: isSelectionMode
                ? Text('${vm.selectedCount}件選択中')
                : GestureDetector(
                    onTap: () => _launchX(username),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(
                            '@$username',
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
                  ),
            actions: [
              if (isSelectionMode && gistId != null)
                IconButton(
                  icon: const Icon(Icons.delete, color: Colors.redAccent),
                  onPressed: () => _showDeleteConfirmDialog(username),
                )
              else ...[
                IconButton(
                  icon: Icon(
                    vm.isFavorite(username)
                        ? Icons.favorite
                        : Icons.favorite_border,
                    color: vm.isFavorite(username) ? Colors.redAccent : null,
                  ),
                  onPressed: () => vm.toggleFavorite(username),
                ),
                IconButton(
                  icon: const Icon(Icons.add),
                  tooltip: '追加',
                  onPressed: () => _handleAppend(username),
                ),
              ],
            ],
          ),
          body: PageView.builder(
            controller: _pageController,
            onPageChanged: _onPageChanged,
            itemCount: widget.usernames.length,
            itemBuilder: (context, index) {
              final uname = widget.usernames[index];
              final isLoadingPage = _loading[uname] ?? false;
              final items = _loadedItems[uname];

              if (isLoadingPage || items == null) {
                return const Center(child: CircularProgressIndicator());
              }
              if (items.isEmpty) {
                return const Center(child: Text('ポストが見つかりませんでした'));
              }
              return TweetGridView(
                items: items,
                selectedIds: vm.selectedIds,
                scrollController: _controllerFor(uname),
              );
            },
          ),
        );
      },
    );
  }
}
