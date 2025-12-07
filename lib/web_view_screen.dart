import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:developer';
import 'dart:io';
import 'dart:typed_data';

// --- PACKAGES ---
import 'package:external_path/external_path.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

// --- LOCAL SCREENS ---
import 'pdf_viewer_screen.dart';
import 'qr_scanner_screen.dart';

class WebViewScreen extends StatefulWidget {
  final String url;
  const WebViewScreen({super.key, required this.url});

  @override
  State<WebViewScreen> createState() => _WebViewScreenState();
}

class _WebViewScreenState extends State<WebViewScreen> with WidgetsBindingObserver {
  
  // ===========================================================================
  // MARK: - STATE VARIABLES & CONTROLLERS
  // ===========================================================================
  
  // Controllers
  InAppWebViewController? _webViewController;
  late PullToRefreshController _pullToRefreshController;
  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();

  // State
  bool _isLoading = true;
  bool _isTablet = false;

  // Odoo Scraped Data
  String? _currentOrderRef;
  String? _currentUuid;

  // Scripts
  final UserScript _apiDisablerScript = UserScript(
    source: """
      window.BarcodeDetector = class BarcodeDetector {
        static getSupportedFormats() { return Promise.resolve([]); }
        constructor() { }
        detect() { return Promise.resolve([]); }
      };
    """,
    injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
  );

  // ===========================================================================
  // MARK: - LIFECYCLE METHODS
  // ===========================================================================

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initPermissionsAndNotifications();

    _pullToRefreshController = PullToRefreshController(
      options: PullToRefreshOptions(color: Colors.blue),
      onRefresh: () async {
        if (Platform.isAndroid) {
          _webViewController?.reload();
        } else if (Platform.isIOS) {
          _webViewController?.loadUrl(
              urlRequest: URLRequest(url: await _webViewController?.getUrl()));
        }
      },
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _isTablet = MediaQuery.of(context).size.shortestSide > 600;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_webViewController != null) {
      if (state == AppLifecycleState.paused) {
        _webViewController?.pause();
      } else if (state == AppLifecycleState.resumed) {
        _webViewController?.resume();
      }
    }
  }

  // ===========================================================================
  // MARK: - UI BUILD
  // ===========================================================================

  @override
  Widget build(BuildContext context) {
    final String userAgent = _isTablet
        ? "Mozilla/5.0 (Linux; Android 10) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Safari/537.36"
        : "Mozilla/5.0 (Linux; Android 10; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Mobile Safari/537.36";

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.white,
        statusBarIconBrightness: Brightness.dark,
        statusBarBrightness: Brightness.light,
        systemNavigationBarColor: Colors.white,
      ),
      child: PopScope(
        canPop: false,
        onPopInvoked: (didPop) async {
          if (didPop) return;
          if (_webViewController != null && await _webViewController!.canGoBack()) {
            _webViewController!.goBack();
          } else {
            if (context.mounted) Navigator.of(context).pop();
          }
        },
        child: Scaffold(
          resizeToAvoidBottomInset: !Platform.isIOS,
          backgroundColor: Colors.white,
          body: SafeArea(
            child: Column(
              children: [
                if (_isLoading)
                  const LinearProgressIndicator(minHeight: 3, color: Colors.blue),
                Expanded(
                  child: InAppWebView(
                    initialUrlRequest: URLRequest(url: WebUri(widget.url)),
                    initialUserScripts: UnmodifiableListView<UserScript>([
                      _apiDisablerScript,
                    ]),
                    initialOptions: InAppWebViewGroupOptions(
                      crossPlatform: InAppWebViewOptions(
                        javaScriptEnabled: true,
                        mediaPlaybackRequiresUserGesture: false,
                        useOnDownloadStart: true,
                        userAgent: userAgent,
                      ),
                      android: AndroidInAppWebViewOptions(
                        useHybridComposition: true,
                        supportMultipleWindows: true,
                        mixedContentMode: AndroidMixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
                      ),
                      ios: IOSInAppWebViewOptions(
                        allowsInlineMediaPlayback: true,
                        disallowOverScroll: true,
                        sharedCookiesEnabled: true,
                      ),
                    ),
                    pullToRefreshController: _pullToRefreshController,
                    onWebViewCreated: (controller) {
                      _webViewController = controller;
                      _registerJavaScriptHandlers(controller);
                    },
                    onLoadStop: (controller, url) {
                      _pullToRefreshController.endRefreshing();
                      _injectCustomJavaScript(controller);
                      setState(() => _isLoading = false);
                    },
                    onPermissionRequest: (controller, request) async {
                      // 1. If it's a Camera request, BLOCK IT.
                      //// This forces Odoo's internal JS to fail, preventing the "cr_VideoCapture" logs.
                      if (request.resources.contains(PermissionResourceType.CAMERA)) {
                        return PermissionResponse(
                          resources: request.resources,
                          action: PermissionResponseAction.DENY, 
                          );
                      }
                      // 2. Allow other things (like storage/microphone if needed)
                      return PermissionResponse(
                        resources: request.resources,
                        action: PermissionResponseAction.GRANT,
                      );
                    },
                    onDownloadStartRequest: (controller, downloadRequest) async {
                      String finalFileName = downloadRequest.suggestedFilename ?? "";
                      if (downloadRequest.contentDisposition != null) {
                        String parsedName = _getFilenameFromContentDisposition(downloadRequest.contentDisposition!);
                        if (parsedName.isNotEmpty) finalFileName = parsedName;
                      }
                      await _handleDownload(downloadRequest.url.toString(), finalFileName);
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ===========================================================================
  // MARK: - WEBVIEW HANDLERS SETUP
  // ===========================================================================

  void _registerJavaScriptHandlers(InAppWebViewController controller) {
    // 1. Transaction Info Handler
    controller.addJavaScriptHandler(
      handlerName: 'TransactionInfoHandler',
      callback: (args) {
        if (args.length >= 2) {
          String? newRef = args[0]?.toString();
          String? newUuid = args[1]?.toString();

          if (newRef != null && newRef != "null") {
            setState(() {
              _currentOrderRef = newRef;
              if (newUuid != null && newUuid != "null") {
                _currentUuid = newUuid;
              }
            });
          }
        }
      },
    );

    // 2. Native QR Scanner Handler
    controller.addJavaScriptHandler(
      handlerName: 'NativeQRScanner',
      callback: (args) async {
        final String? qrData = await Navigator.push<String>(
          context,
          MaterialPageRoute(builder: (context) => const QRScannerScreen()),
        );

        if (qrData != null && qrData.isNotEmpty) {
          String filteredData = _extractDataFromQr(qrData);
          final String escapedQrData = filteredData.replaceAll("'", "\\'");
          String script = "if(window.onFlutterBarcodeScanned) { window.onFlutterBarcodeScanned('$escapedQrData'); }";
          _webViewController?.evaluateJavascript(source: script);
        }
      },
    );

    // 3. Blob Downloader Handler
    controller.addJavaScriptHandler(
      handlerName: 'BlobDownloader',
      callback: (args) async {
        if (args.isNotEmpty) {
          String dataUrl = args[0].toString();
          String mimeType = args.length > 1 ? args[1].toString() : 'application/pdf';
          String? fileName = args.length > 2 ? args[2].toString() : null;
          await _saveBase64ToFile(dataUrl, mimeType, fileName);
        }
      },
    );

    // 4. POS Receipt Print Handler
    controller.addJavaScriptHandler(
      handlerName: 'PrintPosReceipt',
      callback: (args) async {
        if (args.isNotEmpty) {
          String receiptHtml = args[0].toString();

          if (args.length > 1 && args[1] != null && args[1].toString() != "null") {
            String extractedRef = args[1].toString();
            setState(() {
              _currentOrderRef = extractedRef;
            });
          }

          try {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Generating Receipt...'), duration: Duration(seconds: 1)),
              );
            }

            // --- CHANGED: Use Date/Time for receipt filename as well ---
            DateTime now = DateTime.now();
            String timestamp = "${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}_${now.hour.toString().padLeft(2, '0')}-${now.minute.toString().padLeft(2, '0')}-${now.second.toString().padLeft(2, '0')}";
            
            String fileName = "Receipt_$timestamp.pdf";

            // Generate PDF (80mm thermal format)
            final Uint8List pdfBytes = await Printing.convertHtml(
              html: receiptHtml,
              format: PdfPageFormat.roll80,
            );

            // Save to Temp and Open
            final tempDir = await getTemporaryDirectory();
            final tempFile = File('${tempDir.path}/$fileName');
            await tempFile.writeAsBytes(pdfBytes, flush: true);

            if (mounted) {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => PdfViewerScreen(filePath: tempFile.path),
                ),
              );
            }
          } catch (e) {
            log("Error processing receipt: $e");
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text("Receipt Gen Error: $e"))
              );
            }
          }
        }
      },
    );
  }

  // ===========================================================================
  // MARK: - FILE HANDLING & DOWNLOADS
  // ===========================================================================

  Future<void> _handleDownload(String url, String? suggestedFileName) async {
    Uri uri = Uri.parse(url);

    if (uri.scheme == 'blob') {
      await _processBlobUrl(url, suggestedFileName);
      return;
    }
    if (uri.scheme == 'data') {
      await _saveBase64ToFile(url, 'application/pdf', suggestedFileName);
      return;
    }

    try {
      if (Platform.isIOS) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Preparing Document...')),
          );
        }

        CookieManager cookieManager = CookieManager.instance();
        List<Cookie> cookies = await cookieManager.getCookies(url: WebUri(url));
        String cookieHeader = cookies.map((c) => "${c.name}=${c.value}").join("; ");

        final response = await http.get(
          uri,
          headers: {'Cookie': cookieHeader, 'User-Agent': 'FlutterApp'},
        );

        if (response.statusCode == 200) {
          await _saveDataToFile(response.bodyBytes, 'application/pdf', suggestedFileName);
        }
      } else {
        if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
          await launchUrl(uri, mode: LaunchMode.platformDefault);
        }
      }
    } catch (e) {
      log("Download error: $e");
    }
  }

  Future<void> _processBlobUrl(String blobUrl, String? suggestedFileName) async {
    String fileNameArg = suggestedFileName ?? '';
    fileNameArg = fileNameArg.replaceAll("'", "\\'");

    String script = """
      (async function() {
        try {
          var response = await fetch('$blobUrl');
          var blob = await response.blob();
          
          var reader = new FileReader();
          reader.onloadend = function() {
            var base64data = reader.result;
            window.flutter_inappwebview.callHandler('BlobDownloader', base64data, blob.type, '$fileNameArg');
          }
          reader.readAsDataURL(blob);
        } catch (e) {
          console.error("Error fetching blob: " + e);
        }
      })();
    """;
    await _webViewController?.evaluateJavascript(source: script);
  }

  Future<void> _saveBase64ToFile(String dataUrl, String mimeType, String? name) async {
    try {
      final split = dataUrl.split(',');
      if (split.length < 2) return;
      final bytes = base64Decode(split[1]);
      await _saveDataToFile(bytes, mimeType, name);
    } catch (e) {
      log("Base64 error: $e");
    }
  }

  Future<void> _saveDataToFile(List<int> bytes, String mimeType, String? suggestedFileName) async {
    try {
      // --- NEW NAMING LOGIC START ---
      // 1. Get current date and time
      String timestamp = DateTime.now()
          .toString()             // e.g., "2025-12-07 21:10:12.123456"
          .split('.')[0]          // Remove milliseconds -> "2025-12-07 21:10:12"
          .replaceAll(':', '-')   // Replace colons with dashes (safer for filenames)
          .replaceAll(' ', '_');  // Replace space with underscore

      // 2. Set the file name as requested
      String fileName = "MyInvois e-POS_$timestamp.pdf";
      // --- NEW NAMING LOGIC END ---

      // Ensure valid file path characters just in case
      fileName = fileName.replaceAll('/', '_').replaceAll('\\', '_');

      // Double check extension
      if (mimeType == 'application/pdf' && !fileName.toLowerCase().endsWith('.pdf')) {
        fileName += '.pdf';
      }

      String filePath = "";

      if (Platform.isAndroid) {
        String path = await ExternalPath.getExternalStoragePublicDirectory(ExternalPath.DIRECTORY_DOWNLOAD);
        File file = File('$path/$fileName');

        // Check if file exists (unlikely with seconds timestamp, but good practice)
        if (await file.exists()) {
          String nameWithoutExt = fileName.split('.').first;
          String ext = fileName.split('.').last;
          file = File('$path/${nameWithoutExt}_${DateTime.now().millisecondsSinceEpoch}.$ext');
        }

        await file.writeAsBytes(bytes, flush: true);
        filePath = file.path;

        await _showNotification(fileName, filePath);

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Saved: $fileName'),
            backgroundColor: Colors.green,
            action: SnackBarAction(
              label: 'OPEN',
              textColor: Colors.white,
              onPressed: () => _openFile(filePath),
            ),
          ));
        }
      } else if (Platform.isIOS) {
        final directory = await getApplicationDocumentsDirectory();
        final file = File('${directory.path}/$fileName');
        await file.writeAsBytes(bytes, flush: true);
        filePath = file.path;
        _openFile(filePath);
      }
    } catch (e) {
      log("Error saving file: $e");
    }
  }

  Future<void> _openFile(String filePath) async {
    if (filePath.startsWith('file://')) {
      filePath = filePath.substring(7);
    }

    if (filePath.toLowerCase().endsWith('.pdf')) {
      if (mounted) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => PdfViewerScreen(filePath: filePath),
          ),
        );
      }
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: const Text("File saved"),
          action: SnackBarAction(
            label: 'Share',
            onPressed: () => Share.shareXFiles([XFile(filePath)]),
          ),
        ));
      }
    }
  }

  // ===========================================================================
  // MARK: - PERMISSIONS & NOTIFICATIONS
  // ===========================================================================

  Future<void> _initPermissionsAndNotifications() async {
    await _initNotifications();
    await Permission.camera.request();
    if (Platform.isAndroid) {
      if (await Permission.storage.request().isGranted) {
      } else if (await Permission.manageExternalStorage.status.isDenied) {
        await Permission.manageExternalStorage.request();
      }
      await Permission.notification.request();
    }
  }

  Future<void> _initNotifications() async {
    const AndroidInitializationSettings initializationSettingsAndroid =
    AndroidInitializationSettings('@mipmap/ic_launcher');

    final DarwinInitializationSettings initializationSettingsDarwin =
    DarwinInitializationSettings(
        requestSoundPermission: false,
        requestBadgePermission: false,
        requestAlertPermission: false);

    final InitializationSettings initializationSettings = InitializationSettings(
        android: initializationSettingsAndroid, iOS: initializationSettingsDarwin);

    await flutterLocalNotificationsPlugin.initialize(initializationSettings,
        onDidReceiveNotificationResponse: (response) {
          if (response.payload != null) {
            _openFile(response.payload!);
          }
        });
  }

  Future<void> _showNotification(String fileName, String filePath) async {
    if (!Platform.isAndroid) return;

    const AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
      'download_channel_id',
      'Downloads',
      channelDescription: 'Downloaded files',
      importance: Importance.high,
      priority: Priority.high,
      icon: '@mipmap/ic_launcher',
    );

    try {
      await flutterLocalNotificationsPlugin.show(
        DateTime.now().millisecond,
        'Download Complete',
        fileName,
        const NotificationDetails(android: androidDetails),
        payload: filePath,
      );
    } catch (e) {
      log("Notification Error: $e");
    }
  }

  // ===========================================================================
  // MARK: - HELPER UTILS
  // ===========================================================================

  String _extractDataFromQr(String rawData) {
    if (rawData.contains("TIN") || rawData.contains("Taxpayer Profile")) {
      try {
        final RegExp tinRegex = RegExp(r'TIN\s*[:\n\r\s]+\s*([A-Z0-9]+)', caseSensitive: false);
        final match = tinRegex.firstMatch(rawData);
        if (match != null && match.group(1) != null) {
          return match.group(1)!;
        }
      } catch (e) {
        log("Error parsing TIN: $e");
      }
    }
    return rawData;
  }

  String _getFilenameFromContentDisposition(String contentDisposition) {
    RegExp regex = RegExp(r'filename[^;=\n]*=((["\u0027]).*?\2|[^;\n]*)');
    var match = regex.firstMatch(contentDisposition);
    if (match != null) {
      return match.group(1)?.replaceAll('"', '').replaceAll("'", "") ?? "";
    }
    return "";
  }

  // ===========================================================================
  // MARK: - JAVASCRIPT INJECTION LOGIC
  // ===========================================================================

  Future<void> _injectCustomJavaScript(InAppWebViewController controller) async {
    // Note: This script performs DOM manipulation to:
    // 1. Scrape Transaction/UUID
    // 2. Hijack Barcode/Scanner inputs
    // 3. Hijack Buttons for native features
    // 4. E-Invoice Listener
    // 5. Print Receipt Hijacking

    String script = """
    (function() {
      console.log("Injecting Odoo Mobile Hooks...");

      // ============================================================
      // 1. BARCODE INPUT HANDLER
      // Purpose: This is the function Flutter calls when YOU scan a barcode with the native camera.
      // It takes that code and tries to "type" it into Odoo's search bars automatically.
      // ============================================================
      window.onFlutterBarcodeScanned = function(code) {
         console.log("Received barcode: " + code);
         
         // --- LOGIC A: Customer Search (POS) ---
         // If the "Search Customers" modal is open, type the barcode there.
         var partnerSearchInput = document.querySelector('input[placeholder="Search Customers..."]') || document.querySelector('.sb-partner input');
         if (partnerSearchInput && partnerSearchInput.offsetParent !== null) {
           partnerSearchInput.setAttribute('inputmode', 'none'); // Prevent keyboard from popping up
           partnerSearchInput.focus();
           partnerSearchInput.value = code;
           
           // We must dispatch these events so Odoo's Javascript framework (Owl) detects the change
           partnerSearchInput.dispatchEvent(new Event('input', { bubbles: true }));
           partnerSearchInput.dispatchEvent(new Event('change', { bubbles: true }));
           partnerSearchInput.dispatchEvent(new KeyboardEvent('keyup', { key: 'Enter', keyCode: 13, bubbles: true }));
           
           partnerSearchInput.blur();
           setTimeout(() => { partnerSearchInput.removeAttribute('inputmode'); }, 200);
           return;
         }

         // --- LOGIC B: Product Search (POS) ---
         // If we are on the main POS screen, type into the product search bar.
         var productSearchInput = document.querySelector('input[placeholder="Search products..."]') || document.querySelector('input[placeholder="Carian produk..."]') || document.querySelector('.products-widget-control input');
         if (productSearchInput && productSearchInput.offsetParent !== null) {
           productSearchInput.setAttribute('inputmode', 'none');
           productSearchInput.focus();
           productSearchInput.value = code;
           
           // Trigger Odoo to filter products
           productSearchInput.dispatchEvent(new Event('input', { bubbles: true }));
           productSearchInput.dispatchEvent(new Event('change', { bubbles: true }));
           productSearchInput.dispatchEvent(new KeyboardEvent('keyup', { key: 'Enter', keyCode: 13, bubbles: true }));
           productSearchInput.blur();
           setTimeout(() => { productSearchInput.removeAttribute('inputmode'); }, 200);
           
           // Special Trick: After scanning, try to automatically click the "Add" (+) button 
           // or select the first product that appears.
           setTimeout(function() {
               var plusIcon = document.querySelector('#qty_btn_product .fa-plus');
               if (plusIcon && plusIcon.closest('a')) {
                 plusIcon.closest('a').click();
               } else {
                 var firstProduct = document.querySelector('article.product');
                 if (firstProduct) firstProduct.click();
               }
           }, 700);
           return;
         }

         // --- LOGIC C: Fallback (Inventory/Generic) ---
         // If we aren't in POS, simulate raw keyboard presses. 
         // This works for Barcode Action forms in Inventory.
         window.dispatchEvent(new CustomEvent('barcode_scanned', { detail: code }));
         var target = document.activeElement || document.body;
         
         if (target.tagName === 'INPUT' || target.tagName === 'TEXTAREA') {
           // Standard Input typing
           target.setAttribute('inputmode', 'none');
           target.value = code;
           target.dispatchEvent(new Event('change', { bubbles: true }));
           target.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', keyCode: 13, bubbles: true }));
           target.blur();
           setTimeout(() => { target.removeAttribute('inputmode'); }, 200);
         } else {
           // Raw Keypress simulation (for Odoo's global listener)
           for (var i = 0; i < code.length; i++) {
               document.body.dispatchEvent(new KeyboardEvent('keypress', { key: code[i], char: code[i], bubbles: true }));
           }
           document.body.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', keyCode: 13, bubbles: true }));
         }
      };

      // ============================================================
      // 2. CAMERA HIJACKER (Button Replacement)
      // ============================================================
      function hijackButtons() {
          var selectors = ['.o_mobile_barcode_button', '.o_stock_barcode_main_button', '.fa-qrcode', '.fa-barcode'];

          selectors.forEach(function(sel) {
              var elements = document.querySelectorAll(sel);
              elements.forEach(function(el) {
                  // Find the actual button container
                  var btn = el.closest('button') || el.closest('.btn') || el;

                  // Check if we already hijacked it
                  if (btn && !btn.getAttribute('data-flutter-hijacked')) {
                      btn.setAttribute('data-flutter-hijacked', 'true');

                      // REMOVED: btn.style.border = "2px solid red";  <-- This was making the red box

                      // Add Capture Phase Listener (Trigger Native Scanner)
                      btn.addEventListener('click', function(e) {
                          e.preventDefault();
                          e.stopPropagation();
                          e.stopImmediatePropagation();
                          window.flutter_inappwebview.callHandler('NativeQRScanner');
                      }, true); 
                  }
              });
          });
      }

      // Run immediately and every 1s to catch new buttons
      hijackButtons();
      setInterval(hijackButtons, 1000);

      // ============================================================
      // 3. RECEIPT & E-INVOICE CODE
      // ============================================================
      
      document.body.addEventListener('click', function(e) {
          
      });

  })();
  """;
  await controller.evaluateJavascript(source: script);
  }
}