import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:x_post_gallery/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    SharedPreferences.setMockInitialValues({});
    dotenv.loadFromString(envString: 'MASTER_GIST_ID=master_123');
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('App flushes image cache on background transition',
      (WidgetTester tester) async {
    await tester.pumpWidget(const ReViewGallery());
    await tester.pump();

    final cache = PaintingBinding.instance.imageCache;
    expect(cache, isNotNull);

    // アプリがバックグラウンドに移動する標準シーケンス: resumed -> inactive -> hidden -> paused
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();

    // キャッシュがクリアされていることを確認
    expect(cache.currentSize, 0);

    // 再度フォアグラウンドに復帰する標準シーケンス: paused -> hidden -> inactive -> resumed
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
  });
}
