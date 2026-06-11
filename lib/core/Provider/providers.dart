import 'package:flutter/material.dart';
import '../network/api_service.dart';

class ProvidersProvider with ChangeNotifier {
  List<dynamic> _providers = [];
  bool _isLoading = false;
  String _error = "";

  List<dynamic> get providers => _providers;
  bool get isLoading => _isLoading;
  String get error => _error;

  Future<void> fetchProviders() async {
    _isLoading = true;
    _error = "";

    notifyListeners();

    try {
      final response = await PatientApiService.searchPatients('');

      _providers = response;
    } catch (e) {
      _error = e.toString();
      debugPrint("Fetch Providers Error: $_error");
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }
}
