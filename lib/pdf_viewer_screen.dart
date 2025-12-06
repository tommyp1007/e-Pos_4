import 'dart:async';
import 'dart:io';
import 'dart:ui'; // Required for ImageFilter

import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // For Haptics
import 'package:flutter_pdfview/flutter_pdfview.dart';
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';

class PdfViewerScreen extends StatefulWidget {
  final String filePath;
  const PdfViewerScreen({super.key, required this.filePath});

  @override
  State<PdfViewerScreen> createState() => _PdfViewerScreenState();
}

class _PdfViewerScreenState extends State<PdfViewerScreen> {
  final Completer<PDFViewController> _controller = Completer<PDFViewController>();
  
  // State variables
  int _totalPages = 0;
  int _currentPage = 0;
  bool _isReady = false;
  bool _isExporting = false;
  String _errorMessage = '';

  /// Handles the Share functionality securely
  /// Works on Android, iOS, and Tablets (iPad requires origin rect)
  Future<void> _shareFile(BuildContext buttonContext) async {
    if (_isExporting) return;
    setState(() => _isExporting = true);

    try {
      final file = File(widget.filePath);
      
      // Safety Check: Ensure the external file is readable
      if (!await file.exists()) {
        if (mounted) _showError("File source not found.");
        return;
      }

      final String fileName = widget.filePath.split(Platform.pathSeparator).last;
      
      // iPad Fix: Calculate anchor position for the share popover
      final box = buttonContext.findRenderObject() as RenderBox?;
      
      await Share.shareXFiles(
        [XFile(widget.filePath)],
        text: "Sharing document: $fileName",
        subject: fileName,
        sharePositionOrigin: box != null 
            ? box.localToGlobal(Offset.zero) & box.size 
            : null,
      );
    } catch (e) {
      debugPrint("Error sharing: $e");
      // Fallback to Printing package share if SharePlus fails
      try {
        final bytes = await File(widget.filePath).readAsBytes();
        final String name = widget.filePath.split(Platform.pathSeparator).last;
        await Printing.sharePdf(bytes: bytes, filename: name);
      } catch (e2) {
        if (mounted) _showError("Could not share file.");
      }
    } finally {
      if (mounted) setState(() => _isExporting = false);
    }
  }

  /// Handles the Print functionality (System Printer / Thermal Printer)
  Future<void> _printFile() async {
    if (_isExporting) return;
    setState(() => _isExporting = true);

    try {
      final file = File(widget.filePath);
      if (await file.exists()) {
        final bytes = await file.readAsBytes();
        final String fileName = widget.filePath.split(Platform.pathSeparator).last;
        
        await Printing.layoutPdf(
          onLayout: (format) async => bytes,
          name: fileName,
        );
      } else {
        if (mounted) _showError("File source missing.");
      }
    } catch (e) {
      debugPrint('Error printing: $e');
      if (mounted) _showError("Printing failed.");
    } finally {
      if (mounted) setState(() => _isExporting = false);
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, style: const TextStyle(color: Colors.white)),
        backgroundColor: Colors.redAccent,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final String fileName = widget.filePath.split(Platform.pathSeparator).last;

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        elevation: 0,
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              fileName,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.black87),
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
            ),
             if (_totalPages > 0)
              Text(
                "Page ${_currentPage + 1} of $_totalPages",
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
          ],
        ),
        actions: [
          // Save / Share Button (With Builder for iPad context)
          Builder(
            builder: (ctx) {
              return IconButton(
                icon: const Icon(Icons.share_rounded),
                tooltip: 'Share / Save PDF',
                onPressed: () => _shareFile(ctx),
              );
            }
          ),
          // Print Button
          IconButton(
            icon: const Icon(Icons.print_rounded),
            tooltip: 'Print Receipt',
            onPressed: _printFile,
          ),
        ],
      ),
      body: SafeArea(
        child: Stack(
          children: [
            // 1. PDF Viewer
            PDFView(
              filePath: widget.filePath,
              enableSwipe: true,
              swipeHorizontal: false, // Vertical scrolling is better for receipts
              autoSpacing: false,
              pageFling: false,
              pageSnap: false,
              fitPolicy: FitPolicy.WIDTH,
              onRender: (pages) {
                setState(() {
                  _totalPages = pages ?? 0;
                  _isReady = true;
                });
              },
              onError: (error) {
                setState(() {
                  _errorMessage = error.toString();
                });
                debugPrint(error.toString());
              },
              onPageError: (page, error) {
                debugPrint('$page: ${error.toString()}');
              },
              onViewCreated: (PDFViewController pdfViewController) {
                _controller.complete(pdfViewController);
              },
              onPageChanged: (int? page, int? total) {
                if (page != null) {
                   setState(() => _currentPage = page);
                }
              },
            ),

            // 2. Loading State (Initial)
            if (!_isReady && _errorMessage.isEmpty)
              const Center(child: CircularProgressIndicator(color: Colors.black)),

            // 3. Error State
            if (_errorMessage.isNotEmpty)
               Center(child: Text("Error: $_errorMessage")),

            // 4. Bottom Navigation Control (Glassmorphism)
            if (_isReady && _totalPages > 1)
              Positioned(
                bottom: 20,
                left: 20,
                right: 20,
                child: Center(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(30),
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                      child: Container(
                        height: 60,
                        constraints: const BoxConstraints(maxWidth: 500),
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.8),
                          borderRadius: BorderRadius.circular(30),
                          boxShadow: [
                            BoxShadow(color: Colors.black.withOpacity(0.2), blurRadius: 10, offset: const Offset(0, 5))
                          ]
                        ),
                        child: Row(
                          children: [
                            // Page Counter
                            Text(
                              "${_currentPage + 1}",
                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(width: 10),
                            
                            // Slider
                            Expanded(
                              child: SliderTheme(
                                data: SliderTheme.of(context).copyWith(
                                  trackHeight: 2,
                                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                                  overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                                  activeTrackColor: Colors.white,
                                  inactiveTrackColor: Colors.white24,
                                  thumbColor: Colors.white,
                                ),
                                child: Slider(
                                  value: _currentPage.toDouble(),
                                  min: 0,
                                  max: (_totalPages - 1).toDouble(),
                                  divisions: _totalPages > 1 ? _totalPages - 1 : 1,
                                  onChanged: (double value) {
                                    setState(() {
                                      _currentPage = value.toInt();
                                    });
                                  },
                                  onChangeEnd: (double value) async {
                                    final controller = await _controller.future;
                                    await controller.setPage(value.toInt());
                                    HapticFeedback.selectionClick();
                                  },
                                ),
                              ),
                            ),
                            
                            const SizedBox(width: 10),
                            Text(
                              "$_totalPages",
                              style: const TextStyle(color: Colors.white70),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),

            // 5. Exporting Loading Overlay (Blur)
            if (_isExporting)
              Positioned.fill(
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
                  child: Container(
                    color: Colors.black.withOpacity(0.3),
                    child: const Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircularProgressIndicator(color: Colors.white),
                          SizedBox(height: 20),
                          Text(
                            "Processing...",
                            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
                          )
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}