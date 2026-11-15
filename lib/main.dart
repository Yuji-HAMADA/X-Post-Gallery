import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'package:x_post_gallery/l10n/app_localizations.dart';
import 'package:x_post_gallery/screens/gallery/gallery_page.dart';
import 'package:x_post_gallery/viewmodels/gallery_viewmodel.dart';

/// [JA] アプリケーションのエントリポイント
/// [EN] Application entry point
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await dotenv.load(fileName: ".env");
  } catch (e) {
    debugPrint("dotenv load warning: $e");
  }

  runApp(const ReViewGallery());
}

/// [JA] メインアプリケーションウィジェット（ダークテーマ・多言語化設定・LMK対策ライフサイクル監視）
/// [EN] Main application widget (dark theme, localization & LMK defense lifecycle observer)
class ReViewGallery extends StatefulWidget {
  const ReViewGallery({super.key});

  @override
  State<ReViewGallery> createState() => _ReViewGalleryState();
}

class _ReViewGalleryState extends State<ReViewGallery>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // [JA] バックグラウンド移行時に画像キャッシュを解放し、Android OSのLMK (Low Memory Killer) によるKillを防ぐ
    // [EN] Flush image cache when moving to background to prevent OS Low Memory Killer termination
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      debugPrint('[Lifecycle] App moved to background: clearing image cache to avoid LMK kill');
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
    }
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => GalleryViewModel(),
      child: MaterialApp(
        title: 'ReViewGallery',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.indigo,
            brightness: Brightness.dark,
          ),
        ),
        // [JA] システム言語追従のためのローカライゼーション設定
        // [EN] Localization setup for automatic system language following
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: const GalleryPage(),
      ),
    );
  }
}
