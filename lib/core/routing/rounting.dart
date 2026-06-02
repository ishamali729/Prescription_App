import 'package:flutter/material.dart';
import 'package:priscription_app/feature/Screens/login_page.dart';
import 'package:priscription_app/feature/Screens/prescription_page.dart';

class AppRouter {

  static const String loginPage = '/';
  static const String prescriptionPage = '/prescription';

  static Route<dynamic> generateRoute(
      RouteSettings settings) {

    switch (settings.name) {

      case loginPage:
        return MaterialPageRoute(
          builder: (_) => const LoginPage(),
        );

      case prescriptionPage:
        return MaterialPageRoute(
          builder: (_) =>
              const PrescriptionPage(),
        );

      default:
        return MaterialPageRoute(
          builder: (_) => const Scaffold(
            body: Center(
              child: Text('Page Not Found'),
            ),
          ),
        );
    }
  }
}