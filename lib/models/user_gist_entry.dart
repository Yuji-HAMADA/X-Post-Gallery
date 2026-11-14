/// [JA] user_gists の各アカウントデータモデル（新旧フォーマット両対応）
/// [EN] Account data model for user_gists (supports both legacy and structured formats)
class UserGistEntry {
  final String gistId;
  final int priorityUpdatedAt;
  final bool isCandidate;

  const UserGistEntry({
    required this.gistId,
    this.priorityUpdatedAt = 0,
    this.isCandidate = false,
  });

  factory UserGistEntry.fromDynamic(dynamic value) {
    if (value is Map<String, dynamic>) {
      final gistId = (value['gist_id'] ?? '').toString();
      final priority = value['priority_updated_at'];
      final isCandidate = value['is_candidate'] == true;
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
        isCandidate: isCandidate,
      );
    } else if (value is String) {
      return UserGistEntry(gistId: value, priorityUpdatedAt: 0, isCandidate: false);
    }
    return const UserGistEntry(gistId: '', priorityUpdatedAt: 0, isCandidate: false);
  }

  UserGistEntry copyWith({
    String? gistId,
    int? priorityUpdatedAt,
    bool? isCandidate,
  }) {
    return UserGistEntry(
      gistId: gistId ?? this.gistId,
      priorityUpdatedAt: priorityUpdatedAt ?? this.priorityUpdatedAt,
      isCandidate: isCandidate ?? this.isCandidate,
    );
  }

  Map<String, dynamic> toJson() => {
    'gist_id': gistId,
    'priority_updated_at': priorityUpdatedAt,
    if (isCandidate) 'is_candidate': true,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is UserGistEntry &&
          runtimeType == other.runtimeType &&
          gistId == other.gistId &&
          priorityUpdatedAt == other.priorityUpdatedAt &&
          isCandidate == other.isCandidate;

  @override
  int get hashCode => Object.hash(gistId, priorityUpdatedAt, isCandidate);

  @override
  String toString() =>
      'UserGistEntry(gistId: $gistId, priorityUpdatedAt: $priorityUpdatedAt, isCandidate: $isCandidate)';
}
