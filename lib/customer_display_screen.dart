import 'dart:convert';
import 'dart:typed_data'; // Required for Uint8List
import 'package:flutter/material.dart';
import 'package:flutter_presentation_display/flutter_presentation_display.dart';

// --- STATE MODEL ENUM ---
enum PaymentMethodType {
  cash,
  card,
  ewallet,
  bank,
  cheque,
  creditBalance,
  unknown
}

class CustomerDisplayScreen extends StatefulWidget {
  const CustomerDisplayScreen({super.key});

  @override
  State<CustomerDisplayScreen> createState() => _CustomerDisplayScreenState();
}

class _CustomerDisplayScreenState extends State<CustomerDisplayScreen> {
  final FlutterPresentationDisplay _displayManager = FlutterPresentationDisplay();
    
  // --- STATE VARIABLES ---
  String _mode = 'welcome'; 
  String _language = 'en_US'; 
  
  // --- INTENT MODEL VARIABLES (Synced with Scraper) ---
  PaymentMethodType? _selectedMethod; // NULL = not chosen/initialized yet
  double _cashInput = 0.0; // Comes from 'cashKeypadInput'
  bool _hasKeypadInput = false; // Comes from 'methodChosen' logic
    
  // --- DATA VARIABLES ---
  String _total = '0.00';
  String _change = '0.00';
  String _remaining = '0.00';
  String _paidAmount = '0.00'; // Derived for Receipt Mode
  String? _customerName;
  String? _qrCodeUrl;
  String? _qrCodeBase64; 
  String? _cashierName;
  List<Map<String, String>> _items = [];

  // --- TRANSLATION DICTIONARY ---
  final Map<String, Map<String, String>> _translations = {
    'welcome': {
      'en_US': 'Welcome to MyInvois e-Pos',
      'ms_MY': 'Selamat Datang ke MyInvois e-Pos',
    },
    'wait_customer': {
      'en_US': 'Please wait for a moment.',
      'ms_MY': 'Sila tunggu sebentar.'
    },
    'customer': {
      'en_US': 'Customer',
      'ms_MY': 'Pelanggan',
    },
    'new_order': {
      'en_US': 'New Order',
      'ms_MY': 'Pesanan Baru',
    },
    'header_item': {
      'en_US': 'Item',
      'ms_MY': 'Produk',
    },
    'header_qty': {
      'en_US': 'Qty',
      'ms_MY': 'Ktt',
    },
    'header_price': {
      'en_US': 'Price',
      'ms_MY': 'Harga',
    },
    'total_payable': {
      'en_US': 'Total Payable',
      'ms_MY': 'Jumlah Perlu Dibayar',
    },
    'total_amount': {
      'en_US': 'Total Amount',
      'ms_MY': 'Jumlah Besar',
    },
    'total_paid': {
      'en_US': 'Total Paid',
      'ms_MY': 'Jumlah Dibayar',
    },
    'remaining': {
      'en_US': 'Remaining',
      'ms_MY': 'Baki Bayaran',
    },
    'change': {
      'en_US': 'Change',
      'ms_MY': 'Baki',
    },
    'payment_success': {
      'en_US': 'Payment Successful!',
      'ms_MY': 'Pembayaran Berjaya!',
    },
    'served_by': {
      'en_US': 'Served by',
      'ms_MY': 'Dilayan oleh',
    },
    'e_invoice': {
      'en_US': 'E-Invoice',
      'ms_MY': 'E-Invois',
    },
    'scan_view': {
      'en_US': 'Scan to view details',
      'ms_MY': 'Imbas untuk butiran',
    },
    'qr_unavailable': {
      'en_US': 'QR Code Unavailable',
      'ms_MY': 'Kod QR Tidak Tersedia',
    },
    'cash_received': {
      'en_US': 'Cash Received',
      'ms_MY': 'Tunai Diterima',
    },
    'payment_amount': {
      'en_US': 'Payment Amount',
      'ms_MY': 'Jumlah Bayaran',
    },
    'payment_status': {
      'en_US': 'Payment Status',
      'ms_MY': 'Status Bayaran',
    },
    'paid': {
      'en_US': 'Paid',
      'ms_MY': 'Dibayar',
    },
    'waiting_cash': {
      'en_US': 'Waiting for cash input...',
      'ms_MY': 'Menunggu input tunai...',
    }
  };

  String t(String key) {
    return _translations[key]?[_language] ?? _translations[key]?['en_US'] ?? key;
  }

  @override
  void initState() {
    super.initState();
    _displayManager.listenDataFromMainDisplay((data) {
      if (data is Map) {
        _processData(data);
      } else if (data is String) {
        try {
          final decoded = jsonDecode(data);
          if (decoded is Map) {
            _processData(decoded);
          }
        } catch (e) {
          debugPrint("JSON Parse Error: $e");
        }
      }
    });
  }

  void _processData(Map<dynamic, dynamic> rawData) {
    try {
      final data = Map<String, dynamic>.from(rawData);
        
      if (data['type'] == 'display_update') {
        final payload = Map<String, dynamic>.from(data['payload']);
        
        // --- 1. PARSE BASIC DATA ---
        String incomingMode = payload['mode'] ?? 'welcome';
        String newTotalStr = _cleanMoney(payload['total']);
        double calculatedTotal = 0.0;

        // Parse Items (needed for total fallback)
        List<Map<String, String>> tempItems = [];
        if (payload['items'] != null) {
          var list = payload['items'] as List;
          tempItems = list.map((i) {
            var map = Map<String, dynamic>.from(i);
            String priceStr = _cleanMoney(map['price']);
            String qtyStr = map['qty'].toString();
            double price = _parseMoney(priceStr);
            double qty = double.tryParse(qtyStr) ?? 1.0;
            calculatedTotal += (price * qty);
            return {'name': map['name'].toString(), 'qty': qtyStr, 'price': priceStr};
          }).toList();
        }

        // Total Fallback Logic
        if (_parseMoney(newTotalStr) == 0.00 && calculatedTotal > 0.00) {
            newTotalStr = calculatedTotal.toStringAsFixed(2);
        }
        // Keep old total if new total is 0.00 during payment/receipt (common glitch prevention)
        if ((incomingMode == 'payment' || incomingMode == 'receipt') && newTotalStr == "0.00" && _total != "0.00") {
          newTotalStr = _total; 
        }

        // --- 2. INTENT LOGIC SIMULATION (SYNCED WITH SCRAPER) ---
        
        // A. Detect if we just Entered Payment Screen
        if (_mode != 'payment' && incomingMode == 'payment') {
           // Only reset if we are genuinely entering payment mode fresh
           _selectedMethod = null;
           _cashInput = 0.0;
           _hasKeypadInput = false;
        }

        // B. Determine Current Payment Method from Scraper
        String methodStr = payload['payment_method'] ?? payload['paymentMethod'] ?? 'cash';
        PaymentMethodType incomingMethod = _parseMethodType(methodStr);

        // C. Calculate "Implied" Paid Amount from Odoo Math
        // FIX: Only sync keypad/cash logic if we are in PAYMENT mode. 
        // If we are in RECEIPT mode, ignore this section to preserve the _cashInput from the previous screen.
        if (incomingMode == 'payment') {
          
            bool jsMethodChosen = payload['methodChosen'] == true;
            double jsCashInput = double.tryParse(payload['cashKeypadInput']?.toString() ?? '0') ?? 0.0;

            if (jsMethodChosen) {
               // User has specifically engaged with a payment method
               _selectedMethod = PaymentMethodType.cash; 
               
               if (incomingMethod != PaymentMethodType.cash) {
                 _selectedMethod = incomingMethod;
                 _cashInput = 0.0;
                 _hasKeypadInput = false;
               } else {
                 _cashInput = jsCashInput;
                 _hasKeypadInput = _cashInput > 0.001;
               }
            } else {
               // JS says nothing chosen yet
               if (incomingMethod != PaymentMethodType.cash && incomingMethod != PaymentMethodType.unknown) {
                 _selectedMethod = incomingMethod;
               }
               // If cash but 0 input, reset
               if (incomingMethod == PaymentMethodType.cash && !jsMethodChosen) {
                 _selectedMethod = PaymentMethodType.cash;
                 _cashInput = 0.0;
                 _hasKeypadInput = false;
               }
            }
        }

        // --- 3. UPDATE UI STATE ---
        if (mounted) {
          setState(() {
            
            // --- UPDATED MODE LOGIC ---
            if (incomingMode == 'receipt') {
              _mode = 'receipt';
              _items = tempItems; 
              
              // ** RECEIPT SPECIFIC LOGIC **
              // Ensure we capture the method used for the receipt
              if (payload.containsKey('payment_method')) {
                 _selectedMethod = _parseMethodType(payload['payment_method']);
              }
              // Update Change for receipt
              _change = _cleanMoney(payload['change']);
              
              // Derive Paid Amount for Receipt: Total + Change (safest calculation)
              double t = _parseMoney(newTotalStr);
              double c = _parseMoney(_change);
              _paidAmount = (t + c).toStringAsFixed(2);
            } else if (incomingMode == 'payment') {
              _mode = 'payment';
              // FIX: Only overwrite _items if the scraper actually found them.
              // If scraper sends [], keep the existing items so they don't disappear.
              if (tempItems.isNotEmpty) {
                _items = tempItems;
              }
            } else if (tempItems.isNotEmpty) {
              _mode = 'cart';
              _items = tempItems;
            } else {
              _mode = 'welcome';
              _items = [];
            }

            // Update translations/language
            if (payload.containsKey('lang') && payload['lang'] != null) {
              _language = payload['lang'].toString();
            }
            
            // Update other data
            _total = newTotalStr;
            _customerName = payload['customer'];
            _remaining = _cleanMoney(payload['remaining']);
            _change = _cleanMoney(payload['change']);
            _cashierName = payload['cashier'];
            _qrCodeUrl = payload['qrCodeUrl'];
            _qrCodeBase64 = payload['qrCodeBase64']; 
            
          });
        }
      } else if (data['type'] == 'reset') {
        // RESET Logic when leaving POS or closing session
        Future.delayed(const Duration(milliseconds: 100), () {
          if (mounted) {
            setState(() {
              _mode = 'welcome';
              _items = [];
              _total = "0.00";
              _customerName = null;
              _remaining = "0.00";
              _change = "0.00";
              _paidAmount = "0.00";
              _qrCodeBase64 = null;
              _qrCodeUrl = null;
              _selectedMethod = null;
              _cashInput = 0.0;
              _hasKeypadInput = false;
            });
          }
        });
      }
    } catch (e) {
      debugPrint("Data Processing Error: $e");
    }
  }

  PaymentMethodType _parseMethodType(String method) {
    String m = method.toLowerCase();
    if (m.contains('cash') || m.contains('tunai')) return PaymentMethodType.cash;
    if (m.contains('card') || m.contains('credit') || m.contains('debit')) return PaymentMethodType.card;
    if (m.contains('wallet') || m.contains('qr')) return PaymentMethodType.ewallet;
    if (m.contains('bank')) return PaymentMethodType.bank;
    if (m.contains('cheque')) return PaymentMethodType.cheque;
    return PaymentMethodType.unknown; 
  }

  String _cleanMoney(dynamic value) {
    if (value == null) return "0.00";
    String str = value.toString();
    if (str.isEmpty || str == "null") return "0.00";
    return str.replaceAll('RM', '').replaceAll(' ', '').trim();
  }

  double _parseMoney(String val) {
    if (val.isEmpty || val == "null") return 0.0;
    return double.tryParse(val.replaceAll(',', '')) ?? 0.0;
  }

  @override
  Widget build(BuildContext context) {
    switch (_mode) {
      case 'receipt':
        return _buildReceiptScreen();
      case 'welcome':
        return _buildWelcomeScreen();
      case 'cart':
      case 'payment':
      default:
        return _buildMainSplitScreen();
    }
  }

  // --- SCREEN 1: WELCOME ---
  Widget _buildWelcomeScreen() {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(30),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.blue.shade50,
              ),
              child: const Icon(Icons.storefront_outlined, size: 100, color: Colors.blue),
            ),
            const SizedBox(height: 30),
            Text(
              t('welcome'),
              style: const TextStyle(fontSize: 40, fontWeight: FontWeight.bold, color: Colors.black87),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 10),
            Text(
              t('wait_customer'),
              style: const TextStyle(fontSize: 28, color: Colors.grey),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  // --- SCREEN 2 & 3: MAIN SPLIT SCREEN ---
  Widget _buildMainSplitScreen() {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: Text(
          _customerName != null 
            ? "${t('customer')}: $_customerName" 
            : t('new_order')
        ),
        centerTitle: true,
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        elevation: 0,
        titleTextStyle: const TextStyle(color: Colors.black, fontSize: 24, fontWeight: FontWeight.bold),
      ),
      body: Row(
        children: [
          Expanded(
            flex: 6,
            child: _buildItemList(),
          ),
          Expanded(
            flex: 4,
            child: _mode == 'payment' ? _buildPaymentSidebar() : _buildCartSidebar(),
          ),
        ],
      ),
    );
  }

  // --- WIDGET: ITEM LIST ---
  Widget _buildItemList() {
    return Container(
      margin: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 10)]
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            decoration: BoxDecoration(
              color: Colors.grey.shade100,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
            ),
            child: Row(
              children: [
                Expanded(flex: 4, child: Text(t('header_item'), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 20))),
                Expanded(flex: 1, child: Text(t('header_qty'), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 20))),
                Expanded(flex: 2, child: Text(t('header_price'), textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 20))),
              ],
            ),
          ),
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
              itemCount: _items.length,
              separatorBuilder: (c, i) => const Divider(height: 1),
              itemBuilder: (c, i) {
                final item = _items[i];
                String displayName = item['name']!;
                List<String> tags = [];

                // --- TAG PARSER ---
                final RegExp tagRegex = RegExp(r'\s\(([^)]+)\)$');
                while (true) {
                  final match = tagRegex.firstMatch(displayName);
                  if (match != null) {
                    tags.add(match.group(1)!);
                    displayName = displayName.substring(0, match.start);
                  } else {
                    break;
                  }
                }
                tags = tags.reversed.toList();
                // ------------------

                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16.0),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        flex: 4, 
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              displayName, 
                              maxLines: 2, 
                              overflow: TextOverflow.ellipsis, 
                              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w500)
                            ),
                            if (tags.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 4.0),
                                child: Wrap(
                                  spacing: 8.0,
                                  runSpacing: 4.0,
                                  children: tags.map((tag) {
                                    bool isDiscount = tag.contains('%') || tag.toLowerCase().contains('off');
                                    return Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          isDiscount ? Icons.local_offer_outlined : Icons.sticky_note_2_outlined,
                                          size: 16, 
                                          color: isDiscount ? Colors.redAccent : Colors.blueGrey
                                        ),
                                        const SizedBox(width: 4),
                                        Text(
                                          tag,
                                          style: TextStyle(
                                            fontSize: 16, 
                                            fontStyle: FontStyle.italic, 
                                            color: isDiscount ? Colors.redAccent : Colors.blueGrey,
                                            fontWeight: isDiscount ? FontWeight.bold : FontWeight.normal,
                                          ),
                                        ),
                                      ],
                                    );
                                  }).toList(),
                                ),
                              )
                          ],
                        )
                      ),
                      Expanded(
                        flex: 1, 
                        child: Text(item['qty']!, style: const TextStyle(fontSize: 20))
                      ),
                      Expanded(
                        flex: 2, 
                        child: Text("RM ${item['price']}", textAlign: TextAlign.right, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold))
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  // --- WIDGET: SIDEBAR (Cart Mode) ---
  Widget _buildCartSidebar() {
    return Container(
      margin: const EdgeInsets.fromLTRB(0, 16, 16, 16),
      padding: const EdgeInsets.all(32),
      decoration: BoxDecoration(
        color: const Color(0xFF2C3E50), 
        borderRadius: BorderRadius.circular(16),
        boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 10)]
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(t('total_payable'), style: const TextStyle(color: Colors.white70, fontSize: 28)),
          const SizedBox(height: 16),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              "RM $_total",
              key: ValueKey(_total), 
              style: const TextStyle(color: Colors.white, fontSize: 80, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  // --- WIDGET: SIDEBAR (Payment Mode) - REALTIME SYNCED ---
  Widget _buildPaymentSidebar() {
    
    // 1. Determine "Paid Amount" Display using Scraper Data
    String displayedPaidAmount = "0.00";
    bool isCash = _selectedMethod == PaymentMethodType.cash;

    if (isCash) {
       // "Cash Received" Logic: _cashInput comes directly from Scraper's DOM calculation
       displayedPaidAmount = _hasKeypadInput ? _cashInput.toStringAsFixed(2) : "0.00";
    } else {
       // "Non-Cash": Always show Total Payable (Auto-fill)
       displayedPaidAmount = _total;
    }

    // 2. Determine "Bottom Box" Logic (Change/Remaining/Waiting)
    // Only show "Waiting" if it IS cash AND we haven't typed anything yet
    bool showWaitingText = isCash && !_hasKeypadInput;
    
    // Calculate final Change/Remaining for display locally to be fast
    double totalVal = _parseMoney(_total);
    double paidVal = isCash ? _cashInput : totalVal; 
    
    double changeVal = 0.0;
    double remainingVal = 0.0;
    
    if (paidVal >= totalVal) {
        changeVal = paidVal - totalVal;
    } else {
        remainingVal = totalVal - paidVal;
    }

    bool isFullyPaid = remainingVal <= 0.001;

    return Container(
      margin: const EdgeInsets.fromLTRB(0, 16, 16, 16),
      decoration: BoxDecoration(
        color: const Color(0xFF2C3E50), 
        borderRadius: BorderRadius.circular(16),
        boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 10)]
      ),
      child: Column(
        children: [

          // BOX 1: TOTAL PAYABLE
          Expanded(
            flex: 4,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(24),
              decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: Colors.white24, width: 1)),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    t('total_payable'),
                    style: const TextStyle(color: Colors.white70, fontSize: 24),
                  ),
                  const SizedBox(height: 8),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      "RM $_total",
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 60,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // BOX 2: TOTAL PAID / CASH RECEIVED (ONLY SHOW IF METHOD SELECTED)
          if (_selectedMethod != null)
            Expanded(
              flex: 4,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(24),
                decoration: const BoxDecoration(
                  border: Border(
                    bottom: BorderSide(color: Colors.white24, width: 1)),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Icon(
                          isCash ? Icons.payments_outlined : Icons.credit_card,
                          color: Colors.blueAccent,
                          size: 28,
                        ),
                        const SizedBox(width: 10),
                        Text(
                          isCash ? t('cash_received') : t('payment_amount'),
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 24,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        "RM $displayedPaidAmount",
                        style: const TextStyle(
                          color: Colors.blueAccent,
                          fontSize: 50,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    if (!isCash) ...[
                      const SizedBox(height: 6),
                      const Text(
                        "Auto-filled (Non-cash payment)",
                        style: TextStyle(
                          color: Colors.white38,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),


          // BOX 3: CHANGE / REMAINING / WAITING
          Expanded(
            flex: 3,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  
                  if (showWaitingText) ...[
                      // --- WAITING STATE ---
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          t('waiting_cash'), // "Waiting for cash input"
                          style: const TextStyle(color: Colors.orangeAccent, fontSize: 32, fontStyle: FontStyle.italic),
                        ),
                      ),
                  ] else ...[
                      // --- NORMAL STATE ---
                      Text(
                        isCash
                            ? (isFullyPaid ? t('change') : t('remaining'))
                            : t('payment_status'),
                        style: const TextStyle(color: Colors.white70, fontSize: 24),
                      ),
                      const SizedBox(height: 6),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          isCash
                              ? (isFullyPaid 
                                  ? "RM ${changeVal.toStringAsFixed(2)}" 
                                  : "RM ${remainingVal.toStringAsFixed(2)}")
                              : t('paid'),
                          style: TextStyle(
                            color: isCash
                                ? (isFullyPaid
                                  ? Colors.greenAccent
                                  : Colors.orangeAccent)
                                : Colors.greenAccent,
                            fontSize: 40,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                  ]
                  
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // --- SCREEN 4: RECEIPT ---
  // --- SCREEN 4: RECEIPT ---
  Widget _buildReceiptScreen() {
    bool isCash = _selectedMethod == PaymentMethodType.cash;
    
    // --- FIX: SMART CALCULATION ---
    double totalVal = _parseMoney(_total); 
    double finalPaidVal = 0.0;
    double finalChangeVal = 0.0;

    if (isCash) {
      // Logic: If we have a valid Cash Input from the previous screen that covers the total, USE IT.
      // This ensures "Total Paid" is RM10.00, not RM5.00.
      if (_cashInput >= totalVal) {
        finalPaidVal = _cashInput;
        finalChangeVal = finalPaidVal - totalVal;
      } else {
        // Fallback: If app was refreshed and _cashInput is lost, try to calculate from Change
        double scrapedChange = _parseMoney(_change);
        finalPaidVal = totalVal + scrapedChange;
        finalChangeVal = scrapedChange;
      }
    } else {
      // Non-Cash: Paid always equals Total
      finalPaidVal = totalVal;
      finalChangeVal = 0.0;
    }

    // Convert to strings for display
    String realTimePaidDisplay = finalPaidVal.toStringAsFixed(2);
    String realTimeChangeDisplay = finalChangeVal.toStringAsFixed(2);
    // ----------------------------------------

    return Scaffold(
      backgroundColor: Colors.white,
      body: Row(
        children: [
          // Left: Status & Details
          Expanded(
            child: Container(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.check_circle, size: 100, color: Colors.green),
                  const SizedBox(height: 20),
                  Text(t('payment_success'), style: const TextStyle(fontSize: 36, fontWeight: FontWeight.bold, color: Colors.black87), textAlign: TextAlign.center),
                  const SizedBox(height: 40),
                  
                  // Transaction Details Card
                  Container(
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade50,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Colors.grey.shade200),
                    ),
                    child: Column(
                      children: [
                        if (_customerName != null) ...[
                          _buildSummaryRow(t('customer'), _customerName!, isBold: true),
                          const Divider(height: 30),
                        ],
                        
                        // Always show Total Amount
                        _buildSummaryRow(t('total_amount'), "RM $_total", isBold: true),
                        const SizedBox(height: 10),

                        // CONDITIONAL LOGIC FOR CASH ONLY
                        // Uses the calculated realTime variables
                        if (isCash) ...[
                          _buildSummaryRow(t('total_paid'), "RM $realTimePaidDisplay"), 
                          const SizedBox(height: 10),
                          _buildSummaryRow(t('change'), "RM $realTimeChangeDisplay", color: Colors.green, isBold: true),
                        ] else ...[
                          _buildSummaryRow(t('total_paid'), "RM $realTimePaidDisplay"),
                        ]
                      ],
                    ),
                  ),

                  const Spacer(),
                  if (_cashierName != null && _cashierName!.isNotEmpty)
                      Text("${t('served_by')}: $_cashierName", style: const TextStyle(fontSize: 18, color: Colors.grey)),
                ],
              ),
            ),
          ),
            
          // --- RIGHT SIDE: QR CODE ---
          if (_qrCodeBase64 != null || _qrCodeUrl != null)
            Expanded(
              child: Container(
                color: Colors.grey.shade100,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(t('e_invoice'), style: const TextStyle(fontSize: 30, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 20),
                    Container(
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(20),
                        boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 10)]
                      ),
                      child: _buildQrImage(), 
                    ),
                    const SizedBox(height: 20),
                    Text(t('scan_view'), style: const TextStyle(fontSize: 20, color: Colors.grey)),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildQrImage() {
    if (_qrCodeBase64 != null) {
      try {
        String base64String = _qrCodeBase64!.split(',').last;
        return Image.memory(
          base64Decode(base64String),
          gaplessPlayback: true, 
          height: 300,
          width: 300,
          fit: BoxFit.contain,
          errorBuilder: (context, error, stackTrace) {
             return SizedBox(
               height: 300, width: 300,
               child: Center(child: Text(t('qr_unavailable'))),
             );
          },
        );
      } catch (e) {
        debugPrint("Base64 decode error: $e");
      }
    }
    
    if (_qrCodeUrl != null) {
      return Image.network(
        _qrCodeUrl!, 
        gaplessPlayback: true, 
        height: 300, 
        width: 300,
        fit: BoxFit.contain,
        errorBuilder: (context, error, stackTrace) {
           return SizedBox(
             height: 300, width: 300,
             child: Center(child: Text(t('qr_unavailable'))),
           );
        },
      );
    }

    return const SizedBox(height: 300, width: 300);
  }

  Widget _buildSummaryRow(String label, String value, {Color? color, bool isBold = false}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: TextStyle(fontSize: 22, color: Colors.black54, fontWeight: isBold ? FontWeight.bold : FontWeight.normal)),
        Text(value, style: TextStyle(fontSize: 22, color: color ?? Colors.black87, fontWeight: isBold ? FontWeight.bold : FontWeight.normal)),
      ],
    );
  }
}