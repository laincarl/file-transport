import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanlink/services/app_update_service.dart';

Map<String, dynamic> manifest(String host, {String version = '2.0.0'}) => {
  'version': version,
  'releaseUrl': 'https://$host/laincarl/file-transport/releases/tag/v$version',
  'assets': {
    'windows': {
      'name': 'lanlink-windows-x64-setup.exe',
      'url':
          'https://$host/laincarl/file-transport/releases/download/v$version/lanlink-windows-x64-setup.exe',
      'size': 3,
      'sha256': sha256.convert(utf8.encode('apk')).toString(),
    },
  },
};

Map<String, dynamic> release({bool complete = true, String tag = 'v2.0.0'}) => {
  'tag_name': tag,
  'prerelease': !complete,
  'assets': [
    {
      'name': 'latest.json',
      'browser_download_url': 'https://gitee.com/manifest',
    },
  ],
};

void main() {
  test('Gitee 优先并为同版本安装包保留 GitHub 备选', () async {
    final calls = <Uri>[];
    final service = AppUpdateService(
      versionProvider: () async => '1.0.0',
      platform: 'windows',
      jsonLoader: (url) async {
        calls.add(url);
        return url.path.contains('/api/') ? release() : manifest('gitee.com');
      },
    );
    final update = (await service.checkForUpdate())!;
    expect(calls.length, 2);
    expect(update.asset.downloadUrl.host, 'gitee.com');
    expect(update.asset.fallbackUrl!.host, 'github.com');
    expect(update.asset.fallbackUrl!.path, contains('/v2.0.0/'));
  });

  for (final scenario in ['offline', 'incomplete', 'mismatch', 'bad-hash']) {
    test('Gitee $scenario 时回退 GitHub', () async {
      final service = AppUpdateService(
        versionProvider: () async => '1.0.0',
        platform: 'windows',
        jsonLoader: (url) async {
          if (url.host == 'github.com') return manifest('github.com');
          if (scenario == 'offline') throw const SocketException('offline');
          if (url.path.contains('/api/')) {
            return release(
              complete: scenario != 'incomplete',
              tag: scenario == 'mismatch' ? 'v3.0.0' : 'v2.0.0',
            );
          }
          final data = manifest('gitee.com');
          if (scenario == 'bad-hash') {
            (data['assets']['windows'] as Map)['sha256'] = 'invalid';
          }
          return data;
        },
      );
      expect(
        (await service.checkForUpdate())!.asset.downloadUrl.host,
        'github.com',
      );
    });
  }

  test('Gitee 尚未同步新版本时仍能发现 GitHub 新版本', () async {
    final service = AppUpdateService(
      versionProvider: () async => '1.0.0',
      platform: 'windows',
      jsonLoader: (url) async {
        if (url.host == 'github.com') return manifest('github.com');
        return url.path.contains('/api/')
            ? release(tag: 'v1.0.0')
            : manifest('gitee.com', version: '1.0.0');
      },
    );
    expect((await service.checkForUpdate())!.version, '2.0.0');
  });

  test('两源均不可用时明确报错', () async {
    final service = AppUpdateService(
      versionProvider: () async => '1.0.0',
      platform: 'windows',
      jsonLoader: (_) async => throw const SocketException('offline'),
    );
    await expectLater(
      service.checkForUpdate(),
      throwsA(isA<AppUpdateException>()),
    );
  });

  for (final firstResponse in ['error', 'corrupt']) {
    test('下载 $firstResponse 时切换同版本备选并校验哈希', () async {
      final directory = await Directory.systemTemp.createTemp(
        'lanlink-update-test-',
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final calls = <String>[];
      server.listen((request) async {
        calls.add(request.uri.path);
        if (request.uri.path == '/gitee' && firstResponse == 'error') {
          request.response.statusCode = 503;
        } else {
          request.response.write(request.uri.path == '/gitee' ? 'bad' : 'apk');
        }
        await request.response.close();
      });
      try {
        final service = AppUpdateService(
          directoryProvider: () async => directory,
        );
        final update = AppUpdateInfo(
          version: '2.0.0',
          currentVersion: '1.0.0',
          notes: '',
          releaseUrl: Uri.parse('https://gitee.com'),
          asset: AppUpdateAsset(
            name: 'test.apk',
            size: 3,
            sha256: sha256.convert(utf8.encode('apk')).toString(),
            downloadUrl: Uri.parse('http://127.0.0.1:${server.port}/gitee'),
            fallbackUrl: Uri.parse('http://127.0.0.1:${server.port}/github'),
          ),
        );
        final file = await service.downloadUpdate(
          update,
          onProgress: (_, _) {},
        );
        expect(await file.readAsString(), 'apk');
        expect(calls, ['/gitee', '/github']);
      } finally {
        await server.close(force: true);
        await directory.delete(recursive: true);
      }
    });
  }
}
