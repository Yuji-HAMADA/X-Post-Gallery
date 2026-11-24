import 'package:flutter/material.dart';
import '../../../utils/image_aspect_ratio_manager.dart';

/// [JA] 行ごとに最も縦方向が小さい画像のアスペクト比に高さを動的調整するグリッドビュー
/// [EN] Grid view that dynamically adjusts row height to the shortest (most landscape/square) image in each row
class AspectRatioGridView<T> extends StatelessWidget {
  final List<T> items;
  final int columnCount;
  final ScrollController scrollController;
  final ScrollPhysics? physics;
  final EdgeInsetsGeometry padding;
  final String Function(T item) getImageUrl;
  final Widget Function(BuildContext context, T item, int index) itemBuilder;

  const AspectRatioGridView({
    super.key,
    required this.items,
    required this.columnCount,
    required this.scrollController,
    this.physics,
    this.padding = const EdgeInsets.all(4),
    required this.getImageUrl,
    required this.itemBuilder,
  });

  @override
  Widget build(BuildContext context) {
    final effectiveColumnCount = columnCount.clamp(1, 10);
    final rowCount =
        (items.length + effectiveColumnCount - 1) ~/ effectiveColumnCount;

    return ListView.builder(
      controller: scrollController,
      physics: physics,
      padding: padding,
      itemCount: rowCount,
      itemBuilder: (context, rowIndex) {
        final startIndex = rowIndex * effectiveColumnCount;
        final endIndex =
            (startIndex + effectiveColumnCount).clamp(0, items.length);
        final rowItems = items.sublist(startIndex, endIndex);

        return Padding(
          padding: EdgeInsets.only(
            bottom: rowIndex < rowCount - 1 ? 4.0 : 0.0,
          ),
          child: _AspectGridRow<T>(
            items: rowItems,
            startIndex: startIndex,
            columnCount: effectiveColumnCount,
            getImageUrl: getImageUrl,
            itemBuilder: itemBuilder,
          ),
        );
      },
    );
  }
}

class _AspectGridRow<T> extends StatefulWidget {
  final List<T> items;
  final int startIndex;
  final int columnCount;
  final String Function(T item) getImageUrl;
  final Widget Function(BuildContext context, T item, int index) itemBuilder;

  const _AspectGridRow({
    super.key,
    required this.items,
    required this.startIndex,
    required this.columnCount,
    required this.getImageUrl,
    required this.itemBuilder,
  });

  @override
  State<_AspectGridRow<T>> createState() => _AspectGridRowState<T>();
}

class _AspectGridRowState<T> extends State<_AspectGridRow<T>> {
  @override
  void initState() {
    super.initState();
    _resolveImages();
  }

  @override
  void didUpdateWidget(covariant _AspectGridRow<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    _resolveImages();
  }

  void _resolveImages() {
    for (final item in widget.items) {
      final url = widget.getImageUrl(item);
      if (url.isNotEmpty &&
          ImageAspectRatioManager.instance.getAspectRatio(url) == null) {
        ImageAspectRatioManager.instance.resolve(
          url,
          onResolved: () {
            if (mounted) setState(() {});
          },
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // 2列・3列表示（および1列表示）共通:
    // 行内の画像の中で「最も縦方向が小さい（＝アスペクト比 width / height が最大の）画像」のアスペクト比に高さを合わせる
    double? maxRatio;
    for (final item in widget.items) {
      final url = widget.getImageUrl(item);
      final r = ImageAspectRatioManager.instance.getAspectRatio(url);
      if (r != null && r > 0) {
        if (maxRatio == null || r > maxRatio) {
          maxRatio = r;
        }
      }
    }

    final rowAspectRatio = maxRatio ?? 1.0;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (int i = 0; i < widget.columnCount; i++) ...[
          if (i > 0) const SizedBox(width: 4),
          Expanded(
            child: i < widget.items.length
                ? AspectRatio(
                    aspectRatio: rowAspectRatio,
                    child: widget.itemBuilder(
                      context,
                      widget.items[i],
                      widget.startIndex + i,
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ],
    );
  }
}
