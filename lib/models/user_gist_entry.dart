/// マスターGistの user_gists フィールドの各エントリ
class UserGistEntry {
  final String gistId;
  final int? count; // ポスト数（未取得の場合は null）

  const UserGistEntry({required this.gistId, this.count});

  factory UserGistEntry.fromJson(dynamic value) {
    if (value is String) {
      // レガシー形式（文字列のみ = gist_id）
      return UserGistEntry(gistId: value);
    }
    final m = value as Map<String, dynamic>;
    return UserGistEntry(
      gistId: m['gist_id'] as String,
      count: m['count'] as int?,
    );
  }
}
