import 'package:flutter_test/flutter_test.dart';
import 'package:lanlink/models.dart';
import 'package:lanlink/services/app_update_service.dart';
import 'package:lanlink/utils.dart';

void main() {
  test('文件大小使用易读单位', () {
    expect(formatBytes(0), '0 B');
    expect(formatBytes(1024), '1.00 KB');
    expect(formatBytes(1024 * 1024), '1.00 MB');
  });

  test('接收路径不会向上穿越目录', () {
    final result = safeRelativePath('../../相册/照片.jpg');
    expect(result.contains('..'), isFalse);
    expect(result.contains('照片.jpg'), isTrue);
  });

  test('预计剩余时间使用中文易读格式', () {
    expect(formatDuration(const Duration(seconds: 12)), '12 秒');
    expect(formatDuration(const Duration(seconds: 75)), '2 分钟');
    expect(formatDuration(const Duration(minutes: 125)), '2 小时 5 分钟');
  });

  test('传输任务计算实时速度和剩余时间', () async {
    final task = TransferTask(
      id: 'speed-test',
      direction: TransferDirection.send,
      peerName: '测试设备',
      title: 'test.bin',
      fileCount: 1,
      totalBytes: 2048,
    );
    task.beginTransfer();
    await Future<void>.delayed(const Duration(milliseconds: 260));
    task.addTransferredBytes(1024);
    expect(task.bytesPerSecond, greaterThan(0));
    expect(task.remainingTime, isNotNull);
  });

  test('发送端使用接收端回传的进度和速度', () {
    final task = TransferTask(
      id: 'sync',
      direction: TransferDirection.send,
      peerName: '接收端',
      title: '文件.bin',
      fileCount: 1,
      totalBytes: 4096,
    );

    task.syncFromReceiver(1536, 2048);

    expect(task.transferredBytes, 1536);
    expect(task.bytesPerSecond, 2048);
    expect(task.progress, closeTo(0.375, 0.0001));
  });

  test('应用版本比较支持 v 前缀、构建号和不同段数', () {
    expect(
      AppUpdateService.compareVersions('v1.1.0', '1.0.9+12'),
      greaterThan(0),
    );
    expect(AppUpdateService.compareVersions('1.1', '1.1.0'), 0);
    expect(AppUpdateService.compareVersions('1.0.9', '1.1.0'), lessThan(0));
  });

  test('更新文件名会移除路径和非法字符', () {
    expect(
      AppUpdateService.safeAssetName('../局域快传:setup?.exe'),
      '__局域快传_setup_.exe',
    );
  });
}
