import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:x_post_gallery/l10n/app_localizations.dart';

void main() {
  group('AppLocalizations Tests', () {
    test('Japanese locale returns accurate Japanese strings', () {
      final l10n = AppLocalizations(const Locale('ja'));

      expect(l10n.isJapanese, isTrue);
      expect(l10n.cancel, 'キャンセル');
      expect(l10n.delete, '削除');
      expect(l10n.fetchImages, '画像取得');
      expect(l10n.rowHeightStandardLabel, '行の高さ基準');
      expect(l10n.rowHeightShortest, '最小縦幅');
      expect(l10n.rowHeightTallest, '最大縦幅');
      expect(l10n.tooltipSwitchToHorizontal, '横方向レイアウトに切り替え');
      expect(l10n.tooltipToggleGap, '画像の隙間を切り替え');
      expect(l10n.tooltipPinToTop, '一番上に移動');
      expect(l10n.tooltipUnpin, 'ピン留めを解除');
      expect(l10n.selectedCount(3), '3 件選択中');
      expect(l10n.pinnedToTop('user1'), '@user1 を一番上に移動しました');
      expect(l10n.unpinnedFromTop('user1'), '@user1 のピン留めを解除しました');
      expect(l10n.appendConfigTitle, '追加設定');
      expect(l10n.fetchCountLabel, '取得件数');
      expect(l10n.stopOnExistingLabel, 'ストップオン');
      expect(l10n.skipExistingLabel, 'スキップ');
      expect(l10n.fromScratchLabel, '初めから');
      expect(l10n.load, '読込');
      expect(l10n.saveGistIdNote, 'Gist IDをメモしておくと再インストール後に復元できます：');
      expect(l10n.rateLimitExceeded, 'GitHub APIのレート制限に達しました');
      expect(l10n.rateLimitResetTime('18:30', 10), ' (解除予定: 18:30頃、約10分後)');
      expect(l10n.githubAuthFailed, 'GitHubの認証に失敗しました。トークンを確認してください。');
      expect(l10n.githubAccessDenied(null), 'GitHub APIのアクセスが拒否されました(HTTP 403)');
      expect(l10n.gistNotFound, '指定されたGistが見つかりません。');
      expect(l10n.unlock, '解除');
      expect(l10n.unlockGalleryTitle, 'ギャラリーのロック解除');
      expect(l10n.enterGistIdPrompt, 'Gist IDを入力してください:');
      expect(l10n.enterGistIdError, 'Gist IDを入力してください');
      expect(l10n.gistIdLabel, 'Gist ID');
      expect(l10n.userIdLabel, 'ユーザーID');
      expect(l10n.waitingForAuthentication, '認証待ち...');
      expect(l10n.deleteAllDataWarning, '全てのデータが削除されます');
      expect(l10n.deleteFailedGeneric, '削除に失敗しました');
      expect(l10n.deleteUserConfirmTitle('user1'), 'ユーザー @user1 を削除しますか？');
      expect(l10n.linkOpenError('err'), 'リンクを開けませんでした: err');
      expect(
        l10n.failedToLoadImagesCheckUser,
        '画像を読み込めませんでした。\n対象ユーザーが存在するか確認してください。',
      );
      expect(l10n.tooltipMute, '消音');
      expect(l10n.tooltipUnmute, '消音解除');
      expect(l10n.tooltipOpenOriginalPost, '元の投稿を開く');
      expect(l10n.videoLoadFailed, '動画の読み込みに失敗しました');
      expect(l10n.invalidGistIdError, '無効なパスワード（Gist ID）です');
      expect(l10n.networkOrInvalidIdError, '通信エラーまたは無効なIDです');
      expect(l10n.gistUpdateFailed(null), 'Gist の更新に失敗しました');
      expect(l10n.gistUpdateFailed('timeout'), 'Gist の更新に失敗しました: timeout');
      expect(l10n.masterGistIdNotSet, 'マスターGist IDが設定されていません');
      expect(l10n.failedToLoadUserGallery('g1'), 'ユーザーギャラリーの読み込みに失敗しました (g1)');
      expect(l10n.failedToLoadGist('g1'), 'Gistの読み込みに失敗しました (g1)');
      expect(l10n.failedToFetchBatchGist('g1'), 'バッチGistの取得に失敗しました (g1)');
      expect(l10n.columnsCount(2), '2列');
      expect(l10n.networkError('err'), '通信エラーが発生しました: err');
      expect(l10n.masterGistUpdateFailed(null), 'マスターGistの更新に失敗しました');
    });

    test('English locale returns accurate English strings', () {
      final l10n = AppLocalizations(const Locale('en'));

      expect(l10n.isJapanese, isFalse);
      expect(l10n.cancel, 'Cancel');
      expect(l10n.delete, 'Delete');
      expect(l10n.fetchImages, 'Fetch images');
      expect(l10n.rowHeightStandardLabel, 'Row Height Basis');
      expect(l10n.rowHeightShortest, 'Minimum Height');
      expect(l10n.rowHeightTallest, 'Maximum Height');
      expect(l10n.tooltipSwitchToHorizontal, 'Switch to horizontal layout');
      expect(l10n.tooltipToggleGap, 'Toggle image gap');
      expect(l10n.tooltipPinToTop, 'Pin to top');
      expect(l10n.tooltipUnpin, 'Unpin from top');
      expect(l10n.selectedCount(3), '3 selected');
      expect(l10n.pinnedToTop('user1'), 'Pinned @user1 to top');
      expect(l10n.unpinnedFromTop('user1'), 'Unpinned @user1');
      expect(l10n.appendConfigTitle, 'Fetch Settings');
      expect(l10n.fetchCountLabel, 'Fetch Count');
      expect(l10n.stopOnExistingLabel, 'Stop on Existing');
      expect(l10n.skipExistingLabel, 'Skip Existing');
      expect(l10n.fromScratchLabel, 'From Scratch');
      expect(l10n.load, 'Load');
      expect(l10n.saveGistIdNote, 'Save this Gist ID to restore your favorites after reinstallation:');
      expect(l10n.rateLimitExceeded, 'GitHub API rate limit exceeded');
      expect(l10n.rateLimitResetTime('18:30', 10), ' (Resets at ~18:30, in ~10 min)');
      expect(l10n.githubAuthFailed, 'GitHub authentication failed. Please check your token.');
      expect(l10n.githubAccessDenied(null), 'GitHub API access denied (HTTP 403)');
      expect(l10n.gistNotFound, 'Specified Gist was not found.');
      expect(l10n.unlock, 'Unlock');
      expect(l10n.unlockGalleryTitle, 'Unlock Gallery');
      expect(l10n.enterGistIdPrompt, 'Please enter Gist ID:');
      expect(l10n.enterGistIdError, 'Please enter Gist ID');
      expect(l10n.gistIdLabel, 'Gist ID');
      expect(l10n.userIdLabel, 'User ID');
      expect(l10n.waitingForAuthentication, 'Waiting for authentication...');
      expect(l10n.deleteAllDataWarning, 'All data will be deleted');
      expect(l10n.deleteFailedGeneric, 'Failed to delete');
      expect(l10n.deleteUserConfirmTitle('user1'), 'Delete user @user1?');
      expect(l10n.linkOpenError('err'), 'Failed to open link: err');
      expect(
        l10n.failedToLoadImagesCheckUser,
        'Failed to load images.\nPlease check if the target user exists.',
      );
      expect(l10n.tooltipMute, 'Mute');
      expect(l10n.tooltipUnmute, 'Unmute');
      expect(l10n.tooltipOpenOriginalPost, 'Open original post');
      expect(l10n.videoLoadFailed, 'Failed to load video');
      expect(l10n.invalidGistIdError, 'Invalid Password (ID)');
      expect(l10n.networkOrInvalidIdError, 'Network error or invalid ID');
      expect(l10n.gistUpdateFailed(null), 'Failed to update Gist');
      expect(l10n.gistUpdateFailed('timeout'), 'Failed to update Gist: timeout');
      expect(l10n.masterGistIdNotSet, 'Master Gist ID is not set');
      expect(l10n.failedToLoadUserGallery('g1'), 'Failed to load user gallery (g1)');
      expect(l10n.failedToLoadGist('g1'), 'Failed to load gist (g1)');
      expect(l10n.failedToFetchBatchGist('g1'), 'Failed to fetch batch gist (g1)');
      expect(l10n.columnsCount(1), '1 Column');
      expect(l10n.columnsCount(2), '2 Columns');
      expect(l10n.networkError('err'), 'Network error: err');
      expect(l10n.masterGistUpdateFailed(null), 'Failed to update Master Gist');
    });

    testWidgets('AppLocalizations.delegate automatically resolves system language', (tester) async {
      late AppLocalizations resolvedJa;
      late AppLocalizations resolvedEn;

      // 日本語環境
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('ja'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) {
              resolvedJa = AppLocalizations.of(context);
              return const SizedBox();
            },
          ),
        ),
      );
      expect(resolvedJa.isJapanese, isTrue);
      expect(resolvedJa.back, '戻る');

      // 英語環境
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) {
              resolvedEn = AppLocalizations.of(context);
              return const SizedBox();
            },
          ),
        ),
      );
      expect(resolvedEn.isJapanese, isFalse);
      expect(resolvedEn.back, 'Back');
    });

    testWidgets('Hamburger menu displays localized items based on system locale', (tester) async {
      // 英語環境でのハンバーガーメニュー表示テスト
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            appBar: AppBar(
              actions: [
                Builder(
                  builder: (context) {
                    final l10n = AppLocalizations.of(context);
                    return PopupMenuButton<String>(
                      icon: const Icon(Icons.menu),
                      itemBuilder: (context) => [
                        CheckedPopupMenuItem<String>(
                          value: 'random',
                          checked: false,
                          child: Text(l10n.randomSelection),
                        ),
                        PopupMenuItem(
                          value: 'search',
                          child: ListTile(
                            leading: const Icon(Icons.person_search),
                            title: Text(l10n.userSearch),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      );

      // ハンバーガーアイコンをタップ
      final menuButton = find.byIcon(Icons.menu);
      expect(menuButton, findsOneWidget);
      await tester.tap(menuButton);
      await tester.pumpAndSettle();

      // 英語のメニュー項目が表示されていること
      expect(find.text('Random selection'), findsOneWidget);
      expect(find.text('User Search'), findsOneWidget);
      expect(find.text('ランダム選択'), findsNothing);
      expect(find.text('ユーザー検索'), findsNothing);
    });
  });
}
