// File: lib/screens/qr_scanner_screen.dart

import 'dart:async';
import 'dart:developer';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';

class QRScannerScreen extends StatefulWidget {
  final String language; // Received from WebView
  const QRScannerScreen({super.key, required this.language});

  @override
  State<QRScannerScreen> createState() => _QRScannerScreenState();
}

class _QRScannerScreenState extends State<QRScannerScreen>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  
  late MobileScannerController _scannerController;
  StreamSubscription<Object?>? _subscription;
  late AnimationController _animationController;

  bool _isScanCompleted = false;
  bool _isTorchOn = false;
  bool _isPermissionGranted = false;
  bool _isLoading = true; 

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    
    log("QR Scanner initialized with language: ${widget.language}");

    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);

    _scannerController = MobileScannerController(
      facing: CameraFacing.back,
      torchEnabled: false,
      detectionSpeed: DetectionSpeed.noDuplicates, 
      returnImage: false,
      autoStart: false, 
      formats: [
        BarcodeFormat.aztec,
        BarcodeFormat.code128,
        BarcodeFormat.code39,
        BarcodeFormat.dataMatrix,
        BarcodeFormat.ean13,
        BarcodeFormat.ean8,
        BarcodeFormat.itf,
        BarcodeFormat.pdf417,
        BarcodeFormat.qrCode,
        BarcodeFormat.upcA,
        BarcodeFormat.upcE,
        BarcodeFormat.codabar,
        BarcodeFormat.code93,
      ],
    );

    _checkPermissionAndStart();
  }

  Future<void> _checkPermissionAndStart() async {
    final status = await Permission.camera.request();
    
    if (mounted) {
      setState(() {
        _isPermissionGranted = status.isGranted;
        _isLoading = false;
      });

      if (status.isGranted) {
        _startCamera();
      } else if (status.isPermanentlyDenied) {
        _showPermissionDialog();
      }
    }
  }

  void _showPermissionDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text("Camera Permission"),
        content: const Text("Camera access is required to scan QR codes and Barcodes."),
        actions: [
          TextButton(onPressed: () { Navigator.pop(ctx); Navigator.pop(context); }, child: const Text("Cancel")),
          TextButton(onPressed: () { Navigator.pop(ctx); openAppSettings(); }, child: const Text("Settings")),
        ],
      ),
    );
  }

  Future<void> _startCamera() async {
    try {
      await _scannerController.start();
    } catch (e) {
      log("Error starting camera: $e");
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (!_scannerController.value.isInitialized) return;

    switch (state) {
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        _scannerController.stop(); 
        break;
      case AppLifecycleState.resumed:
        _subscription = _scannerController.barcodes.listen(_handleDetection);
        if (_isPermissionGranted) {
           _scannerController.start();
        }
        break;
      default: break;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _subscription?.cancel();
    _scannerController.dispose();
    _animationController.dispose();
    super.dispose();
  }

  void _handleDetection(BarcodeCapture capture) {
    if (_isScanCompleted) return;

    final barcodes = capture.barcodes;
    if (barcodes.isEmpty) return;

    final String? code = barcodes.first.rawValue;
    
    if (code != null && code.isNotEmpty) {
       HapticFeedback.heavyImpact();
       setState(() => _isScanCompleted = true);
       log("Barcode/QR Detected: $code");
       Navigator.pop(context, code);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(backgroundColor: Colors.black, body: Center(child: CircularProgressIndicator(color: Colors.white)));
    }
    
    if (!_isPermissionGranted) {
      return Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(backgroundColor: Colors.black, leading: const BackButton(color: Colors.white)),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.videocam_off, color: Colors.grey, size: 60),
              const SizedBox(height: 20),
              ElevatedButton(onPressed: _checkPermissionAndStart, child: const Text("Grant Permission"))
            ],
          ),
        ),
      );
    }

    // --- LOGIC TO CHANGE TEXT BASED ON LANGUAGE ---
    final bool isMalay = widget.language.trim() == 'ms_MY';
    final String scanText = isMalay ? "Imbas Kod QR atau Kod Bar" : "Scan QR or Barcode";

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          MobileScanner(
            controller: _scannerController,
            onDetect: _handleDetection,
            fit: BoxFit.cover,
            errorBuilder: (context, error, {child}) { 
              return Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.error, color: Colors.white, size: 50),
                    ElevatedButton(onPressed: () => _startCamera(), child: const Text("Retry"))
                  ],
                ),
              );
            },
          ),
          QRScannerOverlay(overlayColour: Colors.black.withOpacity(0.6), animationController: _animationController, scanText: scanText),
          SafeArea(
            child: Align(
              alignment: Alignment.topLeft,
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: CircleAvatar(backgroundColor: Colors.black45, child: BackButton(color: Colors.white, onPressed: () => Navigator.pop(context))),
              ),
            ),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 20),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _buildControlButton(
                      icon: _isTorchOn ? Icons.flash_on : Icons.flash_off,
                      color: _isTorchOn ? Colors.yellowAccent : Colors.white,
                      onTap: () async {
                        await _scannerController.toggleTorch();
                        setState(() => _isTorchOn = !_isTorchOn);
                      },
                    ),
                    const SizedBox(width: 40),
                    _buildControlButton(
                      icon: Icons.cameraswitch_outlined,
                      color: Colors.white,
                      onTap: () async => await _scannerController.switchCamera(),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildControlButton({required IconData icon, required Color color, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 50, width: 50,
        decoration: BoxDecoration(color: Colors.white.withOpacity(0.2), shape: BoxShape.circle, border: Border.all(color: Colors.white.withOpacity(0.3))),
        child: Icon(icon, color: color, size: 28),
      ),
    );
  }
}

class QRScannerOverlay extends StatelessWidget {
  const QRScannerOverlay({super.key, required this.overlayColour, required this.animationController, required this.scanText});
  final Color overlayColour;
  final AnimationController animationController;
  final String scanText;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        double scanArea = math.min(constraints.maxWidth, constraints.maxHeight) * 0.70;
        if (scanArea > 350) scanArea = 350;

        return Stack(
          children: [
            ColorFiltered(
              colorFilter: ColorFilter.mode(overlayColour, BlendMode.srcOut),
              child: Stack(
                children: [
                  Container(decoration: const BoxDecoration(color: Colors.red, backgroundBlendMode: BlendMode.dstOut)),
                  Center(child: Container(height: scanArea, width: scanArea, decoration: BoxDecoration(color: Colors.red, borderRadius: BorderRadius.circular(16)))),
                ],
              ),
            ),
            Center(
              child: Container(
                height: scanArea, width: scanArea,
                decoration: BoxDecoration(borderRadius: BorderRadius.circular(16), border: Border.all(color: Colors.white, width: 2)),
                child: AnimatedBuilder(
                  animation: animationController,
                  builder: (context, child) {
                    return Align(
                      alignment: Alignment(0, animationController.value * 2 - 1),
                      child: Container(height: 2, width: scanArea, color: Colors.redAccent),
                    );
                  },
                ),
              ),
            ),
            Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 100.0),
                child: Text(
                  scanText,
                  style: TextStyle(color: Colors.white.withOpacity(0.8), fontSize: 16),
                ),
              ),
            ),
          ],
        );
      }
    );
  }
}