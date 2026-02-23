class TweetItem {
  final String id;
  final String fullText;
  final String createdAt;
  final List<String> mediaUrls;
  final String? postUrl;
  final String? username; // マスターGistスリム形式用

  const TweetItem({
    required this.id,
    required this.fullText,
    required this.createdAt,
    required this.mediaUrls,
    this.postUrl,
    this.username,
  });

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
          postUrl = expandedUrl.replaceAll(RegExp(r'/photo/\d+$'), '');
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

  Map<String, dynamic> toJson() => {
    'full_text': fullText,
    'created_at': createdAt,
    'media_urls': mediaUrls,
    'id_str': id,
    if (postUrl != null) 'post_url': postUrl,
  };

  /// マスターGist代表ツイート用（スリム形式: username + 先頭1枚のみ）
  Map<String, dynamic> toMasterJson() => {
    'id_str': id,
    if (username != null) 'username': username,
    'media_urls': mediaUrls.isNotEmpty ? [mediaUrls.first] : [],
  };
}
