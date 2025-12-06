import 'dart:async';
import 'dart:io';
import 'dart:ui'; 

import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; 
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

  /// Handles the Share functionality
  Future<void> _shareFile(BuildContext buttonContext) async {
    if (_isExporting) return;
    setState(() => _isExporting = true);

    try {
      final file = File(widget.filePath);
      if (!await file.exists()) {
        if (mounted) _showError("File source not found.");
        return;
      }
      final String fileName = widget.filePath.split(Platform.pathSeparator).last;
      
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
    } finally {
      if (mounted) setState(() => _isExporting = false);
    }
  }

  /// THIS triggers the System/Native Printer Dialog
  Future<void> _printFile() async {
    if (_isExporting) return;
    setState(() => _isExporting = true);

    try {
      final file = File(widget.filePath);
      if (await file.exists()) {
        final bytes = await file.readAsBytes();
        final String fileName = widget.filePath.split(Platform.pathSeparator).last;
        
        // This opens the Native Android/iOS print dialog.
        // The format parameter here dictates the system/native print dialog's initial size, 
        // but since we return raw bytes, the printer service takes over the final layout/size.
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
      backgroundColor: Colors.grey[200], 
      appBar: AppBar(
        elevation: 0,
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          fileName,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          Builder(
            builder: (ctx) {
              return IconButton(
                icon: const Icon(Icons.share_rounded),
                tooltip: 'Share',
                onPressed: () => _shareFile(ctx),
              );
            }
          ),
          // --- THE PRINT BUTTON ---
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
            // PDF Viewer
            PDFView(
              filePath: widget.filePath,
              enableSwipe: true,
              swipeHorizontal: false, 
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
              },
              onViewCreated: (PDFViewController pdfViewController) {
                _controller.complete(pdfViewController);
              },
            ),

            if (!_isReady && _errorMessage.isEmpty)
              const Center(child: CircularProgressIndicator(color: Colors.black)),

            if (_errorMessage.isNotEmpty)
               Center(child: Padding(
                 padding: const EdgeInsets.all(20.0),
                 child: Text("Error: $_errorMessage\n\nTry reopening the receipt."),
               )),

            // Loading Overlay
            if (_isExporting)
              Positioned.fill(
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
                  child: Container(
                    color: Colors.black.withOpacity(0.3),
                    child: const Center(
                      child: CircularProgressIndicator(color: Colors.white),
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