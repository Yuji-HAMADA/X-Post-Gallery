import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:x_post_gallery/models/data_source.dart';
import 'package:x_post_gallery/models/tweet_item.dart';
import 'package:x_post_gallery/services/gallery_repository.dart';
import 'package:x_post_gallery/services/github_service.dart';
import 'package:x_post_gallery/viewmodels/gallery_viewmodel.dart';

class _FakeMultiSourceRepository extends GalleryRepository {
  final Map<String, GalleryData> _remote;

  _FakeMultiSourceRepository(this._remote);

  @override
  Future<GalleryData> fetchGalleryData(
    String gistId, {
    String? remoteUpdatedAt,
  }) async {
    final data = _remote[gistId];
    if (data == null) throw Exception('Unknown gist: $gistId');
    return data;
  }
}

class _FakeGitHubService extends GitHubService {
  _FakeGitHubService() : super(token: 'dummy_token', owner: 'dummy_owner');

  @override
  Future<Map<String, dynamic>> fetchGistMetadata(String gistId) async {
    return {'exists': true, 'updatedAt': '2026-11-24T10:00:00Z'};
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    dotenv.loadFromString(
      envString:
          'MASTER_GIST_ID=x_master_1\n'
          'FAVORITE_GIST_ID=x_fav_1\n'
          'FETCH_QUEUE_GIST_ID=x_queue_1\n'
          'IG_MASTER_GIST_ID=ig_master_1\n'
          'IG_FAVORITE_GIST_ID=ig_fav_1\n'
          'IG_FETCH_QUEUE_GIST_ID=ig_queue_1\n'
          'TIKTOK_MASTER_GIST_ID=tt_master_1\n'
          'TIKTOK_FAVORITE_GIST_ID=tt_fav_1\n'
          'TIKTOK_FETCH_QUEUE_GIST_ID=tt_queue_1\n',
    );
  });

  group('TweetItem Instagram CDN URL preservation', () {
    test('does not append name= param to Instagram signed CDN URLs', () {
      const igUrl =
          'https://scontent-nrt1-2.cdninstagram.com/v/t51.82787-15/abc.jpg?stp=dst-jpg_e35_tt6&oe=6B0AFC30';
      const item = TweetItem(
        id: '4033243665556695716',
        fullText: '@ig_user: caption',
        createdAt: '2026-11-24 12:00:00 JST',
        mediaUrls: [igUrl],
        postUrl: 'https://www.instagram.com/p/AbCdEf/',
      );

      expect(item.thumbnailUrl, igUrl);
      expect(item.origUrls, [igUrl]);
      expect(item.highResImageUrl, igUrl);
      expect(item.displayImageUrl(columnCount: 1), igUrl);
      expect(item.displayImageUrl(columnCount: 2), igUrl);
    });

    test('still appends name=small / name=orig to pbs.twimg.com URLs', () {
      const xUrl = 'https://pbs.twimg.com/media/sample.jpg?format=jpg';
      const item = TweetItem(
        id: '2122474730364280881',
        fullText: '@x_user: hello',
        createdAt: '2026-11-24 12:00:00 JST',
        mediaUrls: [xUrl],
      );

      expect(item.thumbnailUrl, '$xUrl&name=small');
      expect(item.origUrls, ['$xUrl&name=orig']);
    });
  });

  group('DataSource isolation & switching', () {
    test('Repository keeps X and Instagram preferences completely isolated', () async {
      final repo = GalleryRepository();

      repo.setSource(DataSource.x);
      await repo.saveGistId('x_master_1');
      await repo.saveFavoriteUsers({'x_fav_user'});

      repo.setSource(DataSource.instagram);
      expect(await repo.getSavedGistId(), isNull);
      expect(await repo.loadFavoriteUsers(), isEmpty);

      await repo.saveGistId('ig_master_1');
      await repo.saveFavoriteUsers({'ig_fav_user'});

      repo.setSource(DataSource.x);
      expect(await repo.getSavedGistId(), 'x_master_1');
      expect(await repo.loadFavoriteUsers(), {'x_fav_user'});

      repo.setSource(DataSource.instagram);
      expect(await repo.getSavedGistId(), 'ig_master_1');
      expect(await repo.loadFavoriteUsers(), {'ig_fav_user'});
    });

    test('ViewModel switches independently between X and Instagram Gists & queues', () async {
      final repo = _FakeMultiSourceRepository({
        'x_master_1': const GalleryData(
          userName: 'X Master',
          items: [
            TweetItem(
              id: '100',
              fullText: '@x_only_user: post',
              createdAt: '2026-11-24 10:00:00 JST',
              mediaUrls: ['https://pbs.twimg.com/media/x1.jpg'],
              username: 'x_only_user',
            ),
          ],
          userGists: {'x_only_user': 'x_child_1'},
        ),
        'ig_master_1': const GalleryData(
          userName: 'IG Master',
          items: [
            TweetItem(
              id: '4033243665556695716',
              fullText: '@ig_only_user: post',
              createdAt: '2026-11-24 11:00:00 JST',
              mediaUrls: ['https://scontent.cdninstagram.com/ig1.jpg?oe=6B0AFC30'],
              postUrl: 'https://www.instagram.com/p/Code1/',
              username: 'ig_only_user',
            ),
          ],
          userGists: {'ig_only_user': 'ig_child_1'},
        ),
        'tt_master_1': const GalleryData(
          userName: 'TikTok Master',
          items: [
            TweetItem(
              id: '7695367993454251271',
              fullText: '@tt_only_user: tiktok video',
              createdAt: '2026-11-26 12:00:00 JST',
              mediaUrls: ['https://p16-common-sign.tiktokcdn.com/cover.jpg?x-expires=1800000000'],
              videoUrls: ['https://v16-webapp-prime.tiktok.com/vid.mp4?expire=1800000000'],
              postUrl: 'https://www.tiktok.com/@tt_only_user/video/7695367993454251271',
              username: 'tt_only_user',
            ),
          ],
          userGists: {'tt_only_user': 'tt_child_1'},
        ),
      });
      final gh = _FakeGitHubService();
      final vm = GalleryViewModel(repository: repo, githubService: gh);

      // 1. 初期状態は X
      expect(vm.currentSource, DataSource.x);
      expect(vm.defaultMasterGistId, 'x_master_1');
      expect(gh.activeFetchQueueGistId, 'x_queue_1');
      await vm.loadGallery('x_master_1');
      expect(vm.items.map((e) => e.username), ['x_only_user']);

      // 2. Instagram へ切替（IG_MASTER_GIST_ID が自動ロードされ X データと完全独立）
      final igLoaded = await vm.switchSource(DataSource.instagram);
      expect(igLoaded, isTrue);
      expect(vm.currentSource, DataSource.instagram);
      expect(vm.defaultMasterGistId, 'ig_master_1');
      expect(vm.favoriteGistId, 'ig_fav_1');
      expect(gh.activeFetchQueueGistId, 'ig_queue_1');
      expect(vm.items.map((e) => e.username), ['ig_only_user']);
      expect(vm.userGists.keys, ['ig_only_user']);

      // 3. TikTok へ切替（TIKTOK_MASTER_GIST_ID が自動ロードされ X/IG データと完全独立）
      final ttLoaded = await vm.switchSource(DataSource.tiktok);
      expect(ttLoaded, isTrue);
      expect(vm.currentSource, DataSource.tiktok);
      expect(vm.defaultMasterGistId, 'tt_master_1');
      expect(vm.favoriteGistId, 'tt_fav_1');
      expect(gh.activeFetchQueueGistId, 'tt_queue_1');
      expect(vm.items.map((e) => e.username), ['tt_only_user']);
      expect(vm.items.first.thumbnailUrl, 'https://p16-common-sign.tiktokcdn.com/cover.jpg?x-expires=1800000000');
      expect(vm.items.first.isVideo, isTrue);
      expect(vm.userGists.keys, ['tt_only_user']);

      // 4. X へ戻すと X データのみが復元される
      final xLoaded = await vm.switchSource(DataSource.x);
      expect(xLoaded, isTrue);
      expect(vm.currentSource, DataSource.x);
      expect(vm.items.map((e) => e.username), ['x_only_user']);
      expect(vm.userGists.keys, ['x_only_user']);
    });

    test('DataSource profile and hashtag URLs match platform', () {
      expect(DataSource.x.profileUrl('alice'), 'https://x.com/alice');
      expect(
        DataSource.instagram.profileUrl('alice'),
        'https://www.instagram.com/alice/',
      );
      expect(
        DataSource.instagram.hashtagUrl('#nature'),
        'https://www.instagram.com/explore/tags/nature/',
      );
      expect(
        DataSource.tiktok.profileUrl('alice'),
        'https://www.tiktok.com/@alice',
      );
      expect(
        DataSource.tiktok.hashtagUrl('#dance'),
        'https://www.tiktok.com/tag/dance',
      );
      expect(
        DataSource.tiktok.fallbackPostUrl('alice', '7695367993454251271'),
        'https://www.tiktok.com/@alice/video/7695367993454251271',
      );
    });
  });
}
