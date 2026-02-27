import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 追加設定ダイアログ（件数 + モード選択）
/// gallery_page.dart / user_gallery_swipe_page.dart 共通
class AppendConfigDialog extends StatefulWidget {
  const AppendConfigDialog({super.key});

  /// 設定を返す（キャンセル時はnull）
  static Future<({int count, bool stopOnExisting})?> show(
    BuildContext context,
  ) => showDialog(context: context, builder: (_) => const AppendConfigDialog());

  @override
  State<AppendConfigDialog> createState() => _AppendConfigDialogState();
}

class _AppendConfigDialogState extends State<AppendConfigDialog> {
  final _countController = TextEditingController(text: '100');
  bool _stopOnExisting = true;

  @override
  void dispose() {
    _countController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('追加設定'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _countController,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(
              labelText: '取得件数',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(
                value: true,
                label: Text('ストップオン'),
                icon: Icon(Icons.stop_circle_outlined),
              ),
              ButtonSegment(
                value: false,
                label: Text('スキップ'),
                icon: Icon(Icons.skip_next),
              ),
            ],
            selected: {_stopOnExisting},
            onSelectionChanged:
                (s) => setState(() => _stopOnExisting = s.first),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('キャンセル'),
        ),
        ElevatedButton(
          onPressed: () => Navigator.pop(
            context,
            (
              count: int.tryParse(_countController.text) ?? 100,
              stopOnExisting: _stopOnExisting,
            ),
          ),
          child: const Text('実行'),
        ),
      ],
    );
  }
}
