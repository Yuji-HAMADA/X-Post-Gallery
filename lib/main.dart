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
  await dotenv.load(fileName: ".env");

  runApp(const ReViewGallery());
}

/// [JA] メインアプリケーションウィジェット（ダークテーマ・多言語化設定）
/// [EN] Main application widget (dark theme & localization setup)
class ReViewGallery extends StatelessWidget {
  const ReViewGallery({super.key});

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
