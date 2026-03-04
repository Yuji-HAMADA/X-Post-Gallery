import 'package:flutter/material.dart';

/// 進捗表示ダイアログを表示する
void showProgressDialog(BuildContext context, {String message = '削除中...'}) {
  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (_) => AlertDialog(
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(message),
        ],
      ),
    ),
  );
}

/// 削除確認ダイアログを表示する（true = 確認、false/null = キャンセル）
Future<bool> showDeleteConfirmDialog(BuildContext context, int count) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('削除確認'),
      content: Text('$count 件の画像を削除しますか？'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('キャンセル'),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
          onPressed: () => Navigator.pop(context, true),
          child: const Text('削除'),
        ),
      ],
    ),
  );
  return confirmed == true;
}

/// エラー SnackBar を表示する
void showErrorSnackBar(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(message), backgroundColor: Colors.redAccent),
  );
}

/// 成功 SnackBar を表示する
void showSuccessSnackBar(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(message), backgroundColor: Colors.green),
  );
}
