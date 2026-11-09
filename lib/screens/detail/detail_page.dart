import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';
import '../../models/tweet_item.dart';
import 'detail_image_item.dart';
import 'horizontal_detail_page.dart';

/// [JA] ポスト詳細スワイプ表示画面（縦並び画像・テキスト・ズーム対応）
/// [EN] Post detail swipe page (vertical images, text, and zoom support)
class DetailPage extends StatefulWidget {
  final List<TweetItem> items;
  final int initialIndex;

  const DetailPage({
    super.key,
    required this.items,
    required this.initialIndex,
  });

  @override
  State<DetailPage> createState() => _DetailPageState();
}

class _DetailPageState extends State<DetailPage> {
  late PageController _pageController;
  late int _currentIndex;
  bool _isZoomed = false;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: widget.initialIndex);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _preloadAdjacent(widget.initialIndex);
    });
  }

  /// [JA] 前後のアイテムの画像を事前キャッシュ
  /// [EN] Pre-caches images for adjacent items
  void _preloadAdjacent(int index) {
    for (final offset in [-1, 1]) {
      final i = index + offset;
      if (i < 0 || i >= widget.items.length) continue;
      for (final url in widget.items[i].origUrls) {
        precacheImage(NetworkImage(url), context);
      }
    }
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _handleZoomChanged(bool zoomed) {
    if (_isZoomed != zoomed) {
      setState(() => _isZoomed = zoomed);
    }
  }

  /// [JA] 現在のポストが複数画像を持つかどうかを判定
  /// [EN] Determines whether the current post contains multiple images
  bool get _hasMultipleImages {
    if (_currentIndex < 0 || _currentIndex >= widget.items.length) return false;
    return widget.items[_currentIndex].origUrls.length > 1;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Colors.white,
        title: null,
        actions: [
          if (_hasMultipleImages)
            IconButton(
              icon: const Icon(Icons.view_carousel_outlined),
              tooltip: l10n.tooltipSwitchToHorizontal,
              onPressed: () {
                final currentItem = widget.items[_currentIndex];
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => HorizontalDetailPage(item: currentItem),
                  ),
                );
              },
            ),
        ],
      ),
      body: PageView.builder(
        controller: _pageController,
        physics: _isZoomed
            ? const NeverScrollableScrollPhysics()
            : const BouncingScrollPhysics(),
        itemCount: widget.items.length,
        onPageChanged: (index) {
          setState(() {
            _currentIndex = index;
            _isZoomed = false;
          });
          _preloadAdjacent(index);
        },
        itemBuilder: (context, index) {
          return DetailImageItem(
            item: widget.items[index],
            onZoomChanged: _handleZoomChanged,
          );
        },
      ),
    );
  }
}
