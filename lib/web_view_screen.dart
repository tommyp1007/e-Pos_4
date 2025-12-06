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
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:printing/printing.dart';
import 'package:pdf/pdf.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:http/http.dart' as http;

// --- LOCAL SCREENS ---
import 'qr_scanner_screen.dart';
import 'pdf_viewer_screen.dart'; 

class WebViewScreen extends StatefulWidget {
  final String url;
  const WebViewScreen({super.key, required this.url});

  @override
  State<WebViewScreen> createState() => _WebViewScreenState();
}

class _WebViewScreenState extends State<WebViewScreen> with WidgetsBindingObserver {
  // --- CONTROLLERS ---
  InAppWebViewController? _webViewController;
  late PullToRefreshController _pullToRefreshController;
  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();

  // --- STATE VARIABLES ---
  bool _isLoading = true;
  bool _isTablet = false;
   
  // Odoo Scraped Data
  String? _currentOrderRef;
  String? _currentUuid;

  // --- SCRIPTS ---
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
  // LIFECYCLE
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
    // Check if the device is a tablet based on the shortest side length
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
  // PERMISSIONS & NOTIFICATIONS
  // ===========================================================================

  Future<void> _initPermissionsAndNotifications() async {
    await _initNotifications();
    await Permission.camera.request();
    if (Platform.isAndroid) {
      // Check for Storage/External Storage Permissions on Android
      if (await Permission.storage.request().isGranted) {
      } else if (await Permission.manageExternalStorage.status.isDenied) {
        await Permission.manageExternalStorage.request();
      }
      // Request notification permission on Android
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
        // Handle notification tap to open the file
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
        payload: filePath, // Payload for opening the file on tap
      );
    } catch (e) {
      log("Notification Error: $e");
    }
  }

  // ===========================================================================
  // HELPER: TIN EXTRACTION
  // ===========================================================================
  String _extractDataFromQr(String rawData) {
    if (rawData.contains("TIN") || rawData.contains("Taxpayer Profile")) {
      try {
        // Regex to find 'TIN' followed by colon/whitespace and then the alphanumeric TIN value
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

  // ===========================================================================
  // FILE HANDLING
  // ===========================================================================

  Future<void> _openFile(String filePath) async {
    if (filePath.startsWith('file://')) {
      filePath = filePath.substring(7);
    }

    if (filePath.toLowerCase().endsWith('.pdf')) {
      // Open with the custom PDF Viewer Screen
      if (mounted) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => PdfViewerScreen(filePath: filePath),
          ),
        );
      }
    } else {
      // Show snackbar with a Share option for other file types
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

  Future<void> _saveDataToFile(List<int> bytes, String mimeType, String? suggestedFileName) async {
    try {
      String fileName = suggestedFileName ?? "";

      // Custom Filename Logic for Odoo e-POS Invoices
      if (_currentOrderRef != null && _currentOrderRef!.isNotEmpty) {
          String sanitizedRef = _currentOrderRef!.replaceAll('/', '_').replaceAll(' ', '_').trim();
          String sanitizedUuid = (_currentUuid != null && _currentUuid!.isNotEmpty && _currentUuid != 'null') 
              ? _currentUuid!.replaceAll('/', '_').trim() 
              : "e-Invoice"; 
          
          fileName = "MyInvois e-POS_${sanitizedRef}_${sanitizedUuid}.pdf";
      }
      // Fallback for generic or unknown names
      else if (fileName.isEmpty || fileName.toLowerCase().contains("unknown")) {
        String extension = 'pdf';
        if (mimeType.contains('image')) extension = 'png';
        fileName = "Odoo_Doc_${DateTime.now().millisecondsSinceEpoch}.$extension";
      }
        
      // Final filename cleanup and extension check
      fileName = fileName.replaceAll('/', '_').replaceAll('\\', '_');
      if (mimeType == 'application/pdf' && !fileName.toLowerCase().endsWith('.pdf')) {
        fileName += '.pdf';
      }

      String filePath = "";
      
      if (Platform.isAndroid) {
        // Save to Android public Download directory
        String path = await ExternalPath.getExternalStoragePublicDirectory(ExternalPath.DIRECTORY_DOWNLOAD);
        File file = File('$path/$fileName');
        
        // Handle file name collision
        if (await file.exists()) {
          String nameWithoutExt = fileName.split('.').first;
          String ext = fileName.split('.').last;
          file = File('$path/${nameWithoutExt}_${DateTime.now().millisecondsSinceEpoch}.$ext');
        }
        
        await file.writeAsBytes(bytes, flush: true);
        filePath = file.path;
        
        await _showNotification(fileName, filePath);
        
        // Show snackbar with an OPEN action
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
      } 
      else if (Platform.isIOS) {
        // Save to iOS documents directory
        final directory = await getApplicationDocumentsDirectory();
        final file = File('${directory.path}/$fileName');
        await file.writeAsBytes(bytes, flush: true);
        filePath = file.path;
        // iOS opens the file immediately
        _openFile(filePath);
      }
    } catch (e) {
      log("Error saving file: $e");
    }
  }

  Future<void> _saveBase64ToFile(String dataUrl, String mimeType, String? name) async {
    try {
      final split = dataUrl.split(',');
      if (split.length < 2) return;
      // The actual data is the second part
      final bytes = base64Decode(split[1]);
      await _saveDataToFile(bytes, mimeType, name);
    } catch (e) {
      log("Base64 error: $e");
    }
  }

  // ===========================================================================
  // DOWNLOAD HANDLERS
  // ===========================================================================

  /// Processes 'blob:' URLs by fetching the blob content and passing it to Flutter as base64.
  Future<void> _processBlobUrl(String blobUrl, String? suggestedFileName) async {
    String fileNameArg = suggestedFileName ?? '';
    fileNameArg = fileNameArg.replaceAll("'", "\\'"); // Escape quotes for JS string

    String script = """
      (async function() {
        try {
          // Fetch the blob URL
          var response = await fetch('$blobUrl');
          var blob = await response.blob();
          
          // Use FileReader to convert Blob to Base64 Data URL
          var reader = new FileReader();
          reader.onloadend = function() {
            var base64data = reader.result; // data:mime/type;base64,data
            // Call Flutter handler with Base64 data, MIME type, and suggested file name
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

  /// Main download handling logic based on URL scheme.
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
        // iOS: Directly fetch the content to save to the documents directory, 
        // as the native download manager is often complex to fully control.
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Preparing Document...')),
          );
        }
        
        // Include cookies for authenticated downloads
        CookieManager cookieManager = CookieManager.instance();
        List<Cookie> cookies = await cookieManager.getCookies(url: WebUri(url));
        String cookieHeader = cookies.map((c) => "${c.name}=${c.value}").join("; ");

        final response = await http.get(
          uri,
          headers: {'Cookie': cookieHeader, 'User-Agent': 'FlutterApp'},
        );

        if (response.statusCode == 200) {
          // Assuming downloaded files are often PDFs in this context, 
          // or we'd need to extract the actual MIME type from response headers.
          await _saveDataToFile(response.bodyBytes, 'application/pdf', suggestedFileName);
        }
      } else {
        // Android: Rely on the native system download manager for external URLs
        if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
          // Fallback to platform default if external fails
          await launchUrl(uri, mode: LaunchMode.platformDefault);
        }
      }
    } catch (e) {
      log("Download error: $e");
    }
  }

  /// Extracts filename from Content-Disposition header.
  String _getFilenameFromContentDisposition(String contentDisposition) {
    RegExp regex = RegExp(r'filename[^;=\n]*=((["\u0027]).*?\2|[^;\n]*)');
    var match = regex.firstMatch(contentDisposition);
    if (match != null) {
      // Clean up quotes
      return match.group(1)?.replaceAll('"', '').replaceAll("'", "") ?? "";
    }
    return "";
  }

  // ===========================================================================
  // JS INJECTION
  // ===========================================================================

  Future<void> _injectCustomJavaScript(InAppWebViewController controller) async {
    // This script contains all the Odoo-specific hacks/hooks
    String script = """
      (function() {
        console.log("Injecting Odoo Mobile Hooks...");

        // 1. SCRAPER: Periodically scrapes Odoo transaction reference and UUID.
        function scrapeTransactionDetails() {
            try {
                var getValue = function(el) {
                    if (!el) return null;
                    if (el.tagName === 'INPUT') return el.value;
                    if (el.tagName === 'SPAN' || el.tagName === 'DIV' || el.tagName === 'B') return el.innerText;
                    return null;
                };
                // Try to get Order Reference from input field or breadcrumb
                var orderRef = getValue(document.querySelector('[name="name"]'));
                var uuid = getValue(document.querySelector('[name="uuid"]'));
                if (!orderRef) {
                   var breadcrumb = document.querySelector('.o_breadcrumb .active');
                   if (breadcrumb) orderRef = breadcrumb.innerText;
                }
                if (orderRef) {
                    // Send to Flutter handler
                    window.flutter_inappwebview.callHandler('TransactionInfoHandler', orderRef, uuid);
                }
            } catch(e) {}
        }
        setInterval(scrapeTransactionDetails, 1500);

        // 2. BARCODE SCANNER: Global function for Flutter to call after a successful scan.
        window.onFlutterBarcodeScanned = function(code) {
           console.log("Received barcode: " + code);
           
           // A. PARTNER SEARCH (e.g., POS customer search)
           var partnerSearchInput = document.querySelector('input[placeholder="Search Customers..."]') || document.querySelector('.sb-partner input');
           if (partnerSearchInput && partnerSearchInput.offsetParent !== null) {
             partnerSearchInput.setAttribute('inputmode', 'none'); 
             partnerSearchInput.focus();
             partnerSearchInput.value = code;
             partnerSearchInput.dispatchEvent(new Event('input', { bubbles: true }));
             partnerSearchInput.dispatchEvent(new Event('change', { bubbles: true }));
             partnerSearchInput.dispatchEvent(new KeyboardEvent('keyup', { key: 'Enter', keyCode: 13, bubbles: true }));
             partnerSearchInput.blur();
             setTimeout(() => { partnerSearchInput.removeAttribute('inputmode'); }, 200);
             return;
           }

           // B. PRODUCT SEARCH (e.g., POS product search)
           var productSearchInput = document.querySelector('input[placeholder="Search products..."]') || document.querySelector('input[placeholder="Carian produk..."]') || document.querySelector('.products-widget-control input');
           if (productSearchInput && productSearchInput.offsetParent !== null) {
             productSearchInput.setAttribute('inputmode', 'none');
             productSearchInput.focus();
             productSearchInput.value = code;
             productSearchInput.dispatchEvent(new Event('input', { bubbles: true }));
             productSearchInput.dispatchEvent(new Event('change', { bubbles: true }));
             productSearchInput.dispatchEvent(new KeyboardEvent('keyup', { key: 'Enter', keyCode: 13, bubbles: true }));
             productSearchInput.blur();
             setTimeout(() => { productSearchInput.removeAttribute('inputmode'); }, 200);
             
             // After entering the barcode, simulate a click on the first product or the + button
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

           // C. FALLBACK: Send to the currently active element or body
           window.dispatchEvent(new CustomEvent('barcode_scanned', { detail: code }));
           var target = document.activeElement || document.body;
           if (target.tagName === 'INPUT' || target.tagName === 'TEXTAREA') {
             target.setAttribute('inputmode', 'none');
             target.value = code;
             target.dispatchEvent(new Event('change', { bubbles: true }));
             target.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', keyCode: 13, bubbles: true }));
             target.blur();
             setTimeout(() => { target.removeAttribute('inputmode'); }, 200);
           } else {
             // For non-input elements, simulate key presses (like in Inventory/Manufacturing)
             for (var i = 0; i < code.length; i++) {
                 document.body.dispatchEvent(new KeyboardEvent('keypress', { key: code[i], char: code[i], bubbles: true }));
             }
             document.body.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', keyCode: 13, bubbles: true }));
           }
        };


        // 3. BUTTON HIJACKING: Intercepts Odoo's native QR/Barcode buttons.
        function hijackButtons() {
           var selectors = ['.o_mobile_barcode_button', '.o_stock_barcode_main_button', '.fa-qrcode', '.fa-barcode'];
           selectors.forEach(function(sel) {
              var elements = document.querySelectorAll(sel);
              elements.forEach(function(el) {
                 var btn = el.closest('button') || el.closest('.btn') || el;
                 // Prevent hijacking already hijacked buttons
                 if (btn && !btn.getAttribute('data-flutter-hijacked')) {
                    btn.setAttribute('data-flutter-hijacked', 'true');
                    // Clone and replace the button to remove existing JS listeners
                    var newBtn = btn.cloneNode(true);
                    if(btn.parentNode) btn.parentNode.replaceChild(newBtn, btn);
                    
                    // Attach the new listener to call the Flutter Native QR Scanner
                    newBtn.addEventListener('click', function(e) {
                        e.preventDefault(); e.stopPropagation();
                        window.flutter_inappwebview.callHandler('NativeQRScanner');
                    });
                 }
              });
           });
        }
        setInterval(hijackButtons, 1000);

        // 4. RECEIPT PRINTING HIJACKER: Intercepts POS receipt print button.
        document.body.addEventListener('click', function(e) {
           // Find the closest print button from the target element
           var btn = e.target.closest('.button.print') || // Odoo POS default print button
                     e.target.closest('.print-button') ||
                     e.target.closest('.btn-secondary'); 

           // Crucial check: Is this action happening within a POS screen context?
           var isPos = document.querySelector('.pos-receipt-container') || document.querySelector('.pos-content');

           if (btn && isPos) {
              var receipt = document.querySelector('.pos-receipt');
              
              if (receipt) {
                 e.preventDefault(); 
                 e.stopImmediatePropagation(); 

                 var clone = receipt.cloneNode(true);

                 // Fix relative image URLs (e.g., logo images in receipt)
                 var images = clone.querySelectorAll('img');
                 var origin = window.location.origin; 
                 images.forEach(function(img) {
                    var src = img.getAttribute('src');
                    if (src && src.startsWith('/')) {
                        img.src = origin + src; 
                    }
                 });

                 var content = clone.outerHTML;
                 
                 // Try to extract Order Reference for a better file name
                 var extractedRef = null;
                 try {
                     var text = receipt.innerText || "";
                     var match = text.match(/Order\\s*[:\\#]?\\s*([A-Za-z0-9\\-\\/]+)/i);
                     if(match && match[1]) extractedRef = match[1].trim();
                 } catch(err) {}

                 // Essential CSS styles to ensure correct rendering by flutter_html_to_pdf
                 var style = `
                    <style>
                        @import url('https://fonts.googleapis.com/css?family=Inconsolata:400,700&display=swap');
                        body { 
                           font-family: 'Inconsolata', monospace; 
                           background: white; 
                           color: black; 
                           margin: 0; 
                           padding: 10px; 
                           font-size: 13px;
                           /* Set a fixed width for the HTML rendering engine to simulate a receipt printer width */
                           width: 302px; // approx 80mm in CSS px units
                        }
                        img { max-width: 100%; }
                        .text-center { text-align: center; }
                        .text-right { text-align: right; }
                        .fw-bold { font-weight: bold; }
                        .fs-6 { font-size: 14px; font-weight: bold; }
                        .card { border: none; width: 100%; } 
                        .card-body { padding: 0; }
                        table { width: 100%; border-collapse: collapse; }
                        td, th { vertical-align: top; padding: 2px 0; }
                        .receipt-orderlines { border-style: double; border-left: none; border-right: none; border-bottom: none; width: 100%; margin-top: 5px; }
                        .pos-receipt-title { font-weight: bold; font-size: 140%; text-align: center; }
                        ul { list-style-type: none; padding: 0; margin: 0; }
                        tr[style*="border-top: 1px dashed"] { border-top: 1px dashed black !important; }
                        tr[style*="border-bottom:1px dashed"] { border-bottom: 1px dashed black !important; }
                    </style>
                 `;

                 var fullHtml = '<html><head><meta charset="utf-8">' + style + '</head><body>' + content + '</body></html>';
                 
                 // SEND TO FLUTTER to generate PDF
                 window.flutter_inappwebview.callHandler('PrintPosReceipt', fullHtml, extractedRef);
                 return false; 
              }
           }
        }, true); // Use capture phase to catch event before Odoo's listeners
      })();
    """;
    await controller.evaluateJavascript(source: script);
  }

  // ===========================================================================
  // WIDGET BUILD
  // ===========================================================================

  @override
  Widget build(BuildContext context) {
    // Determine User Agent based on whether it's a tablet or phone
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
          // Handle back button press: go back in WebView history if possible
          if (_webViewController != null && await _webViewController!.canGoBack()) {
            _webViewController!.goBack();
          } else {
            // Otherwise, pop the Flutter screen
            if (context.mounted) Navigator.of(context).pop();
          }
        },
        child: Scaffold(
          resizeToAvoidBottomInset: !Platform.isIOS,
          backgroundColor: Colors.white,
          body: SafeArea(
            child: Column(
              children: [
                // Loading indicator
                if (_isLoading)
                  const LinearProgressIndicator(minHeight: 3, color: Colors.blue),
                Expanded(
                  child: InAppWebView(
                    initialUrlRequest: URLRequest(url: WebUri(widget.url)),
                    initialUserScripts: UnmodifiableListView<UserScript>([
                      _apiDisablerScript, // Disable BarcodeDetector API for Odoo
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

                      // --- 1. TRANSACTION INFO HANDLER (Scraper) ---
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
                          }
                      );

                      // --- 2. QR HANDLER (Native QR Scanner) ---
                      controller.addJavaScriptHandler(
                        handlerName: 'NativeQRScanner',
                        callback: (args) async {
                          // Navigate to the native QR scanner screen
                          final String? qrData = await Navigator.push<String>(
                            context,
                            MaterialPageRoute(
                              builder: (context) => const QRScannerScreen(),
                            ),
                          );

                          if (qrData != null && qrData.isNotEmpty) {
                            // Extract TIN or use raw data
                            String filteredData = _extractDataFromQr(qrData);
                            final String escapedQrData = filteredData.replaceAll("'", "\\'");
                            // Call the injected JS function to simulate barcode scan
                            String script = "if(window.onFlutterBarcodeScanned) { window.onFlutterBarcodeScanned('$escapedQrData'); }";
                            _webViewController?.evaluateJavascript(source: script);
                          }
                        },
                      );

                      // --- 3. BLOB HANDLER (Data/Blob downloads) ---
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

                      // --- 4. PRINT HANDLER (POS Receipt) ---
                      controller.addJavaScriptHandler(
                        handlerName: 'PrintPosReceipt',
                        callback: (args) async {
                          if (args.isNotEmpty) {
                            String receiptHtml = args[0].toString();
                            
                            // Update order reference if provided by JS
                            if (args.length > 1 && args[1] != null && args[1].toString() != "null") {
                                String extractedRef = args[1].toString();
                                setState(() {
                                    _currentOrderRef = extractedRef;
                                });
                            }

                            try {
                              if (mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('Generating Receipt Preview...'), duration: Duration(seconds: 1)),
                                );
                              }
                              
                              // Create a dynamic file name
                              String fileName = "Receipt";
                              if (_currentOrderRef != null && _currentOrderRef!.isNotEmpty) {
                                fileName += "_${_currentOrderRef!.replaceAll('/', '_')}";
                              } else {
                                fileName += "_${DateTime.now().millisecondsSinceEpoch}";
                              }
                              fileName += ".pdf";

                              // === GENERATE PDF ===
                              // Use default/standard format. Size is controlled by HTML/CSS injected via JS (width: 302px).
                              final Uint8List pdfBytes = await Printing.convertHtml(
                                html: receiptHtml,
                                format: PdfPageFormat.standard, 
                              );

                              // === SAVE TO TEMP ===
                              final tempDir = await getTemporaryDirectory();
                              final tempFile = File('${tempDir.path}/$fileName');
                              await tempFile.writeAsBytes(pdfBytes, flush: true);

                              // === NAVIGATE TO PDF VIEWER ===
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
                                    SnackBar(content: Text("Receipt Gen Error: ${e.runtimeType}"))
                                );
                              }
                            }
                          }
                        },
                      );
                    },
                    onLoadStop: (controller, url) {
                      _pullToRefreshController.endRefreshing();
                      _injectCustomJavaScript(controller); // Inject JS hooks on page load completion
                      setState(() => _isLoading = false);
                    },
                    onPermissionRequest: (controller, request) async {
                      // Always grant permissions requested by the webview (e.g., camera, storage)
                      return PermissionResponse(
                        resources: request.resources,
                        action: PermissionResponseAction.GRANT,
                      );
                    },
                    onDownloadStartRequest: (controller, downloadRequest) async {
                      // Custom download handling logic
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
}