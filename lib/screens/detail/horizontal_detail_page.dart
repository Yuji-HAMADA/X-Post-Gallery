import 'package:flutter/material.dart';
import '../../models/tweet_item.dart';

/// 複数画像の横方向連続表示画面（白背景・テキスト非表示・自由スクロール・左寄せ）
class HorizontalDetailPage extends StatefulWidget {
  final TweetItem item;

  const HorizontalDetailPage({
    super.key,
    required this.item,
  });

  @override
  State<HorizontalDetailPage> createState() => _HorizontalDetailPageState();
}

class _HorizontalDetailPageState extends State<HorizontalDetailPage> {
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

    return Scaffold(
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
            onPressed: () => Navigator.pop(context),
            padding: EdgeInsets.zero,
            tooltip: '戻る',
          ),
        ),
        title: null,
      ),
      body: SingleChildScrollView(
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
                padding: EdgeInsets.only(right: isLast ? 0.0 : 4.0),
                child: Container(
                  height: screenHeight,
                  width: ratio != null ? screenHeight * ratio : null,
                  color: Colors.white,
                  child: Image.network(
                    url,
                    fit: BoxFit.fitHeight,
                    alignment: Alignment.centerLeft,
                    errorBuilder: (context, error, stackTrace) => const Center(
                      child: Icon(Icons.broken_image, color: Colors.grey, size: 48),
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
      ),
    );
  }
}
