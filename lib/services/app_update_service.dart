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
    this.fallbackUrl,
  });

  final String name;
  final Uri downloadUrl;
  final int size;
  final String sha256;
  final Uri? fallbackUrl;
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
  AppUpdateService({
    this.jsonLoader,
    this.versionProvider,
    this.platform,
    this.directoryProvider,
  });

  final Future<Map<String, dynamic>> Function(Uri)? jsonLoader;
  final Future<String> Function()? versionProvider;
  final String? platform;
  final Future<Directory> Function()? directoryProvider;
  static const repository = 'laincarl/file-transport';
  static const _lastAutomaticCheckKey = 'last_automatic_update_check';
  static const _automaticCheckInterval = Duration(hours: 24);

  Future<String> currentVersion() async {
    if (versionProvider != null) return versionProvider!();
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
    var mirrorUpToDate = false;
    try {
      final release = await _readJson(
        Uri.parse('https://gitee.com/api/v5/repos/$repository/releases/latest'),
        current,
      );
      if (release['prerelease'] == true) {
        throw const AppUpdateException('镜像版本尚未发布完成');
      }
      final tag = release['tag_name'] as String;
      final assets = release['assets'] as List;
      final manifest = assets.cast<Map>().firstWhere(
        (asset) => asset['name'] == 'latest.json',
      );
      final url = Uri.parse(manifest['browser_download_url'] as String);
      if (url.scheme != 'https' || url.host != 'gitee.com') {
        throw const AppUpdateException('镜像清单地址不正确');
      }
      final data = await _readJson(url, current);
      if (normalizeVersion(data['version'] as String) !=
          normalizeVersion(tag)) {
        throw const AppUpdateException('镜像版本与清单不一致');
      }
      final update = _parseUpdate(data, current, mirrorTag: tag);
      if (update != null) return update;
      mirrorUpToDate = true;
    } catch (_) {
      // Gitee 网络、限流、清单缺失或同步未完成时回退 GitHub。
    }
    try {
      final data = await _readJson(
        Uri.parse(
          'https://github.com/$repository/releases/latest/download/latest.json',
        ),
        current,
      );
      return _parseUpdate(data, current);
    } on AppUpdateException {
      if (mirrorUpToDate) return null;
      rethrow;
    } catch (_) {
      if (mirrorUpToDate) return null;
      throw const AppUpdateException('无法获取更新信息，Gitee 和 GitHub 均不可用');
    }
  }

  Future<Map<String, dynamic>> _readJson(Uri url, String current) async {
    if (jsonLoader != null) return jsonLoader!(url);
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 12);
    try {
      final request = await client
          .getUrl(url)
          .timeout(const Duration(seconds: 12));
      request.headers
        ..set(HttpHeaders.acceptHeader, 'application/json')
        ..set(HttpHeaders.userAgentHeader, 'LanLink/$current');
      final response = await request.close().timeout(
        const Duration(seconds: 15),
      );
      final body = await utf8.decoder
          .bind(response)
          .join()
          .timeout(const Duration(seconds: 15));
      if (response.statusCode == HttpStatus.notFound) {
        throw const AppUpdateException('暂时没有可用的正式版本');
      }
      if (response.statusCode != HttpStatus.ok) {
        throw AppUpdateException('检查更新失败（${response.statusCode}）');
      }

      return (jsonDecode(body) as Map).cast<String, dynamic>();
    } finally {
      client.close(force: true);
    }
  }

  AppUpdateInfo? _parseUpdate(
    Map<String, dynamic> data,
    String current, {
    String? mirrorTag,
  }) {
    final latest = normalizeVersion(data['version'] as String? ?? '');
    if (!RegExp(r'^\d+\.\d+\.\d+(?:\+\d+)?$').hasMatch(latest)) {
      throw const AppUpdateException('发布版本号格式不正确');
    }
    if (compareVersions(latest, current) <= 0) return null;

    final platformKey =
        platform ??
        (Platform.isAndroid
            ? 'android'
            : Platform.isWindows
            ? 'windows'
            : Platform.isMacOS
            ? 'macos'
            : '');
    final rawAssets = (data['assets'] as Map? ?? const {})
        .cast<String, dynamic>();
    final rawAssetValue = rawAssets[platformKey];
    if (rawAssetValue is! Map) {
      throw const AppUpdateException('最新版本没有适用于当前平台的安装包');
    }
    final rawAsset = rawAssetValue.cast<String, dynamic>();
    final hash = (rawAsset['sha256'] as String? ?? '').toLowerCase();
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(hash)) {
      throw const AppUpdateException('发布文件缺少 SHA256 校验信息');
    }
    final name = rawAsset['name'] as String;
    final url = Uri.parse(rawAsset['url'] as String);
    final size = rawAsset['size'] as int? ?? 0;
    if (name.isEmpty ||
        name != safeAssetName(name) ||
        size <= 0 ||
        url.scheme != 'https' ||
        url.host != (mirrorTag == null ? 'github.com' : 'gitee.com')) {
      throw const AppUpdateException('发布安装包信息不正确');
    }

    return AppUpdateInfo(
      version: latest,
      currentVersion: current,
      notes: (data['notes'] as String? ?? '').trim(),
      releaseUrl: Uri.parse(data['releaseUrl'] as String),
      asset: AppUpdateAsset(
        name: name,
        downloadUrl: url,
        size: size,
        sha256: hash,
        fallbackUrl: mirrorTag == null
            ? null
            : Uri.parse(
                'https://github.com/$repository/releases/download/${Uri.encodeComponent(mirrorTag)}/${Uri.encodeComponent(rawAsset['name'] as String)}',
              ),
      ),
    );
  }

  Future<File> downloadUpdate(
    AppUpdateInfo update, {
    required void Function(int received, int total) onProgress,
  }) async {
    final directory = directoryProvider != null
        ? await directoryProvider!()
        : Directory(
            '${(await getTemporaryDirectory()).path}${Platform.pathSeparator}lanlink-update',
          );
    await directory.create(recursive: true);
    final file = File(
      '${directory.path}${Platform.pathSeparator}${safeAssetName(update.asset.name)}',
    );
    if (await file.exists()) await file.delete();

    for (final url in [
      update.asset.downloadUrl,
      if (update.asset.fallbackUrl != null) update.asset.fallbackUrl!,
    ]) {
      try {
        onProgress(0, update.asset.size);
        return await _downloadFile(update.asset, url, file, onProgress);
      } catch (_) {
        if (await file.exists()) await file.delete();
        if (url == (update.asset.fallbackUrl ?? update.asset.downloadUrl)) {
          rethrow;
        }
      }
    }
    throw const AppUpdateException('下载安装包失败');
  }

  Future<File> _downloadFile(
    AppUpdateAsset asset,
    Uri url,
    File file,
    void Function(int, int) onProgress,
  ) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    IOSink? sink;
    try {
      final request = await client
          .getUrl(url)
          .timeout(const Duration(seconds: 15));
      request.headers.set(HttpHeaders.userAgentHeader, 'LanLink updater');
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      if (response.statusCode != HttpStatus.ok) {
        throw AppUpdateException('下载安装包失败（${response.statusCode}）');
      }
      final total = response.contentLength > 0
          ? response.contentLength
          : asset.size;
      var received = 0;
      sink = file.openWrite();
      await for (final chunk in response.timeout(const Duration(seconds: 30))) {
        sink.add(chunk);
        received += chunk.length;
        onProgress(received, total);
      }
      await sink.close();
      sink = null;

      final actualHash = (await sha256.bind(file.openRead()).first).toString();
      if (received != asset.size ||
          actualHash.toLowerCase() != asset.sha256.toLowerCase()) {
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

  static String safeAssetName(String value) =>
      value.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').replaceAll('..', '_');
}
