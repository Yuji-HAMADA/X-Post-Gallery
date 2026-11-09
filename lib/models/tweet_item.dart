/// [JA] 単一ポスト（画像・動画・本文・メタデータ）のデータモデル
/// [EN] Data model for a single post (images, videos, text, and metadata)
class TweetItem {
  final String id;
  final String fullText;
  final String createdAt;
  final List<String> mediaUrls;
  final String? postUrl;
  final String? username; // [JA: マスターGistスリム形式用 / EN: For master Gist slim format]
  final List<String> videoUrls;
  final String? videoThumbnailUrl;

  const TweetItem({
    required this.id,
    required this.fullText,
    required this.createdAt,
    required this.mediaUrls,
    this.postUrl,
    this.username,
    this.videoUrls = const [],
    this.videoThumbnailUrl,
  });

  bool get isVideo => videoUrls.isNotEmpty;
  bool get hasVideo => videoUrls.isNotEmpty;
  String? get videoUrl => videoUrls.isNotEmpty ? videoUrls.first : null;

  /// [JA] 新旧2形式のJSONを吸収してデシリアライズ
  /// [EN] Deserializes JSON supporting both legacy and structured schemas
  factory TweetItem.fromJson(Map<String, dynamic> json) {
    // 1. video_urls の抽出（複数動画対応）
    List<String> videoUrls = [];
    String? videoThumb;

    if (json['video_urls'] != null) {
      videoUrls = List<String>.from(json['video_urls']);
    } else if (json['video_url'] != null &&
        json['video_url'].toString().isNotEmpty) {
      videoUrls = [json['video_url'].toString()];
    }

    final rawMediaList = (json['tweet']?['extended_entities']?['media'] ??
        json['tweet']?['entities']?['media']) as List?;

    if (rawMediaList != null) {
      for (final m in rawMediaList) {
        if (m is Map) {
          final mType = m['type']?.toString();
          if (mType == 'video' || mType == 'animated_gif') {
            if (videoThumb == null && m['media_url_https'] != null) {
              videoThumb = m['media_url_https'].toString();
            }
            final variants = (m['video_info']?['variants'] as List?) ?? [];
            final mp4Variants = variants
                .where((v) =>
                    v is Map &&
                    (v['content_type'] == 'video/mp4' ||
                        v['type'] == 'video/mp4'))
                .toList();
            if (mp4Variants.isNotEmpty) {
              mp4Variants.sort((a, b) {
                final bitA = (a['bitrate'] as num?)?.toInt() ?? 0;
                final bitB = (b['bitrate'] as num?)?.toInt() ?? 0;
                return bitB.compareTo(bitA);
              });
              final url = mp4Variants.first['url']?.toString() ??
                  mp4Variants.first['src']?.toString();
              if (url != null && url.isNotEmpty && !videoUrls.contains(url)) {
                videoUrls.add(url);
              }
            }
          }
        }
      }
    }

    // 2. media_urls（静止画）の抽出
    List<String> mediaUrls = [];
    if (json['media_urls'] != null) {
      mediaUrls = List<String>.from(json['media_urls']);
    } else if (rawMediaList != null) {
      final photoItems = rawMediaList
          .where(
              (m) => m is Map && (m['type'] == 'photo' || m['type'] == null))
          .map((m) => m['media_url_https']?.toString() ?? '')
          .where((u) => u.isNotEmpty)
          .toList();

      if (photoItems.isNotEmpty) {
        mediaUrls = photoItems;
      } else if (videoUrls.isEmpty) {
        mediaUrls = rawMediaList
            .map((m) => m['media_url_https']?.toString() ?? '')
            .where((u) => u.isNotEmpty)
            .toList();
      }
    } else {
      final single = json['image_url'] ?? json['media_url'] ?? '';
      mediaUrls = single.toString().isNotEmpty ? [single.toString()] : [];
    }

    // post_url
    String? postUrl = json['post_url'] as String?;
    if (postUrl == null || postUrl.isEmpty) {
      if (rawMediaList != null && rawMediaList.isNotEmpty) {
        final expandedUrl = rawMediaList[0]['expanded_url']?.toString() ?? '';
        if (expandedUrl.contains('/status/')) {
          postUrl = expandedUrl.replaceAll(RegExp(r'/(photo|video)/\d+$'), '');
        }
      }
    }

    return TweetItem(
      id: (json['id'] ?? json['id_str'] ?? json['tweet']?['id_str'] ?? '')
          .toString(),
      fullText: json['full_text'] ?? json['tweet']?['full_text'] ?? '',
      createdAt:
          json['created_at'] ?? json['tweet']?['created_at'] ?? 'Unknown',
      mediaUrls: mediaUrls,
      postUrl: (postUrl != null && postUrl.isNotEmpty) ? postUrl : null,
      username: json['username'] as String?,
      videoUrls: videoUrls,
      videoThumbnailUrl: videoThumb ?? json['thumbnail_url']?.toString(),
    );
  }

  /// [JA] Twitterメディアに name= パラメータを付与する
  /// [EN] Appends the name= size parameter to Twitter media URLs
  static String _withImageSize(String url, String size) {
    if (url.isEmpty) return '';
    return url.contains('?') ? '$url&name=$size' : '$url?name=$size';
  }

  /// [JA] Grid表示用サムネイル（低解像度: name=small）
  /// [EN] Thumbnail for grid display (low-resolution: name=small)
  String get thumbnailUrl {
    if (mediaUrls.isNotEmpty) {
      return _withImageSize(mediaUrls.first, 'small');
    }
    if (videoThumbnailUrl != null && videoThumbnailUrl!.isNotEmpty) {
      return _withImageSize(videoThumbnailUrl!, 'small');
    }
    return '';
  }

  /// [JA] 詳細表示用URL一覧（高解像度: name=orig）
  /// [EN] Full URLs for detail viewer (high-resolution: name=orig)
  List<String> get origUrls =>
      mediaUrls.map((u) => _withImageSize(u, 'orig')).toList();

  /// [JA] ツイート本文の先頭にある "@username:" からスクリーンネームを抽出する（username フィールドがある場合はそれを優先する）
  /// [EN] Extracts username from the leading '@username:' text, prioritizing the dedicated username field
  String? get extractedUsername {
    if (username != null && username!.isNotEmpty) {
      return username;
    }
    final match = RegExp(r'^@([^:]+):').firstMatch(fullText);
    return match?.group(1)?.trim();
  }

  Map<String, dynamic> toJson() => {
    'full_text': fullText,
    'created_at': createdAt,
    'media_urls': mediaUrls,
    'id_str': id,
    if (postUrl != null) 'post_url': postUrl,
    if (videoUrl != null) 'video_url': videoUrl,
    if (videoUrls.isNotEmpty) 'video_urls': videoUrls,
  };

  /// [JA] マスターGist代表ツイート用（スリム形式: username + 先頭1枚のみ）
  /// [EN] Serializer for master Gist representative post (slim format: username + primary thumbnail)
  Map<String, dynamic> toMasterJson() => {
    'id_str': id,
    if (username != null) 'username': username,
    'media_urls': mediaUrls.isNotEmpty
        ? [mediaUrls.first]
        : (videoThumbnailUrl != null ? [videoThumbnailUrl!] : []),
    if (videoUrl != null) 'video_url': videoUrl,
  };
}
