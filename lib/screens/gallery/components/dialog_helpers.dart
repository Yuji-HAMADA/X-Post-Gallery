import 'package:flutter/material.dart';
import '../../../viewmodels/gallery_viewmodel.dart';

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

/// 画面下部からスッとせり出すトースト通知を表示する（2〜3秒で自動消去）
void showToastNotification(
  BuildContext context,
  String message, {
  IconData icon = Icons.vertical_align_top,
  Duration duration = const Duration(milliseconds: 2500),
}) {
  final messenger = ScaffoldMessenger.of(context);
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(
    SnackBar(
      content: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
      ),
      backgroundColor: const Color(0xE6212121), // 90% 不透明なダークグレー
      elevation: 6,
      margin: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      duration: duration,
    ),
  );
}

/// アカウントのピン留め状態をトグルし、スライドイントースト通知を表示する共通アクション
Future<void> togglePinAccount(
  BuildContext context,
  GalleryViewModel vm,
  String username,
) async {
  final wasPinned = vm.isPinned(username);
  await vm.togglePin(username);
  if (context.mounted) {
    if (wasPinned) {
      showToastNotification(
        context,
        '@$username のピン留めを解除しました',
        icon: Icons.push_pin_outlined,
      );
    } else {
      showToastNotification(
        context,
        '@$username を一番上に移動しました',
        icon: Icons.push_pin,
      );
    }
  }
}

/// 後方互換用: アカウントのピン留めアクション
Future<void> pinAccountToTop(
  BuildContext context,
  GalleryViewModel vm,
  String username,
) =>
    togglePinAccount(context, vm, username);
