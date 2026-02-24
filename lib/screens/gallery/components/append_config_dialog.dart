import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 追加設定ダイアログ（件数のみ）
/// gallery_page.dart / user_gallery_swipe_page.dart 共通
class AppendConfigDialog extends StatefulWidget {
  const AppendConfigDialog({super.key});

  /// 件数を返す（キャンセル時はnull）
  static Future<int?> show(BuildContext context) =>
      showDialog<int>(
        context: context,
        builder: (_) => const AppendConfigDialog(),
      );

  @override
  State<AppendConfigDialog> createState() => _AppendConfigDialogState();
}

class _AppendConfigDialogState extends State<AppendConfigDialog> {
  final _countController = TextEditingController(text: '100');

  @override
  void dispose() {
    _countController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('追加設定'),
      content: TextField(
        controller: _countController,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        decoration: const InputDecoration(
          labelText: '取得件数',
          border: OutlineInputBorder(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('キャンセル'),
        ),
        ElevatedButton(
          onPressed: () => Navigator.pop(
            context,
            int.tryParse(_countController.text) ?? 100,
          ),
          child: const Text('実行'),
        ),
      ],
    );
  }
}
