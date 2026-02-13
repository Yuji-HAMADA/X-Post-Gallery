import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart'; // インポート追加
import 'package:x_post_gallery/screens/gallery/gallery_page.dart';

// async に変更して読み込みを待機する
void main() async {
  // これが重要！
  await dotenv.load(fileName: ".env");
  
  runApp(const ReViewGallery());
}

class ReViewGallery extends StatelessWidget {
  const ReViewGallery({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ReViewGallery',
      debugShowCheckedModeBanner: false, // 右上のリボンを消すとより綺麗です
      theme: ThemeData(
        useMaterial3: true, 
        colorSchemeSeed: Colors.indigo,
        brightness: Brightness.dark, // ギャラリーならダークモードもおすすめ
      ),
      home: const GalleryPage(),
    );
  }
}