class TweetItem {
  final String id;
  final String fullText;
  final String createdAt;
  final List<String> mediaUrls;
  final String? postUrl;
  final String? username; // マスターGistスリム形式用
  final String? videoUrl;

  const TweetItem({
    required this.id,
    required this.fullText,
    required this.createdAt,
    required this.mediaUrls,
    this.postUrl,
    this.username,
    this.videoUrl,
  });

  bool get isVideo => videoUrl != null && videoUrl!.isNotEmpty;

  /// 新旧2形式のJSONを吸収する
  factory TweetItem.fromJson(Map<String, dynamic> json) {
    // media_urls (新形式) or tweet.extended_entities (旧形式)
    List<String> mediaUrls;
    if (json['media_urls'] != null) {
      mediaUrls = List<String>.from(json['media_urls']);
    } else if (json['tweet']?['extended_entities']?['media'] != null) {
      mediaUrls = (json['tweet']['extended_entities']['media'] as List)
          .map((m) => m['media_url_https'].toString())
          .toList();
    } else {
      final single = json['image_url'] ?? json['media_url'] ?? '';
      mediaUrls = single.toString().isNotEmpty ? [single.toString()] : [];
    }

    // post_url
    String? postUrl = json['post_url'] as String?;
    if (postUrl == null || postUrl.isEmpty) {
      final media = json['tweet']?['extended_entities']?['media'] as List?;
      if (media != null && media.isNotEmpty) {
        final expandedUrl = media[0]['expanded_url']?.toString() ?? '';
        if (expandedUrl.contains('/status/')) {
          postUrl = expandedUrl.replaceAll(RegExp(r'/(photo|video)/\d+$'), '');
        }
      }
    }

    // video_url
    String? videoUrl = json['video_url'] as String?;
    if (videoUrl == null || videoUrl.isEmpty) {
      final media = (json['tweet']?['extended_entities']?['media'] ??
          json['tweet']?['entities']?['media']) as List?;
      if (media != null) {
        for (final m in media) {
          if (m is Map && m['type'] == 'video') {
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
              videoUrl = mp4Variants.first['url']?.toString() ??
                  mp4Variants.first['src']?.toString();
              break;
            }
          }
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
      videoUrl: (videoUrl != null && videoUrl.isNotEmpty) ? videoUrl : null,
    );
  }

  /// Twitterメディアに name= パラメータを付与する
  static String _withImageSize(String url, String size) {
    if (url.isEmpty) return '';
    return url.contains('?') ? '$url&name=$size' : '$url?name=$size';
  }

  /// Grid表示用サムネイル（低解像度: name=small）
  String get thumbnailUrl =>
      _withImageSize(mediaUrls.isNotEmpty ? mediaUrls.first : '', 'small');

  /// 詳細表示用URL一覧（高解像度: name=orig）
  List<String> get origUrls =>
      mediaUrls.map((u) => _withImageSize(u, 'orig')).toList();

  /// ツイート本文の先頭にある "@username:" からスクリーンネームを抽出する（username フィールドがある場合はそれを優先する）
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
  };

  /// マスターGist代表ツイート用（スリム形式: username + 先頭1枚のみ）
  Map<String, dynamic> toMasterJson() => {
    'id_str': id,
    if (username != null) 'username': username,
    'media_urls': mediaUrls.isNotEmpty ? [mediaUrls.first] : [],
    if (videoUrl != null) 'video_url': videoUrl,
  };
}
