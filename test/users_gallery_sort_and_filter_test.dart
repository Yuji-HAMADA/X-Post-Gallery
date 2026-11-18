import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:x_post_gallery/l10n/app_localizations.dart';
import 'package:x_post_gallery/models/tweet_item.dart';
import 'package:x_post_gallery/models/user_gist_entry.dart';
import 'package:x_post_gallery/screens/gallery/components/user_card.dart';
import 'package:x_post_gallery/screens/gallery/gallery_page.dart';
import 'package:x_post_gallery/services/gallery_repository.dart';
import 'package:x_post_gallery/services/github_service.dart';
import 'package:x_post_gallery/viewmodels/gallery_viewmodel.dart';

class _MockRepoForUsersGalleryTest extends GalleryRepository {
  @override
  Future<String?> getSavedGistId() async => 'dummy_master';

  @override
  Future<void> clearCache() async {}

  @override
  Future<GalleryData> fetchGalleryData(String gistId, {String? remoteUpdatedAt}) async {
    return GalleryData(
      userName: 'test_owner',
      items: [
        // fav_user: お気に入り登録済み。最新投稿 2026-11-18 12:00:00 JST
        TweetItem(
          id: '101',
          fullText: '@fav_user: newest post',
          createdAt: '2026-11-18 12:00:00 JST',
          mediaUrls: ['https://example.com/fav.jpg'],
        ),
        // pinned_older_user: ピン留めありだが投稿日時は古い 2026-11-16 10:00:00 JST
        TweetItem(
          id: '102',
          fullText: '@pinned_older_user: older post',
          createdAt: '2026-11-16 10:00:00 JST',
          mediaUrls: ['https://example.com/pinned.jpg'],
        ),
        // normal_newer_user: 通常ユーザー。中間投稿日時 2026-11-17 15:00:00 JST
        TweetItem(
          id: '103',
          fullText: '@normal_newer_user: middle post',
          createdAt: '2026-11-17 15:00:00 JST',
          mediaUrls: ['https://example.com/normal.jpg'],
        ),
        // candidate_user: 候補アカウント。日時が新しくてもUsersギャラリーからは除外されるべき
        TweetItem(
          id: '104',
          fullText: '@candidate_user: cand post',
          createdAt: '2026-11-19 20:00:00 JST',
          mediaUrls: ['https://example.com/candidate.jpg'],
        ),
      ],
      userGists: {
        'fav_user': 'g_fav',
        'pinned_older_user': 'g_pinned',
        'normal_newer_user': 'g_normal',
        'candidate_user': 'g_candidate',
      },
      userPriorities: {
        'fav_user': 0,
        'pinned_older_user': 5000, // ピン留めあり
        'normal_newer_user': 0,
        'candidate_user': 0,
      },
      userGistEntries: {
        'fav_user': const UserGistEntry(gistId: 'g_fav', priorityUpdatedAt: 0, isCandidate: false),
        'pinned_older_user': const UserGistEntry(gistId: 'g_pinned', priorityUpdatedAt: 5000, isCandidate: false),
        'normal_newer_user': const UserGistEntry(gistId: 'g_normal', priorityUpdatedAt: 0, isCandidate: false),
        'candidate_user': const UserGistEntry(gistId: 'g_candidate', priorityUpdatedAt: 0, isCandidate: true),
      },
    );
  }

  @override
  Future<Set<String>> loadFavoriteUsers() async => {'fav_user'};

  @override
  Future<Map<String, int>> loadUserPriorities() async => {
    'pinned_older_user': 5000,
  };
}

class _MockGitHubServiceForUsersGalleryTest extends GitHubService {
  @override
  Future<Map<String, dynamic>> fetchGistMetadata(String gistId) async {
    return {'exists': true, 'updatedAt': '2026-11-18T12:00:00Z'};
  }
}

void main() {
  setUpAll(() {
    SharedPreferences.setMockInitialValues({'saved_gist_id': 'dummy_master'});
    dotenv.loadFromString(envString: 'MASTER_GIST_ID=dummy_master');
  });

  testWidgets('Users gallery displays all accounts sorted by newest post regardless of fav/pinned, excluding candidates', (tester) async {
    final repo = _MockRepoForUsersGalleryTest();
    final github = _MockGitHubServiceForUsersGalleryTest();
    final vm = GalleryViewModel(repository: repo, githubService: github);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: vm,
        child: const MaterialApp(
          locale: Locale('ja'),
          localizationsDelegates: [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: GalleryPage(),
        ),
      ),
    );

    await tester.pumpAndSettle();

    // 2番目のタブ「ユーザー」（Users）へスワイプ
    final pageView = find.byType(PageView);
    expect(pageView, findsOneWidget);
    await tester.fling(pageView, const Offset(-400, 0), 1000);
    await tester.pumpAndSettle();

    // 「ユーザー」タブが表示されていること
    expect(find.text('ユーザー'), findsWidgets);

    // Usersタブ内のUserCard一覧を取得
    final userCards = tester.widgetList<UserCard>(find.byType(UserCard)).toList();

    // Candidateアカウントは除外され、fav_user, normal_newer_user, pinned_older_user の3人が表示されること
    final displayedUsernames = userCards.map((c) => c.username).toList();
    expect(displayedUsernames, contains('fav_user'));
    expect(displayedUsernames, contains('normal_newer_user'));
    expect(displayedUsernames, contains('pinned_older_user'));
    expect(displayedUsernames.contains('candidate_user'), isFalse);

    // 並び順検証: ピン留めやfavに関係なく「最新ポストの新しい順」
    // 1. fav_user (2026-11-18)
    // 2. normal_newer_user (2026-11-17)
    // 3. pinned_older_user (2026-11-16, ピン留めされていても最新ポスト順のため最後)
    expect(displayedUsernames, equals(['fav_user', 'normal_newer_user', 'pinned_older_user']));

    // お気に入りフラグおよびピン留めフラグのUI表示確認
    final favCard = userCards.firstWhere((c) => c.username == 'fav_user');
    expect(favCard.isFavorite, isTrue);
    expect(favCard.isPinned, isFalse);

    final pinnedCard = userCards.firstWhere((c) => c.username == 'pinned_older_user');
    expect(pinnedCard.isFavorite, isFalse);
    expect(pinnedCard.isPinned, isTrue);

    final normalCard = userCards.firstWhere((c) => c.username == 'normal_newer_user');
    expect(normalCard.isFavorite, isFalse);
    expect(normalCard.isPinned, isFalse);
  });
}
