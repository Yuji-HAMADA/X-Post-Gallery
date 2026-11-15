import '../models/tweet_item.dart';

/// [JA] 月名（英字3文字）から月番号へのマッピング
const Map<String, int> _monthMap = {
  'Jan': 1,
  'Feb': 2,
  'Mar': 3,
  'Apr': 4,
  'May': 5,
  'Jun': 6,
  'Jul': 7,
  'Aug': 8,
  'Sep': 9,
  'Oct': 10,
  'Nov': 11,
  'Dec': 12,
};

/// [JA] Twitter API (RFC 2822 風) の日時文字列 ("Wed Oct 10 20:19:24 +0000 2018") をパースする
DateTime? parseTwitterDate(String dateStr) {
  final match = RegExp(
    r'^[A-Za-z]{3}\s+([A-Za-z]{3})\s+(\d{1,2})\s+(\d{2}):(\d{2}):(\d{2})\s+([+-]\d{4})\s+(\d{4})$',
  ).firstMatch(dateStr.trim());
  if (match == null) return null;

  final monthStr = match.group(1);
  final month = _monthMap[monthStr] ?? 1;
  final day = int.tryParse(match.group(2) ?? '') ?? 1;
  final hour = int.tryParse(match.group(3) ?? '') ?? 0;
  final minute = int.tryParse(match.group(4) ?? '') ?? 0;
  final second = int.tryParse(match.group(5) ?? '') ?? 0;
  final offsetStr = match.group(6) ?? '+0000';
  final year = int.tryParse(match.group(7) ?? '') ?? 1970;

  // オフセット計算 (+0900 -> +9 hours)
  final isNegative = offsetStr.startsWith('-');
  final offsetHours = int.tryParse(offsetStr.substring(1, 3)) ?? 0;
  final offsetMins = int.tryParse(offsetStr.substring(3, 5)) ?? 0;
  var totalOffsetMinutes = offsetHours * 60 + offsetMins;
  if (isNegative) totalOffsetMinutes = -totalOffsetMinutes;

  final utcTime = DateTime.utc(year, month, day, hour, minute, second).subtract(
    Duration(minutes: totalOffsetMinutes),
  );
  return utcTime;
}

/// [JA] 任意のタイムスタンプ文字列を東京ローカルタイム（JST: UTC+9）の DateTime にパースする
DateTime? parseToJstDateTime(String rawDate) {
  if (rawDate.isEmpty || rawDate == 'Unknown') return null;

  final trimmed = rawDate.trim();

  // すでに "YYYY-MM-DD HH:mm:ss JST" 形式の場合
  final jstMatch = RegExp(r'^(\d{4})-(\d{2})-(\d{2})\s+(\d{2}):(\d{2}):(\d{2})\s+JST$').firstMatch(trimmed);
  if (jstMatch != null) {
    return DateTime.utc(
      int.parse(jstMatch.group(1)!),
      int.parse(jstMatch.group(2)!),
      int.parse(jstMatch.group(3)!),
      int.parse(jstMatch.group(4)!),
      int.parse(jstMatch.group(5)!),
      int.parse(jstMatch.group(6)!),
    );
  }

  // 1. ISO-8601 パース
  DateTime? dt = DateTime.tryParse(trimmed);

  // 2. Twitter API 形式パース
  dt ??= parseTwitterDate(trimmed);

  if (dt == null) return null;

  // 東京ローカルタイム (UTC+9) の日時を構築
  final jstUtc = dt.toUtc().add(const Duration(hours: 9));
  return DateTime.utc(
    jstUtc.year,
    jstUtc.month,
    jstUtc.day,
    jstUtc.hour,
    jstUtc.minute,
    jstUtc.second,
  );
}

/// [JA] タイムスタンプ文字列を東京ローカルタイム（JST: "YYYY-MM-DD HH:mm:ss JST"）の統一文字列に変換する
String formatToJst(String rawDate) {
  if (rawDate.isEmpty || rawDate == 'Unknown') {
    return rawDate;
  }
  final trimmed = rawDate.trim();
  if (trimmed.endsWith('JST')) {
    return trimmed;
  }

  final dt = parseToJstDateTime(trimmed);
  if (dt == null) {
    return rawDate;
  }

  String twoDigits(int n) => n.toString().padLeft(2, '0');
  final y = dt.year.toString().padLeft(4, '0');
  final m = twoDigits(dt.month);
  final d = twoDigits(dt.day);
  final h = twoDigits(dt.hour);
  final min = twoDigits(dt.minute);
  final s = twoDigits(dt.second);

  return '$y-$m-$d $h:$min:$s JST';
}

/// [JA] アカウント単位ギャラリー用: ポストを「新しい順（降順）」に並べる比較関数
/// ピン留めポストについても複雑な例外処理を設けず、投稿日時の新しい順（同一日時はID降順）で一貫して並べる
int compareTweetsByNewest(TweetItem a, TweetItem b) {
  final dtA = parseToJstDateTime(a.createdAt);
  final dtB = parseToJstDateTime(b.createdAt);

  if (dtA != null && dtB != null) {
    final cmp = dtB.compareTo(dtA);
    if (cmp != 0) return cmp;
  } else if (dtA != null) {
    return -1; // a の方が有効な日時を持つため前（新しい）
  } else if (dtB != null) {
    return 1;
  }

  // 日時で判定できない・同じ場合は Snowflake ID の降順
  final idA = BigInt.tryParse(a.id);
  final idB = BigInt.tryParse(b.id);
  if (idA != null && idB != null) {
    return idB.compareTo(idA);
  }
  return b.id.compareTo(a.id);
}
