import 'dart:convert';
import 'package:http/http.dart' as http;

class DataService {
  static Future<List<dynamic>> fetchGistData(String inputKey) async {
    final String url =
        'https://gist.githubusercontent.com/Yuji-HAMADA/$inputKey/raw/gallary_data.json';
    final response = await http.get(Uri.parse(url));

    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception("Invalid Password (ID)");
    }
  }
}
