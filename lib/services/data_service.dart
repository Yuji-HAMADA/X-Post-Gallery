import 'dart:convert';
import 'package:http/http.dart' as http;

class DataService {
  static Future<List<dynamic>> fetchGistData(String inputKey) async {
    // data.json を優先し、404なら gallary_data.json にフォールバック
    final String baseUrl =
        'https://gist.githubusercontent.com/Yuji-HAMADA/$inputKey/raw/';

    var response = await http.get(Uri.parse('${baseUrl}data.json'));

    if (response.statusCode == 404) {
      response = await http.get(Uri.parse('${baseUrl}gallary_data.json'));
    }

    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception("Invalid Password (ID)");
    }
  }
}
