import 'package:flutter_dotenv/flutter_dotenv.dart';

/// Webビルド時のコンパイル済み環境変数を優先し、無ければ dotenv から取得
String resolveEnv(String compiled, String dotenvKey, [String fallback = '']) {
  if (compiled.isNotEmpty) return compiled;
  return dotenv.env[dotenvKey] ?? fallback;
}
