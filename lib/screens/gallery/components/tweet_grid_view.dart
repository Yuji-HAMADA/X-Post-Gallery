import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../models/tweet_item.dart';
import '../../../viewmodels/gallery_viewmodel.dart';
import '../../detail/detail_page.dart';
import 'aspect_ratio_grid_view.dart';
import 'thumbnail_video_player.dart';

/// ツイート画像グリッド（gallery_page / user_gallery_swipe_page 共通）
class TweetGridView extends StatelessWidget {
  final List<TweetItem> items;
  final Set<String> selectedIds;
  final ScrollController scrollController;
  final VoidCallback? onNavigatePreviousAccount;
  final VoidCallback? onNavigateNextAccount;
  final bool? hasPreviousAccount;
  final bool? hasNextAccount;

  const TweetGridView({
    super.key,
    required this.items,
    required this.selectedIds,
    required this.scrollController,
    this.onNavigatePreviousAccount,
    this.onNavigateNextAccount,
    this.hasPreviousAccount,
    this.hasNextAccount,
  });

  @override
  Widget build(BuildContext context) {
    final columnCount =
        context.watch<GalleryViewModel?>()?.gridColumnCount ?? 3;
    return AspectRatioGridView<TweetItem>(
      scrollController: scrollController,
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(4),
      columnCount: columnCount,
      items: items,
      getImageUrl: (item) => item.thumbnailUrl,
      itemBuilder: (context, item, index) => TweetGridItem(
        items: items,
        index: index,
        selectedIds: selectedIds,
        columnCount: columnCount,
        onNavigatePreviousAccount: onNavigatePreviousAccount,
        onNavigateNextAccount: onNavigateNextAccount,
        hasPreviousAccount: hasPreviousAccount,
        hasNextAccount: hasNextAccount,
      ),
    );
  }
}

/// グリッド内の1件分（画像 + 選択オーバーレイ + 1列時複数画像横スクロール）
class TweetGridItem extends StatefulWidget {
  final List<TweetItem> items;
  final int index;
  final Set<String> selectedIds;
  final int columnCount;
  final VoidCallback? onNavigatePreviousAccount;
  final VoidCallback? onNavigateNextAccount;
  final bool? hasPreviousAccount;
  final bool? hasNextAccount;

  const TweetGridItem({
    super.key,
    required this.items,
    required this.index,
    required this.selectedIds,
    this.columnCount = 3,
    this.onNavigatePreviousAccount,
    this.onNavigateNextAccount,
    this.hasPreviousAccount,
    this.hasNextAccount,
  });

  @override
  State<TweetGridItem> createState() => _TweetGridItemState();
}

class _TweetGridItemState extends State<TweetGridItem> {
  late final PageController _imagePageController;
  int _currentImageIndex = 0;
  bool _isMostlyVisible = false;
  ScrollPosition? _scrollPosition;
  double _minOverscrollPixels = 0.0;
  double _maxOverscrollPixels = 0.0;
  bool _navigated = false;

  @override
  void initState() {
    super.initState();
    _imagePageController = PageController();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkVisibility();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final newPosition = Scrollable.maybeOf(context)?.position;
    if (_scrollPosition != newPosition) {
      _scrollPosition?.removeListener(_checkVisibility);
      _scrollPosition = newPosition;
      _scrollPosition?.addListener(_checkVisibility);
    }
  }

  @override
  void dispose() {
    _scrollPosition?.removeListener(_checkVisibility);
    _imagePageController.dispose();
    super.dispose();
  }

  void _checkVisibility() {
    if (!mounted) return;
    final rb = context.findRenderObject() as RenderBox?;
    if (rb == null || !rb.hasSize) return;

    final pos = rb.localToGlobal(Offset.zero);
    final size = rb.size;
    final screenHeight = MediaQuery.of(context).size.height;

    // 画面中央線がアイテムの縦幅内にある場合（画面の主役として大部分を占める）
    final midY = screenHeight * 0.5;
    final isCenter = pos.dy <= midY && (pos.dy + size.height) >= midY;

    if (isCenter != _isMostlyVisible) {
      setState(() {
        _isMostlyVisible = isCenter;
      });
    }
  }

  void _openDetail() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => DetailPage(
          items: widget.items,
          initialIndex: widget.index,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.items[widget.index];
    final isSelected = widget.selectedIds.contains(item.id);
    final isSelectionMode = widget.selectedIds.isNotEmpty;
    final isMultiImageInOneColumn =
        widget.columnCount == 1 && !item.isVideo && item.mediaUrls.length > 1;

    return GestureDetector(
      onTap: () {
        if (isSelectionMode) {
          context.read<GalleryViewModel>().toggleSelection(item.id);
        } else {
          _openDetail();
        }
      },
      onLongPress: () =>
          context.read<GalleryViewModel>().toggleSelection(item.id),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Container(
            decoration: BoxDecoration(color: Colors.grey[900]),
            child: isMultiImageInOneColumn
                ? NotificationListener<ScrollNotification>(
                    onNotification: (notification) {
                      if (notification is ScrollStartNotification) {
                        _minOverscrollPixels = 0.0;
                        _maxOverscrollPixels = 0.0;
                        _navigated = false;
                      } else if (notification is OverscrollNotification) {
                        if (notification.overscroll < 0) {
                          _minOverscrollPixels += notification.overscroll;
                          if (!_navigated &&
                              _currentImageIndex == 0 &&
                              (widget.hasPreviousAccount ?? false) &&
                              _minOverscrollPixels < -15.0) {
                            _navigated = true;
                            widget.onNavigatePreviousAccount?.call();
                          }
                        } else if (notification.overscroll > 0) {
                          _maxOverscrollPixels += notification.overscroll;
                          if (!_navigated &&
                              _currentImageIndex ==
                                  item.mediaUrls.length - 1 &&
                              (widget.hasNextAccount ?? false) &&
                              _maxOverscrollPixels > 15.0) {
                            _navigated = true;
                            widget.onNavigateNextAccount?.call();
                          }
                        }
                      } else if (notification is ScrollUpdateNotification) {
                        final px = notification.metrics.pixels;
                        final minExt = notification.metrics.minScrollExtent;
                        final maxExt = notification.metrics.maxScrollExtent;
                        if (px < minExt) {
                          final over = px - minExt;
                          if (over < _minOverscrollPixels) {
                            _minOverscrollPixels = over;
                          }
                          if (!_navigated &&
                              _currentImageIndex == 0 &&
                              (widget.hasPreviousAccount ?? false) &&
                              over < -15.0) {
                            _navigated = true;
                            widget.onNavigatePreviousAccount?.call();
                          }
                        } else if (px > maxExt) {
                          final over = px - maxExt;
                          if (over > _maxOverscrollPixels) {
                            _maxOverscrollPixels = over;
                          }
                          if (!_navigated &&
                              _currentImageIndex ==
                                  item.mediaUrls.length - 1 &&
                              (widget.hasNextAccount ?? false) &&
                              over > 15.0) {
                            _navigated = true;
                            widget.onNavigateNextAccount?.call();
                          }
                        }
                      } else if (notification is ScrollEndNotification) {
                        const threshold = 20.0;
                        if (!_navigated) {
                          if (_currentImageIndex == 0 &&
                              _minOverscrollPixels < -threshold) {
                            widget.onNavigatePreviousAccount?.call();
                          } else if (_currentImageIndex ==
                                  item.mediaUrls.length - 1 &&
                              _maxOverscrollPixels > threshold) {
                            widget.onNavigateNextAccount?.call();
                          }
                        }
                        _minOverscrollPixels = 0.0;
                        _maxOverscrollPixels = 0.0;
                        _navigated = false;
                      }
                      return false;
                    },
                    child: PageView.builder(
                      controller: _imagePageController,
                      physics: _isMostlyVisible
                          ? const BouncingScrollPhysics(
                              parent: PageScrollPhysics(),
                            )
                          : const NeverScrollableScrollPhysics(),
                      itemCount: item.mediaUrls.length,
                      onPageChanged: (pageIndex) {
                        setState(() => _currentImageIndex = pageIndex);
                      },
                      itemBuilder: (context, imgIndex) {
                        final url = item.mediaUrls[imgIndex];
                        return Image.network(
                          url,
                          fit: BoxFit.cover,
                          alignment: Alignment.topCenter,
                          errorBuilder: (c, e, s) => const Center(
                            child:
                                Icon(Icons.broken_image, color: Colors.grey),
                          ),
                        );
                      },
                    ),
                  )
                : (item.isVideo && item.videoUrl != null
                    ? ThumbnailVideoPlayer(
                        videoUrl: item.videoUrl!,
                        thumbnailUrl: item.thumbnailUrl,
                        bottomOffset: 8,
                      )
                    : (item.thumbnailUrl.isNotEmpty
                        ? Image.network(
                            item.thumbnailUrl,
                            fit: BoxFit.cover,
                            alignment: Alignment.topCenter,
                            errorBuilder: (c, e, s) => const Center(
                              child:
                                  Icon(Icons.broken_image, color: Colors.grey),
                            ),
                          )
                        : const Center(
                            child:
                                Icon(Icons.broken_image, color: Colors.grey),
                          ))),
          ),
          // 1列表示かつ複数画像の場合のインジケータ・操作ボタン
          if (isMultiImageInOneColumn) ...[
            // 右上: ページ番号インジケータ
            Positioned(
              top: 6,
              right: 6,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.65),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '${_currentImageIndex + 1}/${item.mediaUrls.length}',
                  style: const TextStyle(fontSize: 11, color: Colors.white),
                ),
              ),
            ),
            // 画面の大部分を占めている時の左右矢印（タップでのページ送り補助）
            if (_isMostlyVisible && _currentImageIndex > 0)
              Positioned(
                left: 4,
                top: 0,
                bottom: 0,
                child: Center(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      _imagePageController.previousPage(
                        duration: const Duration(milliseconds: 250),
                        curve: Curves.easeInOut,
                      );
                    },
                    child: Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.5),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.chevron_left,
                        color: Colors.white,
                        size: 20,
                      ),
                    ),
                  ),
                ),
              ),
            if (_isMostlyVisible &&
                _currentImageIndex < item.mediaUrls.length - 1)
              Positioned(
                right: 4,
                top: 0,
                bottom: 0,
                child: Center(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      _imagePageController.nextPage(
                        duration: const Duration(milliseconds: 250),
                        curve: Curves.easeInOut,
                      );
                    },
                    child: Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.5),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.chevron_right,
                        color: Colors.white,
                        size: 20,
                      ),
                    ),
                  ),
                ),
              ),
          ],
          if (item.isVideo && item.videoUrl == null)
            Positioned(
              right: 6,
              bottom: 6,
              child: Container(
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.65),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Icon(
                  Icons.play_arrow,
                  color: Colors.white,
                  size: 14,
                ),
              ),
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
}
