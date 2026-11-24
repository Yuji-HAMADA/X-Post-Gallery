import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../models/tweet_item.dart';
import '../../../viewmodels/gallery_viewmodel.dart';
import '../../detail/detail_page.dart';
import 'aspect_ratio_grid_view.dart';

/// ツイート画像グリッド（gallery_page / user_gallery_swipe_page 共通）
class TweetGridView extends StatelessWidget {
  final List<TweetItem> items;
  final Set<String> selectedIds;
  final ScrollController scrollController;

  const TweetGridView({
    super.key,
    required this.items,
    required this.selectedIds,
    required this.scrollController,
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

  const TweetGridItem({
    super.key,
    required this.items,
    required this.index,
    required this.selectedIds,
    this.columnCount = 3,
  });

  @override
  State<TweetGridItem> createState() => _TweetGridItemState();
}

class _TweetGridItemState extends State<TweetGridItem> {
  late final PageController _imagePageController;
  int _currentImageIndex = 0;
  bool _isMostlyVisible = false;
  ScrollPosition? _scrollPosition;

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
        widget.columnCount == 1 && item.mediaUrls.length > 1;

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
                ? PageView.builder(
                    controller: _imagePageController,
                    physics: _isMostlyVisible
                        ? const PageScrollPhysics()
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
                          child: Icon(Icons.broken_image, color: Colors.grey),
                        ),
                      );
                    },
                  )
                : (item.thumbnailUrl.isNotEmpty
                    ? Image.network(
                        item.thumbnailUrl,
                        fit: BoxFit.cover,
                        alignment: Alignment.topCenter,
                        errorBuilder: (c, e, s) => const Center(
                          child: Icon(Icons.broken_image, color: Colors.grey),
                        ),
                      )
                    : const Center(
                        child: Icon(Icons.broken_image, color: Colors.grey),
                      )),
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
          if (item.isVideo)
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
