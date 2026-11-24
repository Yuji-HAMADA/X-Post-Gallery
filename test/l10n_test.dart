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
