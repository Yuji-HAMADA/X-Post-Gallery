import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_linkify/flutter_linkify.dart';
import 'package:linkify/linkify.dart' as linkify_pkg;
import 'package:url_launcher/url_launcher.dart';
import '../../models/tweet_item.dart';
import '../gallery/gallery_page.dart';

class DetailImageItem extends StatefulWidget {
  final TweetItem item;
  final List<TweetItem> allItems;
  final Function(bool) onZoomChanged;

  const DetailImageItem({
    super.key,
    required this.item,
    required this.allItems,
    required this.onZoomChanged,
  });

  @override
  State<DetailImageItem> createState() => _DetailImageItemState();
}

class _DetailImageItemState extends State<DetailImageItem>
    with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  Animation<Matrix4>? _animation;
  VoidCallback? _activeAnimationListener;
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
      final urls = widget.item.mediaUrls;
      for (int i = 0; i < urls.length; i++) {
        _resolveImageSize(i, urls[i]);
      }
    });
  }

  @override
  void dispose() {
    for (var controller in _controllers.values) {
      controller.dispose();
    }
    _controllers.clear();

    for (var r in _urlRecognizers) {
      r.dispose();
    }
    _urlRecognizers.clear();

    _animationController.dispose();

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

  void _updateZoomState(bool zoomed) {
    if (_isZoomed != zoomed) {
      setState(() => _isZoomed = zoomed);
      widget.onZoomChanged(zoomed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final List<String> imageUrls = widget.item.mediaUrls;

    return SingleChildScrollView(
      physics: _isZoomed
          ? const NeverScrollableScrollPhysics()
          : const AlwaysScrollableScrollPhysics(),
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildImageSlider(imageUrls),
          Visibility(
            visible: !_isZoomed,
            maintainSize: true,
            maintainAnimation: true,
            maintainState: true,
            child: _buildTextDetail(),
          ),
        ],
      ),
    );
  }

  Widget _buildImageSlider(List<String> imageUrls) {
    final double screenWidth = MediaQuery.of(context).size.width;

    return Column(
      children: imageUrls.asMap().entries.map((entry) {
        final int i = entry.key;
        final String url = entry.value;
        final double ratio = _resolvedRatios[i] ?? 1.0;

        return Padding(
          padding: const EdgeInsets.only(bottom: 4.0),
          child: Container(
            width: screenWidth,
            constraints: BoxConstraints(
              minHeight: 0,
              maxHeight: _isZoomed
                  ? math.max(MediaQuery.of(context).size.height, screenWidth / ratio)
                  : screenWidth / ratio,
            ),
            child: _buildZoomableImage(url, widget.item.id, i),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildZoomableImage(String url, String itemId, int index) {
    final controller = _getController(index);

    return InteractiveViewer(
      transformationController: controller,
      boundaryMargin: EdgeInsets.zero,
      clipBehavior: Clip.none,
      minScale: 1.0,
      maxScale: 5.0,
      scaleEnabled: _isZoomed,
      panEnabled: _isZoomed,
      alignment: Alignment.topLeft,
      onInteractionUpdate: (details) {
        double currentScale = controller.value.getMaxScaleOnAxis();
        _updateZoomState(currentScale > 1.0);
      },
      child: GestureDetector(
        onDoubleTapDown: (details) => _doubleTapDetails = details,
        onDoubleTap: () {
          if (controller.value.getMaxScaleOnAxis() > 1.0) {
            _runAnimationForIndex(index, Matrix4.identity());
            _updateZoomState(false);
          } else {
            _resetOtherZooms(index);

            final position = _doubleTapDetails!.localPosition;
            const double scale = 2.0;

            final Matrix4 result = Matrix4.identity()
              ..translateByDouble(position.dx, position.dy, 0.0, 1.0)
              ..scaleByDouble(scale, scale, 1.0, 1.0)
              ..translateByDouble(-position.dx, -position.dy, 0.0, 1.0);
            _runAnimationForIndex(index, result);
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

  final Map<int, TransformationController> _controllers = {};

  TransformationController _getController(int index) {
    return _controllers.putIfAbsent(index, () => TransformationController());
  }

  void _runAnimationForIndex(int index, Matrix4 targetMatrix) {
    final controller = _getController(index);

    _animationController.stop();
    if (_activeAnimationListener != null) {
      _animationController.removeListener(_activeAnimationListener!);
    }

    _animation = Matrix4Tween(begin: controller.value, end: targetMatrix)
        .animate(
          CurvedAnimation(parent: _animationController, curve: Curves.easeOut),
        );

    _activeAnimationListener = () {
      if (mounted && _animation != null) {
        controller.value = _animation!.value;
      }
    };
    _animationController.addListener(_activeAnimationListener!);

    _animationController.forward(from: 0);
  }

  void _resetOtherZooms(int activeIndex) {
    for (var entry in _controllers.entries) {
      if (entry.key != activeIndex) {
        entry.value.value = Matrix4.identity();
      }
    }
  }

  Widget _buildTextDetail() {
    for (var r in _urlRecognizers) {
      r.dispose();
    }
    _urlRecognizers.clear();

    final text = widget.item.fullText;
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
            "Posted: ${widget.item.createdAt}",
            style: const TextStyle(color: Colors.grey, fontSize: 13),
          ),
          if (widget.item.postUrl != null) ...[
            const SizedBox(height: 8),
            GestureDetector(
              onTap: () => _onUrlTap(widget.item.postUrl!),
              child: const Text(
                "View on X",
                style: TextStyle(
                  color: Colors.blueAccent,
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
          const SizedBox(height: 100),
        ],
      ),
    );
  }

  /// ハッシュタグ・ユーザー名タップ → アプリ内検索
  void _onTagTap(String tag) async {
    debugPrint("Tag tapped: $tag");

    final filtered = widget.allItems.where((i) {
      return i.fullText.toLowerCase().contains(tag.toLowerCase());
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

// ハッシュタグ用 Linkifier
class HashtagLinkifier extends Linkifier {
  @override
  List<LinkifyElement> parse(
    List<LinkifyElement> elements,
    LinkifyOptions options,
  ) {
    final list = <LinkifyElement>[];
    final regExp = RegExp(r"#[^\s#]+");

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
