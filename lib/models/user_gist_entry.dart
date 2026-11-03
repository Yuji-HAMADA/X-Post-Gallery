/// user_gists の各アカウントデータモデル（新旧フォーマット両対応）
class UserGistEntry {
  final String gistId;
  final int priorityUpdatedAt;

  const UserGistEntry({
    required this.gistId,
    this.priorityUpdatedAt = 0,
  });

  factory UserGistEntry.fromDynamic(dynamic value) {
    if (value is Map<String, dynamic>) {
      final gistId = (value['gist_id'] ?? '').toString();
      final priority = value['priority_updated_at'];
      int parsedPriority = 0;
      if (priority is int) {
        parsedPriority = priority;
      } else if (priority is num) {
        parsedPriority = priority.toInt();
      } else if (priority is String) {
        parsedPriority = int.tryParse(priority) ??
            DateTime.tryParse(priority)?.millisecondsSinceEpoch ??
            0;
      }
      return UserGistEntry(
        gistId: gistId,
        priorityUpdatedAt: parsedPriority,
      );
    } else if (value is String) {
      return UserGistEntry(gistId: value, priorityUpdatedAt: 0);
    }
    return const UserGistEntry(gistId: '', priorityUpdatedAt: 0);
  }

  UserGistEntry copyWith({
    String? gistId,
    int? priorityUpdatedAt,
  }) {
    return UserGistEntry(
      gistId: gistId ?? this.gistId,
      priorityUpdatedAt: priorityUpdatedAt ?? this.priorityUpdatedAt,
    );
  }

  Map<String, dynamic> toJson() => {
    'gist_id': gistId,
    'priority_updated_at': priorityUpdatedAt,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is UserGistEntry &&
          runtimeType == other.runtimeType &&
          gistId == other.gistId &&
          priorityUpdatedAt == other.priorityUpdatedAt;

  @override
  int get hashCode => Object.hash(gistId, priorityUpdatedAt);

  @override
  String toString() =>
      'UserGistEntry(gistId: $gistId, priorityUpdatedAt: $priorityUpdatedAt)';
}
