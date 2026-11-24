/// [JA] ギャラリーのデータ取得元プラットフォーム種別（X / Instagram）
/// [EN] Supported gallery data source platforms (X / Instagram)
enum DataSource {
  x,
  instagram,
}

extension DataSourceX on DataSource {
  /// [JA] 永続化用の識別キー
  String get key => name;

  /// [JA] SharedPreferences キー用のプレフィックス（X は既存互換のため空文字）
  String get storagePrefix => this == DataSource.instagram ? 'ig_' : '';

  /// [JA] 表示ラベル
  String get displayName => this == DataSource.instagram ? 'Instagram' : 'X';

  /// [JA] ユーザープロフィールURLを生成
  String profileUrl(String username) {
    final cleaned = username.startsWith('@') ? username.substring(1) : username;
    return this == DataSource.instagram
        ? 'https://www.instagram.com/$cleaned/'
        : 'https://x.com/$cleaned';
  }

  /// [JA] ハッシュタグ検索URLを生成
  String hashtagUrl(String tag) {
    final cleaned = tag.startsWith('#') ? tag.substring(1) : tag;
    return this == DataSource.instagram
        ? 'https://www.instagram.com/explore/tags/${Uri.encodeComponent(cleaned)}/'
        : 'https://x.com/search?q=${Uri.encodeComponent('#$cleaned')}&src=typed_query&f=media';
  }

  /// [JA] postUrl 欠損時のフォールバック投稿URLを生成
  String fallbackPostUrl(String username, String id) {
    if (this == DataSource.instagram) {
      return profileUrl(username);
    }
    return 'https://x.com/$username/status/$id';
  }

  static DataSource fromKey(String? key) {
    if (key?.toLowerCase() == 'instagram') {
      return DataSource.instagram;
    }
    return DataSource.x;
  }
}
