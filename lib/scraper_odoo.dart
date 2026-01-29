// scraper_odoo.dart

class OdooScraper {
  // New Blob Fetcher Script
  static const String blobFetcherScript = r"""
    console.log("External View: Ready for downloads.");
  """;

  // Main Odoo Script
  static const String script = r"""
    (function() {
      console.log("Injecting Odoo Mobile Hooks (Updated)...");

      // ============================================================
      // 1. BARCODE INPUT HANDLER
      // ============================================================
      window.onFlutterBarcodeScanned = function(code) {
          console.log("Received barcode: " + code);
          
          // --- LOGIC: Product Search (POS) ---
          // Updated to cover both English and Malay placeholders
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

          // --- LOGIC: Fallback (Generic Input) ---
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
            // Raw Keypress simulation
            for (var i = 0; i < code.length; i++) {
                document.body.dispatchEvent(new KeyboardEvent('keypress', { key: code[i], char: code[i], bubbles: true }));
            }
            document.body.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', keyCode: 13, bubbles: true }));
          }
      };

      // ============================================================
      // 2. CAMERA HIJACKER (ONLY FOR PRODUCT SCANNING)
      // ============================================================
      function hijackButtons() {
          // Selectors for buttons that usually trigger a scanner
          var selectors = ['.o_mobile_barcode_button', '.o_stock_barcode_main_button', '.fa-qrcode', '.fa-barcode'];

          selectors.forEach(function(sel) {
              var elements = document.querySelectorAll(sel);
              elements.forEach(function(el) {
                  // Find the actual button container
                  var btn = el.closest('button') || el.closest('.btn') || el;
                  
                  // Handle icons usually nested in divs
                  if(el.classList.contains('fa-barcode') || el.classList.contains('fa-qrcode')) {
                      var possibleParent = el.parentElement;
                      if(possibleParent) {
                        btn = possibleParent;
                      }
                  }

                  // --- CRITICAL CHECK: IGNORE CUSTOMER QR BUTTONS ---
                  // If this button has the fa-qrcode class (or contains it), we assume it's the Customer Scanner.
                  // We do NOT hijack it, so Odoo's native JS will run instead.
                  var isCustomerBtn = el.classList.contains('fa-qrcode') || el.querySelector('.fa-qrcode');
                  if (isCustomerBtn) return;

                  // --- HIJACK PRODUCT/BARCODE BUTTONS ---
                  if (btn && !btn.getAttribute('data-flutter-hijacked')) {
                      btn.setAttribute('data-flutter-hijacked', 'true');

                      // Add Capture Phase Listener (Trigger Native Scanner)
                      btn.addEventListener('click', function(e) {
                          e.preventDefault();
                          e.stopPropagation();
                          e.stopImmediatePropagation();
                          
                          // --- DETERMINE LANGUAGE ---
                          var currentLang = 'en_US'; 
                          if (document.querySelector('input[placeholder="Carian produk..."]')) {
                              currentLang = 'ms_MY';
                          } else if (window.location.href.indexOf('lang=ms_MY') > -1) {
                              currentLang = 'ms_MY';
                          } else if (document.documentElement.lang.includes('ms')) {
                              currentLang = 'ms_MY';
                          }
                          
                          // Call Flutter for Product Scanning (Default 'product')
                          window.flutter_inappwebview.callHandler('NativeQRScanner', currentLang, 'product');
                          
                      }, true); 
                  }
              });
          });
      }

      // ============================================================
      // 3. UI SCRAPER (Sends data to Customer Display)
      // ============================================================
      function getText(el) { return el ? el.innerText.trim() : ""; }
      function isVisible(el) { return el && (el.offsetParent !== null || window.getComputedStyle(el).display !== 'none'); }

      function scrapeAndSend() {
          // AUTO-RESET: If not in POS UI, tell Flutter to reset display
          if (window.location.href.indexOf('/pos/ui') === -1) {
             window.flutter_inappwebview.callHandler('UpdateCustomerDisplay', JSON.stringify({ "type": "reset" }));
             return;
          }

          try {
              var payload = { "mode": "welcome" };
              
              var receiptScreen = document.querySelector('.receipt-screen');
              var paymentScreen = document.querySelector('.payment-screen');
              var productScreen = document.querySelector('.product-screen');
              var ticketScreen = document.querySelector('.ticket-screen'); 
              
              var isReceiptActive = isVisible(receiptScreen);
              var isPaymentActive = isVisible(paymentScreen);
              var numpad = document.querySelector('.numpad');
              var orderWidget = document.querySelector('.order-widget') || document.querySelector('.orderline');
              
              var isCartActive = isVisible(productScreen) || isVisible(ticketScreen) || 
                                 (!isReceiptActive && !isPaymentActive && (isVisible(numpad) || isVisible(orderWidget)));

              // --- A. RECEIPT SCREEN ---
              if (isReceiptActive) {
                  payload.mode = "receipt";
                  var totalEl = receiptScreen.querySelector('.top-content-center h1') || 
                                receiptScreen.querySelector('.pos-receipt-amount');
                  payload.total = getText(totalEl).replace(/[^0-9.-]+/g,""); 

                  // --- IMPROVED CHANGE SCRAPING ---
                  var changeVal = "0.00";
                  var possibleChangeRows = document.querySelectorAll('.receipt-line, .pos-receipt-right-align, .pos-receipt-amount');
                  
                  possibleChangeRows.forEach(function(el) {
                      var text = el.innerText.toLowerCase();
                      if (text.includes('change') || text.includes('baki')) {
                          var numbers = el.innerText.match(/[0-9]+(\.[0-9]+)?/);
                          if(numbers) changeVal = numbers[0];
                      }
                  });
                  payload.change = changeVal;

                  // QR Code Handling (Canvas to Base64)
                  var receiptContainer = receiptScreen.querySelector('.pos-receipt');
                  if (receiptContainer) {
                      var qrImg = receiptContainer.querySelector('img[src*="/report/barcode/QR/"]');
                      if (qrImg) {
                          try {
                              var canvas = document.createElement('canvas');
                              canvas.width = qrImg.naturalWidth || 150;
                              canvas.height = qrImg.naturalHeight || 150;
                              var ctx = canvas.getContext('2d');
                              ctx.drawImage(qrImg, 0, 0);
                              var dataURL = canvas.toDataURL("image/png");
                              if(dataURL.length > 100) payload.qrCodeBase64 = dataURL;
                              else payload.qrCodeUrl = qrImg.src; 
                          } catch(e) {
                              payload.qrCodeUrl = qrImg.src; 
                          }
                      }
                  }

                  // Extract Payment Method
                  var paymentLines = document.querySelectorAll('.pos-receipt table tr');
                  paymentLines.forEach(function(tr) {
                      var tds = tr.querySelectorAll('td');
                      if(tds.length >= 2) {
                          var text = tds[0].innerText.toLowerCase();
                          if(!text.includes('total') && !text.includes('change') && !text.includes('tax') && !text.includes('subtotal')) {
                              payload.paymentMethod = tds[0].innerText;
                          }
                      }
                  });

                  window.flutter_inappwebview.callHandler('UpdateCustomerDisplay', JSON.stringify(payload));
                  return;
              }

              // --- B. PAYMENT SCREEN ---
              if (isPaymentActive) {
                  payload.mode = "payment";
                  var totalDue = document.querySelector('.payment-status-total-due .amount') || 
                                 document.querySelector('.payment-status-total-due span:last-child');
                  payload.total = getText(totalDue);
                  var remaining = document.querySelector('.payment-status-remaining .amount');
                  payload.remaining = getText(remaining);
                  var change = document.querySelector('.payment-status-change .amount');
                  payload.change = getText(change);
                  var partnerBtn = document.querySelector('.partner-button .partner-name');
                  var customerName = getText(partnerBtn);
                  if (customerName && customerName !== "Customer" && customerName !== "Pelanggan") {
                      payload.customer = customerName;
                  }

                  // Detect Selected Payment Method
                  var selectedMethodEl = document.querySelector('.paymentmethods .paymentmethod.selected .payment-name');
                  if (!selectedMethodEl) {
                      selectedMethodEl = document.querySelector('.paymentlines .paymentline.selected .payment-name');
                  }
                  if (selectedMethodEl) {
                      payload.payment_method = getText(selectedMethodEl);
                  }

                  // --- DETECT CASH KEYPAD INPUT ---
                  var totalDueEl = document.querySelector('.payment-status-total-due .amount') ||
                                   document.querySelector('.payment-status-total-due span:last-child');
                  var remainingEl = document.querySelector('.payment-status-remaining .amount');
                  var changeEl = document.querySelector('.payment-status-change .amount');
                  
                  var valTotalDue = parseFloat((totalDueEl ? totalDueEl.innerText.replace(/[^0-9.-]+/g,"") : "0"));
                  var valRemaining = parseFloat((remainingEl ? remainingEl.innerText.replace(/[^0-9.-]+/g,"") : "0"));
                  var valChange = parseFloat((changeEl ? changeEl.innerText.replace(/[^0-9.-]+/g,"") : "0"));
                  
                  var paidAmount = valTotalDue - valRemaining + valChange;
                  
                  if (paidAmount > 0) {
                      payload.cashKeypadInput = paidAmount;
                      payload.methodChosen = true;
                  } else {
                      payload.cashKeypadInput = 0;
                      payload.methodChosen = false;
                  }

                  // --- FIX: SCRAPE ITEMS DURING PAYMENT ---
                  var items = [];
                  var lines = document.querySelectorAll('.orderline');
                  lines.forEach(function(line) {
                      var name = getText(line.querySelector('.product-name'));
                      var price = getText(line.querySelector('.price'));
                      var qty = "1";
                      var infoList = line.querySelector('.info-list');
                      if (infoList) {
                          var qtyEl = infoList.querySelector('.qty');
                          if (qtyEl) qty = getText(qtyEl);
                          var discountItems = infoList.querySelectorAll('li');
                          discountItems.forEach(function(li) {
                              var text = li.innerText.toLowerCase();
                              if (text.includes('discount') || text.includes('diskaun')) {
                                  var em = li.querySelector('em');
                                  if (em) {
                                      name = name + " (" + getText(em) + " Off)"; 
                                  }
                              }
                          });
                      }
                      var note = getText(line.querySelector('.customer-note'));
                      if(note) name = name + " (" + note + ")";
                      if(name) items.push({ "name": name, "qty": qty, "price": price });
                  });
                  payload.items = items;

                  window.flutter_inappwebview.callHandler('UpdateCustomerDisplay', JSON.stringify(payload));
                  return;
              }

              // --- C. CART SCREEN ---
              if (isCartActive) {
                  payload.mode = "cart";
                  var items = [];
                  var partnerBtn = document.querySelector('.partner-button .partner-name') || 
                                   document.querySelector('.set-partner');
                  var customerName = getText(partnerBtn).split('\n')[0];
                  if (customerName && customerName !== "Customer" && customerName !== "Pelanggan") {
                      payload.customer = customerName;
                  }
                  var lines = document.querySelectorAll('.orderline');
                  lines.forEach(function(line) {
                      var name = getText(line.querySelector('.product-name'));
                      var price = getText(line.querySelector('.price'));
                      var qty = "1";
                      var infoList = line.querySelector('.info-list');
                      if (infoList) {
                          var qtyEl = infoList.querySelector('.qty');
                          if (qtyEl) qty = getText(qtyEl);
                          var discountItems = infoList.querySelectorAll('li');
                          discountItems.forEach(function(li) {
                              var text = li.innerText.toLowerCase();
                              if (text.includes('discount') || text.includes('diskaun')) {
                                  var em = li.querySelector('em');
                                  if (em) {
                                      name = name + " (" + getText(em) + " Off)"; 
                                  }
                              }
                          });
                      }
                      var note = getText(line.querySelector('.customer-note'));
                      if(note) name = name + " (" + note + ")";
                      if(name) items.push({ "name": name, "qty": qty, "price": price });
                  });
                  payload.items = items;
                  var totalEl = document.querySelector('.order-summary .total') || 
                                document.querySelector('.check-control-button .amount');
                  payload.total = getText(totalEl);
                  window.flutter_inappwebview.callHandler('UpdateCustomerDisplay', JSON.stringify(payload));
                  return;
              }
              
              if (document.querySelector('.pos-content')) {
                 window.flutter_inappwebview.callHandler('UpdateCustomerDisplay', JSON.stringify(payload));
              }

          } catch(e) {
             console.error("Flutter Scraper Error: " + e);
          }
      }

      // ============================================================
      // 4. INSTANT UPDATE HIJACKERS (Speed up UI response)
      // ============================================================
      function hijackNumpad() {
          var pads = document.querySelectorAll('.numpad .input-button, .numpad .mode-button');
          pads.forEach(btn => {
              if(!btn.getAttribute('data-flutter-numpad')) {
                  btn.setAttribute('data-flutter-numpad', 'true');
                  btn.addEventListener('click', function() {
                      setTimeout(scrapeAndSend, 50);
                  });
              }
          });
      }

      function hijackPaymentMethods() {
          var methods = document.querySelectorAll('.paymentmethod');
          methods.forEach(btn => {
               if(!btn.getAttribute('data-flutter-pm')) {
                  btn.setAttribute('data-flutter-pm', 'true');
                  btn.addEventListener('click', function() {
                      setTimeout(scrapeAndSend, 50);
                  });
              }
          });
      }

      function hijackPayButton() {
          var payBtns = document.querySelectorAll('.pay-order-button');
          payBtns.forEach(btn => {
               if(!btn.getAttribute('data-flutter-pay')) {
                  btn.setAttribute('data-flutter-pay', 'true');
                  btn.addEventListener('click', function() {
                      setTimeout(scrapeAndSend, 50);
                      setTimeout(scrapeAndSend, 200); 
                  });
              }
          });
      }

      function sendWelcomeOnStart() {
          if (window.location.href.indexOf('/pos/ui') !== -1) {
              console.log("POS session detected — sending welcome screen to Flutter");

              window.flutter_inappwebview.callHandler('UpdateCustomerDisplay', JSON.stringify({
                  type: 'display_update',
                  payload: {
                      mode: 'welcome',
                      items: [],
                      total: "0.00",
                      remaining: "0.00",
                      change: "0.00",
                      customer: null,
                      qrCodeBase64: null,
                      qrCodeUrl: null,
                      methodChosen: false,
                      cashKeypadInput: 0
                  }
              }));
          }
      }

      // --- INITIALIZATION ---
      // Use Observer to detect DOM changes (Navigation/Modal changes)
      var observer = new MutationObserver(function(mutations) { 
          scrapeAndSend(); 
      });
      var targetNode = document.body;
      observer.observe(targetNode, { childList: true, subtree: true, attributes: true });
      
      // Periodic Scrapers & Hijackers (To catch re-renders)
      setInterval(scrapeAndSend, 1000); 
      
      hijackButtons();
      setInterval(hijackButtons, 1000);
      
      setInterval(hijackNumpad, 1000);
      setInterval(hijackPaymentMethods, 1000);
      setInterval(hijackPayButton, 1000); 
      
      // Run once after page load
      setTimeout(sendWelcomeOnStart, 500);

    })();
  """;
}