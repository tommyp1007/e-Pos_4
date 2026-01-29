import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image_gallery_saver_plus/image_gallery_saver_plus.dart'; 
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
    PermissionStatus status;
    if (source == ImageSource.camera) {
      // Camera always needs permission
      status = await Permission.camera.request();
    } else {
      // GALLERY LOGIC
      if (Platform.isAndroid) {
        // [FIX FOR GOOGLE PLAY]
        // On Android 13+, image_picker uses the "Photo Picker" which requires NO permissions.
        // On older Android, image_picker handles the intent gracefully.
        // We MUST NOT request Permission.photos (READ_MEDIA_IMAGES) here, or Google will reject the app.
        status = PermissionStatus.granted; 
      } else {
        // iOS still requires explicit permission for the gallery
        status = await Permission.photos.request();
      }
    }

    // SAFETY CHECK: If permission denied (mainly for Camera or iOS), stop here.
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
      // Note: On Android 10+ (Scoped Storage), saving to the gallery usually 
      // does not require WRITE_EXTERNAL_STORAGE if using standard MediaStore APIs.
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