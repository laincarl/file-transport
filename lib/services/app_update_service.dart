import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'android_platform_service.dart';

class AppUpdateAsset {
  const AppUpdateAsset({
    required this.name,
    required this.downloadUrl,
    required this.size,
    required this.sha256,
  });

  final String name;
  final Uri downloadUrl;
  final int size;
  final String sha256;
}

class AppUpdateInfo {
  const AppUpdateInfo({
    required this.version,
    required this.currentVersion,
    required this.notes,
    required this.releaseUrl,
    required this.asset,
  });

  final String version;
  final String currentVersion;
  final String notes;
  final Uri releaseUrl;
  final AppUpdateAsset asset;
}

enum UpdateLaunchResult { started, installPermissionRequested }

class AppUpdateException implements Exception {
  const AppUpdateException(this.message);

  final String message;

  @override
  String toString() => message;
}

class AppUpdateService {
  static const repository = 'laincarl/file-transport';
  static const _lastAutomaticCheckKey = 'last_automatic_update_check';
  static const _automaticCheckInterval = Duration(hours: 24);

  Future<String> currentVersion() async {
    final packageInfo = await PackageInfo.fromPlatform();
    return packageInfo.version;
  }

  Future<bool> shouldCheckAutomatically() async {
    final preferences = await SharedPreferences.getInstance();
    final timestamp = preferences.getInt(_lastAutomaticCheckKey);
    if (timestamp == null) return true;
    final lastCheck = DateTime.fromMillisecondsSinceEpoch(timestamp);
    return DateTime.now().difference(lastCheck) >= _automaticCheckInterval;
  }

  Future<void> markAutomaticCheckCompleted() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setInt(
      _lastAutomaticCheckKey,
      DateTime.now().millisecondsSinceEpoch,
    );
  }

  Future<AppUpdateInfo?> checkForUpdate() async {
    final current = await currentVersion();
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 12);
    try {
      final request = await client.getUrl(
        Uri.parse('https://api.github.com/repos/$repository/releases/latest'),
      );
      request.headers
        ..set(HttpHeaders.acceptHeader, 'application/vnd.github+json')
        ..set(HttpHeaders.userAgentHeader, 'LanLink/$current')
        ..set('X-GitHub-Api-Version', '2026-03-10');
      final response = await request.close().timeout(
        const Duration(seconds: 15),
      );
      final body = await utf8.decoder.bind(response).join();
      if (response.statusCode == HttpStatus.notFound) {
        throw const AppUpdateException('暂时没有可用的正式版本');
      }
      if (response.statusCode != HttpStatus.ok) {
        throw AppUpdateException('检查更新失败（${response.statusCode}）');
      }

      final data = (jsonDecode(body) as Map).cast<String, dynamic>();
      final latest = normalizeVersion(data['tag_name'] as String? ?? '');
      if (latest.isEmpty) {
        throw const AppUpdateException('发布版本号格式不正确');
      }
      if (compareVersions(latest, current) <= 0) return null;

      final rawAssets = (data['assets'] as List? ?? const [])
          .whereType<Map>()
          .map((asset) => asset.cast<String, dynamic>())
          .toList();
      final rawAsset = selectAsset(rawAssets);
      if (rawAsset == null) {
        throw const AppUpdateException('最新版本没有适用于当前平台的安装包');
      }
      final digest = rawAsset['digest'] as String? ?? '';
      final hash = digest.startsWith('sha256:')
          ? digest.substring('sha256:'.length).toLowerCase()
          : '';
      if (hash.length != 64) {
        throw const AppUpdateException('发布文件缺少 SHA256 校验信息');
      }

      return AppUpdateInfo(
        version: latest,
        currentVersion: current,
        notes: (data['body'] as String? ?? '').trim(),
        releaseUrl: Uri.parse(data['html_url'] as String),
        asset: AppUpdateAsset(
          name: rawAsset['name'] as String,
          downloadUrl: Uri.parse(rawAsset['browser_download_url'] as String),
          size: rawAsset['size'] as int? ?? 0,
          sha256: hash,
        ),
      );
    } on AppUpdateException {
      rethrow;
    } on SocketException {
      throw const AppUpdateException('无法连接更新服务器，请检查网络');
    } on FormatException {
      throw const AppUpdateException('更新信息格式不正确');
    } catch (_) {
      throw const AppUpdateException('检查更新失败，请稍后重试');
    } finally {
      client.close(force: true);
    }
  }

  Future<File> downloadUpdate(
    AppUpdateInfo update, {
    required void Function(int received, int total) onProgress,
  }) async {
    final directory = Directory(
      '${(await getTemporaryDirectory()).path}${Platform.pathSeparator}lanlink-update',
    );
    await directory.create(recursive: true);
    final file = File(
      '${directory.path}${Platform.pathSeparator}${safeAssetName(update.asset.name)}',
    );
    if (await file.exists()) await file.delete();

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    IOSink? sink;
    try {
      final request = await client.getUrl(update.asset.downloadUrl);
      request.headers.set(HttpHeaders.userAgentHeader, 'LanLink updater');
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      if (response.statusCode != HttpStatus.ok) {
        throw AppUpdateException('下载安装包失败（${response.statusCode}）');
      }
      final total = response.contentLength > 0
          ? response.contentLength
          : update.asset.size;
      var received = 0;
      sink = file.openWrite();
      await for (final chunk in response) {
        sink.add(chunk);
        received += chunk.length;
        onProgress(received, total);
      }
      await sink.close();
      sink = null;

      final actualHash = (await sha256.bind(file.openRead()).first).toString();
      if (actualHash.toLowerCase() != update.asset.sha256.toLowerCase()) {
        await file.delete();
        throw const AppUpdateException('安装包校验失败，文件可能不完整');
      }
      return file;
    } on AppUpdateException {
      rethrow;
    } on SocketException {
      throw const AppUpdateException('下载中断，请检查网络后重试');
    } catch (_) {
      throw const AppUpdateException('下载安装包失败，请稍后重试');
    } finally {
      await sink?.close();
      client.close(force: true);
    }
  }

  Future<UpdateLaunchResult> launchInstaller(File installer) async {
    if (Platform.isAndroid) {
      final result = await AndroidPlatformService.openFile(installer.path);
      if (result == 'install_permission_requested') {
        return UpdateLaunchResult.installPermissionRequested;
      }
      if (result != 'done') {
        throw const AppUpdateException('无法打开 Android 系统安装器');
      }
      return UpdateLaunchResult.started;
    }
    if (Platform.isWindows) {
      await Process.start(
        installer.path,
        const [],
        mode: ProcessStartMode.detached,
      );
      return UpdateLaunchResult.started;
    }
    if (Platform.isMacOS) {
      await Process.start('open', [
        installer.path,
      ], mode: ProcessStartMode.detached);
      return UpdateLaunchResult.started;
    }
    throw const AppUpdateException('当前平台暂不支持应用内更新');
  }

  static String normalizeVersion(String value) {
    final trimmed = value.trim();
    if (trimmed.startsWith('v') || trimmed.startsWith('V')) {
      return trimmed.substring(1);
    }
    return trimmed;
  }

  static int compareVersions(String left, String right) {
    final leftParts = _versionParts(left);
    final rightParts = _versionParts(right);
    final length = leftParts.length > rightParts.length
        ? leftParts.length
        : rightParts.length;
    for (var index = 0; index < length; index++) {
      final leftPart = index < leftParts.length ? leftParts[index] : 0;
      final rightPart = index < rightParts.length ? rightParts[index] : 0;
      if (leftPart != rightPart) return leftPart.compareTo(rightPart);
    }
    return 0;
  }

  static List<int> _versionParts(String value) {
    final normalized = normalizeVersion(
      value,
    ).split('+').first.split('-').first;
    return normalized
        .split('.')
        .map((part) => int.tryParse(part) ?? 0)
        .toList();
  }

  static Map<String, dynamic>? selectAsset(List<Map<String, dynamic>> assets) {
    final expectedName = Platform.isAndroid
        ? '局域快传-android.apk'
        : Platform.isWindows
        ? '局域快传-windows-x64-setup.exe'
        : Platform.isMacOS
        ? '局域快传-macos.dmg'
        : '';
    if (expectedName.isEmpty) return null;
    for (final asset in assets) {
      if (asset['name'] == expectedName) return asset;
    }
    return null;
  }

  static String safeAssetName(String value) =>
      value.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').replaceAll('..', '_');
}
