import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image_gallery_saver_plus/image_gallery_saver_plus.dart'; // package is correct
import 'package:permission_handler/permission_handler.dart';

class CameraAccessHelper {
  static final ImagePicker _picker = ImagePicker();

  static Future<File?> pickImage(BuildContext context) async {
    // 1. Ask User: Camera or Gallery?
    final ImageSource? source = await showDialog<ImageSource>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Select Image Source"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt, color: Colors.blue),
              title: const Text("Take Photo"),
              subtitle: const Text("Review & Save to Gallery"),
              onTap: () => Navigator.pop(context, ImageSource.camera),
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.photo_library, color: Colors.green),
              title: const Text("Choose from Gallery"),
              onTap: () => Navigator.pop(context, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );

    if (source == null) return null;

    // 2. Handle Permissions
    // We request specific permissions based on the source to be efficient
    PermissionStatus status;
    if (source == ImageSource.camera) {
      status = await Permission.camera.request();
    } else {
      // Android 13+ uses photos, older uses storage
      if (Platform.isAndroid) {
         // Simple check: Request both, the OS handles which one applies
         Map<Permission, PermissionStatus> statuses = await [
           Permission.storage, 
           Permission.photos
         ].request();
         
         // If either is granted, we are good
         if (statuses[Permission.storage]!.isGranted || statuses[Permission.photos]!.isGranted) {
            status = PermissionStatus.granted;
         } else {
            status = PermissionStatus.denied;
         }
      } else {
        // iOS
        status = await Permission.photos.request();
      }
    }

    // SAFETY CHECK: If permission denied, stop here to prevent crash
    if (status.isPermanentlyDenied || status.isDenied) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Permission denied. Please enable in settings.")),
        );
      }
      return null;
    }

    // 3. Launch the Picker
    try {
      final XFile? pickedFile = await _picker.pickImage(
        source: source,
        imageQuality: 85,
      );

      if (pickedFile != null) {
        // 4. If Camera, Save to Gallery
        if (source == ImageSource.camera) {
          await _saveToGallery(pickedFile.path, context);
        }
        return File(pickedFile.path);
      }
    } catch (e) {
      print("Error picking image: $e");
    }

    return null;
  }

  static Future<void> _saveToGallery(String path, BuildContext context) async {
    try {
      // 🛠️ FIX: Class name changed from ImageGallerySaver to ImageGallerySaverPlus
      final result = await ImageGallerySaverPlus.saveFile(path);
      
      print("File saved to gallery: $result");

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("Photo saved to Gallery"),
            duration: Duration(seconds: 1),
          ),
        );
      }
    } catch (e) {
      print("Error saving to gallery: $e");
    }
  }
}