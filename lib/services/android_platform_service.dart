import 'dart:io';

import 'package:flutter/services.dart';

class AndroidPlatformService {
  static const _channel = MethodChannel('lanlink/android');

  static Future<String?> getPublicDownloadsPath() async {
    if (!Platform.isAndroid) return null;
    return _channel.invokeMethod<String>('getPublicDownloadsPath');
  }

  static Future<String?> getDeviceName() async {
    if (!Platform.isAndroid) return null;
    return _channel.invokeMethod<String>('getDeviceName');
  }

  static Future<bool> hasStorageAccess() async {
    if (!Platform.isAndroid) return true;
    return await _channel.invokeMethod<bool>('hasStorageAccess') ?? false;
  }

  static Future<void> requestStorageAccess() async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod<void>('requestStorageAccess');
  }

  static Future<void> acquireMulticastLock() async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod<void>('acquireMulticastLock');
  }

  static Future<String> openFile(String path) async {
    if (!Platform.isAndroid) return 'unsupported';
    return await _channel.invokeMethod<String>('openFile', {'path': path}) ??
        'failed';
  }

  static Future<bool> openFolder(String path) async {
    if (!Platform.isAndroid) return false;
    return await _channel.invokeMethod<bool>('openFolder', {'path': path}) ??
        false;
  }
}
