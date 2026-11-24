import 'package:flutter/widgets.dart';

/// [JA] 画像のアスペクト比（幅 / 高さ）を動的に取得・保持するマネージャー
/// [EN] Manager that dynamically resolves and caches image aspect ratios (width / height)
class ImageAspectRatioManager {
  ImageAspectRatioManager._();
  static final ImageAspectRatioManager instance = ImageAspectRatioManager._();

  final Map<String, double> _aspectRatios = {};
  final Set<String> _pendingUrls = {};

  /// [JA] キャッシュされたアスペクト比を取得
  /// [EN] Gets the cached aspect ratio
  double? getAspectRatio(String? url) {
    if (url == null || url.isEmpty) return null;
    return _aspectRatios[url];
  }

  /// [JA] アスペクト比を直接設定（テスト用・事前設定用）
  /// [EN] Sets the aspect ratio directly (for testing or pre-setting)
  void setAspectRatio(String url, double ratio) {
    if (url.isNotEmpty && ratio > 0) {
      _aspectRatios[url] = ratio;
    }
  }

  /// [JA] キャッシュをクリア
  /// [EN] Clears the cache
  void clear() {
    _aspectRatios.clear();
    _pendingUrls.clear();
  }

  /// [JA] 画像URLからアスペクト比を非同期で解決
  /// [EN] Asynchronously resolves the aspect ratio from an image URL
  void resolve(String? url, {VoidCallback? onResolved}) {
    if (url == null || url.isEmpty) return;
    if (_aspectRatios.containsKey(url)) {
      onResolved?.call();
      return;
    }
    if (_pendingUrls.contains(url)) return;

    _pendingUrls.add(url);
    try {
      final stream = NetworkImage(url).resolve(ImageConfiguration.empty);
      ImageStreamListener? listener;
      listener = ImageStreamListener(
        (ImageInfo info, bool synchronousCall) {
          final w = info.image.width;
          final h = info.image.height;
          if (h > 0) {
            _aspectRatios[url] = w / h;
            onResolved?.call();
          }
          if (listener != null) {
            stream.removeListener(listener);
          }
          _pendingUrls.remove(url);
        },
        onError: (exception, stackTrace) {
          if (listener != null) {
            stream.removeListener(listener);
          }
          _pendingUrls.remove(url);
        },
      );
      stream.addListener(listener);
    } catch (_) {
      _pendingUrls.remove(url);
    }
  }
}
