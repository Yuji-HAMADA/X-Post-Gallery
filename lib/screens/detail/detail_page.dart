import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../l10n/app_localizations.dart';
import '../../models/tweet_item.dart';
import '../../viewmodels/gallery_viewmodel.dart';
import '../gallery/components/dialog_helpers.dart';
import 'detail_image_item.dart';
import 'horizontal_detail_page.dart';

/// [JA] ポスト詳細スワイプ表示画面（縦並び画像・テキスト・ズーム対応）
/// [EN] Post detail swipe page (vertical images, text, and zoom support)
class DetailPage extends StatefulWidget {
  final List<TweetItem> items;
  final int initialIndex;
  final String? username;
  final String? userGistId;
  final void Function(String deletedId, int remainingCount)? onItemDeleted;

  const DetailPage({
    super.key,
    required this.items,
    required this.initialIndex,
    this.username,
    this.userGistId,
    this.onItemDeleted,
  });

  @override
  State<DetailPage> createState() => _DetailPageState();
}

class _DetailPageState extends State<DetailPage> {
  late PageController _pageController;
  late List<TweetItem> _items;
  late int _currentIndex;
  bool _isZoomed = false;
  final ValueNotifier<bool> _firstVideoMutedNotifier = ValueNotifier<bool>(true);

  @override
  void initState() {
    super.initState();
    _items = List<TweetItem>.from(widget.items);
    _currentIndex = _items.isEmpty
        ? 0
        : widget.initialIndex.clamp(0, _items.length - 1);
    _pageController = PageController(initialPage: _currentIndex);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _preloadAdjacent(_currentIndex);
    });
  }

  /// [JA] 前後のアイテムの画像を事前キャッシュ
  /// [EN] Pre-caches images for adjacent items
  void _preloadAdjacent(int index) {
    for (final offset in [-1, 1]) {
      final i = index + offset;
      if (i < 0 || i >= _items.length) continue;
      for (final url in _items[i].origUrls) {
        precacheImage(NetworkImage(url), context);
      }
    }
  }

  @override
  void dispose() {
    _pageController.dispose();
    _firstVideoMutedNotifier.dispose();
    super.dispose();
  }

  void _handleZoomChanged(bool zoomed) {
    if (_isZoomed != zoomed) {
      setState(() => _isZoomed = zoomed);
    }
  }

  /// [JA] 現在のポストが画像のみ（動画を含まない）を持つかどうかを判定
  /// [EN] Determines whether the current post contains images without videos
  bool get _hasImages {
    if (_currentIndex < 0 || _currentIndex >= _items.length) return false;
    final item = _items[_currentIndex];
    // 動画を含むポストは横方向表示モードへの遷移ボタンは不要
    if (item.isVideo) return false;
    return item.origUrls.isNotEmpty;
  }

  /// [JA] 現在のポストが動画を含むかどうかを判定
  /// [EN] Determines whether the current post contains a video
  bool get _hasVideo {
    if (_currentIndex < 0 || _currentIndex >= _items.length) return false;
    return _items[_currentIndex].isVideo;
  }

  /// [JA] 現在表示中のポストを削除可能かどうかを判定
  /// [EN] Determines whether the currently displayed post can be deleted
  bool _canDeleteCurrentItem(GalleryViewModel? vm) {
    if (vm == null || _currentIndex < 0 || _currentIndex >= _items.length) {
      return false;
    }
    if (widget.userGistId != null && widget.userGistId!.isNotEmpty) {
      return true;
    }
    final uname = widget.username ?? _items[_currentIndex].extractedUsername;
    if (uname == null || uname.isEmpty) return false;
    return (vm.getGistIdForUser(uname) ?? '').isNotEmpty;
  }

  /// [JA] 指定ポストを確認ダイアログ付きで削除し、一覧状態を更新する
  /// [EN] Confirms and deletes the specified post, updating local items state
  Future<bool> _handleDeleteItem(
    BuildContext dialogContext,
    TweetItem item,
  ) async {
    final remainingCount = await confirmAndDeleteSingleTweet(
      dialogContext,
      item,
      username: widget.username,
      gistId: widget.userGistId,
      allUserItems:
          (widget.userGistId != null && widget.userGistId!.isNotEmpty)
              ? List<TweetItem>.from(_items)
              : null,
    );
    if (remainingCount == null) return false;

    widget.onItemDeleted?.call(item.id, remainingCount);
    if (!mounted) return true;

    final removedIdx = _items.indexWhere((e) => e.id == item.id);
    if (removedIdx >= 0) {
      _items.removeAt(removedIdx);
    }

    if (_items.isEmpty) {
      // HorizontalDetailPage 側が上に積まれている場合はそちらが戻った後に閉じる
      if (ModalRoute.of(context)?.isCurrent == true) {
        Navigator.pop(context, remainingCount == 0);
      }
      return true;
    }

    final nextIndex = _currentIndex.clamp(0, _items.length - 1);
    setState(() {
      _currentIndex = nextIndex;
      _isZoomed = false;
    });
    _firstVideoMutedNotifier.value = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_pageController.hasClients) {
        _pageController.jumpToPage(_currentIndex);
      }
      _preloadAdjacent(_currentIndex);
    });
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final vm = context.read<GalleryViewModel?>();
    final canDelete = _canDeleteCurrentItem(vm);

    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Colors.white,
        title: null,
        actions: [
          if (_hasImages)
            IconButton(
              icon: const Icon(Icons.view_carousel_outlined),
              tooltip: l10n.tooltipSwitchToHorizontal,
              onPressed: () async {
                final newIndex = await Navigator.push<int>(
                  context,
                  MaterialPageRoute(
                    builder: (_) => HorizontalDetailPage(
                      items: List<TweetItem>.from(_items),
                      initialIndex: _currentIndex,
                      onDeleteItem: canDelete
                          ? (hContext, item) => _handleDeleteItem(hContext, item)
                          : null,
                    ),
                  ),
                );
                if (!context.mounted) return;
                if (_items.isEmpty) {
                  Navigator.pop(context, true);
                  return;
                }
                if (newIndex != null) {
                  final clamped = newIndex.clamp(0, _items.length - 1);
                  if (clamped != _currentIndex) {
                    _pageController.jumpToPage(clamped);
                    setState(() {
                      _currentIndex = clamped;
                    });
                  }
                }
              },
            ),
          if (_hasVideo)
            ValueListenableBuilder<bool>(
              valueListenable: _firstVideoMutedNotifier,
              builder: (context, isMuted, _) {
                return IconButton(
                  icon: Icon(
                    isMuted ? Icons.volume_off : Icons.volume_up,
                    color: Colors.white,
                  ),
                  tooltip: isMuted
                      ? AppLocalizations.of(context).tooltipUnmute
                      : AppLocalizations.of(context).tooltipMute,
                  onPressed: () {
                    _firstVideoMutedNotifier.value =
                        !_firstVideoMutedNotifier.value;
                  },
                );
              },
            ),
          if (canDelete)
            IconButton(
              icon: const Icon(Icons.delete_outline, color: Colors.white),
              tooltip: l10n.delete,
              onPressed: () =>
                  _handleDeleteItem(context, _items[_currentIndex]),
            ),
        ],
      ),
      body: PageView.builder(
        controller: _pageController,
        physics: _isZoomed
            ? const NeverScrollableScrollPhysics()
            : const BouncingScrollPhysics(),
        itemCount: _items.length,
        onPageChanged: (index) {
          setState(() {
            _currentIndex = index;
            _isZoomed = false;
          });
          _firstVideoMutedNotifier.value = true;
          _preloadAdjacent(index);
        },
        itemBuilder: (context, index) {
          return DetailImageItem(
            key: ValueKey(_items[index].id),
            item: _items[index],
            onZoomChanged: _handleZoomChanged,
            muteNotifier:
                index == _currentIndex ? _firstVideoMutedNotifier : null,
          );
        },
      ),
    );
  }
}
