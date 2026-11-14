import 'package:flutter_test/flutter_test.dart';
import 'package:x_post_gallery/models/user_gist_entry.dart';
import 'package:x_post_gallery/services/gallery_repository.dart';

void main() {
  group('Candidate Gallery & UserGistEntry Tests', () {
    test('UserGistEntry parses is_candidate flag correctly', () {
      final entry1 = UserGistEntry.fromDynamic({
        'gist_id': 'gist123',
        'priority_updated_at': 1000,
        'is_candidate': true,
      });
      expect(entry1.gistId, 'gist123');
      expect(entry1.priorityUpdatedAt, 1000);
      expect(entry1.isCandidate, isTrue);

      final entry2 = UserGistEntry.fromDynamic({
        'gist_id': 'gist456',
        'priority_updated_at': 2000,
      });
      expect(entry2.isCandidate, isFalse);

      final entryLegacy = UserGistEntry.fromDynamic('gist789');
      expect(entryLegacy.gistId, 'gist789');
      expect(entryLegacy.isCandidate, isFalse);
    });

    test('UserGistEntry toJson includes is_candidate when true', () {
      const entryCandidate = UserGistEntry(
        gistId: 'gist123',
        priorityUpdatedAt: 1000,
        isCandidate: true,
      );
      final jsonCandidate = entryCandidate.toJson();
      expect(jsonCandidate['is_candidate'], isTrue);
      expect(jsonCandidate['gist_id'], 'gist123');

      const entryRegular = UserGistEntry(
        gistId: 'gist456',
        priorityUpdatedAt: 2000,
        isCandidate: false,
      );
      final jsonRegular = entryRegular.toJson();
      expect(jsonRegular.containsKey('is_candidate'), isFalse);
    });

    test('GalleryRepository buildMasterGistJson preserves isCandidate state', () {
      final repo = GalleryRepository();
      const entryCandidate = UserGistEntry(
        gistId: 'cand_gist',
        priorityUpdatedAt: 500,
        isCandidate: true,
      );
      const entryUser = UserGistEntry(
        gistId: 'user_gist',
        priorityUpdatedAt: 100,
        isCandidate: false,
      );

      final jsonStr = repo.buildMasterGistJson(
        [],
        userName: 'test_owner',
        userGists: {
          'candidate_user': 'cand_gist',
          'regular_user': 'user_gist',
        },
        userPriorities: {
          'candidate_user': 500,
          'regular_user': 100,
        },
        userGistEntries: {
          'candidate_user': entryCandidate,
          'regular_user': entryUser,
        },
      );

      expect(jsonStr.contains('"candidate_user"'), isTrue);
      expect(jsonStr.contains('"is_candidate":true'), isTrue);
    });
  });
}
