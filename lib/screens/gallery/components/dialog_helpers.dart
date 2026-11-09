import 'package:flutter/material.dart';
import '../../../l10n/app_localizations.dart';
import '../../../viewmodels/gallery_viewmodel.dart';

/// [JA] 進捗表示ダイアログを表示する
/// [EN] Displays a progress dialog with a message
void showProgressDialog(BuildContext context, {String? message}) {
  final l10n = AppLocalizations.of(context);
  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (_) => AlertDialog(
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(message ?? l10n.deletingProgress),
        ],
      ),
    ),
  );
}

/// [JA] 削除確認ダイアログを表示する（true = 確認、false/null = キャンセル）
/// [EN] Displays a delete confirmation dialog (true = confirmed, false/null = cancelled)
Future<bool> showDeleteConfirmDialog(BuildContext context, int count) async {
  final l10n = AppLocalizations.of(context);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(l10n.deleteConfirmTitle),
      content: Text(l10n.deleteImagesConfirmMessage(count)),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(l10n.cancel),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
          onPressed: () => Navigator.pop(context, true),
          child: Text(l10n.delete),
        ),
      ],
    ),
  );
  return confirmed == true;
}

/// [JA] エラー SnackBar を表示する
/// [EN] Displays an error SnackBar
void showErrorSnackBar(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(message), backgroundColor: Colors.redAccent),
  );
}

/// [JA] 成功 SnackBar を表示する
/// [EN] Displays a success SnackBar
void showSuccessSnackBar(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(message), backgroundColor: Colors.green),
  );
}

/// [JA] 画面下部からスッとせり出すトースト通知を表示する（2〜3秒で自動消去）
/// [EN] Displays a slide-in toast notification from the bottom (auto-dismissed in 2-3s)
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
      backgroundColor: const Color(0xE6212121), // 90% 不透明なダークグレー / 90% opaque dark grey
      elevation: 6,
      margin: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      duration: duration,
    ),
  );
}

/// [JA] アカウントのピン留め状態をトグルし、スライドイントースト通知を表示する共通アクション
/// [EN] Common action to toggle account pin state and show a toast notification
Future<void> togglePinAccount(
  BuildContext context,
  GalleryViewModel vm,
  String username,
) async {
  final l10n = AppLocalizations.of(context);
  final wasPinned = vm.isPinned(username);
  await vm.togglePin(username);
  if (context.mounted) {
    if (wasPinned) {
      showToastNotification(
        context,
        l10n.unpinnedFromTop(username),
        icon: Icons.push_pin_outlined,
      );
    } else {
      showToastNotification(
        context,
        l10n.pinnedToTop(username),
        icon: Icons.push_pin,
      );
    }
  }
}

/// [JA] 後方互換用: アカウントのピン留めアクション
/// [EN] Backward compatibility: Pin account action
Future<void> pinAccountToTop(
  BuildContext context,
  GalleryViewModel vm,
  String username,
) =>
    togglePinAccount(context, vm, username);
