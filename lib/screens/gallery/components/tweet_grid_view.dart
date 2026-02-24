import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../models/tweet_item.dart';
import '../../../viewmodels/gallery_viewmodel.dart';
import '../../detail/detail_page.dart';

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
    return GridView.builder(
      controller: scrollController,
      padding: const EdgeInsets.all(4),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 4,
        mainAxisSpacing: 4,
      ),
      itemCount: items.length,
      itemBuilder: (context, index) => TweetGridItem(
        items: items,
        index: index,
        selectedIds: selectedIds,
      ),
    );
  }
}

/// グリッド内の1件分（画像 + 選択オーバーレイ）
class TweetGridItem extends StatelessWidget {
  final List<TweetItem> items;
  final int index;
  final Set<String> selectedIds;

  const TweetGridItem({
    super.key,
    required this.items,
    required this.index,
    required this.selectedIds,
  });

  @override
  Widget build(BuildContext context) {
    final item = items[index];
    final imageUrl = item.thumbnailUrl;
    final isSelected = selectedIds.contains(item.id);
    final isSelectionMode = selectedIds.isNotEmpty;

    return GestureDetector(
      onTap: () {
        if (isSelectionMode) {
          context.read<GalleryViewModel>().toggleSelection(item.id);
        } else {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => DetailPage(items: items, initialIndex: index),
            ),
          );
        }
      },
      onLongPress: () =>
          context.read<GalleryViewModel>().toggleSelection(item.id),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Container(
            decoration: BoxDecoration(color: Colors.grey[900]),
            child: imageUrl.isNotEmpty
                ? Image.network(
                    imageUrl,
                    fit: BoxFit.cover,
                    alignment: Alignment.topCenter,
                    errorBuilder: (c, e, s) => const Center(
                      child: Icon(Icons.broken_image, color: Colors.grey),
                    ),
                  )
                : const Center(
                    child: Icon(Icons.broken_image, color: Colors.grey),
                  ),
          ),
          if (isSelected)
            Container(
              color: Colors.blue.withValues(alpha: 0.4),
              child: const Align(
                alignment: Alignment.topRight,
                child: Padding(
                  padding: EdgeInsets.all(4),
                  child: Icon(Icons.check_circle, color: Colors.white, size: 24),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
