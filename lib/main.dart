import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';

import 'models.dart';
import 'services/android_platform_service.dart';
import 'services/lan_transfer_service.dart';
import 'utils.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const LanLinkApp());
}

class LanLinkApp extends StatelessWidget {
  const LanLinkApp({super.key});

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF4F46E5);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: '局域快传',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: seed,
          surface: const Color(0xFFF8FAFC),
        ),
        scaffoldBackgroundColor: const Color(0xFFF3F5F9),
        useMaterial3: true,
        fontFamilyFallback: const ['Microsoft YaHei', 'PingFang SC'],
        cardTheme: const CardThemeData(
          elevation: 0,
          margin: EdgeInsets.zero,
          color: Colors.white,
        ),
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
          filled: true,
          fillColor: Colors.white,
        ),
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late final LanTransferService service;
  PeerDevice? selectedPeer;
  bool dragging = false;
  bool isTelevision = false;

  @override
  void initState() {
    super.initState();
    service = LanTransferService();
    service.onIncomingOffer = _confirmIncoming;
    _initialize();
  }

  Future<void> _initialize() async {
    if (Platform.isAndroid) {
      try {
        final television = await AndroidPlatformService.isTelevision();
        if (mounted) setState(() => isTelevision = television);
      } catch (_) {}
    }
    await service.start();
    if (!mounted || !Platform.isAndroid) return;
    if (await AndroidPlatformService.hasStorageAccess()) return;
    if (!mounted) return;
    final shouldOpenSettings =
        await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (context) => AlertDialog(
            icon: const Icon(Icons.folder_shared_outlined, size: 34),
            title: const Text('允许访问下载目录'),
            content: const Text('局域快传会把接收的文件保存到系统“下载/局域快传”目录，需要授予文件访问权限。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('稍后'),
              ),
              FilledButton(
                autofocus: isTelevision,
                onPressed: () => Navigator.pop(context, true),
                child: const Text('去授权'),
              ),
            ],
          ),
        ) ??
        false;
    if (shouldOpenSettings) {
      await AndroidPlatformService.requestStorageAccess();
    }
  }

  @override
  void dispose() {
    service.dispose();
    super.dispose();
  }

  Future<IncomingDecision> _confirmIncoming(IncomingOffer offer) async {
    if (!mounted) return const IncomingDecision(accepted: false);
    final accepted =
        await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (context) => AlertDialog(
            icon: const Icon(Icons.download_rounded, size: 34),
            title: const Text('收到文件传输请求'),
            content: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${offer.senderName} 想要发送文件到此设备。'),
                  const SizedBox(height: 18),
                  _InfoRow(label: '文件数量', value: '${offer.files.length} 个'),
                  const SizedBox(height: 8),
                  _InfoRow(label: '总大小', value: formatBytes(offer.totalBytes)),
                  const SizedBox(height: 8),
                  _InfoRow(
                    label: '保存到',
                    value: service.defaultDestination ?? '默认下载目录',
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('拒绝'),
              ),
              FilledButton(
                autofocus: isTelevision,
                onPressed: () => Navigator.pop(context, true),
                child: const Text('接收'),
              ),
            ],
          ),
        ) ??
        false;
    return IncomingDecision(
      accepted: accepted,
      destination: service.defaultDestination,
    );
  }

  Future<void> _pickFiles() async {
    final result = await FilePicker.pickFiles();
    if (result.isEmpty) return;
    final entries = <SendEntry>[];
    for (final item in result) {
      if (item.path == null) continue;
      final file = File(item.path!);
      entries.add(
        SendEntry(
          file: file,
          relativePath: item.name,
          size: await file.length(),
        ),
      );
    }
    await _sendEntries(entries);
  }

  Future<void> _pickFolder() async {
    final path = await FilePicker.getDirectoryPath();
    if (path != null) await _sendEntries(await _entriesFromPath(path));
  }

  Future<List<SendEntry>> _entriesFromPath(String path) async {
    final type = FileSystemEntity.typeSync(path);
    if (type == FileSystemEntityType.file) {
      final file = File(path);
      return [
        SendEntry(
          file: file,
          relativePath: _basename(path),
          size: await file.length(),
        ),
      ];
    }
    if (type != FileSystemEntityType.directory) return [];
    final directory = Directory(path);
    final parentPath = directory.parent.path;
    final entries = <SendEntry>[];
    await for (final entity in directory.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File) continue;
      entries.add(
        SendEntry(
          file: entity,
          relativePath: entity.path.substring(parentPath.length + 1),
          size: await entity.length(),
        ),
      );
    }
    return entries;
  }

  String _basename(String path) => path
      .replaceAll('\\', '/')
      .split('/')
      .where((part) => part.isNotEmpty)
      .last;

  Future<void> _sendEntries(List<SendEntry> entries) async {
    if (entries.isEmpty) {
      _message('没有找到可发送的文件');
      return;
    }
    var peer = selectedPeer;
    peer ??= await _choosePeer();
    if (peer != null) await service.sendFiles(peer, entries);
  }

  Future<PeerDevice?> _choosePeer() async {
    if (service.peers.isEmpty) {
      _message('暂未发现其他设备，请确认它们位于同一局域网');
      return null;
    }
    return showModalBottomSheet<PeerDevice>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('选择接收设备', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 12),
              ...service.peers.map(
                (peer) => ListTile(
                  leading: _DeviceAvatar(platform: peer.platform),
                  title: Text(peer.name),
                  subtitle: Text(
                    '${platformLabel(peer.platform)} · ${peer.address.address}',
                  ),
                  onTap: () => Navigator.pop(context, peer),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _message(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }
  }

  Future<void> _openReceivedFile(TransferTask task) async {
    if (task.receivedPaths.isEmpty) {
      _message('文件不存在或尚未接收完成');
      return;
    }
    final path = task.receivedPaths.first;
    if (Platform.isAndroid) {
      try {
        final result = await AndroidPlatformService.openFile(path);
        if (result == 'install_permission_requested') {
          _message('请允许安装未知应用，返回后再次点击“安装 APK”');
        } else if (result != 'done') {
          _message('无法打开此文件');
        }
      } catch (_) {
        _message('无法打开此文件');
      }
      return;
    }
    final result = await OpenFilex.open(path);
    if (result.type != ResultType.done) {
      _message(result.message.isEmpty ? '无法打开此文件' : result.message);
    }
  }

  Future<void> _revealReceivedFile(TransferTask task) async {
    if (task.receivedPaths.isEmpty) {
      _message('文件不存在或尚未接收完成');
      return;
    }
    final filePath = task.receivedPaths.first;
    try {
      if (Platform.isWindows) {
        await Process.start('explorer.exe', ['/select,', filePath]);
      } else if (Platform.isMacOS) {
        await Process.start('open', ['-R', filePath]);
      } else {
        final opened = await AndroidPlatformService.openFolder(
          task.destinationDirectory ?? File(filePath).parent.path,
        );
        if (!opened) _message('无法打开文件所在目录');
      }
    } catch (_) {
      _message('无法打开文件所在位置');
    }
  }

  Future<void> _manualConnect() async {
    final controller = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('手动连接设备'),
        content: SizedBox(
          width: 380,
          child: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'IP 地址',
              hintText: '例如 192.168.1.20',
            ),
            onSubmitted: (value) => Navigator.pop(context, value),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('添加'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value == null || value.trim().isEmpty) return;
    try {
      setState(() => selectedPeer = service.addManualPeer(value));
    } catch (_) {
      _message('IP 地址格式不正确');
    }
  }

  Future<void> _showSettings() async {
    final nameController = TextEditingController(text: service.deviceName);
    var autoReceive = service.autoReceive;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          scrollable: true,
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 20,
            vertical: 16,
          ),
          title: const Text('设置'),
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: nameController,
                  decoration: const InputDecoration(labelText: '本机名称'),
                ),
                const SizedBox(height: 18),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('自动接收文件'),
                  subtitle: const Text('开启后无需确认，直接保存到接收目录'),
                  value: autoReceive,
                  onChanged: (value) =>
                      setDialogState(() => autoReceive = value),
                ),
                const SizedBox(height: 12),
                Text('接收目录', style: Theme.of(context).textTheme.labelLarge),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF8FAFC),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: const Color(0xFFE3E6EC)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.folder_outlined, size: 21),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          service.defaultDestination ?? '尚未选择目录',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton(
                        onPressed: () async {
                          final path = await FilePicker.getDirectoryPath(
                            initialDirectory: service.defaultDestination,
                          );
                          if (path != null) {
                            await service.setDefaultDestination(path);
                            setDialogState(() {});
                          }
                        },
                        child: const Text('更改目录'),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 7),
                const Text(
                  '之后接收的文件将保存到此目录',
                  style: TextStyle(fontSize: 12, color: Color(0xFF7B8190)),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () async {
                await service.setAutoReceive(autoReceive);
                await service.renameDevice(nameController.text);
                if (dialogContext.mounted) Navigator.pop(dialogContext);
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    nameController.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: service,
      builder: (context, _) => Scaffold(
        body: SafeArea(
          child: DropTarget(
            onDragEntered: (_) => setState(() => dragging = true),
            onDragExited: (_) => setState(() => dragging = false),
            onDragDone: (detail) async {
              setState(() => dragging = false);
              final entries = <SendEntry>[];
              for (final file in detail.files) {
                entries.addAll(await _entriesFromPath(file.path));
              }
              await _sendEntries(entries);
            },
            child: Stack(
              children: [
                Column(
                  children: [
                    _Header(
                      deviceName: service.deviceName,
                      peerCount: service.peers.length,
                      onSettings: _showSettings,
                      autofocusSettings: isTelevision,
                    ),
                    Expanded(
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final wide = constraints.maxWidth >= 760;
                          final devices = _DevicesPanel(
                            peers: service.peers,
                            selected: selectedPeer,
                            television: isTelevision,
                            localAddress: service.localAddress,
                            onSelected: (peer) =>
                                setState(() => selectedPeer = peer),
                            onRefresh: () =>
                                service.discoverNow(forceScan: true),
                            onManualConnect: _manualConnect,
                          );
                          final right = Column(
                            children: [
                              _SendPanel(
                                peer: selectedPeer,
                                onPickFiles: _pickFiles,
                                onPickFolder: _pickFolder,
                                television: isTelevision,
                              ),
                              const SizedBox(height: 18),
                              Expanded(
                                child: _TransfersPanel(
                                  tasks: service.tasks,
                                  television: isTelevision,
                                  onCancel: service.cancelTask,
                                  onClear: service.clearFinishedTasks,
                                  onOpen: _openReceivedFile,
                                  onReveal: _revealReceivedFile,
                                ),
                              ),
                            ],
                          );
                          return Padding(
                            padding: EdgeInsets.fromLTRB(
                              wide ? 28 : 16,
                              18,
                              wide ? 28 : 16,
                              24,
                            ),
                            child: wide
                                ? Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      Expanded(flex: 5, child: devices),
                                      const SizedBox(width: 18),
                                      Expanded(flex: 4, child: right),
                                    ],
                                  )
                                : ListView(
                                    key: ValueKey(
                                      constraints.maxWidth >
                                              constraints.maxHeight
                                          ? 'mobile-landscape'
                                          : 'mobile-portrait',
                                    ),
                                    children: [
                                      SizedBox(height: 310, child: devices),
                                      const SizedBox(height: 18),
                                      SizedBox(height: 470, child: right),
                                    ],
                                  ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
                if (dragging)
                  Positioned.fill(
                    child: ColoredBox(
                      color: Theme.of(
                        context,
                      ).colorScheme.primary.withValues(alpha: .12),
                      child: Center(
                        child: Card(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 42,
                              vertical: 32,
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.file_download_outlined,
                                  size: 52,
                                  color: Theme.of(context).colorScheme.primary,
                                ),
                                const SizedBox(height: 12),
                                const Text(
                                  '松开发送文件',
                                  style: TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                if (service.startupError != null)
                  Positioned(
                    left: 16,
                    right: 16,
                    bottom: 12,
                    child: MaterialBanner(
                      content: Text(service.startupError!),
                      actions: [
                        TextButton(onPressed: () {}, child: const Text('知道了')),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.deviceName,
    required this.peerCount,
    required this.onSettings,
    required this.autofocusSettings,
  });
  final String deviceName;
  final int peerCount;
  final VoidCallback onSettings;
  final bool autofocusSettings;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 600;
        return Container(
          height: 78,
          padding: EdgeInsets.symmetric(horizontal: compact ? 14 : 28),
          decoration: const BoxDecoration(
            color: Colors.white,
            border: Border(bottom: BorderSide(color: Color(0xFFE8EAF0))),
          ),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(13),
                ),
                clipBehavior: Clip.antiAlias,
                child: Image.asset(
                  'assets/icon/app_icon.png',
                  fit: BoxFit.cover,
                ),
              ),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '局域快传',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 19,
                      ),
                    ),
                    if (!compact)
                      const Text(
                        '文件只在局域网内传输',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Color(0xFF7B8190),
                          fontSize: 12,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: EdgeInsets.symmetric(
                  horizontal: compact ? 9 : 12,
                  vertical: 7,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFFECFDF3),
                  borderRadius: BorderRadius.circular(99),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(
                      width: 7,
                      height: 7,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Color(0xFF12B76A),
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                    const SizedBox(width: 7),
                    Text(
                      compact
                          ? '$peerCount 台在线'
                          : '$deviceName · $peerCount 台在线',
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF027A48),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 4),
              IconButton(
                onPressed: onSettings,
                autofocus: autofocusSettings,
                tooltip: '设置',
                icon: const Icon(Icons.settings_outlined),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _DevicesPanel extends StatelessWidget {
  const _DevicesPanel({
    required this.peers,
    required this.selected,
    required this.television,
    required this.localAddress,
    required this.onSelected,
    required this.onRefresh,
    required this.onManualConnect,
  });
  final List<PeerDevice> peers;
  final PeerDevice? selected;
  final bool television;
  final String? localAddress;
  final ValueChanged<PeerDevice> onSelected;
  final VoidCallback onRefresh;
  final VoidCallback onManualConnect;

  @override
  Widget build(BuildContext context) {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  television ? '本机接收信息' : '附近设备',
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                ),
                const Spacer(),
                IconButton(
                  onPressed: onRefresh,
                  tooltip: '刷新',
                  icon: const Icon(Icons.refresh_rounded),
                ),
                if (!television)
                  TextButton.icon(
                    onPressed: onManualConnect,
                    icon: const Icon(Icons.add_link_rounded),
                    label: const Text('手动连接'),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              television
                  ? '局域网 IP：${localAddress ?? '正在获取'} · 如未自动发现，可在发送端手动连接此 IP'
                  : '选择一台设备，然后发送文件或文件夹',
              style: const TextStyle(color: Color(0xFF737988)),
            ),
            const SizedBox(height: 18),
            Expanded(
              child: peers.isEmpty
                  ? const _EmptyDevices()
                  : GridView.builder(
                      gridDelegate:
                          const SliverGridDelegateWithMaxCrossAxisExtent(
                            maxCrossAxisExtent: 230,
                            mainAxisExtent: 150,
                            crossAxisSpacing: 12,
                            mainAxisSpacing: 12,
                          ),
                      itemCount: peers.length,
                      itemBuilder: (context, index) {
                        final peer = peers[index];
                        final active = selected?.id == peer.id;
                        return InkWell(
                          onTap: () => onSelected(peer),
                          borderRadius: BorderRadius.circular(14),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 160),
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: active
                                  ? const Color(0xFFEEF2FF)
                                  : const Color(0xFFF8FAFC),
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                color: active
                                    ? Theme.of(context).colorScheme.primary
                                    : const Color(0xFFE5E7EB),
                                width: active ? 1.5 : 1,
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    _DeviceAvatar(platform: peer.platform),
                                    const Spacer(),
                                    if (active)
                                      Icon(
                                        Icons.check_circle,
                                        size: 20,
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.primary,
                                      ),
                                  ],
                                ),
                                const Spacer(),
                                Text(
                                  peer.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  '${platformLabel(peer.platform)} · ${peer.address.address}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: Color(0xFF7B8190),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyDevices extends StatelessWidget {
  const _EmptyDevices();
  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              color: Color(0xFFF0F2F7),
              shape: BoxShape.circle,
            ),
            child: Padding(
              padding: EdgeInsets.all(18),
              child: Icon(
                Icons.radar_rounded,
                size: 34,
                color: Color(0xFF667085),
              ),
            ),
          ),
          SizedBox(height: 14),
          Text('正在寻找附近设备', style: TextStyle(fontWeight: FontWeight.w600)),
          SizedBox(height: 5),
          Text(
            '请在其他设备上打开局域快传',
            style: TextStyle(color: Color(0xFF7B8190), fontSize: 13),
          ),
        ],
      ),
    );
  }
}

class _SendPanel extends StatelessWidget {
  const _SendPanel({
    required this.peer,
    required this.onPickFiles,
    required this.onPickFolder,
    required this.television,
  });
  final PeerDevice? peer;
  final VoidCallback onPickFiles;
  final VoidCallback onPickFolder;
  final bool television;

  @override
  Widget build(BuildContext context) {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: television
            ? const Row(
                children: [
                  Icon(Icons.tv_rounded, size: 42, color: Color(0xFF4F46E5)),
                  SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '电视端等待接收',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        SizedBox(height: 6),
                        Text(
                          '请在手机或电脑上选择此电视并发送 APK',
                          style: TextStyle(color: Color(0xFF737988)),
                        ),
                      ],
                    ),
                  ),
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '发送文件',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    peer == null ? '先选择附近设备，也可以直接拖入文件' : '发送到 ${peer!.name}',
                    style: const TextStyle(
                      color: Color(0xFF737988),
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: onPickFiles,
                          icon: const Icon(Icons.insert_drive_file_outlined),
                          label: const Text('选择文件'),
                          style: FilledButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 14),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: onPickFolder,
                          icon: const Icon(Icons.folder_outlined),
                          label: const Text('选择文件夹'),
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 14),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
      ),
    );
  }
}

class _TransfersPanel extends StatelessWidget {
  const _TransfersPanel({
    required this.tasks,
    required this.television,
    required this.onCancel,
    required this.onClear,
    required this.onOpen,
    required this.onReveal,
  });
  final List<TransferTask> tasks;
  final bool television;
  final ValueChanged<String> onCancel;
  final VoidCallback onClear;
  final ValueChanged<TransferTask> onOpen;
  final ValueChanged<TransferTask> onReveal;

  @override
  Widget build(BuildContext context) {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  '传输记录',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                if (tasks.isNotEmpty)
                  TextButton(onPressed: onClear, child: const Text('清除已完成')),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              child: tasks.isEmpty
                  ? const Center(
                      child: Text(
                        '暂无传输记录',
                        style: TextStyle(color: Color(0xFF9298A7)),
                      ),
                    )
                  : ListView.separated(
                      itemCount: tasks.length,
                      separatorBuilder: (_, _) => const Divider(height: 22),
                      itemBuilder: (context, index) => _TransferRow(
                        task: tasks[index],
                        television: television,
                        onCancel: onCancel,
                        onOpen: onOpen,
                        onReveal: onReveal,
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TransferRow extends StatelessWidget {
  const _TransferRow({
    required this.task,
    required this.television,
    required this.onCancel,
    required this.onOpen,
    required this.onReveal,
  });
  final TransferTask task;
  final bool television;
  final ValueChanged<String> onCancel;
  final ValueChanged<TransferTask> onOpen;
  final ValueChanged<TransferTask> onReveal;

  @override
  Widget build(BuildContext context) {
    final active =
        task.status == TransferStatus.transferring ||
        task.status == TransferStatus.finalizing ||
        task.status == TransferStatus.waiting;
    final icon = task.direction == TransferDirection.send
        ? Icons.north_east_rounded
        : Icons.south_west_rounded;
    final status = switch (task.status) {
      TransferStatus.waiting => '等待对方确认',
      TransferStatus.transferring => '传输中',
      TransferStatus.finalizing => '文件已发送，等待对方确认完成',
      TransferStatus.completed => '传输完成',
      TransferStatus.failed => task.error ?? '传输失败',
      TransferStatus.cancelled => task.error ?? '已取消',
    };
    final peerText =
        '${task.direction == TransferDirection.send ? '发送到' : '来自'} ${task.peerName}';
    final receivedApk =
        Platform.isAndroid &&
        task.receivedPaths.isNotEmpty &&
        task.receivedPaths.first.toLowerCase().endsWith('.apk');
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: const Color(0xFFF0F2FF),
            borderRadius: BorderRadius.circular(11),
          ),
          child: Icon(
            icon,
            size: 20,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                task.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 3),
              Text(
                '$peerText · $status',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  color: task.status == TransferStatus.failed
                      ? Colors.red
                      : const Color(0xFF7B8190),
                ),
              ),
              if (active) ...[
                const SizedBox(height: 8),
                LinearProgressIndicator(
                  value: task.status == TransferStatus.waiting
                      ? null
                      : task.progress,
                  minHeight: 5,
                  borderRadius: BorderRadius.circular(5),
                ),
              ],
              if (task.status == TransferStatus.transferring ||
                  task.status == TransferStatus.finalizing) ...[
                const SizedBox(height: 7),
                Wrap(
                  spacing: 12,
                  runSpacing: 4,
                  children: _transferProgressItems(task)
                      .map(
                        (text) => Text(
                          text,
                          style: const TextStyle(
                            fontSize: 11,
                            color: Color(0xFF667085),
                          ),
                        ),
                      )
                      .toList(),
                ),
              ],
              if (task.status == TransferStatus.completed &&
                  task.direction == TransferDirection.receive &&
                  task.receivedPaths.isNotEmpty) ...[
                const SizedBox(height: 6),
                Wrap(
                  spacing: 4,
                  children: [
                    if (task.fileCount == 1)
                      TextButton.icon(
                        onPressed: () => onOpen(task),
                        autofocus: receivedApk,
                        icon: Icon(
                          receivedApk
                              ? Icons.install_mobile_rounded
                              : Icons.open_in_new_rounded,
                          size: 17,
                        ),
                        label: Text(receivedApk ? '安装 APK' : '打开文件'),
                      ),
                    if (!television)
                      TextButton.icon(
                        onPressed: () => onReveal(task),
                        icon: const Icon(Icons.folder_open_rounded, size: 17),
                        label: Text(
                          Platform.isWindows
                              ? '在资源管理器中显示'
                              : Platform.isMacOS
                              ? '在 Finder 中显示'
                              : '打开所在位置',
                        ),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
        if (task.status == TransferStatus.transferring ||
            task.status == TransferStatus.finalizing)
          IconButton(
            onPressed: () => onCancel(task.id),
            tooltip: '取消',
            icon: const Icon(Icons.close_rounded, size: 20),
          ),
        if (task.status == TransferStatus.completed)
          const Padding(
            padding: EdgeInsets.only(top: 9),
            child: Icon(Icons.check_circle, color: Color(0xFF12B76A), size: 20),
          ),
      ],
    );
  }

  List<String> _transferProgressItems(TransferTask task) {
    final parts = <String>[
      '${formatBytes(task.transferredBytes)} / ${formatBytes(task.totalBytes)}',
    ];
    if (task.bytesPerSecond > 0) {
      parts.add('${formatBytes(task.bytesPerSecond.round())}/秒');
    }
    final remaining = task.remainingTime;
    if (remaining != null) {
      parts.add('剩余约 ${formatDuration(remaining)}');
    }
    return parts;
  }
}

class _DeviceAvatar extends StatelessWidget {
  const _DeviceAvatar({required this.platform});
  final String platform;
  @override
  Widget build(BuildContext context) {
    final icon = switch (platform) {
      'android' => Icons.smartphone_rounded,
      'windows' || 'macos' => Icons.laptop_rounded,
      _ => Icons.devices_other_rounded,
    };
    return Container(
      width: 42,
      height: 42,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE3E6EC)),
      ),
      child: Icon(icon, size: 22, color: const Color(0xFF475467)),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 72,
          child: Text(label, style: const TextStyle(color: Color(0xFF7B8190))),
        ),
        Expanded(
          child: Text(value, maxLines: 2, overflow: TextOverflow.ellipsis),
        ),
      ],
    );
  }
}
