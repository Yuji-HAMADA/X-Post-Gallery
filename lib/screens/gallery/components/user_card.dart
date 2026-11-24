import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../models/tweet_item.dart';
import '../../../viewmodels/gallery_viewmodel.dart';
import 'thumbnail_video_player.dart';

/// ユーザーグリッド上のカードウィジェット
class UserCard extends StatelessWidget {
  final String username;
  final TweetItem thumbItem;
  final bool isFavorite;
  final bool isPinned;
  final int? columnCount;
  final bool? hasVideo;
  final VoidCallback onTap;
  final VoidCallback onFavoriteTap;
  final VoidCallback? onLongPress;

  const UserCard({
    super.key,
    required this.username,
    required this.thumbItem,
    required this.isFavorite,
    this.isPinned = false,
    this.columnCount,
    this.hasVideo,
    required this.onTap,
    required this.onFavoriteTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final effectiveColumnCount = columnCount ??
        context.watch<GalleryViewModel?>()?.mainGridColumnCount ??
        2;

    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Container(
            color: Colors.grey[900],
            child: thumbItem.isVideo && thumbItem.videoUrl != null
                ? ThumbnailVideoPlayer(
                    videoUrl: thumbItem.videoUrl!,
                    thumbnailUrl: thumbItem.thumbnailUrl,
                    bottomOffset: 24.0, // 下部ユーザー名バーの上に配置
                    enableAutoplay: effectiveColumnCount == 1,
                  )
                : (thumbItem.thumbnailUrl.isNotEmpty
                    ? Image.network(
                        thumbItem.thumbnailUrl,
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
          // 左上: ピンマーク（ピン留めアカウントのみ表示）
          if (isPinned)
            Positioned(
              top: 2,
              left: 2,
              child: Container(
                padding: const EdgeInsets.all(3),
                decoration: const BoxDecoration(
                  color: Colors.black38,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.push_pin,
                  color: Colors.amber,
                  size: 16,
                ),
              ),
            ),
          // 右上: ハートボタン（短押しでお気に入りトグル）
          Positioned(
            top: 2,
            right: 2,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onFavoriteTap,
              child: Container(
                padding: const EdgeInsets.all(3),
                decoration: const BoxDecoration(
                  color: Colors.black38,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  isFavorite ? Icons.favorite : Icons.favorite_border,
                  color: isFavorite ? Colors.redAccent : Colors.white70,
                  size: 16,
                ),
              ),
            ),
          ),
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Container(
              color: Colors.black54,
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '@$username',
                      style: const TextStyle(fontSize: 10, color: Colors.white),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if ((hasVideo ?? false) || thumbItem.isVideo) ...[
                    const SizedBox(width: 2),
                    const Icon(Icons.play_arrow,
                        size: 12, color: Colors.white70),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
