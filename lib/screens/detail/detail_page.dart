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
  final ValueNotifier<bool> _firstVideoMutedNotifier = ValueNotifier<bool>(true);

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
    if (_currentIndex < 0 || _currentIndex >= widget.items.length) return false;
    final item = widget.items[_currentIndex];
    // 動画を含むポストは横方向表示モードへの遷移ボタンは不要
    if (item.isVideo) return false;
    return item.origUrls.isNotEmpty;
  }

  /// [JA] 現在のポストが動画を含むかどうかを判定
  /// [EN] Determines whether the current post contains a video
  bool get _hasVideo {
    if (_currentIndex < 0 || _currentIndex >= widget.items.length) return false;
    return widget.items[_currentIndex].isVideo;
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
          if (_hasImages)
            IconButton(
              icon: const Icon(Icons.view_carousel_outlined),
              tooltip: l10n.tooltipSwitchToHorizontal,
              onPressed: () async {
                final newIndex = await Navigator.push<int>(
                  context,
                  MaterialPageRoute(
                    builder: (_) => HorizontalDetailPage(
                      items: widget.items,
                      initialIndex: _currentIndex,
                    ),
                  ),
                );
                if (newIndex != null && newIndex != _currentIndex && mounted) {
                  _pageController.jumpToPage(newIndex);
                  setState(() {
                    _currentIndex = newIndex;
                  });
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
                  tooltip: isMuted ? '消音解除' : '消音',
                  onPressed: () {
                    _firstVideoMutedNotifier.value =
                        !_firstVideoMutedNotifier.value;
                  },
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
          _firstVideoMutedNotifier.value = true;
          _preloadAdjacent(index);
        },
        itemBuilder: (context, index) {
          return DetailImageItem(
            item: widget.items[index],
            onZoomChanged: _handleZoomChanged,
            muteNotifier:
                index == _currentIndex ? _firstVideoMutedNotifier : null,
          );
        },
      ),
    );
  }
}
