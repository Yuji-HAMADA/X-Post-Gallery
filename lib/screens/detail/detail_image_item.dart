import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_linkify/flutter_linkify.dart';
import 'package:linkify/linkify.dart' as linkify_pkg;
import 'package:url_launcher/url_launcher.dart';
import '../gallery/gallery_page.dart';

class DetailImageItem extends StatefulWidget {
  final dynamic item;
  final Function(bool) onZoomChanged;

  const DetailImageItem({
    super.key,
    required this.item,
    required this.onZoomChanged,
  });

  @override
  State<DetailImageItem> createState() => _DetailImageItemState();
}

class _DetailImageItemState extends State<DetailImageItem>
    with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  Animation<Matrix4>? _animation;
  TapDownDetails? _doubleTapDetails;
  bool _isZoomed = false;

  final Map<int, double> _resolvedRatios = {};
  final List<GestureRecognizer> _urlRecognizers = [];

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      final urls = _getImageUrls();
      for (int i = 0; i < urls.length; i++) {
        _resolveImageSize(i, urls[i]);
      }
    });
  }

  @override
  void dispose() {
    // 1. Mapの中に作ったすべてのコントローラーを順番に破棄する
    for (var controller in _controllers.values) {
      controller.dispose();
    }
    // 箱（Map）自体もクリアする
    _controllers.clear();

    // 2. URL用のGestureRecognizerを破棄
    for (var r in _urlRecognizers) {
      r.dispose();
    }
    _urlRecognizers.clear();

    // 3. 既存のコントローラーを破棄
    _animationController.dispose();

    super.dispose();
  }

  List<String> _getImageUrls() {
    return widget.item['tweet']?['extended_entities']?['media'] != null
        ? (widget.item['tweet']['extended_entities']['media'] as List)
              .map((m) => m['media_url_https'].toString())
              .toList()
        : (widget.item['media_urls'] != null
              ? List<String>.from(widget.item['media_urls'])
              : [widget.item['image_url'] ?? widget.item['media_url'] ?? ""]);
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
                // 各画像ごとの比率を保存
                _resolvedRatios[index] = info.image.width / info.image.height;
              });
            }
          }),
        );
  }

  void _updateZoomState(bool zoomed) {
    if (_isZoomed != zoomed) {
      setState(() => _isZoomed = zoomed);
      widget.onZoomChanged(zoomed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final List<String> imageUrls = _getImageUrls();

    return SingleChildScrollView(
      // ズーム中は親スクロールを止め、画像内の操作に集中させる
      physics: _isZoomed
          ? const NeverScrollableScrollPhysics()
          : const AlwaysScrollableScrollPhysics(),
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildImageSlider(imageUrls),
          // ズーム中だけテキストを非表示にする
          if (!_isZoomed) _buildTextDetail(),
        ],
      ),
    );
  }

  Widget _buildImageSlider(List<String> imageUrls) {
    final String itemId =
        (widget.item['id'] ??
                widget.item['id_str'] ??
                widget.item['tweet']?['id_str'] ??
                "item")
            .toString();

    final double screenWidth = MediaQuery.of(context).size.width;

    return Column(
      // imageUrlsをループしてWidgetのリストを作る
      children: imageUrls.asMap().entries.map((entry) {
        final int i = entry.key;
        final String url = entry.value;
        // その画像専用の比率を取得（まだなければ1.0）
        final double ratio = _resolvedRatios[i] ?? 1.0;

        return Padding(
          padding: const EdgeInsets.only(bottom: 4.0),
          child: Container(
            width: screenWidth,
            constraints: BoxConstraints(
              minHeight: 100,
              maxHeight: _isZoomed
                  ? MediaQuery.of(context).size.height
                  : screenWidth / ratio,
            ),
            child: _buildZoomableImage(url, itemId, i),
          ),
        );
      }).toList(), // 最後にリストに変換
    );
  }

  Widget _buildZoomableImage(String url, String itemId, int index) {
    final controller = _getController(index); // 自分専用のリモコンを取得

    return InteractiveViewer(
      transformationController: controller, // ここを個別に
      boundaryMargin: EdgeInsets.zero,
      clipBehavior: Clip.none,
      minScale: 1.0,
      maxScale: 5.0,
      scaleEnabled: _isZoomed,
      panEnabled: _isZoomed,
      // ★ 重要：ここを topLeft にします（行列計算の基準と合わせるため）
      alignment: Alignment.topLeft,
      // 修正後（その画像のコントローラーを使う
      onInteractionUpdate: (details) {
        double currentScale = controller.value.getMaxScaleOnAxis();
        _updateZoomState(currentScale > 1.0);
      },
      child: GestureDetector(
        onDoubleTapDown: (details) => _doubleTapDetails = details,
        onDoubleTap: () {
          if (controller.value.getMaxScaleOnAxis() > 1.0) {
            _runAnimationForIndex(index, Matrix4.identity()); // 個別の関数を呼ぶ
            _updateZoomState(false);
          } else {
            // タップした「画像内の相対座標」を取得
            final position = _doubleTapDetails!.localPosition;
            const double scale = 2.0;

            // タップ位置を支点にして拡大する正しい行列
            final Matrix4 result = Matrix4.identity()
              ..translate(position.dx, position.dy)
              ..scale(scale)
              ..translate(-position.dx, -position.dy);
            _runAnimationForIndex(index, result); // 個別にアニメーション
            _updateZoomState(true);
          }
        },
        child: Image.network(
          url,
          fit: BoxFit.contain,
          alignment: Alignment.topLeft,
        ),
      ),
    );
  }

  // 1. 変数定義：リモコン（コントローラー）を複数しまっておく箱
  final Map<int, TransformationController> _controllers = {};

  // 2. 道具の定義：必要な時に箱から取り出し、なければ新しく作る
  TransformationController _getController(int index) {
    return _controllers.putIfAbsent(index, () => TransformationController());
  }

  // 3. アニメーションの修正：指定したインデックスの画像を動かす
  void _runAnimationForIndex(int index, Matrix4 targetMatrix) {
    final controller = _getController(index);

    // 以前の動きを止め、登録されているリスナーを一旦すべて解除する
    _animationController.stop();
    // ここで古いリスナー（initStateのもの含む）をすべてクリアします
    _animationController.clearListeners();

    // 現在のアニメーションを定義
    _animation = Matrix4Tween(begin: controller.value, end: targetMatrix)
        .animate(
          CurvedAnimation(parent: _animationController, curve: Curves.easeOut),
        );

    // 今回の画像専用のリスナーを新しく登録
    _animationController.addListener(() {
      if (mounted && _animation != null) {
        controller.value = _animation!.value;
      }
    });

    // アニメーション開始
    _animationController.forward(from: 0);
  }

  Widget _buildTextDetail() {
    // 前回ビルド時のrecognizerを破棄
    for (var r in _urlRecognizers) {
      r.dispose();
    }
    _urlRecognizers.clear();

    final text = widget.item['full_text'] ?? '';
    final elements = linkify_pkg.linkify(
      text,
      linkifiers: [
        const UrlLinkifier(),
        UserTagLinkifier(),
        HashtagLinkifier(),
      ],
      options: const LinkifyOptions(humanize: false),
    );

    const defaultStyle = TextStyle(
      color: Colors.white,
      fontSize: 16,
      height: 1.6,
    );
    const linkStyle = TextStyle(
      color: Colors.blueAccent,
      fontWeight: FontWeight.bold,
      fontSize: 16,
      height: 1.6,
    );

    final spans = <InlineSpan>[];
    for (final element in elements) {
      if (element is UrlElement) {
        final isTag =
            element.url.startsWith('@') || element.url.startsWith('#');
        if (isTag) {
          // ハッシュタグ・ユーザー名: タップ＝アプリ内検索、長押し＝Xで開く
          spans.add(
            WidgetSpan(
              alignment: PlaceholderAlignment.baseline,
              baseline: TextBaseline.alphabetic,
              child: GestureDetector(
                onTap: () => _onTagTap(element.url),
                onLongPress: () => _onTagLongPress(element.url),
                child: Text(element.text, style: linkStyle),
              ),
            ),
          );
        } else {
          // 通常URL: タップで外部ブラウザ
          final recognizer = TapGestureRecognizer()
            ..onTap = () => _onUrlTap(element.url);
          _urlRecognizers.add(recognizer);
          spans.add(TextSpan(
            text: element.text,
            style: const TextStyle(
              color: Colors.blueAccent,
              fontWeight: FontWeight.bold,
            ),
            recognizer: recognizer,
          ));
        }
      } else {
        spans.add(TextSpan(text: element.text));
      }
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 30.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text.rich(
            TextSpan(children: spans),
            style: defaultStyle,
          ),
          const SizedBox(height: 40),
          Text(
            "Posted: ${widget.item['tweet']?['created_at'] ?? widget.item['created_at'] ?? 'Unknown'}",
            style: const TextStyle(color: Colors.grey, fontSize: 13),
          ),
          const SizedBox(height: 100),
        ],
      ),
    );
  }

  /// ハッシュタグ・ユーザー名タップ → アプリ内検索
  void _onTagTap(String tag) async {
    debugPrint("Tag tapped: $tag");
    final allItems = widget.item['all_items'] as List?;
    if (allItems == null) return;

    final filtered = allItems.where((i) {
      final text =
          (i['tweet']?['full_text'] ?? i['full_text'] ?? '').toString();
      return text.toLowerCase().contains(tag.toLowerCase());
    }).toList();

    if (filtered.isNotEmpty) {
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => GalleryPage(
            initialItems: filtered,
            title: tag,
          ),
        ),
      );
    }
  }

  /// ハッシュタグ・ユーザー名長押し → Xのページを外部ブラウザで開く
  void _onTagLongPress(String tag) async {
    HapticFeedback.mediumImpact();
    final String url;
    if (tag.startsWith('#')) {
      url = 'https://x.com/search?q=${Uri.encodeComponent(tag)}&src=typed_query&f=media';
    } else if (tag.startsWith('@')) {
      url = 'https://x.com/${tag.substring(1)}';
    } else {
      return;
    }
    debugPrint("Tag long-pressed: $tag → $url");
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  /// 通常URLタップ → 外部ブラウザで開く
  void _onUrlTap(String url) async {
    debugPrint("URL tapped: $url");
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else {
      debugPrint("Could not launch $url");
    }
  }
}

// ハッシュタグ用 Linkifier: #から始まる文字列を抽出
class HashtagLinkifier extends Linkifier {
  @override
  List<LinkifyElement> parse(
    List<LinkifyElement> elements,
    LinkifyOptions options,
  ) {
    final list = <LinkifyElement>[];
    // #に続く、空白・改行・#以外の文字を抽出
    final regExp = RegExp(r"#[^\s#]+");
    //    final regExp = RegExp(r"(#[^\s#]+)", dotAll: true);

    for (var element in elements) {
      if (element is TextElement) {
        final matches = regExp.allMatches(element.text);
        if (matches.isEmpty) {
          list.add(element);
          continue;
        }

        int lastIndex = 0;
        for (var match in matches) {
          if (match.start > lastIndex) {
            list.add(
              TextElement(element.text.substring(lastIndex, match.start)),
            );
          }
          // 見つけたタグをリンク要素として登録
          list.add(UrlElement(match.group(0)!, match.group(0)!));
          lastIndex = match.end;
        }
        if (lastIndex < element.text.length) {
          list.add(TextElement(element.text.substring(lastIndex)));
        }
      } else {
        list.add(element);
      }
    }
    return list;
  }
}

// カスタムLinkifier: @から始まる英数字とアンダースコアを抽出
class UserTagLinkifier extends Linkifier {
  @override
  List<LinkifyElement> parse(
    List<LinkifyElement> elements,
    LinkifyOptions options,
  ) {
    final list = <LinkifyElement>[];
    final regExp = RegExp(r"(@[a-zA-Z0-9_]+)", dotAll: true);

    for (var element in elements) {
      if (element is TextElement) {
        final matches = regExp.allMatches(element.text);
        if (matches.isEmpty) {
          list.add(element);
          continue;
        }

        int lastIndex = 0;
        for (var match in matches) {
          if (match.start > lastIndex) {
            list.add(
              TextElement(element.text.substring(lastIndex, match.start)),
            );
          }
          list.add(UrlElement(match.group(0)!, match.group(0)!));
          lastIndex = match.end;
        }
        if (lastIndex < element.text.length) {
          list.add(TextElement(element.text.substring(lastIndex)));
        }
      } else {
        list.add(element);
      }
    }
    return list;
  }
}
