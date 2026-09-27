import 'package:flutter_test/flutter_test.dart';
import 'package:lanlink/models.dart';
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
}
