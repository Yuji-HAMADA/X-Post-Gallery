/// [JA] ギャラリーのデータ取得元プラットフォーム種別（X / Instagram / TikTok）
/// [EN] Supported gallery data source platforms (X / Instagram / TikTok)
enum DataSource {
  x,
  instagram,
  tiktok,
}

extension DataSourceX on DataSource {
  /// [JA] 永続化用の識別キー
  String get key => name;

  /// [JA] SharedPreferences キー用のプレフィックス（X は既存互換のため空文字）
  String get storagePrefix {
    switch (this) {
      case DataSource.x:
        return '';
      case DataSource.instagram:
        return 'ig_';
      case DataSource.tiktok:
        return 'tt_';
    }
  }

  /// [JA] 表示ラベル
  String get displayName {
    switch (this) {
      case DataSource.x:
        return 'X';
      case DataSource.instagram:
        return 'Instagram';
      case DataSource.tiktok:
        return 'TikTok';
    }
  }

  /// [JA] AppBar バッジ用の短縮ラベル
  String get shortLabel {
    switch (this) {
      case DataSource.x:
        return 'X';
      case DataSource.instagram:
        return 'IG';
      case DataSource.tiktok:
        return 'TT';
    }
  }

  /// [JA] ユーザープロフィールURLを生成
  String profileUrl(String username) {
    final cleaned = username.startsWith('@') ? username.substring(1) : username;
    switch (this) {
      case DataSource.x:
        return 'https://x.com/$cleaned';
      case DataSource.instagram:
        return 'https://www.instagram.com/$cleaned/';
      case DataSource.tiktok:
        return 'https://www.tiktok.com/@$cleaned';
    }
  }

  /// [JA] ハッシュタグ検索URLを生成
  String hashtagUrl(String tag) {
    final cleaned = tag.startsWith('#') ? tag.substring(1) : tag;
    switch (this) {
      case DataSource.x:
        return 'https://x.com/search?q=${Uri.encodeComponent('#$cleaned')}&src=typed_query&f=media';
      case DataSource.instagram:
        return 'https://www.instagram.com/explore/tags/${Uri.encodeComponent(cleaned)}/';
      case DataSource.tiktok:
        return 'https://www.tiktok.com/tag/${Uri.encodeComponent(cleaned)}';
    }
  }

  /// [JA] postUrl 欠損時のフォールバック投稿URLを生成
  String fallbackPostUrl(String username, String id) {
    final cleaned = username.startsWith('@') ? username.substring(1) : username;
    switch (this) {
      case DataSource.x:
        return 'https://x.com/$cleaned/status/$id';
      case DataSource.instagram:
        return profileUrl(cleaned);
      case DataSource.tiktok:
        return 'https://www.tiktok.com/@$cleaned/video/$id';
    }
  }

  static DataSource fromKey(String? key) {
    switch (key?.toLowerCase()) {
      case 'instagram':
        return DataSource.instagram;
      case 'tiktok':
        return DataSource.tiktok;
      default:
        return DataSource.x;
    }
  }
}
