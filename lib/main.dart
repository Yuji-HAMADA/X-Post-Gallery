import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:provider/provider.dart';
import 'package:x_post_gallery/screens/gallery/gallery_page.dart';
import 'package:x_post_gallery/viewmodels/gallery_viewmodel.dart';

void main() async {
  await dotenv.load(fileName: ".env");

  runApp(const ReViewGallery());
}

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
          useMaterial3: true,
          colorSchemeSeed: Colors.indigo,
          brightness: Brightness.dark,
        ),
        home: const GalleryPage(),
      ),
    );
  }
}
