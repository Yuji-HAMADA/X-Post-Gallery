import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../l10n/app_localizations.dart';

/// 取得モード定義
enum AppendFetchMode {
  stopOnExisting,
  skip,
  fromScratch;

  bool get isStopOnExisting => this == AppendFetchMode.stopOnExisting;
  bool get isFromScratch => this == AppendFetchMode.fromScratch;
}

/// 追加設定ダイアログ（件数 + モード選択）
/// gallery_page.dart / user_gallery_swipe_page.dart 共通
class AppendConfigDialog extends StatefulWidget {
  const AppendConfigDialog({super.key});

  /// 設定を返す（キャンセル時はnull）
  static Future<({int count, bool stopOnExisting, bool fromScratch})?> show(
    BuildContext context,
  ) =>
      showDialog(context: context, builder: (_) => const AppendConfigDialog());

  @override
  State<AppendConfigDialog> createState() => _AppendConfigDialogState();
}

class _AppendConfigDialogState extends State<AppendConfigDialog> {
  final _countController = TextEditingController(text: '100');
  AppendFetchMode _mode = AppendFetchMode.stopOnExisting;

  @override
  void dispose() {
    _countController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return AlertDialog(
      title: Text(l10n.appendConfigTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _countController,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: InputDecoration(
              labelText: l10n.fetchCountLabel,
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          SegmentedButton<AppendFetchMode>(
            showSelectedIcon: false,
            segments: [
              ButtonSegment(
                value: AppendFetchMode.stopOnExisting,
                icon: const Icon(Icons.stop_circle_outlined),
                tooltip: l10n.stopOnExistingLabel,
              ),
              ButtonSegment(
                value: AppendFetchMode.skip,
                icon: const Icon(Icons.skip_next),
                tooltip: l10n.skipExistingLabel,
              ),
              ButtonSegment(
                value: AppendFetchMode.fromScratch,
                icon: const Icon(Icons.restart_alt),
                tooltip: l10n.fromScratchLabel,
              ),
            ],
            selected: {_mode},
            onSelectionChanged: (s) => setState(() => _mode = s.first),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.cancel),
        ),
        ElevatedButton(
          onPressed: () {
            final count = int.tryParse(_countController.text) ?? 100;
            final stopOnExisting = _mode.isStopOnExisting;
            final fromScratch = _mode.isFromScratch;
            debugPrint(
              'AppendConfigDialog: Execute pressed. count=$count, mode=$_mode, stopOnExisting=$stopOnExisting, fromScratch=$fromScratch',
            );
            Navigator.pop(context, (
              count: count,
              stopOnExisting: stopOnExisting,
              fromScratch: fromScratch,
            ));
          },
          child: Text(l10n.execute),
        ),
      ],
    );
  }
}
