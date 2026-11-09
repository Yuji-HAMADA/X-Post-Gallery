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
      expect(l10n.tooltipSwitchToHorizontal, '横方向レイアウトに切り替え');
      expect(l10n.tooltipPinToTop, '一番上に移動');
      expect(l10n.tooltipUnpin, 'ピン留めを解除');
      expect(l10n.selectedCount(3), '3 件選択中');
      expect(l10n.pinnedToTop('user1'), '@user1 を一番上に移動しました');
      expect(l10n.unpinnedFromTop('user1'), '@user1 のピン留めを解除しました');
    });

    test('English locale returns accurate English strings', () {
      final l10n = AppLocalizations(const Locale('en'));

      expect(l10n.isJapanese, isFalse);
      expect(l10n.cancel, 'Cancel');
      expect(l10n.delete, 'Delete');
      expect(l10n.tooltipSwitchToHorizontal, 'Switch to horizontal layout');
      expect(l10n.tooltipPinToTop, 'Pin to top');
      expect(l10n.tooltipUnpin, 'Unpin from top');
      expect(l10n.selectedCount(3), '3 selected');
      expect(l10n.pinnedToTop('user1'), 'Pinned @user1 to top');
      expect(l10n.unpinnedFromTop('user1'), 'Unpinned @user1');
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
