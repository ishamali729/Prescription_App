import 'dart:convert';

import 'dart:io';

import '../../feature/Screens/prescription_page.dart';

class PatientApiService {
  static const String _url = 'https://hms.yourhrms.in/api/patient/';

  static List<Patient>? _cache;

  static Future<List<Patient>> searchPatients(String query) async {
    // Load & cache the full list on first call
    if (_cache == null) {
      final httpClient = HttpClient();
      final request = await httpClient.getUrl(Uri.parse(_url));
      final httpResponse = await request.close();
      if (httpResponse.statusCode == 200) {
        final body = await httpResponse.transform(utf8.decoder).join();
        final List<dynamic> data = jsonDecode(body);
        _cache = data.map((j) => Patient.fromJson(j)).toList();
      } else {
        throw Exception('API error: ${httpResponse.statusCode}');
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
