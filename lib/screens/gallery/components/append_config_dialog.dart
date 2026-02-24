import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 追加設定ダイアログ（モード・件数・重複処理）
/// gallery_page.dart / user_gallery_swipe_page.dart 共通
class AppendConfigDialog extends StatefulWidget {
  const AppendConfigDialog({super.key});

  static Future<Map<String, dynamic>?> show(BuildContext context) =>
      showDialog<Map<String, dynamic>>(
        context: context,
        builder: (_) => const AppendConfigDialog(),
      );

  @override
  State<AppendConfigDialog> createState() => _AppendConfigDialogState();
}

class _AppendConfigDialogState extends State<AppendConfigDialog> {
  final _countController = TextEditingController(text: '100');
  bool _stopOnExisting = true;
  String _mode = 'post_only';

  @override
  void dispose() {
    _countController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('追加設定'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('モード', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            RadioGroup<String>(
              groupValue: _mode,
              onChanged: (v) => setState(() => _mode = v!),
              child: Column(
                children: [
                  RadioListTile<String>(
                    value: 'post_only',
                    title: const Text('投稿のみ'),
                    subtitle: const Text('リポストを除外'),
                    contentPadding: EdgeInsets.zero,
                  ),
                  RadioListTile<String>(
                    value: 'all',
                    title: const Text('すべて'),
                    subtitle: const Text('リポストを含む'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              '重複ポストの処理',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            RadioGroup<bool>(
              groupValue: _stopOnExisting,
              onChanged: (v) => setState(() => _stopOnExisting = v!),
              child: Column(
                children: [
                  RadioListTile<bool>(
                    value: true,
                    title: const Text('ストップオンモード'),
                    subtitle: const Text('既存IDに当たったら停止'),
                    contentPadding: EdgeInsets.zero,
                  ),
                  RadioListTile<bool>(
                    value: false,
                    title: const Text('スキップモード'),
                    subtitle: const Text('既存IDをスキップして続行'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _countController,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(
                labelText: '取得件数',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('キャンセル'),
        ),
        ElevatedButton(
          onPressed: () => Navigator.pop(context, {
            'mode': _mode,
            'count': int.tryParse(_countController.text) ?? 100,
            'stopOnExisting': _stopOnExisting,
          }),
          child: const Text('実行'),
        ),
      ],
    );
  }
}
