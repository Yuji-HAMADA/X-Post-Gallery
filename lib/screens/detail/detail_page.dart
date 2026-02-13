import 'package:flutter/material.dart';
import 'detail_image_item.dart';

class DetailPage extends StatefulWidget {
  final List items;
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
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  // 子(DetailImageItem)側でズームされたらPageViewのスワイプをロックする
  void _handleZoomChanged(bool zoomed) {
    if (_isZoomed != zoomed) {
      setState(() => _isZoomed = zoomed);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      // bodyを画面の本当の最上部（0,0）から配置する
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent, // 矢印を画像の上に浮かせる
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
          setState(() {
            _isZoomed = false;
          });
        },
        itemBuilder: (context, index) {
          return DetailImageItem(
            // ここで widget.items (DetailPageが持っている全データ) を 'all_items' として追加
            item: {
              ...widget.items[index], // 今までのデータ
              'all_items': widget.items, // ★ これを追加！
            },
            onZoomChanged: _handleZoomChanged,
          );
        },
      ),
    );
  }
}
