import 'dart:convert';
import 'dart:io'; // Required for HttpClient & Certificate bypass
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

class CustomerScannerPage extends StatefulWidget {
  final String language;
  final String odooUrl;     
  final String sessionId;   

  const CustomerScannerPage({
    super.key, 
    required this.language,
    required this.odooUrl,
    required this.sessionId,
  });

  @override
  State<CustomerScannerPage> createState() => _CustomerScannerPageState();
}

class _CustomerScannerPageState extends State<CustomerScannerPage> with WidgetsBindingObserver {
  late MobileScannerController controller;
  bool _isProcessing = false; 

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    controller = MobileScannerController(
      detectionSpeed: DetectionSpeed.noDuplicates,
      // We focus on QR Codes. If you scan DataMatrix, ensure it contains valid text.
      formats: [BarcodeFormat.qrCode, BarcodeFormat.dataMatrix],
      returnImage: false,
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!controller.value.isInitialized) return;
    switch (state) {
      case AppLifecycleState.resumed:
        controller.start();
        break;
      case AppLifecycleState.inactive:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        controller.stop();
        break;
    }
    super.didChangeAppLifecycleState(state);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    controller.dispose();
    super.dispose();
  }

  String get _title => widget.language == 'ms_MY' ? 'Pengimbas Pelanggan' : 'Customer Scanner';
  String get _hint => widget.language == 'ms_MY' ? 'Imbas Kod QR MyInvois' : 'Scan MyInvois QR Code';

  /// Decodes Base64 to string. If it fails, returns the original string.
  String _tryDecodeBase64(String rawValue) {
    try {
      final cleanValue = rawValue.trim().replaceAll('\n', '');
      List<int> decodedBytes = base64.decode(cleanValue);
      return utf8.decode(decodedBytes);
    } catch (e) {
      // If it's not base64, return the raw scan
      return rawValue;
    }
  }

  /// Checks if the string looks like a valid UUID to prevent sending garbage to Odoo.
  bool _isValidUuid(String str) {
    // Basic regex for UUID (8-4-4-4-12 hex characters)
    // Example: 9a79a4ff-6b1b-46cb-be5b-8577ad121983
    final uuidRegex = RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');
    return uuidRegex.hasMatch(str);
  }

  // --- API CALL TO ODOO ---
  Future<void> _fetchTaxpayerInfo(String uuid) async {
    // 1. Validate Input (Prevent "UTF-8 invalid start byte" server errors)
    if (!_isValidUuid(uuid)) {
      _showErrorDialog("Invalid QR Code Format.\nScanned data is not a valid UUID.");
      return;
    }

    // 2. Construct API Endpoint
    final uri = Uri.parse("${widget.odooUrl}/web/dataset/call_kw/res.partner/supplier_qrcode_capture");

    try {
      // 3. Setup HttpClient with SSL Bypass
      HttpClient client = HttpClient();
      client.badCertificateCallback = ((X509Certificate cert, String host, int port) => true);
      
      // 4. Prepare Request
      HttpClientRequest request = await client.postUrl(uri);
      
      // Headers
      request.headers.set('Content-Type', 'application/json; charset=utf-8');
      request.headers.set('Cookie', 'session_id=${widget.sessionId}');

      // Body
      final body = jsonEncode({
          "jsonrpc": "2.0",
          "method": "call",
          "params": {
            "model": "res.partner",
            "method": "supplier_qrcode_capture",
            "args": [
              [],     
              uuid,   // We validated this is safe now
              false   
            ],
            "kwargs": {}
          },
          "id": DateTime.now().millisecondsSinceEpoch,
      });
      request.add(utf8.encode(body));

      // 5. Send & Receive
      HttpClientResponse response = await request.close();
      String responseBody = await response.transform(utf8.decoder).join();

      // 6. Handle Response
      if (response.statusCode == 200) {
        final result = jsonDecode(responseBody);
        
        if (result.containsKey('error')) {
          String errorMsg = result['error']['data']['message'] ?? result['error']['message'];
          _showErrorDialog("Odoo Error: $errorMsg");
        } else {
          final data = result['result'];
          if (data != null) {
            _showCustomerResultDialog(data, uuid);
          } else {
             _showErrorDialog("Customer not found or invalid data returned.");
          }
        }
      } else {
        _showErrorDialog("Server Error: ${response.statusCode}");
      }
    } catch (e) {
      _showErrorDialog("Connection Error: $e");
    }
  }

  void _handleBarcode(BarcodeCapture capture) async {
    if (_isProcessing) return;

    final List<Barcode> barcodes = capture.barcodes;
    for (final barcode in barcodes) {
      if (barcode.rawValue != null) {
        setState(() { _isProcessing = true; });
        await controller.stop(); // Freeze camera

        final String rawResult = barcode.rawValue!;
        final String uuid = _tryDecodeBase64(rawResult);

        // Debug print to see what is actually being scanned
        print("Scanned Raw: $rawResult");
        print("Decoded UUID: $uuid");

        await _fetchTaxpayerInfo(uuid);
        break; 
      }
    }
  }

  // --- UI DIALOGS ---

  void _showCustomerResultDialog(dynamic data, String uuid) {
    String name = data is Map ? (data['name'] ?? "Unknown") : "Customer ID: $data";
    String tin = data is Map ? (data['company_tin'] ?? data['vat'] ?? "-") : "-";
    String nric = data is Map ? (data['nric'] ?? data['l10n_my_identification_id'] ?? "-") : "-";

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text("Taxpayer Found"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _infoRow("Name:", name),
            const SizedBox(height: 8),
            _infoRow("TIN:", tin),
            const SizedBox(height: 8),
            _infoRow("ID/NRIC:", nric),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              setState(() { _isProcessing = false; });
              controller.start(); 
            },
            child: const Text("Cancel", style: TextStyle(color: Colors.red)),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.of(ctx).pop(); 
              Navigator.of(context).pop(uuid); // Return valid UUID to WebView
            },
            child: const Text("Select Customer"),
          ),
        ],
      ),
    );
  }

  void _showErrorDialog(String msg) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Error"),
        content: SingleChildScrollView(child: Text(msg)),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              setState(() { _isProcessing = false; });
              controller.start(); // Restart scan
            },
            child: const Text("Retry"),
          )
        ],
      ),
    );
  }

  Widget _infoRow(String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: 70, child: Text(label, style: const TextStyle(fontWeight: FontWeight.bold))),
        Expanded(child: Text(value, style: const TextStyle(color: Colors.black87))),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          MobileScanner(
            controller: controller,
            onDetect: _isProcessing ? (c) {} : _handleBarcode,
            // [FIXED] Removed the 3rd argument 'child' here. 
            // Now it matches: (BuildContext context, MobileScannerException error)
            errorBuilder: (context, error, /*child removed*/) {
              return Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.error, color: Colors.red, size: 40),
                    const SizedBox(height: 10),
                    Text(
                      "Camera Error: ${error.errorCode}",
                      style: const TextStyle(color: Colors.white),
                    ),
                  ],
                ),
              );
            },
          ),
          CustomPaint(
            painter: OdooScannerOverlayPainter(),
            child: Container(),
          ),
          Positioned(
            top: 0, left: 0, right: 0,
            child: SafeArea(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                color: Colors.black.withOpacity(0.6),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(_title, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            bottom: 40, left: 0, right: 0,
            child: Column(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.5),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(_hint, style: const TextStyle(color: Colors.white, fontSize: 16)),
                ),
                const SizedBox(height: 30),
                ValueListenableBuilder<MobileScannerState>(
                  valueListenable: controller,
                  builder: (context, state, child) {
                    switch (state.torchState) {
                      case TorchState.off:
                        return IconButton(icon: const Icon(Icons.flash_off, color: Colors.grey, size: 36), onPressed: () => controller.toggleTorch());
                      case TorchState.on:
                        return IconButton(icon: const Icon(Icons.flash_on, color: Colors.yellow, size: 36), onPressed: () => controller.toggleTorch());
                      default:
                        return IconButton(icon: const Icon(Icons.no_flash, color: Colors.grey, size: 36), onPressed: null);
                    }
                  },
                ),
              ],
            ),
          ),
          if (_isProcessing)
            Container(
              color: Colors.black54,
              child: const Center(
                child: CircularProgressIndicator(color: Colors.white),
              ),
            ),
        ],
      ),
    );
  }
}

class OdooScannerOverlayPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final double scanBoxSize = size.width * 0.70;
    final double scanBoxHeight = scanBoxSize;
    final Paint paintBackground = Paint()..color = Colors.black.withOpacity(0.6);
    final double left = (size.width - scanBoxSize) / 2;
    final double top = (size.height - scanBoxHeight) / 2;
    final Rect scanRect = Rect.fromLTWH(left, top, scanBoxSize, scanBoxHeight);
    final Path backgroundPath = Path()..addRect(Rect.fromLTWH(0, 0, size.width, size.height));
    final Path cutoutPath = Path()..addRRect(RRect.fromRectAndRadius(scanRect, const Radius.circular(12)));
    final Path finalPath = Path.combine(PathOperation.difference, backgroundPath, cutoutPath);
    canvas.drawPath(finalPath, paintBackground);
    final Paint borderPaint = Paint()..color = Colors.white..style = PaintingStyle.stroke..strokeWidth = 4.0..strokeCap = StrokeCap.square;
    double cornerSize = 25;
    canvas.drawPath(Path()..moveTo(left, top + cornerSize)..lineTo(left, top)..lineTo(left + cornerSize, top), borderPaint);
    canvas.drawPath(Path()..moveTo(left + scanBoxSize - cornerSize, top)..lineTo(left + scanBoxSize, top)..lineTo(left + scanBoxSize, top + cornerSize), borderPaint);
    canvas.drawPath(Path()..moveTo(left, top + scanBoxHeight - cornerSize)..lineTo(left, top + scanBoxHeight)..lineTo(left + cornerSize, top + scanBoxHeight), borderPaint);
    canvas.drawPath(Path()..moveTo(left + scanBoxSize - cornerSize, top + scanBoxHeight)..lineTo(left + scanBoxSize, top + scanBoxHeight)..lineTo(left + scanBoxSize, top + scanBoxHeight - cornerSize), borderPaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) {
    return false;
  }
}