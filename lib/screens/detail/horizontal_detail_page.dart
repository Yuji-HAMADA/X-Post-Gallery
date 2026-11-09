import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';
import '../../models/tweet_item.dart';

/// [JA] 複数画像の横方向連続表示画面（白背景・テキスト非表示・上下スワイプで前後の投稿へ移動）
/// [EN] Full-screen horizontal continuous viewer for images (white background, no text, vertical swipe for prev/next post)
class HorizontalDetailPage extends StatefulWidget {
  final List<TweetItem> items;
  final int initialIndex;

  const HorizontalDetailPage({
    super.key,
    required this.items,
    this.initialIndex = 0,
  });

  /// [JA] 単一アイテム表示用の簡易ファクトリ
  /// [EN] Factory for displaying a single item
  factory HorizontalDetailPage.single({
    Key? key,
    required TweetItem item,
  }) =>
      HorizontalDetailPage(
        key: key,
        items: [item],
        initialIndex: 0,
      );

  @override
  State<HorizontalDetailPage> createState() => _HorizontalDetailPageState();
}

class _HorizontalDetailPageState extends State<HorizontalDetailPage> {
  late PageController _verticalPageController;
  late int _currentIndex;
  bool _zeroGap = false;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _verticalPageController = PageController(initialPage: widget.initialIndex);
  }

  @override
  void dispose() {
    _verticalPageController.dispose();
    super.dispose();
  }

  void _handleBack() {
    Navigator.pop(context, _currentIndex);
  }

  void _toggleGap() {
    setState(() {
      _zeroGap = !_zeroGap;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          _handleBack();
        }
      },
      child: Scaffold(
        backgroundColor: Colors.white,
        extendBodyBehindAppBar: true,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          leading: Container(
            margin: const EdgeInsets.all(8),
            decoration: const BoxDecoration(
              color: Colors.black38,
              shape: BoxShape.circle,
            ),
            child: IconButton(
              icon: const Icon(Icons.arrow_back, color: Colors.white, size: 20),
              onPressed: _handleBack,
              padding: EdgeInsets.zero,
              tooltip: l10n.back,
            ),
          ),
          title: null,
        ),
        // [JA] 上下スワイプで前後の投稿へシームレスに切り替える垂直 PageView
        // [EN] Vertical PageView allowing seamless transition between posts via up/down swipe
        body: Stack(
          children: [
            PageView.builder(
              controller: _verticalPageController,
              scrollDirection: Axis.vertical,
              itemCount: widget.items.length,
              onPageChanged: (index) {
                setState(() => _currentIndex = index);
              },
              itemBuilder: (context, index) {
                return _HorizontalPostImagesView(
                  key: ValueKey(widget.items[index].id),
                  item: widget.items[index],
                  zeroGap: _zeroGap,
                );
              },
            ),
            // [JA] 画面左下の隙間切り替えトグルボタン
            // [EN] Zero-gap toggle button positioned at the bottom left
            Positioned(
              left: 16,
              bottom: 24,
              child: SafeArea(
                child: Container(
                  decoration: const BoxDecoration(
                    color: Colors.black38,
                    shape: BoxShape.circle,
                  ),
                  child: IconButton(
                    icon: Icon(
                      _zeroGap ? Icons.view_column : Icons.view_column_outlined,
                      color: _zeroGap ? Colors.lightBlueAccent : Colors.white,
                      size: 20,
                    ),
                    onPressed: _toggleGap,
                    tooltip: l10n.tooltipToggleGap,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// [JA] 単一投稿の全画像を水平方向に連続スクロール表示するビュー
/// [EN] View that renders all images of a single post in a horizontal continuous scroll
class _HorizontalPostImagesView extends StatefulWidget {
  final TweetItem item;
  final bool zeroGap;

  const _HorizontalPostImagesView({
    super.key,
    required this.item,
    this.zeroGap = false,
  });

  @override
  State<_HorizontalPostImagesView> createState() =>
      _HorizontalPostImagesViewState();
}

class _HorizontalPostImagesViewState extends State<_HorizontalPostImagesView> {
  final ScrollController _scrollController = ScrollController();
  final Map<int, double> _resolvedRatios = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final urls = widget.item.origUrls;
      for (int i = 0; i < urls.length; i++) {
        _resolveImageSize(i, urls[i]);
      }
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  /// [JA] ネットワーク画像の固有アスペクト比を解決して保持
  /// [EN] Resolves and caches the intrinsic aspect ratio of a network image
  void _resolveImageSize(int index, String url) {
    if (_resolvedRatios.containsKey(index)) return;
    final ImageProvider provider = NetworkImage(url);
    provider
        .resolve(const ImageConfiguration())
        .addListener(
          ImageStreamListener((info, _) {
            if (mounted) {
              setState(() {
                _resolvedRatios[index] = info.image.width / info.image.height;
              });
            }
          }),
        );
  }

  @override
  Widget build(BuildContext context) {
    final List<String> imageUrls = widget.item.origUrls;
    final double screenHeight = MediaQuery.of(context).size.height;

    if (imageUrls.isEmpty) {
      return const SizedBox();
    }

    return SingleChildScrollView(
      controller: _scrollController,
      scrollDirection: Axis.horizontal,
      physics: const BouncingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      ),
      child: SizedBox(
        height: screenHeight,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: imageUrls.asMap().entries.map((entry) {
            final int i = entry.key;
            final String url = entry.value;
            final double? ratio = _resolvedRatios[i];
            final bool isLast = i == imageUrls.length - 1;

            return Padding(
              padding: EdgeInsets.only(right: (isLast || widget.zeroGap) ? 0.0 : 4.0),
              child: Container(
                height: screenHeight,
                width: ratio != null ? screenHeight * ratio : null,
                color: Colors.white,
                child: Image.network(
                  url,
                  fit: BoxFit.fitHeight,
                  alignment: Alignment.centerLeft,
                  errorBuilder: (context, error, stackTrace) => const Center(
                    child:
                        Icon(Icons.broken_image, color: Colors.grey, size: 48),
                  ),
                  loadingBuilder: (context, child, loadingProgress) {
                    if (loadingProgress == null) return child;
                    return const Center(
                      child: SizedBox(
                        width: 32,
                        height: 32,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.black26,
                        ),
                      ),
                    );
                  },
                ),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }
}
