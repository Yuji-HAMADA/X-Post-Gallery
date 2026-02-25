class CharacterGroup {
  final String label;
  final int clusterId;
  final List<String> usernames;
  final List<String> tweetIds;
  final List<String> imageUrls;
  final int faceCount;
  final String representativeImage;

  const CharacterGroup({
    required this.label,
    required this.clusterId,
    required this.usernames,
    required this.tweetIds,
    required this.imageUrls,
    required this.faceCount,
    required this.representativeImage,
  });

  factory CharacterGroup.fromJson(Map<String, dynamic> json) {
    return CharacterGroup(
      label: json['label'] as String? ?? '',
      clusterId: json['cluster_id'] as int? ?? 0,
      usernames: List<String>.from(json['usernames'] ?? []),
      tweetIds: List<String>.from(json['tweet_ids'] ?? []),
      imageUrls: List<String>.from(json['image_urls'] ?? []),
      faceCount: json['face_count'] as int? ?? 0,
      representativeImage: json['representative_image'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
    'label': label,
    'cluster_id': clusterId,
    'usernames': usernames,
    'tweet_ids': tweetIds,
    'image_urls': imageUrls,
    'face_count': faceCount,
    'representative_image': representativeImage,
  };

  /// サムネイル用URL（small サイズ）
  String get thumbnailUrl {
    if (representativeImage.isEmpty) return '';
    return representativeImage.contains('?')
        ? '$representativeImage&name=small'
        : '$representativeImage?name=small';
  }
}
