import 'dart:io';
import 'dart:ui'; // Required for PointerDeviceKind

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';

// Ensure these point to your actual file locations
import 'package:epos/web_view_screen.dart';
import 'package:epos/urls.dart';
import 'package:epos/customer_display_screen.dart'; // Import Customer Screen

// Global Key
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

// ---------------------------------------------------------
// ENTRY POINT 1: The Main App (Phone/Tablet Screen)
// ---------------------------------------------------------
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 1. Android WebView Debugging (Optional but helpful)
  if (Platform.isAndroid) {
    await InAppWebViewController.setWebContentsDebuggingEnabled(kDebugMode);
  }

  // 2. Transparent Status Bar
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.dark,
    statusBarBrightness: Brightness.light,
  ));

  // 3. Lock Orientation to Portrait & Landscape
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);

  runApp(const MyApp());
}

// ---------------------------------------------------------
// ENTRY POINT 2: The Second Screen (Customer Display)
// ---------------------------------------------------------
// This function MUST be named 'secondaryDisplayMain' and
// MUST have the @pragma('vm:entry-point') annotation.
// The plugin looks for this specific function to launch the 2nd screen.
@pragma('vm:entry-point')
void secondaryDisplayMain() {
  // CRITICAL FIX: Initialize binding for the second engine
  // Without this, plugins (like InAppWebView) won't register on the second screen.
  WidgetsFlutterBinding.ensureInitialized(); 
  
  runApp(const MySecondaryApp());
}

// ---------------------------------------------------------
// WIDGET: Secondary Application Wrapper
// ---------------------------------------------------------
class MySecondaryApp extends StatelessWidget {
  const MySecondaryApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      // The second screen starts directly with the Customer View
      home: const CustomerDisplayScreen(),
    );
  }
}

// ---------------------------------------------------------
// WIDGET: Main Application (Primary Screen)
// ---------------------------------------------------------
class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  @override
  void initState() {
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: navigatorKey,
      title: "EPOS Pilot",
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: Colors.white,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blue,
          brightness: Brightness.light,
        ),
        visualDensity: VisualDensity.adaptivePlatformDensity,
      ),
      // Custom Scroll Behavior for Touch Devices
      scrollBehavior: const MaterialScrollBehavior().copyWith(
        dragDevices: {
          PointerDeviceKind.mouse,
          PointerDeviceKind.touch,
          PointerDeviceKind.stylus,
          PointerDeviceKind.trackpad,
          PointerDeviceKind.unknown,
        },
      ),
      // Pointing to your Production URL (from urls.dart)
      home: const WebViewScreen(url: ApiUrls.production),

      // CRITICAL: Register the presentation route
      // This tells the app what to show when the secondary display connects
      routes: {
        'presentation': (context) => const CustomerDisplayScreen(),
      },
    );
  }
}