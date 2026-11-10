import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:x_post_gallery/l10n/app_localizations.dart';
import 'package:x_post_gallery/screens/gallery/components/append_config_dialog.dart';

void main() {
  Widget buildTestableWidget({
    required Locale locale,
    required void Function(({int count, bool stopOnExisting, bool fromScratch})?) onResult,
  }) {
    return MaterialApp(
      locale: locale,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: Scaffold(
        body: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async {
              final res = await AppendConfigDialog.show(context);
              onResult(res);
            },
            child: const Text('Open'),
          ),
        ),
      ),
    );
  }

  group('AppendConfigDialog Localization & Mode Selection Tests', () {
    testWidgets('Japanese locale renders icons and localized tooltips without text labels in segments', (tester) async {
      await tester.pumpWidget(
        buildTestableWidget(
          locale: const Locale('ja'),
          onResult: (_) {},
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      expect(find.text('追加設定'), findsOneWidget);
      expect(find.text('取得件数'), findsOneWidget);
      expect(find.text('キャンセル'), findsOneWidget);
      expect(find.text('実行'), findsOneWidget);

      // セグメント内のテキストは削除され、アイコンのみが表示されていること
      expect(find.text('ストップオン'), findsNothing);
      expect(find.text('スキップ'), findsNothing);
      expect(find.text('初めから'), findsNothing);

      expect(find.byIcon(Icons.stop_circle_outlined), findsOneWidget);
      expect(find.byIcon(Icons.skip_next), findsOneWidget);
      expect(find.byIcon(Icons.restart_alt), findsOneWidget);

      // Tooltip にローカライズされた文字列が設定されていること
      expect(find.byTooltip('ストップオン'), findsOneWidget);
      expect(find.byTooltip('スキップ'), findsOneWidget);
      expect(find.byTooltip('初めから'), findsOneWidget);
    });

    testWidgets('English locale renders icons and localized English tooltips without text labels in segments', (tester) async {
      await tester.pumpWidget(
        buildTestableWidget(
          locale: const Locale('en'),
          onResult: (_) {},
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      expect(find.text('Fetch Settings'), findsOneWidget);
      expect(find.text('Fetch Count'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
      expect(find.text('Execute'), findsOneWidget);

      // セグメント内のテキストは削除され、アイコンのみが表示されていること
      expect(find.text('Stop on Existing'), findsNothing);
      expect(find.text('Skip Existing'), findsNothing);
      expect(find.text('From Scratch'), findsNothing);

      expect(find.byIcon(Icons.stop_circle_outlined), findsOneWidget);
      expect(find.byIcon(Icons.skip_next), findsOneWidget);
      expect(find.byIcon(Icons.restart_alt), findsOneWidget);

      // Tooltip にローカライズされた英語文字列が設定されていること
      expect(find.byTooltip('Stop on Existing'), findsOneWidget);
      expect(find.byTooltip('Skip Existing'), findsOneWidget);
      expect(find.byTooltip('From Scratch'), findsOneWidget);
    });

    testWidgets('Selecting From Scratch icon returns correct configuration', (tester) async {
      ({int count, bool stopOnExisting, bool fromScratch})? result;

      await tester.pumpWidget(
        buildTestableWidget(
          locale: const Locale('en'),
          onResult: (res) => result = res,
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      // "restart_alt" アイコン（From Scratch）をタップ
      await tester.tap(find.byIcon(Icons.restart_alt));
      await tester.pumpAndSettle();

      // "Execute" ボタンをタップ
      await tester.tap(find.text('Execute'));
      await tester.pumpAndSettle();

      expect(result, isNotNull);
      expect(result!.count, 100);
      expect(result!.stopOnExisting, isFalse);
      expect(result!.fromScratch, isTrue);
    });

    testWidgets('Editing count and selecting Skip icon returns modified configuration', (tester) async {
      ({int count, bool stopOnExisting, bool fromScratch})? result;

      await tester.pumpWidget(
        buildTestableWidget(
          locale: const Locale('ja'),
          onResult: (res) => result = res,
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      // 件数を 50 に書き換え
      final countField = find.byType(TextField);
      await tester.enterText(countField, '50');
      await tester.pumpAndSettle();

      // "skip_next" アイコン（スキップ）をタップ
      await tester.tap(find.byIcon(Icons.skip_next));
      await tester.pumpAndSettle();

      // "実行" ボタンをタップ
      await tester.tap(find.text('実行'));
      await tester.pumpAndSettle();

      expect(result, isNotNull);
      expect(result!.count, 50);
      expect(result!.stopOnExisting, isFalse);
      expect(result!.fromScratch, isFalse);
    });
  });
}
