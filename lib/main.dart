import 'package:flutter/material.dart';
import 'package:priscription_app/core/routing/rounting.dart';
import 'package:priscription_app/feature/Screens/prescription_page.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      initialRoute: AppRouter.loginPage,
      onGenerateRoute: AppRouter.generateRoute,
    );
  }
}