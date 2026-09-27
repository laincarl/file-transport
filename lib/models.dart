import 'dart:io';

enum TransferDirection { send, receive }

enum TransferStatus {
  waiting,
  transferring,
  finalizing,
  completed,
  failed,
  cancelled,
}

class PeerDevice {
  const PeerDevice({
    required this.id,
    required this.name,
    required this.platform,
    required this.address,
    required this.port,
    required this.lastSeen,
  });

  final String id;
  final String name;
  final String platform;
  final InternetAddress address;
  final int port;
  final DateTime lastSeen;

  PeerDevice copyWith({DateTime? lastSeen}) => PeerDevice(
    id: id,
    name: name,
    platform: platform,
    address: address,
    port: port,
    lastSeen: lastSeen ?? this.lastSeen,
  );
}

class SendEntry {
  const SendEntry({
    required this.file,
    required this.relativePath,
    required this.size,
  });

  final File file;
  final String relativePath;
  final int size;
}

class IncomingOffer {
  IncomingOffer({
    required this.senderName,
    required this.senderPlatform,
    required this.files,
    required this.totalBytes,
  });

  final String senderName;
  final String senderPlatform;
  final List<Map<String, dynamic>> files;
  final int totalBytes;
}

class IncomingDecision {
  const IncomingDecision({required this.accepted, this.destination});

  final bool accepted;
  final String? destination;
}

class TransferTask {
  TransferTask({
    required this.id,
    required this.direction,
    required this.peerName,
    required this.title,
    required this.fileCount,
    required this.totalBytes,
  });

  final String id;
  final TransferDirection direction;
  final String peerName;
  final String title;
  final int fileCount;
  final int totalBytes;
  int transferredBytes = 0;
  TransferStatus status = TransferStatus.waiting;
  String? error;
  DateTime createdAt = DateTime.now();
  String? destinationDirectory;
  final List<String> receivedPaths = [];
  DateTime? _lastSpeedSampleAt;
  int _lastSpeedSampleBytes = 0;
  double bytesPerSecond = 0;

  double get progress => totalBytes == 0
      ? (status == TransferStatus.completed ? 1 : 0)
      : (transferredBytes / totalBytes).clamp(0, 1);

  Duration? get remainingTime {
    if (bytesPerSecond <= 0 || transferredBytes >= totalBytes) return null;
    final seconds = ((totalBytes - transferredBytes) / bytesPerSecond).ceil();
    return Duration(seconds: seconds);
  }

  void beginTransfer() {
    status = TransferStatus.transferring;
    _lastSpeedSampleAt = DateTime.now();
    _lastSpeedSampleBytes = transferredBytes;
  }

  void addTransferredBytes(int count) {
    transferredBytes += count;
    final now = DateTime.now();
    final previous = _lastSpeedSampleAt ?? now;
    final elapsed = now.difference(previous).inMilliseconds;
    if (elapsed < 250) return;
    final bytes = transferredBytes - _lastSpeedSampleBytes;
    final currentSpeed = bytes * 1000 / elapsed;
    bytesPerSecond = bytesPerSecond == 0
        ? currentSpeed
        : bytesPerSecond * 0.65 + currentSpeed * 0.35;
    _lastSpeedSampleAt = now;
    _lastSpeedSampleBytes = transferredBytes;
  }

  void syncFromReceiver(int bytes, double speed) {
    transferredBytes = bytes.clamp(0, totalBytes);
    bytesPerSecond = speed < 0 ? 0 : speed;
  }
}
