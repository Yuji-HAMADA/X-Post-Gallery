import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/tweet_item.dart';
import '../../viewmodels/gallery_viewmodel.dart';
import 'components/append_config_dialog.dart';
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
      if (mounted) _showErrorSnackBar('マスターGist IDでログインしてください');
      return;
    }

    // キーワード検索のAppendをトリガー
    await vm.executeAppend(
      hashtag: keyword,
      count: result.count,
      stopOnExisting: result.stopOnExisting,
    );

    if (mounted) {
      final status = vm.appendStatus;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            status == AppendStatus.completed ? '追加完了: $keyword' : '追加に失敗しました',
          ),
          backgroundColor: status == AppendStatus.completed
              ? Colors.green
              : Colors.redAccent,
        ),
      );
      vm.clearAppendStatus();

      // リロード
      if (status == AppendStatus.completed) {
        setState(() => _loadedItems.remove(keyword));
        _loadPage(_currentIndex);
      }
    }
  }

  // --- Delete ---

  Future<void> _showDeleteConfirmDialog(String keyword) async {
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

    if (confirmed != true || !mounted) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
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
