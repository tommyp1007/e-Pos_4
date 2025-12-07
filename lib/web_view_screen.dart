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

            String fileName = "Receipt";
            if (_currentOrderRef != null && _currentOrderRef!.isNotEmpty) {
              fileName += "_${_currentOrderRef!.replaceAll('/', '_')}";
            } else {
              fileName += "_${DateTime.now().millisecondsSinceEpoch}";
            }
            fileName += ".pdf";

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
      String fileName = suggestedFileName ?? "";

      // --- CUSTOM NAMING LOGIC FOR E-POS ---
      // Format: MyInvois e-POS_{OrderRef}_{UUID}.pdf
      if (_currentOrderRef != null && _currentOrderRef!.isNotEmpty) {
        String cleanRef = _currentOrderRef!.trim().replaceAll('/', '_').replaceAll('\\', '_');
        String cleanUuid = (_currentUuid != null && _currentUuid != "null" && _currentUuid!.isNotEmpty)
            ? _currentUuid!.trim()
            : "No-UUID";

        fileName = "MyInvois e-POS_${cleanRef}_${cleanUuid}.pdf";
      } else if (fileName.isEmpty || fileName.toLowerCase().contains("unknown") || fileName.toLowerCase().contains("document")) {
        // Fallback
        String extension = 'pdf';
        if (mimeType.contains('image')) extension = 'png';
        fileName = "Odoo_Doc_${DateTime.now().millisecondsSinceEpoch}.$extension";
      }

      // Cleanup filename
      fileName = fileName.replaceAll('/', '_').replaceAll('\\', '_');
      if (mimeType == 'application/pdf' && !fileName.toLowerCase().endsWith('.pdf')) {
        fileName += '.pdf';
      }

      String filePath = "";

      if (Platform.isAndroid) {
        String path = await ExternalPath.getExternalStoragePublicDirectory(ExternalPath.DIRECTORY_DOWNLOAD);
        File file = File('$path/$fileName');

        if (await file.exists()) {
          String nameWithoutExt = fileName.substring(0, fileName.lastIndexOf('.'));
          String ext = fileName.substring(fileName.lastIndexOf('.'));
          file = File('$path/${nameWithoutExt}_${DateTime.now().millisecondsSinceEpoch}$ext');
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
    // 4. E-Invoice Listener (Updated to target 'action_print_pos_invoice')
    // 5. Print Receipt Hijacking

    String script = """
      (function() {
        console.log("Injecting Odoo Mobile Hooks...");

        // HELPER: Scrape Odoo Fields (Handles Input vs Span vs Div)
        function getOdooFieldValue(fieldName) {
            var el = document.querySelector('[name="' + fieldName + '"]');
            if (!el) {
                // Try finding label if direct name attribute missing
                var label = Array.from(document.querySelectorAll('label')).find(l => l.innerText.includes(fieldName));
                if (label && label.nextElementSibling) el = label.nextElementSibling;
            }
            if (el) {
                if (el.tagName === 'INPUT') return el.value;
                return el.innerText.trim();
            }
            return null;
        }

        // 1. TRANSACTION SCRAPER (Periodic Backup)
        function scrapeTransactionDetails() {
            try {
                var orderRef = getOdooFieldValue('name');
                // Fallback for Ref
                if (!orderRef) {
                    var breadcrumb = document.querySelector('.o_breadcrumb .active');
                    if (breadcrumb) orderRef = breadcrumb.innerText;
                }
                var uuid = getOdooFieldValue('uuid');
                
                if (orderRef) {
                    window.flutter_inappwebview.callHandler('TransactionInfoHandler', orderRef, uuid);
                }
            } catch(e) {}
        }
        setInterval(scrapeTransactionDetails, 1500);

        // 2. BARCODE SCANNER
        window.onFlutterBarcodeScanned = function(code) {
           console.log("Received barcode: " + code);
           
           // Partner Search
           var partnerSearchInput = document.querySelector('input[placeholder="Search Customers..."]') || document.querySelector('.sb-partner input');
           if (partnerSearchInput && partnerSearchInput.offsetParent !== null) {
             partnerSearchInput.focus();
             partnerSearchInput.value = code;
             partnerSearchInput.dispatchEvent(new Event('input', { bubbles: true }));
             partnerSearchInput.dispatchEvent(new Event('change', { bubbles: true }));
             partnerSearchInput.dispatchEvent(new KeyboardEvent('keyup', { key: 'Enter', keyCode: 13, bubbles: true }));
             return;
           }

           // Product Search
           var productSearchInput = document.querySelector('input[placeholder="Search products..."]') || document.querySelector('input[placeholder="Carian produk..."]') || document.querySelector('.products-widget-control input');
           if (productSearchInput && productSearchInput.offsetParent !== null) {
             productSearchInput.focus();
             productSearchInput.value = code;
             productSearchInput.dispatchEvent(new Event('input', { bubbles: true }));
             productSearchInput.dispatchEvent(new Event('change', { bubbles: true }));
             productSearchInput.dispatchEvent(new KeyboardEvent('keyup', { key: 'Enter', keyCode: 13, bubbles: true }));
             
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

           // Fallback
           window.dispatchEvent(new CustomEvent('barcode_scanned', { detail: code }));
           var target = document.activeElement || document.body;
           if (target.tagName === 'INPUT' || target.tagName === 'TEXTAREA') {
             target.value = code;
             target.dispatchEvent(new Event('change', { bubbles: true }));
             target.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', keyCode: 13, bubbles: true }));
           } else {
             for (var i = 0; i < code.length; i++) {
                 document.body.dispatchEvent(new KeyboardEvent('keypress', { key: code[i], char: code[i], bubbles: true }));
             }
             document.body.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', keyCode: 13, bubbles: true }));
           }
        };

        // 3. HIJACK STANDARD QR BUTTONS
        function hijackButtons() {
           var selectors = ['.o_mobile_barcode_button', '.o_stock_barcode_main_button', '.fa-qrcode', '.fa-barcode'];
           selectors.forEach(function(sel) {
              var elements = document.querySelectorAll(sel);
              elements.forEach(function(el) {
                 var btn = el.closest('button') || el.closest('.btn') || el;
                 if (btn && !btn.getAttribute('data-flutter-hijacked')) {
                    btn.setAttribute('data-flutter-hijacked', 'true');
                    var newBtn = btn.cloneNode(true);
                    if(btn.parentNode) btn.parentNode.replaceChild(newBtn, btn);
                    
                    newBtn.addEventListener('click', function(e) {
                        e.preventDefault(); e.stopPropagation();
                        window.flutter_inappwebview.callHandler('NativeQRScanner');
                    });
                 }
              });
           });
        }
        setInterval(hijackButtons, 1000);

        // 4. E-INVOICE BUTTON LISTENER (action_print_pos_invoice)
        // Captures Ref & UUID immediately on click to ensure filename is correct
        function attachEInvoiceListener() {
           var btn = document.querySelector('button[name="action_print_pos_invoice"]');
           if (btn && !btn.getAttribute('data-flutter-listener')) {
               btn.setAttribute('data-flutter-listener', 'true');
               
               btn.addEventListener('click', function() {
                   console.log("Print e-Invoice Button Clicked");
                   try {
                       var orderRef = getOdooFieldValue('name');
                       // Fallback for Ref if not found in form
                       if (!orderRef) {
                           var breadcrumb = document.querySelector('.o_breadcrumb .active');
                           if (breadcrumb) orderRef = breadcrumb.innerText;
                       }
                       var uuid = getOdooFieldValue('uuid');

                       if (orderRef) {
                           console.log("Sending Ref: " + orderRef + " UUID: " + uuid);
                           window.flutter_inappwebview.callHandler('TransactionInfoHandler', orderRef, uuid);
                       }
                   } catch(e) {
                       console.error("Error scraping on e-invoice click: " + e);
                   }
               });
           }
        }
        setInterval(attachEInvoiceListener, 1000);


        // 5. EXISTING POS RECEIPT PRINTING HIJACKER (For .button.print)
        document.body.addEventListener('click', function(e) {
           var btn = e.target.closest('.button.print');
           
           if (btn) {
              var receiptContainer = document.querySelector('.pos-receipt');
              
              if (receiptContainer) {
                 e.preventDefault(); 
                 e.stopImmediatePropagation();

                 var clone = receiptContainer.cloneNode(true);

                 // FIX IMAGES
                 var images = clone.querySelectorAll('img');
                 var origin = window.location.origin; 
                 images.forEach(function(img) {
                    var src = img.getAttribute('src');
                    if (src && src.startsWith('/')) {
                        img.src = origin + src; 
                    }
                 });

                 // EXTRACT REF from Receipt Text (Backup extraction)
                 var extractedRef = null;
                 try {
                     var text = receiptContainer.innerText || "";
                     var match = text.match(/Order\\s*[:\\#]?\\s*([A-Za-z0-9\\-\\/]+)/i);
                     if(match && match[1]) extractedRef = match[1].trim();
                 } catch(err) {}

                 var content = clone.outerHTML;

                 var style = `
                    <style>
                        @import url('https://fonts.googleapis.com/css?family=Inconsolata:400,700&display=swap');
                        
                        body { 
                           font-family: 'Inconsolata', monospace; 
                           background: white; 
                           color: black; 
                           margin: 0; 
                           padding: 20px;
                           width: 100%;
                        }
                        .d-flex { display: flex; }
                        .flex-column { flex-direction: column; }
                        .justify-content-center { justify-content: center; }
                        .align-items-center { align-items: center; }
                        .text-center { text-align: center; }
                        .text-end, .text-right { text-align: right; }
                        .text-start, .text-left { text-align: left; }
                        .fw-bold { font-weight: bold; }
                        .fs-6 { font-size: 14px; }
                        .mb-0 { margin-bottom: 0; }
                        .ms-2 { margin-left: 0.5rem; }
                        .w-100 { width: 100%; }
                        
                        .pos-receipt { 
                            padding: 5px; 
                            width: 100%; 
                            box-sizing: border-box;
                        }
                        
                        img { max-width: 100%; height: auto; }
                        .card { border: none; width: 100%; } 
                        .card-body { padding: 0; }
                        
                        table { width: 100% !important; border-collapse: collapse; }
                        td, th { vertical-align: top; padding: 2px 0; font-size: 12px; }
                        
                        .receipt-orderlines { 
                             border-style: double; 
                             border-left: none; 
                             border-right: none; 
                             border-bottom: none; 
                             width: 100%; 
                             margin-top: 5px; 
                        }
                    </style>
                 `;

                 var fullHtml = '<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1.0">' + style + '</head><body><div class="pos-receipt">' + content + '</div></body></html>';
                 
                 window.flutter_inappwebview.callHandler('PrintPosReceipt', fullHtml, extractedRef);
                 return false; 
              }
           }
        }, true);
      })();
    """;
    await controller.evaluateJavascript(source: script);
  }
}