 

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:priscription_app/feature/Screens/prescription_page.dart';

class PatientApiService {
  static const String _url = 'https://hms.yourhrms.in/api/patient/';

  static List<Patient>? _cache;

  static Future<List<Patient>> searchPatients(String query) async {
    // Load & cache the full list on first call
    if (_cache == null) {
      final response = await http.get(Uri.parse(_url));
      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body);
        _cache = data.map((j) => Patient.fromJson(j)).toList();
      } else {
        throw Exception('API error: ${response.statusCode}');
      }
    }

    if (query.trim().isEmpty) return _cache!;

    final q = query.toLowerCase();
    return _cache!
        .where(
          (p) =>
              p.fullName.toLowerCase().contains(q) ||
              p.uhid.toLowerCase().contains(q) ||
              p.mobile.contains(q),
        )
        .toList();
  }

   
  static void clearCache() => _cache = null;
}
