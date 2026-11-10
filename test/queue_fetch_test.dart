import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:x_post_gallery/services/github_service.dart';
import 'package:x_post_gallery/viewmodels/gallery_viewmodel.dart';

class MockGitHubService extends GitHubService {
  bool addUserToFetchQueueResult = true;
  String? lastQueuedUser;
  int? lastCount;
  bool? lastStopOnExisting;
  bool? lastFromScratch;

  @override
  Future<bool> addUserToFetchQueue(
    String username, {
    int? count,
    bool stopOnExisting = true,
    bool fromScratch = false,
  }) async {
    lastQueuedUser = username;
    lastCount = count;
    lastStopOnExisting = stopOnExisting;
    lastFromScratch = fromScratch;
    return addUserToFetchQueueResult;
  }
}

void main() {
  setUpAll(() {
    dotenv.loadFromString(envString: 'DUMMY=1');
  });

  group('GalleryViewModel queueUserForFetch Tests', () {
    test('returns true when addUserToFetchQueue succeeds', () async {
      final mockGithub = MockGitHubService()..addUserToFetchQueueResult = true;
      final vm = GalleryViewModel(githubService: mockGithub);

      final result = await vm.queueUserForFetch('test_user', count: 100, stopOnExisting: true);

      expect(result, isTrue);
      expect(mockGithub.lastQueuedUser, 'test_user');
      expect(mockGithub.lastCount, 100);
      expect(mockGithub.lastStopOnExisting, isTrue);
    });

    test('passes fromScratch flag correctly when queueing user', () async {
      final mockGithub = MockGitHubService()..addUserToFetchQueueResult = true;
      final vm = GalleryViewModel(githubService: mockGithub);

      final result = await vm.queueUserForFetch(
        'scratch_user',
        count: 200,
        stopOnExisting: false,
        fromScratch: true,
      );

      expect(result, isTrue);
      expect(mockGithub.lastQueuedUser, 'scratch_user');
      expect(mockGithub.lastCount, 200);
      expect(mockGithub.lastStopOnExisting, isFalse);
      expect(mockGithub.lastFromScratch, isTrue);
    });

    test('returns false when addUserToFetchQueue fails', () async {
      final mockGithub = MockGitHubService()..addUserToFetchQueueResult = false;
      final vm = GalleryViewModel(githubService: mockGithub);

      final result = await vm.queueUserForFetch('failed_user', count: 50, stopOnExisting: false);

      expect(result, isFalse);
      expect(mockGithub.lastQueuedUser, 'failed_user');
    });
  });
}
