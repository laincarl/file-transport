import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models.dart';
import '../utils.dart';
import 'android_platform_service.dart';

typedef OfferHandler = Future<IncomingDecision> Function(IncomingOffer offer);

class LanTransferService extends ChangeNotifier {
  static const discoveryPort = 45678;
  static const transferPort = 45679;

  final Map<String, PeerDevice> _peers = {};
  final List<TransferTask> _tasks = [];
  final Map<String, Socket> _activeSockets = {};
  RawDatagramSocket? _discoverySocket;
  ServerSocket? _server;
  Timer? _advertiseTimer;
  Timer? _cleanupTimer;
  SharedPreferences? _preferences;

  String deviceId = '';
  String deviceName = '正在初始化';
  String? defaultDestination;
  String? startupError;
  OfferHandler? onIncomingOffer;

  List<PeerDevice> get peers {
    final result = _peers.values.toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    return result;
  }

  List<TransferTask> get tasks => List.unmodifiable(_tasks);

  Future<void> start() async {
    try {
      _preferences = await SharedPreferences.getInstance();
      deviceId = _preferences!.getString('device_id') ?? _newId();
      await _preferences!.setString('device_id', deviceId);
      deviceName =
          _preferences!.getString('device_name') ??
          (Platform.localHostname.trim().isEmpty
              ? '我的设备'
              : Platform.localHostname);
      final savedDestination = _preferences!.getString('destination');
      final defaultPath = await _defaultDownloadPath();
      defaultDestination = _isLegacyAndroidDestination(savedDestination)
          ? defaultPath
          : savedDestination ?? defaultPath;
      if (defaultDestination != savedDestination) {
        await _preferences!.setString('destination', defaultDestination!);
      }

      _server = await ServerSocket.bind(
        InternetAddress.anyIPv4,
        transferPort,
        shared: true,
      );
      _server!.listen(_handleConnection);

      _discoverySocket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        discoveryPort,
        reuseAddress: true,
        reusePort: false,
      );
      _discoverySocket!.broadcastEnabled = true;
      _discoverySocket!.listen(_handleDiscoveryEvent, onError: (_) {});
      _advertiseTimer = Timer.periodic(
        const Duration(seconds: 2),
        (_) => advertise(),
      );
      _cleanupTimer = Timer.periodic(
        const Duration(seconds: 3),
        (_) => _removeExpiredPeers(),
      );
      advertise();
    } catch (error) {
      startupError = '网络服务启动失败：$error';
    }
    notifyListeners();
  }

  Future<String> _defaultDownloadPath() async {
    if (Platform.isAndroid) {
      final downloads = await AndroidPlatformService.getPublicDownloadsPath();
      if (downloads != null && downloads.isNotEmpty) return downloads;
    }
    try {
      final downloads = await getDownloadsDirectory();
      if (downloads != null) {
        return '${downloads.path}${Platform.pathSeparator}局域快传';
      }
    } catch (_) {}
    final documents = await getApplicationDocumentsDirectory();
    return '${documents.path}${Platform.pathSeparator}局域快传';
  }

  bool _isLegacyAndroidDestination(String? path) {
    if (!Platform.isAndroid || path == null) return false;
    final normalized = path.replaceAll('\\', '/');
    return normalized.endsWith(
          '/Android/data/com.lanlink.lanlink/files/Download/局域快传',
        ) ||
        normalized.endsWith(
          '/data/user/0/com.lanlink.lanlink/app_flutter/局域快传',
        );
  }

  String _newId() =>
      '${DateTime.now().microsecondsSinceEpoch}-${Random().nextInt(1 << 32)}';

  Future<void> renameDevice(String value) async {
    final name = value.trim();
    if (name.isEmpty) return;
    deviceName = name;
    await _preferences?.setString('device_name', name);
    advertise();
    notifyListeners();
  }

  Future<void> setDefaultDestination(String path) async {
    defaultDestination = path;
    await _preferences?.setString('destination', path);
    notifyListeners();
  }

  void advertise() {
    final socket = _discoverySocket;
    if (socket == null) return;
    final payload = utf8.encode(
      jsonEncode({
        'type': 'lanlink',
        'version': 1,
        'id': deviceId,
        'name': deviceName,
        'platform': currentPlatform(),
        'port': transferPort,
      }),
    );
    try {
      socket.send(payload, InternetAddress('255.255.255.255'), discoveryPort);
    } catch (_) {}
  }

  void _handleDiscoveryEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    Datagram? datagram;
    while ((datagram = _discoverySocket?.receive()) != null) {
      try {
        final data =
            jsonDecode(utf8.decode(datagram!.data)) as Map<String, dynamic>;
        if (data['type'] != 'lanlink' || data['id'] == deviceId) continue;
        final id = data['id'] as String;
        _peers[id] = PeerDevice(
          id: id,
          name: data['name'] as String? ?? '未知设备',
          platform: data['platform'] as String? ?? 'unknown',
          address: datagram.address,
          port: data['port'] as int? ?? transferPort,
          lastSeen: DateTime.now(),
        );
        notifyListeners();
      } catch (_) {}
    }
  }

  void _removeExpiredPeers() {
    final cutoff = DateTime.now().subtract(const Duration(seconds: 8));
    final before = _peers.length;
    _peers.removeWhere(
      (id, peer) => !id.startsWith('manual-') && peer.lastSeen.isBefore(cutoff),
    );
    if (_peers.length != before) notifyListeners();
  }

  PeerDevice addManualPeer(String input) {
    var host = input.trim();
    var port = transferPort;
    if (host.contains(':')) {
      final parts = host.split(':');
      host = parts.first;
      port = int.tryParse(parts.last) ?? transferPort;
    }
    final address = InternetAddress(host);
    final peer = PeerDevice(
      id: 'manual-$host-$port',
      name: host,
      platform: 'unknown',
      address: address,
      port: port,
      lastSeen: DateTime.now(),
    );
    _peers[peer.id] = peer;
    notifyListeners();
    return peer;
  }

  Future<void> sendFiles(PeerDevice peer, List<SendEntry> entries) async {
    if (entries.isEmpty) return;
    final totalBytes = entries.fold<int>(0, (sum, item) => sum + item.size);
    final task = TransferTask(
      id: _newId(),
      direction: TransferDirection.send,
      peerName: peer.name,
      title: entries.length == 1
          ? entries.first.relativePath
          : '${entries.length} 个文件',
      fileCount: entries.length,
      totalBytes: totalBytes,
    );
    _tasks.insert(0, task);
    notifyListeners();

    Socket? socket;
    try {
      socket = await Socket.connect(
        peer.address,
        peer.port,
        timeout: const Duration(seconds: 8),
      );
      _activeSockets[task.id] = socket;
      final reader = _SocketReader(socket);
      await _writePacket(socket, {
        'type': 'offer',
        'senderName': deviceName,
        'senderPlatform': currentPlatform(),
        'totalBytes': totalBytes,
        'files': entries
            .map((entry) => {'path': entry.relativePath, 'size': entry.size})
            .toList(),
      });
      final response = await reader.readPacket();
      if (response['accepted'] != true) {
        throw const _TransferRejected();
      }

      task.beginTransfer();
      notifyListeners();
      for (final entry in entries) {
        if (task.status == TransferStatus.cancelled) {
          throw const _TransferCancelled();
        }
        await _writePacket(socket, {
          'type': 'file',
          'path': entry.relativePath,
          'size': entry.size,
        });
        await for (final chunk in entry.file.openRead()) {
          if (task.status == TransferStatus.cancelled) {
            throw const _TransferCancelled();
          }
          socket.add(chunk);
          task.addTransferredBytes(chunk.length);
          notifyListeners();
        }
        await socket.flush();
      }
      await _writePacket(socket, {'type': 'done'});
      task.status = TransferStatus.finalizing;
      notifyListeners();
      final acknowledgement = await reader.readPacket();
      if (acknowledgement['received'] != true) {
        throw const FormatException('接收方未确认完成');
      }
      task.status = TransferStatus.completed;
    } on _TransferRejected {
      task.status = TransferStatus.cancelled;
      task.error = '对方拒绝了接收请求';
    } on _TransferCancelled {
      task.status = TransferStatus.cancelled;
      task.error = '传输已取消';
    } catch (error) {
      task.status = TransferStatus.failed;
      task.error = _friendlyError(error);
    } finally {
      _activeSockets.remove(task.id);
      socket?.destroy();
      notifyListeners();
    }
  }

  void cancelTask(String taskId) {
    final task = _tasks.where((item) => item.id == taskId).firstOrNull;
    if (task == null ||
        (task.status != TransferStatus.transferring &&
            task.status != TransferStatus.finalizing)) {
      return;
    }
    task.status = TransferStatus.cancelled;
    task.error = '传输已取消';
    _activeSockets.remove(taskId)?.destroy();
    notifyListeners();
  }

  void clearFinishedTasks() {
    _tasks.removeWhere(
      (task) =>
          task.status == TransferStatus.completed ||
          task.status == TransferStatus.failed ||
          task.status == TransferStatus.cancelled,
    );
    notifyListeners();
  }

  Future<void> _handleConnection(Socket socket) async {
    final reader = _SocketReader(socket);
    TransferTask? task;
    File? temporaryFile;
    IOSink? currentSink;
    try {
      final packet = await reader.readPacket();
      if (packet['type'] != 'offer') throw const FormatException('无效的传输请求');
      final rawFiles = (packet['files'] as List)
          .cast<Map>()
          .map((item) => item.cast<String, dynamic>())
          .toList();
      final offer = IncomingOffer(
        senderName: packet['senderName'] as String? ?? '未知设备',
        senderPlatform: packet['senderPlatform'] as String? ?? 'unknown',
        files: rawFiles,
        totalBytes: packet['totalBytes'] as int? ?? 0,
      );
      final handler = onIncomingOffer;
      final decision = handler == null
          ? const IncomingDecision(accepted: false)
          : await handler(offer);
      await _writePacket(socket, {'accepted': decision.accepted});
      if (!decision.accepted) return;

      final destination = decision.destination ?? defaultDestination!;
      await Directory(destination).create(recursive: true);
      task =
          TransferTask(
              id: _newId(),
              direction: TransferDirection.receive,
              peerName: offer.senderName,
              title: rawFiles.length == 1
                  ? rawFiles.first['path'] as String
                  : '${rawFiles.length} 个文件',
              fileCount: rawFiles.length,
              totalBytes: offer.totalBytes,
            )
            ..destinationDirectory = destination
            ..beginTransfer();
      _tasks.insert(0, task);
      _activeSockets[task.id] = socket;
      notifyListeners();

      for (var index = 0; index < rawFiles.length; index++) {
        final filePacket = await reader.readPacket();
        if (filePacket['type'] != 'file') throw const FormatException('文件信息无效');
        final relativePath = safeRelativePath(
          filePacket['path'] as String? ?? '未命名文件',
        );
        final size = filePacket['size'] as int? ?? 0;
        final target = await _availableFile(
          '$destination${Platform.pathSeparator}$relativePath',
        );
        await target.parent.create(recursive: true);
        temporaryFile = File('${target.path}.lanlink-part');
        if (await temporaryFile.exists()) await temporaryFile.delete();
        currentSink = temporaryFile.openWrite();
        await reader.pipeBytes(size, currentSink, (received) {
          task!.addTransferredBytes(received);
          notifyListeners();
        });
        await currentSink.close();
        currentSink = null;
        await temporaryFile.rename(target.path);
        task.receivedPaths.add(target.path);
        temporaryFile = null;
      }
      final done = await reader.readPacket();
      if (done['type'] != 'done') throw const FormatException('传输未正常结束');
      task.status = TransferStatus.completed;
      task.bytesPerSecond = 0;
      notifyListeners();
      // 先让接收端渲染完成状态，再向发送端确认，保证双方状态顺序一致。
      await Future<void>.delayed(const Duration(milliseconds: 80));
      await _writePacket(socket, {'received': true});
    } catch (error) {
      if (task != null && task.status != TransferStatus.cancelled) {
        task.status = TransferStatus.failed;
        task.error = _friendlyError(error);
      }
      try {
        await currentSink?.close();
        if (temporaryFile != null && await temporaryFile.exists()) {
          await temporaryFile.delete();
        }
      } catch (_) {}
    } finally {
      if (task != null) _activeSockets.remove(task.id);
      socket.destroy();
      notifyListeners();
    }
  }

  Future<File> _availableFile(String requestedPath) async {
    var candidate = File(requestedPath);
    if (!await candidate.exists()) return candidate;
    final separator = Platform.pathSeparator;
    final slash = requestedPath.lastIndexOf(separator);
    final directory = slash < 0 ? '' : requestedPath.substring(0, slash + 1);
    final name = slash < 0 ? requestedPath : requestedPath.substring(slash + 1);
    final dot = name.lastIndexOf('.');
    final base = dot > 0 ? name.substring(0, dot) : name;
    final extension = dot > 0 ? name.substring(dot) : '';
    var index = 1;
    do {
      candidate = File('$directory$base ($index)$extension');
      index++;
    } while (await candidate.exists());
    return candidate;
  }

  String _friendlyError(Object error) {
    if (error is SocketException) return '网络连接失败或已中断';
    if (error is FileSystemException) return '文件读取或保存失败：${error.message}';
    return '传输失败：$error';
  }

  static Future<void> _writePacket(
    Socket socket,
    Map<String, dynamic> data,
  ) async {
    final body = utf8.encode(jsonEncode(data));
    final header = ByteData(4)..setUint32(0, body.length, Endian.big);
    socket.add(header.buffer.asUint8List());
    socket.add(body);
    await socket.flush();
  }

  @override
  void dispose() {
    _advertiseTimer?.cancel();
    _cleanupTimer?.cancel();
    _discoverySocket?.close();
    _server?.close();
    for (final socket in _activeSockets.values) {
      socket.destroy();
    }
    super.dispose();
  }
}

class _SocketReader {
  _SocketReader(Socket socket) {
    _subscription = socket.listen(
      (data) {
        _chunks.add(Uint8List.fromList(data));
        _signal?.complete();
        _signal = null;
      },
      onDone: () {
        _closed = true;
        _signal?.complete();
      },
      onError: (Object error) {
        _error = error;
        _signal?.complete();
      },
      cancelOnError: false,
    );
  }

  final Queue<Uint8List> _chunks = Queue();
  late final StreamSubscription<List<int>> _subscription;
  int _offset = 0;
  bool _closed = false;
  Object? _error;
  Completer<void>? _signal;

  Future<void> _waitForData() async {
    while (_chunks.isEmpty) {
      if (_error != null) throw _error!;
      if (_closed) throw const SocketException('连接已关闭');
      _signal ??= Completer<void>();
      await _signal!.future;
    }
  }

  Future<Uint8List> readBytes(int length) async {
    final result = Uint8List(length);
    var written = 0;
    while (written < length) {
      await _waitForData();
      final first = _chunks.first;
      final available = first.length - _offset;
      final take = min(available, length - written);
      result.setRange(written, written + take, first, _offset);
      written += take;
      _offset += take;
      if (_offset == first.length) {
        _chunks.removeFirst();
        _offset = 0;
      }
    }
    return result;
  }

  Future<Map<String, dynamic>> readPacket() async {
    final header = await readBytes(4);
    final length = ByteData.sublistView(header).getUint32(0, Endian.big);
    if (length > 16 * 1024 * 1024) throw const FormatException('数据包过大');
    final body = await readBytes(length);
    return (jsonDecode(utf8.decode(body)) as Map).cast<String, dynamic>();
  }

  Future<void> pipeBytes(
    int length,
    IOSink sink,
    void Function(int count) onChunk,
  ) async {
    var remaining = length;
    while (remaining > 0) {
      await _waitForData();
      final first = _chunks.first;
      final available = first.length - _offset;
      final take = min(available, remaining);
      sink.add(Uint8List.sublistView(first, _offset, _offset + take));
      _offset += take;
      remaining -= take;
      onChunk(take);
      if (_offset == first.length) {
        _chunks.removeFirst();
        _offset = 0;
      }
    }
  }

  Future<void> close() => _subscription.cancel();
}

class _TransferRejected implements Exception {
  const _TransferRejected();
}

class _TransferCancelled implements Exception {
  const _TransferCancelled();
}
