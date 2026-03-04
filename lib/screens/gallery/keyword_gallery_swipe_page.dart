import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/tweet_item.dart';
import '../../viewmodels/gallery_viewmodel.dart';
import 'components/append_config_dialog.dart';
import 'components/dialog_helpers.dart';
import 'components/tweet_grid_view.dart';

/// 複数キーワードギャラリーを左右スワイプで切り替えるページ
class KeywordGallerySwipePage extends StatefulWidget {
  final List<String> keywords;
  final List<String> childGistIds;
  final int initialIndex;

  const KeywordGallerySwipePage({
    super.key,
    required this.keywords,
    required this.childGistIds,
    required this.initialIndex,
  });

  @override
  State<KeywordGallerySwipePage> createState() =>
      _KeywordGallerySwipePageState();
}

class _KeywordGallerySwipePageState extends State<KeywordGallerySwipePage> {
  late final PageController _pageController;
  late int _currentIndex;

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

  String get _currentKeyword => widget.keywords[_currentIndex];

  ScrollController _controllerFor(String keyword) {
    return _scrollControllers.putIfAbsent(keyword, () => ScrollController());
  }

  Future<void> _loadPage(int index) async {
    final keyword = widget.keywords[index];
    if (_loadedItems.containsKey(keyword)) return;
    setState(() => _loading[keyword] = true);

    final vm = context.read<GalleryViewModel>();
    try {
      final items = await vm.fetchKeywordItems(keyword);
      if (mounted) setState(() => _loadedItems[keyword] = items);
    } catch (_) {
      if (mounted) setState(() => _loadedItems[keyword] = []);
    } finally {
      if (mounted) setState(() => _loading[keyword] = false);
    }
  }

  void _onPageChanged(int index) {
    context.read<GalleryViewModel>().clearSelection();
    setState(() => _currentIndex = index);
    _loadPage(index);
    if (index + 1 < widget.keywords.length) _loadPage(index + 1);
    if (index - 1 >= 0) _loadPage(index - 1);
  }

  // --- Append ---

  Future<void> _handleAppend(String keyword) async {
    final result = await AppendConfigDialog.show(context);
    if (result == null || !mounted) return;

    final vm = context.read<GalleryViewModel>();
    if (!await vm.isAdminAuthenticated()) {
      if (mounted) showErrorSnackBar(context, 'マスターGist IDでログインしてください');
      return;
    }

    // キーワード検索のAppendをキューに追加
    final success = await vm.queueKeywordForFetch(
      keyword,
      count: result.count,
      stopOnExisting: result.stopOnExisting,
    );

    if (mounted) {
      if (success) {
        showSuccessSnackBar(context, 'キューに追加しました: $keyword');
      } else {
        showErrorSnackBar(context, 'キューへの追加に失敗しました');
      }
    }
  }

  // --- Delete ---

  Future<void> _showDeleteConfirmDialog(String keyword) async {
    final vm = context.read<GalleryViewModel>();
    final count = vm.selectedCount;

    if (!await showDeleteConfirmDialog(context, count)) return;
    if (!mounted) return;

    showProgressDialog(context);

    final gistId = widget.childGistIds[_currentIndex];
    final currentItems = _loadedItems[keyword] ?? [];
    final deletedIds = Set<String>.from(vm.selectedIds);
    final remainingCount = await vm.deleteSelectedFromKeywordGist(
      gistId,
      currentItems,
    );

    if (mounted) Navigator.pop(context);

    if (remainingCount != null) {
      setState(() {
        _loadedItems[keyword] = currentItems
            .where((item) => !deletedIds.contains(item.id))
            .toList();
      });
      if (mounted) showSuccessSnackBar(context, '$count 件を削除しました');
    } else {
      if (mounted) showErrorSnackBar(context, vm.errorMessage);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<GalleryViewModel>(
      builder: (context, vm, _) {
        final keyword = _currentKeyword;
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
                : Text(keyword),
            actions: [
              if (isSelectionMode)
                IconButton(
                  icon: const Icon(Icons.delete, color: Colors.redAccent),
                  onPressed: () => _showDeleteConfirmDialog(keyword),
                )
              else
                IconButton(
                  icon: const Icon(Icons.add),
                  tooltip: '追加',
                  onPressed: () => _handleAppend(keyword),
                ),
            ],
          ),
          body: PageView.builder(
            controller: _pageController,
            onPageChanged: _onPageChanged,
            itemCount: widget.keywords.length,
            itemBuilder: (context, index) {
              final kw = widget.keywords[index];
              final isLoadingPage = _loading[kw] ?? false;
              final items = _loadedItems[kw];

              if (isLoadingPage || items == null) {
                return const Center(child: CircularProgressIndicator());
              }
              if (items.isEmpty) {
                return const Center(child: Text('ポストが見つかりませんでした'));
              }
              return TweetGridView(
                items: items,
                selectedIds: vm.selectedIds,
                scrollController: _controllerFor(kw),
              );
            },
          ),
        );
      },
    );
  }
}
