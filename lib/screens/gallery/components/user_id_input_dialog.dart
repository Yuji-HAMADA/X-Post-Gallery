import 'package:flutter/material.dart';

class UserIdInputDialog extends StatefulWidget {
  const UserIdInputDialog({super.key});

  @override
  State<UserIdInputDialog> createState() => _UserIdInputDialogState();
}

class _UserIdInputDialogState extends State<UserIdInputDialog> {
  final TextEditingController _userIdController = TextEditingController();

  void _submitUserId() {
    final userId = _userIdController.text.trim();
    if (userId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('User IDを入力してください'),
          backgroundColor: Colors.redAccent,
        ),
      );
      return;
    }
    // Return the userId to the caller
    Navigator.of(context).pop(userId);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('User IDを入力'),
      content: TextField(
        controller: _userIdController,
        autofocus: true,
        decoration: const InputDecoration(
          labelText: 'User ID',
          hintText: 'example_user',
          border: OutlineInputBorder(),
        ),
        keyboardType: TextInputType.text,
        onSubmitted: (_) => _submitUserId(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(null),
          child: const Text('キャンセル'),
        ),
        ElevatedButton(onPressed: _submitUserId, child: const Text('表示')),
      ],
    );
  }

  @override
  void dispose() {
    _userIdController.dispose();
    super.dispose();
  }
}
