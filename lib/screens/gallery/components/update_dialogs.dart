import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class UpdateDialogs {
  // 1. 入力設定ダイアログ
  static Future<Map<String, dynamic>?> showUpdateConfigDialog(
    BuildContext context,
  ) async {
    final TextEditingController userController = TextEditingController(
      text: "travelbeauty8",
    );
    final TextEditingController countController = TextEditingController(
      text: "100",
    );
    String selectedMode = 'all';

    return showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text("Update Gallery Data"),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: userController,
                  decoration: const InputDecoration(
                    labelText: "Target X User ID",
                    hintText: "e.g. username without @",
                    prefixText: "@",
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: countController,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(
                    labelText: "Max Item Count",
                    hintText: "100",
                  ),
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  initialValue: selectedMode,
                  decoration: const InputDecoration(
                    labelText: "Extraction Mode",
                  ),
                  items: const [
                    DropdownMenuItem(
                      value: 'all',
                      child: Text("All (Post & RT)"),
                    ),
                    DropdownMenuItem(
                      value: 'post_only',
                      child: Text("Post Only"),
                    ),
                  ],
                  onChanged: (value) {
                    if (value != null) {
                      setDialogState(() => selectedMode = value);
                    }
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, null),
              child: const Text("Cancel", style: TextStyle(color: Colors.red)),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, {
                'user': userController.text.trim(),
                'count': int.tryParse(countController.text) ?? 100,
                'mode': selectedMode,
              }),
              child: const Text("Run Update"),
            ),
          ],
        ),
      ),
    );
  }

  // 2. 待機中ダイアログ
  static void showProcessingDialog(
    BuildContext context, {
    required int count,
    required String user,
    required String mode,
  }) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 20),
            const Text(
              "Updating Gallery...",
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text("@$user ($mode)", style: const TextStyle(fontSize: 13)),
            Text(
              "Extracting $count items.",
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const Text(
              "This may take a few minutes.",
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }

  // 3. 成功ダイアログ
  static void showSuccessDialog(BuildContext context, String gistId) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.check_circle, color: Colors.green),
            SizedBox(width: 10),
            Text("Update Complete"),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text("Latest Gist ID:"),
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.blueGrey[900],
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.blueAccent, width: 1),
              ),
              child: SelectableText(
                gistId,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                  color: Colors.yellowAccent,
                ),
              ),
            ),
          ],
        ),
        actions: [
          ElevatedButton.icon(
            icon: const Icon(Icons.copy),
            label: const Text("Copy ID"),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: gistId));
              Navigator.pop(context);
            },
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("Close"),
          ),
        ],
      ),
    );
  }
}
