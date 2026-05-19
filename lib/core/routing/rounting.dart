import 'package:flutter/material.dart';
import 'package:priscription_app/feature/Screens/prescription_page.dart';
 

class AppRouter {

  static const String home = '/';

  static Map<String, WidgetBuilder> get routes => {

        home: (context) => const PrescriptionPage(),

      };
}