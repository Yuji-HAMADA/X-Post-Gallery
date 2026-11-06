import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:x_post_gallery/services/github_service.dart';
import 'package:x_post_gallery/viewmodels/gallery_viewmodel.dart';

class MockGitHubService extends GitHubService {
  bool addUserToFetchQueueResult = true;
  String? lastQueuedUser;
  int? lastCount;
  bool? lastStopOnExisting;
  bool triggerScheduledFetchWorkflowCalled = false;

  @override
  Future<bool> addUserToFetchQueue(
    String username, {
    int? count,
    bool stopOnExisting = true,
  }) async {
    lastQueuedUser = username;
    lastCount = count;
    lastStopOnExisting = stopOnExisting;
    return addUserToFetchQueueResult;
  }

  @override
  Future<bool> triggerScheduledFetchWorkflow() async {
    triggerScheduledFetchWorkflowCalled = true;
    return false;
  }
}

void main() {
  setUpAll(() {
    dotenv.loadFromString(envString: 'DUMMY=1');
  });

  group('GalleryViewModel queueUserForFetch Tests', () {
    test('returns true when addUserToFetchQueue succeeds without calling workflow', () async {
      final mockGithub = MockGitHubService()..addUserToFetchQueueResult = true;
      final vm = GalleryViewModel(githubService: mockGithub);

      final result = await vm.queueUserForFetch('test_user', count: 100, stopOnExisting: true);

      expect(result, isTrue);
      expect(mockGithub.lastQueuedUser, 'test_user');
      expect(mockGithub.lastCount, 100);
      expect(mockGithub.lastStopOnExisting, isTrue);
      // GitHub Actions ワークフローは廃止されたためトリガーされないこと
      expect(mockGithub.triggerScheduledFetchWorkflowCalled, isFalse);
    });

    test('returns false when addUserToFetchQueue fails', () async {
      final mockGithub = MockGitHubService()..addUserToFetchQueueResult = false;
      final vm = GalleryViewModel(githubService: mockGithub);

      final result = await vm.queueUserForFetch('failed_user', count: 50, stopOnExisting: false);

      expect(result, isFalse);
      expect(mockGithub.lastQueuedUser, 'failed_user');
      expect(mockGithub.triggerScheduledFetchWorkflowCalled, isFalse);
    });
  });
}
