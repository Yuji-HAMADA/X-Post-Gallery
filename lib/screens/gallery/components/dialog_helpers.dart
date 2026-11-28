import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../l10n/app_localizations.dart';
import '../../../models/tweet_item.dart';
import '../../../viewmodels/gallery_viewmodel.dart';
import 'append_config_dialog.dart';

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

/// [JA] 単一ポスト削除の確認ダイアログ〜削除実行〜結果通知までの共通フロー
/// [EN] Shared flow to confirm, delete a single post, and display the result SnackBar
Future<int?> confirmAndDeleteSingleTweet(
  BuildContext context,
  TweetItem item, {
  String? username,
  String? gistId,
  List<TweetItem>? allUserItems,
}) async {
  final l10n = AppLocalizations.of(context);
  final vm = context.read<GalleryViewModel?>();
  if (vm == null) return null;

  if (!await showDeleteConfirmDialog(context, 1) || !context.mounted) {
    return null;
  }

  showProgressDialog(context);
  final remainingCount = await vm.deleteSingleTweetItem(
    item,
    username: username,
    gistId: gistId,
    allUserItems: allUserItems,
  );
  if (context.mounted) Navigator.pop(context);

  if (!context.mounted) return remainingCount;
  if (remainingCount != null) {
    showSuccessSnackBar(context, l10n.deletedCount(1));
  } else {
    showErrorSnackBar(context, vm.errorMessage);
  }
  return remainingCount;
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

/// [JA] 外部URLをブラウザ/外部アプリで開く共通ヘルパー
/// [EN] Shared helper to launch an external URL and report errors via SnackBar
Future<void> launchExternalUrl(BuildContext context, String urlStr) async {
  if (urlStr.isEmpty) return;
  final url = Uri.parse(urlStr);
  try {
    if (await canLaunchUrl(url)) {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    }
  } catch (e) {
    if (context.mounted) {
      showErrorSnackBar(
        context,
        AppLocalizations.of(context).linkOpenError(e.toString()),
      );
    }
  }
}

/// [JA] 取得設定ダイアログを表示し、認証確認のうえユーザーをフェッチキューへ追加する共通フロー
/// [EN] Shared flow: show append config dialog, check admin auth, and enqueue user fetch
Future<bool> queueUserWithConfigDialog(
  BuildContext context,
  String username, {
  bool registerOnSuccess = false,
}) async {
  if (username.isEmpty) return false;

  final result = await AppendConfigDialog.show(context);
  if (result == null || !context.mounted) return false;

  final l10n = AppLocalizations.of(context);
  final vm = context.read<GalleryViewModel>();
  if (!await vm.isAdminAuthenticated()) {
    if (context.mounted) {
      showErrorSnackBar(context, l10n.pleaseLoginWithMasterGist);
    }
    return false;
  }

  final success = await vm.queueUserForFetch(
    username,
    count: result.count,
    stopOnExisting: result.stopOnExisting,
    fromScratch: result.fromScratch,
  );
  if (success && registerOnSuccess) {
    await vm.registerUser(username);
  }
  if (context.mounted) {
    if (success) {
      showSuccessSnackBar(context, l10n.addedToQueue(username));
    } else {
      showErrorSnackBar(context, l10n.failedToAddToQueue);
    }
  }
  return success;
}

/// [JA] ラジオボタン選択ダイアログの共通ヘルパー
/// [EN] Shared radio selection dialog helper
Future<void> _showRadioSelectionDialog<T>(
  BuildContext context, {
  required String title,
  required T currentValue,
  required List<({T value, String label})> options,
  required void Function(T value) onSelected,
}) async {
  final l10n = AppLocalizations.of(context);
  await showDialog<void>(
    context: context,
    builder: (dialogContext) {
      return AlertDialog(
        title: Text(title),
        contentPadding: const EdgeInsets.symmetric(vertical: 16),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: options.map((opt) {
            return RadioListTile<T>(
              title: Text(opt.label),
              value: opt.value,
              groupValue: currentValue,
              onChanged: (val) {
                if (val != null) {
                  onSelected(val);
                  Navigator.pop(dialogContext);
                }
              },
            );
          }).toList(),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(l10n.cancel),
          ),
        ],
      );
    },
  );
}

/// [JA] 列数選択ダイアログ（ラジオボタン）を表示する
/// [EN] Displays a dialog with radio buttons to select the grid column count
Future<void> showGridColumnsDialog(
  BuildContext context, {
  bool isAccountGallery = false,
}) async {
  final l10n = AppLocalizations.of(context);
  final vm = context.read<GalleryViewModel>();
  final current =
      isAccountGallery ? vm.accountGridColumnCount : vm.mainGridColumnCount;

  await _showRadioSelectionDialog<int>(
    context,
    title: l10n.gridColumnsLabel,
    currentValue: current,
    options: [
      for (final count in [1, 2, 3])
        (value: count, label: l10n.columnsCount(count)),
    ],
    onSelected: (val) {
      if (isAccountGallery) {
        vm.setAccountGridColumnCount(val);
      } else {
        vm.setMainGridColumnCount(val);
      }
    },
  );
}

/// [JA] 行の高さ基準選択ダイアログ（ラジオボタン）を表示する
/// [EN] Displays a dialog with radio buttons to select row height basis
Future<void> showRowHeightDialog(BuildContext context) async {
  final l10n = AppLocalizations.of(context);
  final vm = context.read<GalleryViewModel>();

  await _showRadioSelectionDialog<String>(
    context,
    title: l10n.rowHeightStandardLabel,
    currentValue: vm.rowHeightMode,
    options: [
      (value: 'shortest', label: l10n.rowHeightShortest),
      (value: 'tallest', label: l10n.rowHeightTallest),
    ],
    onSelected: vm.setRowHeightMode,
  );
}

PopupMenuItem<String> _buildIconMenuItem({
  required String value,
  required IconData icon,
  required String label,
}) {
  return PopupMenuItem<String>(
    value: value,
    child: Row(
      children: [
        Icon(icon),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            label,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    ),
  );
}

/// [JA] 列数選択用メニュー項目
/// [EN] Menu item to select grid column count
PopupMenuItem<String> buildGridColumnsMenuItem(BuildContext context) {
  final l10n = AppLocalizations.of(context);
  return _buildIconMenuItem(
    value: 'grid_columns',
    icon: Icons.grid_view,
    label: l10n.gridColumnsLabel,
  );
}

/// [JA] 行の高さ基準選択用メニュー項目
/// [EN] Menu item to select row height basis
PopupMenuItem<String> buildRowHeightMenuItem(BuildContext context) {
  final l10n = AppLocalizations.of(context);
  return _buildIconMenuItem(
    value: 'row_height',
    icon: Icons.height,
    label: l10n.rowHeightStandardLabel,
  );
}

