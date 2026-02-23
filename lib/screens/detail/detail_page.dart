import 'package:flutter/material.dart';
import '../../models/tweet_item.dart';
import 'detail_image_item.dart';

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
  bool _isZoomed = false;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(initialPage: widget.initialIndex);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _preloadAdjacent(widget.initialIndex);
    });
  }

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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Colors.white,
        title: null,
      ),
      body: PageView.builder(
        controller: _pageController,
        physics: _isZoomed
            ? const NeverScrollableScrollPhysics()
            : const BouncingScrollPhysics(),
        itemCount: widget.items.length,
        onPageChanged: (index) {
          setState(() => _isZoomed = false);
          _preloadAdjacent(index);
        },
        itemBuilder: (context, index) {
          return DetailImageItem(
            item: widget.items[index],
            allItems: widget.items,
            onZoomChanged: _handleZoomChanged,
          );
        },
      ),
    );
  }
}
