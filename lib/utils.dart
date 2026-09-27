import 'dart:io';

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var index = -1;
  do {
    value /= 1024;
    index++;
  } while (value >= 1024 && index < units.length - 1);
  final digits = value >= 100
      ? 0
      : value >= 10
      ? 1
      : 2;
  return '${value.toStringAsFixed(digits)} ${units[index]}';
}

String formatDuration(Duration duration) {
  final seconds = duration.inSeconds;
  if (seconds < 60) return '${seconds.clamp(1, 59)} 秒';
  final minutes = (seconds / 60).ceil();
  if (minutes < 60) return '$minutes 分钟';
  final hours = minutes ~/ 60;
  final rest = minutes % 60;
  return rest == 0 ? '$hours 小时' : '$hours 小时 $rest 分钟';
}

String platformLabel(String platform) => switch (platform) {
  'windows' => 'Windows',
  'macos' => 'macOS',
  'android' => 'Android',
  _ => platform,
};

String currentPlatform() {
  if (Platform.isWindows) return 'windows';
  if (Platform.isMacOS) return 'macos';
  if (Platform.isAndroid) return 'android';
  return Platform.operatingSystem;
}

String safeRelativePath(String input) {
  final normalized = input.replaceAll('\\', '/');
  final parts = normalized
      .split('/')
      .where((part) => part.isNotEmpty && part != '.' && part != '..')
      .map(
        (part) => Platform.isWindows
            ? part.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')
            : part,
      )
      .toList();
  return parts.isEmpty ? '未命名文件' : parts.join(Platform.pathSeparator);
}
