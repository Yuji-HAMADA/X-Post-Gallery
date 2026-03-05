import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../viewmodels/gallery_viewmodel.dart';

/// ベクトル類似度で並べた画像を 2D 自由スクロールで閲覧する画面。
/// 横方向 = ユーザー列（類似ユーザーが隣接）
/// 縦方向 = 同一ユーザーの画像（類似画像が隣接）
class VectorGalleryPage extends StatefulWidget {
  const VectorGalleryPage({super.key});

  @override
  State<VectorGalleryPage> createState() => _VectorGalleryPageState();
}

class _VectorGalleryPageState extends State<VectorGalleryPage> {
  final TransformationController _transformController =
      TransformationController(Matrix4.diagonal3Values(0.5, 0.5, 1.0));

  @override
  void initState() {
    super.initState();
    // ビルド完了後にデータロード（initState中のnotifyListeners回避）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final vm = context.read<GalleryViewModel>();
      if (vm.vectorUsers.isEmpty) {
        vm.loadVectorGallery();
      }
    });
    // ビューポート変化を監視して再描画（画像の遅延ロード用）
    _transformController.addListener(_onTransformChanged);
  }

  void _onTransformChanged() {
    // setState でビューポート計算を更新 → 可視画像のみロード
    setState(() {});
  }

  @override
  void dispose() {
    _transformController.removeListener(_onTransformChanged);
    _transformController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<GalleryViewModel>();
    final users = vm.vectorUsers;

    if (vm.vectorLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (users.isEmpty) {
      return const Center(
        child: Text(
          'ベクトルギャラリーデータがありません\n.env に VECTOR_GIST_ID を設定してください',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.grey),
        ),
      );
    }

    final screenWidth = MediaQuery.of(context).size.width;

    return LayoutBuilder(
      builder: (context, constraints) {
        final viewportSize = Size(constraints.maxWidth, constraints.maxHeight);

        // 現在のビューポート矩形を計算（逆変換で可視領域を算出）
        final matrix = _transformController.value;
        final inv = Matrix4.inverted(matrix);
        final topLeft = MatrixUtils.transformPoint(inv, Offset.zero);
        final bottomRight = MatrixUtils.transformPoint(
          inv,
          Offset(viewportSize.width, viewportSize.height),
        );
        // マージン付きの可視領域（画面幅1つ分の余裕）
        final visibleRect = Rect.fromLTRB(
          topLeft.dx - screenWidth,
          topLeft.dy - viewportSize.height,
          bottomRight.dx + screenWidth,
          bottomRight.dy + viewportSize.height,
        );

        return _VectorCanvas(
          users: users,
          columnWidth: screenWidth,
          viewportSize: viewportSize,
          transformController: _transformController,
          visibleRect: visibleRect,
        );
      },
    );
  }
}

/// 2D キャンバス上に画像を配置し InteractiveViewer で自由スクロール
class _VectorCanvas extends StatelessWidget {
  final List<VectorUser> users;
  final double columnWidth;
  final Size viewportSize;
  final TransformationController transformController;
  final Rect visibleRect;

  const _VectorCanvas({
    required this.users,
    required this.columnWidth,
    required this.viewportSize,
    required this.transformController,
    required this.visibleRect,
  });

  @override
  Widget build(BuildContext context) {
    // 各ユーザー列の合計高さを事前計算
    final columnHeights = <double>[];
    for (final user in users) {
      double h = 28; // ユーザー名ラベル高さ
      for (final img in user.images) {
        final aspect = img.w > 0 ? img.h / img.w : 1.0;
        h += columnWidth * aspect;
      }
      columnHeights.add(h);
    }

    final totalWidth = columnWidth * users.length;
    final maxHeight = columnHeights.isEmpty
        ? viewportSize.height
        : columnHeights.reduce((a, b) => a > b ? a : b);

    return InteractiveViewer(
      transformationController: transformController,
      constrained: false,
      boundaryMargin: EdgeInsets.zero,
      minScale: 0.1,
      maxScale: 3.0,
      child: SizedBox(
        width: totalWidth,
        height: maxHeight,
        child: Stack(
          children: [
            for (int col = 0; col < users.length; col++)
              _UserColumn(
                user: users[col],
                columnWidth: columnWidth,
                left: col * columnWidth,
                visibleRect: visibleRect,
              ),
          ],
        ),
      ),
    );
  }
}

/// 1 ユーザー分の縦列
class _UserColumn extends StatelessWidget {
  final VectorUser user;
  final double columnWidth;
  final double left;
  final Rect visibleRect;

  const _UserColumn({
    required this.user,
    required this.columnWidth,
    required this.left,
    required this.visibleRect,
  });

  @override
  Widget build(BuildContext context) {
    // この列が可視範囲外なら空ウィジェットを返す（パフォーマンス最適化）
    if (left + columnWidth < visibleRect.left || left > visibleRect.right) {
      return const SizedBox.shrink();
    }

    final children = <Widget>[];
    double yOffset = 0;

    // ユーザー名ラベル
    children.add(
      Positioned(
        left: left,
        top: 0,
        width: columnWidth,
        height: 28,
        child: Container(
          color: Colors.black87,
          alignment: Alignment.center,
          child: Text(
            '@${user.username}',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.bold,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
    );
    yOffset += 28;

    // 画像を縦に隙間なく配置
    for (final img in user.images) {
      final aspect = img.w > 0 ? img.h / img.w : 1.0;
      final imgHeight = columnWidth * aspect;

      // 可視範囲内チェック
      final isVisible =
          yOffset + imgHeight > visibleRect.top && yOffset < visibleRect.bottom;

      children.add(
        Positioned(
          left: left,
          top: yOffset,
          width: columnWidth,
          height: imgHeight,
          child: isVisible
              ? GestureDetector(
                  onTap: () => _openPostUrl(img.postUrl),
                  child: Image.network(
                    _withSize(img.url, 'medium'),
                    fit: BoxFit.cover,
                    loadingBuilder: (context, child, progress) {
                      if (progress == null) return child;
                      // 読み込み中は黒背景（スクロールの邪魔にならない）
                      return Container(color: Colors.black);
                    },
                    errorBuilder: (context, error, stack) => Container(
                      color: Colors.grey[900],
                      child: const Icon(Icons.broken_image, color: Colors.grey),
                    ),
                  ),
                )
              // 範囲外は黒プレースホルダー（メモリ節約）
              : Container(color: Colors.black),
        ),
      );
      yOffset += imgHeight;
    }

    return Stack(children: children);
  }

  static String _withSize(String url, String size) {
    if (url.isEmpty) return '';
    return url.contains('?') ? '$url&name=$size' : '$url?name=$size';
  }

  static Future<void> _openPostUrl(String url) async {
    if (url.isEmpty) return;
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }
}
