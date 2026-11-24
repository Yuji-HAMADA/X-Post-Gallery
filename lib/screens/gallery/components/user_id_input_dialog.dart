import 'package:flutter/material.dart';
import '../../../l10n/app_localizations.dart';

class UserIdInputDialog extends StatefulWidget {
  const UserIdInputDialog({super.key});

  @override
  State<UserIdInputDialog> createState() => _UserIdInputDialogState();
}

class _UserIdInputDialogState extends State<UserIdInputDialog> {
  final TextEditingController _userIdController = TextEditingController();

  void _submitUserId() {
    final l10n = AppLocalizations.of(context);
    final userId = _userIdController.text.trim();
    if (userId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.inputUserIdHint),
          backgroundColor: Colors.redAccent,
        ),
      );
      return;
    }
    // 入力されたユーザーIDを呼び出し元へ返す
    Navigator.of(context).pop(userId);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l10n.inputUserIdTitle),
      content: TextField(
        controller: _userIdController,
        autofocus: true,
        decoration: InputDecoration(
          labelText: l10n.userIdLabel,
          hintText: l10n.userIdHintExample,
          border: const OutlineInputBorder(),
        ),
        keyboardType: TextInputType.text,
        onSubmitted: (_) => _submitUserId(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(null),
          child: Text(l10n.cancel),
        ),
        ElevatedButton(onPressed: _submitUserId, child: Text(l10n.show)),
      ],
    );
  }

  @override
  void dispose() {
    _userIdController.dispose();
    super.dispose();
  }
}
