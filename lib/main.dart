import 'dart:convert';
import 'dart:io';
import 'dart:ui' show ImageFilter;

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:window_manager/window_manager.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  await windowManager.waitUntilReadyToShow(
    const WindowOptions(
      size: Size(1100, 720),
      minimumSize: Size(900, 600),
      center: true,
      title: 'FlasherPro',
      backgroundColor: Color(0xFF101114),
    ),
    () async {
      await windowManager.show();
      await windowManager.focus();
    },
  );
  runApp(const FlasherProApp());
}

class FlasherProApp extends StatefulWidget {
  const FlasherProApp({super.key});
  @override
  State<FlasherProApp> createState() => _FlasherProAppState();
}

class _FlasherProAppState extends State<FlasherProApp> with WidgetsBindingObserver {
  String _appTheme = 'Dark';
  String _uiScale = '100%';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangePlatformBrightness() {
    if (_appTheme == 'System' && mounted) setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const accent = Color(0xFFB8F36B);
    final brightness = _appTheme == 'System'
        ? WidgetsBinding.instance.platformDispatcher.platformBrightness
        : (_appTheme == 'Light' ? Brightness.light : Brightness.dark);
    final dark = brightness == Brightness.dark;
    final scale = (double.tryParse(_uiScale.replaceAll('%', '')) ?? 100) / 100;
    final density = (scale - 1).clamp(-1.0, 1.0).toDouble();
    final theme = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      visualDensity: VisualDensity(horizontal: density, vertical: density),
      scaffoldBackgroundColor: dark ? const Color(0xFF101114) : const Color(0xFFF4F6F8),
      colorScheme: ColorScheme.fromSeed(seedColor: accent, brightness: brightness,
        surface: dark ? const Color(0xFF181A1F) : Colors.white),
      cardTheme: CardThemeData(
        color: dark ? const Color(0xCC20232B) : Colors.white,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: dark ? const Color(0xFF2A2D34) : const Color(0xFFDCE1E7)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: dark ? const Color(0xFF111216) : const Color(0xFFF0F2F5),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: dark ? const Color(0xFF30333A) : const Color(0xFFD0D6DE))),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(backgroundColor: accent, foregroundColor: const Color(0xFF101114),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
      ),
    );
    return MaterialApp(
      title: 'FlasherPro',
      debugShowCheckedModeBanner: false,
      theme: theme,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
        child: child ?? const SizedBox.shrink(),
      ),
      home: FlasherHome(
        appTheme: _appTheme, uiScale: _uiScale,
        onThemeChanged: (value) => setState(() => _appTheme = value),
        onScaleChanged: (value) => setState(() => _uiScale = value),
      ),
    );
  }
}

class _UnpackCancelled implements Exception {
  const _UnpackCancelled();
}

enum FlasherSection { extraTools, logcat, drivers, unpacker, flasher, settings }

class FlasherHome extends StatefulWidget {
  const FlasherHome({super.key, required this.appTheme, required this.uiScale, required this.onThemeChanged, required this.onScaleChanged});
  final String appTheme;
  final String uiScale;
  final ValueChanged<String> onThemeChanged;
  final ValueChanged<String> onScaleChanged;

  @override
  State<FlasherHome> createState() => _FlasherHomeState();
}

class _FlasherHomeState extends State<FlasherHome> {
  @override
  void initState() {
    super.initState();
    _refreshSavedFirmwares();
  }

  @override
  void dispose() {
    _firmwareNameController.dispose();
    _logcatProcess?.kill();
    super.dispose();
  }

  FlasherSection _section = FlasherSection.extraTools;
  String? _firmwareArchive;
  final TextEditingController _firmwareNameController = TextEditingController();
  double _unpackProgress = 0;
  String _unpackStatus = 'Ready to unpack';
  String? _activeFirmwareDirectory;
  List<Directory> _savedFirmwares = [];
  final List<File> _images = [];
  final Set<String> _selectedImages = {};
  final List<String> _log = [];
  bool _busy = false;
  bool _cancelUnpack = false;
  Process? _payloadProcess;
  bool _skipPreloaderRaw = true;
  Process? _logcatProcess;
  bool _logcatRunning = false;
  String _logcatBuffer = 'main';
  String _logcatLevel = 'Verbose';
  String _logcatSearch = '';
  final List<String> _logcatLines = [];
  final List<String> _driverPackages = [];
  String? _selectedDriver;
  String? _driverOutput;
  bool _aboutExpanded = true;

  String get _sectionTitle => switch (_section) {
        FlasherSection.extraTools => 'Extra Tools',
        FlasherSection.logcat => 'Logcat',
        FlasherSection.drivers => 'Drivers',
        FlasherSection.unpacker => 'Firmware Unpacker',
        FlasherSection.flasher => 'Firmware Flasher',
        FlasherSection.settings => 'Settings',
      };

  void _writeLog(String message) {
    if (!mounted) return;
    setState(() {
      _log.insert(0, '[${DateTime.now().toLocal().toString().substring(11, 19)}] $message');
      if (_log.length > 120) _log.removeLast();
    });
  }

  String _safeFolderName(String input) {
    final cleaned = input.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_')
        .trim().replaceAll(RegExp(r'[. ]+$'), '');
    if (cleaned.isEmpty) return 'Firmware_${DateTime.now().millisecondsSinceEpoch}';
    return cleaned.substring(0, cleaned.length > 80 ? 80 : cleaned.length);
  }

  Future<Directory> _firmwareLibraryDirectory() async {
    final installDir = Directory(p.dirname(Platform.resolvedExecutable));
    final preferred = Directory(p.join(installDir.path, 'Firmware'));
    try {
      await preferred.create(recursive: true);
      final probe = File(p.join(preferred.path, '.write_test'));
      await probe.writeAsString('ok');
      await probe.delete();
      return preferred;
    } catch (_) {
      final local = Platform.environment['LOCALAPPDATA'] ??
          Platform.environment['USERPROFILE'] ?? Directory.systemTemp.path;
      final fallback = Directory(p.join(local, 'FlasherPro', 'Firmware'));
      await fallback.create(recursive: true);
      return fallback;
    }
  }

  String _payloadDumperExecutable() =>
      p.join(p.dirname(Platform.resolvedExecutable), 'payload-dumper-go.exe');

  String _firmwareSectionFor(String name) {
    const bootloader = ['preloader', 'lk', 'lk2', 'abl', 'xbl', 'xbl_config', 'sbl',
      'sbl1', 'tz', 'tee', 'trustzone', 'rpm', 'hyp', 'devcfg', 'keymaster',
      'cmnlib', 'mcupm', 'sspm', 'spmfw', 'scp', 'gz', 'dpm', 'md1img', 'logo'];
    const critical = ['boot', 'vendor_boot', 'init_boot', 'recovery', 'vbmeta',
      'dtbo', 'super', 'metadata', 'misc', 'persist', 'para', 'expdb', 'frp',
      'nvram', 'nvdata', 'protect1', 'protect2'];
    final stem = p.basenameWithoutExtension(name).toLowerCase().replaceAll(RegExp(r'_[ab]$'), '');
    if (bootloader.any((part) => stem == part || stem.startsWith('${part}_'))) return 'bootloader';
    if (critical.any((part) => stem == part || stem.startsWith('${part}_'))) return 'critical';
    return 'system';
  }

  Future<void> _refreshSavedFirmwares() async {
    final root = await _firmwareLibraryDirectory();
    final entries = await root.list(followLinks: false)
        .where((entity) => entity is Directory && !p.basename(entity.path).startsWith('.'))
        .cast<Directory>().toList();
    entries.sort((a, b) => p.basename(a.path).toLowerCase().compareTo(p.basename(b.path).toLowerCase()));
    if (mounted) setState(() => _savedFirmwares = entries);
  }

  Future<void> _openDirectory(String path) async {
    try {
      if (Platform.isWindows) {
        await Process.start('explorer.exe', [path], mode: ProcessStartMode.detached);
      } else if (Platform.isMacOS) {
        await Process.start('open', [path], mode: ProcessStartMode.detached);
      } else {
        await Process.start('xdg-open', [path], mode: ProcessStartMode.detached);
      }
    } catch (error) { _writeLog('Could not open folder: $error'); }
  }

  Future<void> _deleteFirmware(Directory firmware) async {
    final name = p.basename(firmware.path);
    final confirmed = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
      title: const Text('Delete unpacked firmware?'),
      content: Text('Permanently delete "$name" and all extracted images? This cannot be undone.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
      ],
    ));
    if (confirmed != true) return;
    try {
      await firmware.delete(recursive: true);
      if (_activeFirmwareDirectory == firmware.path) _activeFirmwareDirectory = null;
      await _refreshSavedFirmwares();
      _writeLog('Deleted unpacked firmware: $name');
    } catch (error) { _writeLog('Could not delete $name: $error'); }
  }

  String? _platformToolsDirectory() {
    final executableDirectory = p.dirname(Platform.resolvedExecutable);
    final candidates = <String>[
      p.join(executableDirectory, 'platform-tools'),
      p.join(Directory.current.path, 'platform-tools'),
    ];
    for (final candidate in candidates) {
      if (File(p.join(candidate, 'fastboot.exe')).existsSync()) {
        return candidate;
      }
    }
    return null;
  }

  Future<void> _openPlatformTools() async {
    if (!Platform.isWindows) {
      _writeLog('The interactive Platform Tools terminal is available on Windows.');
      return;
    }
    final directory = _platformToolsDirectory();
    final workingDirectory = directory ?? Directory.current.path;
    try {
      // Detach CMD from the GUI process so Windows opens a separate console
      // window instead of inheriting Flutter's hidden GUI console.
      await Process.start(
        Platform.environment['COMSPEC'] ?? r'C:\Windows\System32\cmd.exe',
        ['/c', 'start', '"FlasherPro Platform Tools"', 'cmd.exe', '/K', 'cd /d "$workingDirectory"'],
        workingDirectory: workingDirectory,
        mode: ProcessStartMode.detached,
        runInShell: false,
      );
      _writeLog(directory == null
          ? 'Opened Command Prompt. Platform Tools were not found beside the app; commands require tools on PATH.'
          : 'Opened Platform Tools CMD in $directory');
    } catch (error) {
      _writeLog('Could not open Command Prompt: $error');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open CMD. Check Windows security settings and try again.')),
        );
      }
    }
  }

  Future<void> _chooseFirmwareArchive() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['zip'],
      dialogTitle: 'Select a firmware ZIP archive',
    );
    if (result == null || result.files.single.path == null) return;
    setState(() => _firmwareArchive = result.files.single.path);
    _writeLog('Selected archive: ${p.basename(_firmwareArchive!)}');
  }

  Future<void> _stopUnpack() async {
    if (!_busy) return;
    setState(() { _cancelUnpack = true; _unpackStatus = 'Stopping and cleaning temporary files…'; });
    _payloadProcess?.kill(ProcessSignal.sigterm);
    _writeLog('Stop requested; cleaning temporary payload and partial output.');
  }

  Future<void> _extractFirmware() async {
    final archivePath = _firmwareArchive;
    if (archivePath == null) {
      _writeLog('Select a firmware ZIP archive first.');
      return;
    }
    final enteredName = _firmwareNameController.text.trim();
    final safeName = _safeFolderName(enteredName.isEmpty
        ? p.basenameWithoutExtension(archivePath) : enteredName);
    final library = await _firmwareLibraryDirectory();
    final destination = Directory(p.join(library.path, safeName));
    if (await destination.exists()) {
      _writeLog('Firmware folder "$safeName" already exists; use a different name or delete it first.');
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('That firmware folder already exists. Choose another name.')));
      return;
    }

    setState(() { _busy = true; _cancelUnpack = false; _unpackProgress = 0; _unpackStatus = 'Preparing temporary workspace…'; });
    Directory? tempRoot;
    var succeeded = false;
    try {
      await destination.create(recursive: true);
      final tempParent = Directory(p.join(library.path, '.temp'));
      await tempParent.create(recursive: true);
      tempRoot = await tempParent.createTemp('unpack_');
      final zipWorkspace = Directory(p.join(tempRoot.path, 'zip'));
      await zipWorkspace.create(recursive: true);
      setState(() => _unpackStatus = 'Reading ZIP archive…');
      final bytes = await File(archivePath).readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);
      final payloadEntries = archive.where((entry) =>
          entry.isFile && p.basename(entry.name).toLowerCase() == 'payload.bin').toList();
      if (payloadEntries.isEmpty) {
        throw const FormatException('This ZIP does not contain payload.bin. Only Android OTA ZIP packages with payload.bin are supported.');
      }

      var processed = 0;
      final payloadFiles = <File>[];
      for (final entry in archive) {
        if (_cancelUnpack) throw const _UnpackCancelled();
        final target = p.normalize(p.join(zipWorkspace.path, entry.name));
        if (!p.isWithin(zipWorkspace.path, target)) {
          _writeLog('Skipped unsafe ZIP entry: ${entry.name}');
          continue;
        }
        if (entry.isFile) {
          final file = File(target);
          await file.parent.create(recursive: true);
          final data = entry.readBytes();
          if (data != null) {
            await file.writeAsBytes(data, flush: false);
            if (p.basename(entry.name).toLowerCase() == 'payload.bin') payloadFiles.add(file);
          }
        } else {
          await Directory(target).create(recursive: true);
        }
        processed++;
        if (mounted) setState(() {
          _unpackProgress = archive.isEmpty ? 0.08 : 0.08 * processed / archive.length;
          _unpackStatus = 'Extracting ZIP: $processed/${archive.length} entries';
        });
      }

      final dumper = _payloadDumperExecutable();
      if (!await File(dumper).exists()) {
        throw FileSystemException('Bundled payload-dumper-go.exe was not found beside FlasherPro.', dumper);
      }
      final rawOutput = Directory(p.join(tempRoot.path, 'payload-images'));
      await rawOutput.create(recursive: true);
      final payload = payloadFiles.first;
      if (mounted) setState(() { _unpackProgress = 0.1; _unpackStatus = 'Unpacking Android payload…'; });
      _writeLog('Starting payload-dumper-go: ${p.basename(payload.path)}');
      final args = ['-o', rawOutput.path, payload.path];
      final process = await Process.start(
        dumper, args,
        workingDirectory: p.dirname(dumper),
        environment: {
          ...Platform.environment,
          'PATH': '${p.dirname(dumper)};${Platform.environment['PATH'] ?? ''}',
        },
        runInShell: false,
      );
      _payloadProcess = process;
      final outputLines = <String>[];
          process.stdout.transform(const SystemEncoding().decoder).transform(const LineSplitter()).listen((line) {
        outputLines.add(line);
        _writeLog(line);
        final match = RegExp(r'(\d{1,3})\s*%').firstMatch(line);
        if (match != null) {
          final percent = (int.tryParse(match.group(1)!) ?? 0).clamp(0, 100);
          if (mounted) setState(() {
            _unpackProgress = 0.1 + percent / 100 * 0.85;
            _unpackStatus = 'Payload extraction: $percent%';
          });
        } else if (mounted) {
          setState(() => _unpackStatus = line.length > 72 ? '${line.substring(0, 69)}…' : line);
        }
      });
      process.stderr.transform(const SystemEncoding().decoder).transform(const LineSplitter()).listen((line) {
        outputLines.add(line);
        _writeLog('payload-dumper-go: $line');
      });
      final exitCode = await process.exitCode;
      _payloadProcess = null;
      if (_cancelUnpack) throw const _UnpackCancelled();
      if (exitCode != 0) {
        throw ProcessException(dumper, args, 'payload-dumper-go exited with code $exitCode. ${outputLines.take(10).join(' | ')}', exitCode);
      }
      final images = await rawOutput.list(recursive: true, followLinks: false)
          .where((entity) => entity is File && p.extension(entity.path).toLowerCase() == '.img')
          .cast<File>().toList();
      if (images.isEmpty) throw const FormatException('payload-dumper-go finished but no .img images were created.');

      final counts = <String, int>{'bootloader': 0, 'critical': 0, 'system': 0};
      for (final section in counts.keys) {
        await Directory(p.join(destination.path, section)).create(recursive: true);
      }
      for (final image in images) {
        final section = _firmwareSectionFor(p.basename(image.path));
        final sectionDir = Directory(p.join(destination.path, section));
        await sectionDir.create(recursive: true);
        await image.copy(p.join(sectionDir.path, p.basename(image.path)));
        counts[section] = counts[section]! + 1;
      }
      await File(p.join(destination.path, 'firmware-info.txt')).writeAsString(
        'Source ZIP: ${p.basename(archivePath)}\n'
        'Created: ${DateTime.now().toIso8601String()}\n'
        'Total images: ${images.length}\n'
        'Bootloader: ${counts['bootloader']}\nCritical: ${counts['critical']}\nSystem: ${counts['system']}\n');
      succeeded = true;
      if (mounted) setState(() {
        _activeFirmwareDirectory = destination.path;
        _unpackProgress = 1;
        _unpackStatus = 'Complete — ${images.length} images unpacked';
      });
      await _refreshSavedFirmwares();
      _writeLog('Unpack complete: ${images.length} images saved to ${destination.path}');
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Unpacked ${images.length} images into "$safeName".')));
    } on _UnpackCancelled {
      _writeLog('Unpack cancelled; temporary files and partial output removed.');
      _images.clear();
      _selectedImages.clear();
      if (mounted) setState(() { _unpackProgress = 0; _unpackStatus = 'Cancelled — temporary data removed'; });
    } catch (error) {
      _writeLog('Firmware unpack failed: $error');
      if (mounted) {
        setState(() => _unpackStatus = 'Unpack failed');
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Unpack failed: $error')));
      }
    } finally {
      _payloadProcess = null;
      if (tempRoot != null && await tempRoot.exists()) {
        try { await tempRoot.delete(recursive: true); }
        catch (error) { _writeLog('Temporary cleanup warning: $error'); }
      }
      if (!succeeded && await destination.exists()) {
        try { await destination.delete(recursive: true); }
        catch (error) { _writeLog('Failed-output cleanup warning: $error'); }
      }
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _chooseImages() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['img'],
      allowMultiple: true,
      dialogTitle: 'Select firmware image files',
    );
    if (result == null) return;
    final files = result.files
        .where((file) => file.path != null)
        .map((file) => File(file.path!))
        .toList();
    setState(() {
      _images
        ..clear()
        ..addAll(files);
      _selectedImages
        ..clear()
        ..addAll(files.map((file) => file.path));
    });
    _writeLog('Loaded ${files.length} image file(s) for review.');
  }

  Future<String?> _findFastboot() async {
    final bundledDirectory = _platformToolsDirectory();
    if (bundledDirectory != null) return p.join(bundledDirectory, 'fastboot.exe');
    return 'fastboot';
  }

  Future<void> _checkDevice() async {
    final fastboot = await _findFastboot();
    try {
      final result = await Process.run(fastboot!, ['devices']);
      final output = '${result.stdout}'.trim();
      final errors = '${result.stderr}'.trim();
      _writeLog(output.isEmpty ? 'No Fastboot device detected.' : 'Connected device(s): $output');
      if (errors.isNotEmpty) _writeLog(errors);
    } catch (error) {
      _writeLog('Could not run Fastboot. Check Platform Tools installation: $error');
    }
  }

  Future<void> _flashSelected() async {
    final selected = _images
        .where((file) => _selectedImages.contains(file.path))
        .where((file) => !_skipPreloaderRaw || p.basenameWithoutExtension(file.path).toLowerCase() != 'preloader_raw')
        .toList();
    final skippedPreloader = _skipPreloaderRaw && _images.any((file) =>
        _selectedImages.contains(file.path) && p.basenameWithoutExtension(file.path).toLowerCase() == 'preloader_raw');
    if (skippedPreloader) {
      _writeLog('Safety option enabled: preloader_raw.img will be skipped.');
    }
    if (selected.isEmpty) {
      _writeLog('Select at least one image before starting a flash.');
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Confirm firmware flash'),
        content: Text(
          'FlasherPro will flash ${selected.length} selected image(s) to partitions matching their filenames. '
          'Verify the device model and partition names before continuing. This operation can make a device unbootable if the images are incorrect.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _busy = true);
    try {
      final fastboot = await _findFastboot();
      final deviceResult = await Process.run(fastboot!, ['devices']);
      if ('${deviceResult.stdout}'.trim().isEmpty) {
        _writeLog('No Fastboot device detected. Flash cancelled.');
        return;
      }
      for (final image in selected) {
        final partition = p.basenameWithoutExtension(image.path);
        _writeLog('Running: fastboot flash $partition "${image.path}"');
        final result = await Process.run(
          fastboot,
          ['flash', partition, image.path],
          runInShell: false,
        );
        final stdout = '${result.stdout}'.trim();
        final stderr = '${result.stderr}'.trim();
        if (stdout.isNotEmpty) _writeLog(stdout);
        if (stderr.isNotEmpty) _writeLog(stderr);
        if (result.exitCode != 0) {
          _writeLog('Flash failed for $partition (exit code ${result.exitCode}). Remaining images were not flashed.');
          return;
        }
        _writeLog('Flashed $partition successfully.');
      }
      _writeLog('Selected images finished successfully.');
    } catch (error) {
      _writeLog('Fastboot operation failed: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          const Positioned.fill(child: DecoratedBox(decoration: BoxDecoration(color: Color(0xFF101114)))),
          Positioned(top: -180, left: 180, child: _ambientGlow(const Color(0xFF386BFF), 420)),
          Positioned(top: -130, right: 80, child: _ambientGlow(const Color(0xFFFF476F), 360)),
          Positioned(bottom: -230, right: 240, child: _ambientGlow(const Color(0xFF8A4DFF), 460)),
          Row(
        children: [
          Container(
            width: 235,
            padding: const EdgeInsets.fromLTRB(18, 24, 14, 18),
            decoration: BoxDecoration(
              color: const Color(0xB815161A),
              border: const Border(right: BorderSide(color: Color(0x553C414D))),
              boxShadow: const [BoxShadow(color: Color(0x22000000), blurRadius: 28, offset: Offset(8, 0))],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(Icons.bolt_rounded, color: Color(0xFFB8F36B), size: 30),
                    SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'FLASHERPRO',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, letterSpacing: 1.2),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                const Text('FASTBOOT UTILITIES', style: TextStyle(color: Colors.white38, fontSize: 10, letterSpacing: 1.6)),
                const SizedBox(height: 34),
                _navItem(FlasherSection.extraTools, Icons.widgets_outlined, 'Extra Tools'),
                _navItem(FlasherSection.drivers, Icons.usb_rounded, 'Drivers'),
                _navItem(FlasherSection.unpacker, Icons.inventory_2_outlined, 'Firmware Unpacker'),
                _navItem(FlasherSection.flasher, Icons.memory_rounded, 'Firmware Flasher'),
                _navItem(FlasherSection.settings, Icons.settings_outlined, 'Settings'),
                const Spacer(),
                const Divider(color: Color(0xFF303239)),
                const Text('OPLUS DEVICE UTILITIES', style: TextStyle(color: Colors.white38, fontSize: 10, letterSpacing: 1)),
                const SizedBox(height: 6),
                const Text('Use firmware built for your exact model.', style: TextStyle(color: Colors.white54, fontSize: 11)),
              ],
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(30, 26, 30, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(_sectionTitle, style: const TextStyle(fontSize: 27, fontWeight: FontWeight.w700)),
                            const SizedBox(height: 5),
                            Text(
                              switch (_section) {
                                FlasherSection.extraTools => 'Quick access to Android utilities.',
                                FlasherSection.logcat => 'Stream, filter, and save Android device logs.',
                                FlasherSection.drivers => 'Install USB drivers and manage Windows driver packages.',
                                FlasherSection.unpacker => 'Extract payload images and manage saved firmware.',
                                FlasherSection.unpacker => 'Extract ZIP firmware packages to a folder you choose.',
                                FlasherSection.flasher => 'Review image files and flash selected partitions.',
                                FlasherSection.settings => 'Personalize FlasherPro and view creator information.',
                              },
                              style: const TextStyle(color: Colors.white54),
                            ),
                          ],
                        ),
                      ),
                      _statusPill(_busy ? 'WORKING' : 'READY', _busy),
                    ],
                  ),
                  const SizedBox(height: 24),
                  Expanded(
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 420),
                      reverseDuration: const Duration(milliseconds: 300),
                      switchInCurve: Curves.easeOutQuart,
                      switchOutCurve: Curves.easeInCubic,
                      transitionBuilder: (child, animation) => FadeTransition(
                        opacity: animation,
                        child: SlideTransition(
                          position: Tween<Offset>(
                            begin: const Offset(0.035, 0.008),
                            end: Offset.zero,
                          ).animate(animation),
                          child: child,
                        ),
                      ),
                      child: KeyedSubtree(
                        key: ValueKey(_section),
                        child: _sectionContent(),
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  _logPanel(),
                ],
              ),
            ),
          ),
        ],
      ),
        ],
      ),
    );
  }

  Widget _ambientGlow(Color color, double size) {
    return IgnorePointer(child: ImageFiltered(
      imageFilter: ImageFilter.blur(sigmaX: 75, sigmaY: 75),
      child: Container(width: size, height: size, decoration: BoxDecoration(shape: BoxShape.circle, color: color.withValues(alpha: 0.16))),
    ));
  }

  Widget _navItem(FlasherSection section, IconData icon, String label) {
    final selected = _section == section;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => setState(() => _section = section),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 320),
          curve: Curves.easeOutQuart,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
          decoration: BoxDecoration(
            color: selected ? const Color(0xFF282C23).withValues(alpha: 0.88) : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: selected ? const Color(0xFF48543A) : Colors.transparent),
          ),
          child: Row(
            children: [
              Icon(icon, size: 20, color: selected ? const Color(0xFFB8F36B) : Colors.white60),
              const SizedBox(width: 12),
              Expanded(child: Text(label, style: TextStyle(color: selected ? Colors.white : Colors.white70, fontWeight: selected ? FontWeight.w600 : FontWeight.normal))),
              if (selected) const Icon(Icons.chevron_right_rounded, size: 18, color: Color(0xFFB8F36B)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sectionContent() {
    return switch (_section) {
      FlasherSection.extraTools => _extraToolsPanel(),
      FlasherSection.logcat => _logcatPanel(),
      FlasherSection.drivers => _driversPanel(),
      FlasherSection.unpacker => _unpackerPanel(),
      FlasherSection.flasher => _flasherPanel(),
      FlasherSection.settings => _settingsPanel(),
    };
  }

  Widget _extraToolsPanel() {
    return Wrap(spacing: 16, runSpacing: 16, children: [
      _toolTile(Icons.terminal_rounded, 'Platform Tools', 'Open ADB / Fastboot CMD', _openPlatformTools),
      _toolTile(Icons.bug_report_outlined, 'Logcat', 'Live Android system logs', () => setState(() => _section = FlasherSection.logcat)),
    ]);
  }

  Widget _toolTile(IconData icon, String title, String subtitle, VoidCallback onTap) {
    final colors = switch (title) {
      'Platform Tools' => (const Color(0xFF69AFFF), const Color(0xFF34315C)),
      'Logcat' => (const Color(0xFFFFA044), const Color(0xFF57334C)),
      'Drivers' => (const Color(0xFF45D6A0), const Color(0xFF254B4C)),
      _ => (const Color(0xFFB8F36B), const Color(0xFF3D4B2E)),
    };
    return SizedBox(
      width: 225,
      height: 174,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
          child: Material(
            color: const Color(0xA822242B),
            child: InkWell(
              onTap: onTap,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 360),
                curve: Curves.easeOutQuart,
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [colors.$2.withValues(alpha: .70), const Color(0x7721242B), const Color(0x3321242B)]),
                  border: Border.all(color: Colors.white.withValues(alpha: .08)),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Container(width: 58, height: 58, decoration: BoxDecoration(color: colors.$1.withValues(alpha: .10), borderRadius: BorderRadius.circular(15), border: Border.all(color: colors.$1.withValues(alpha: .24))), child: Icon(icon, size: 32, color: colors.$1)),
                  const Spacer(),
                  Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
                  const SizedBox(height: 4),
                  Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white60, fontSize: 11)),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }

  String get _adbExecutable {
    final dir = _platformToolsDirectory();
    return dir == null ? 'adb' : p.join(dir, Platform.isWindows ? 'adb.exe' : 'adb');
  }

  Future<void> _startLogcat() async {
    if (_logcatRunning) return;
    try {
      final process = await Process.start(_adbExecutable, ['logcat', '-b', _logcatBuffer, '*:${_logcatLevel.substring(0, 1)}'], runInShell: false);
      _logcatProcess = process;
      setState(() => _logcatRunning = true);
      process.stdout.transform(const SystemEncoding().decoder).transform(const LineSplitter()).listen((line) {
        if (!mounted) return;
        setState(() {
          _logcatLines.add(line);
          if (_logcatLines.length > 5000) _logcatLines.removeRange(0, 500);
        });
      });
      process.stderr.transform(const SystemEncoding().decoder).transform(const LineSplitter()).listen((line) { if (mounted) _writeLog('adb: $line'); });
      process.exitCode.then((code) { if (mounted) setState(() => _logcatRunning = false); _writeLog('Logcat stopped (exit $code).'); });
    } catch (error) {
      setState(() => _logcatRunning = false);
      _writeLog('Could not start Logcat: $error');
    }
  }

  Future<void> _stopLogcat() async {
    _logcatProcess?.kill();
    _logcatProcess = null;
    if (mounted) setState(() => _logcatRunning = false);
  }

  List<String> get _filteredLogcat => _logcatLines.where((line) => line.toLowerCase().contains(_logcatSearch.toLowerCase())).toList();

  Future<void> _saveLogcat() async {
    final path = await FilePicker.platform.saveFile(dialogTitle: 'Save Logcat output', fileName: 'flasherpro-logcat.txt', type: FileType.custom, allowedExtensions: ['txt', 'log']);
    if (path == null) return;
    await File(path).writeAsString(_filteredLogcat.join('\n'));
    _writeLog('Saved Logcat to $path');
  }

  Widget _logcatPanel() {
    return Column(children: [
      Card(child: Padding(padding: const EdgeInsets.all(10), child: Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        _statusPill(_logcatRunning ? 'STREAMING' : 'STOPPED', _logcatRunning),
        FilledButton(onPressed: _logcatRunning ? _stopLogcat : _startLogcat, child: Text(_logcatRunning ? 'Stop' : 'Start')),
        const Text('Buffer', style: TextStyle(color: Colors.white60, fontSize: 12)),
        DropdownButton<String>(value: _logcatBuffer, items: const ['main','system','radio','events','crash','all'].map((v) => DropdownMenuItem(value: v, child: Text(v))).toList(), onChanged: _logcatRunning ? null : (v) => setState(() => _logcatBuffer = v ?? 'main')),
        const Text('Level', style: TextStyle(color: Colors.white60, fontSize: 12)),
        DropdownButton<String>(value: _logcatLevel, items: const ['Verbose','Debug','Info','Warn','Error','Fatal'].map((v) => DropdownMenuItem(value: v, child: Text(v))).toList(), onChanged: _logcatRunning ? null : (v) => setState(() => _logcatLevel = v ?? 'Verbose')),
        SizedBox(width: 160, child: TextField(decoration: const InputDecoration(hintText: 'Search logs…', isDense: true), onChanged: (v) => setState(() => _logcatSearch = v))),
        OutlinedButton(onPressed: () => setState(_logcatLines.clear), child: const Text('Clear')),
        OutlinedButton(onPressed: _saveLogcat, child: const Text('Save')),
      ]))),
      const SizedBox(height: 8),
      Expanded(child: Card(child: _filteredLogcat.isEmpty
        ? Center(child: Text(_logcatRunning ? 'Waiting for log entries…' : 'Press Start to stream logcat', style: const TextStyle(color: Colors.white54)))
        : ListView.builder(itemCount: _filteredLogcat.length, itemBuilder: (context, i) => Padding(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2), child: SelectableText(_filteredLogcat[i], style: const TextStyle(fontFamily: 'Consolas', fontSize: 11, color: Colors.white70)))))),
    ]);
  }

  Future<void> _refreshDrivers() async {
    try {
      final result = await Process.run('pnputil.exe', ['/enum-drivers'], runInShell: false);
      final output = '${result.stdout}\n${result.stderr}'.trim();
      final packages = RegExp(r'Published Name:\s*(oem\d+\.inf)', caseSensitive: false).allMatches(output).map((m) => m.group(1)!).toList();
      setState(() {
        _driverPackages..clear()..addAll(packages);
        _driverOutput = output.isEmpty ? 'No driver information returned.' : output;
        if (_selectedDriver != null && !_driverPackages.contains(_selectedDriver)) _selectedDriver = null;
      });
      _writeLog('Loaded ${packages.length} published driver package(s).');
    } catch (error) {
      setState(() => _driverOutput = 'Could not enumerate drivers: $error');
    }
  }

  Future<void> _installDriver() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['inf'], dialogTitle: 'Select USB driver INF');
    final path = result?.files.single.path;
    if (path == null) return;
    final escaped = path.replaceAll("'", "''");
    final script = "Start-Process -FilePath 'pnputil.exe' -ArgumentList @('/add-driver', '$escaped', '/install') -Verb RunAs -Wait";
    try {
      final proc = await Process.run('powershell.exe', ['-NoProfile','-Command',script]);
      setState(() => _driverOutput = 'Driver install request finished.\n${proc.stdout}\n${proc.stderr}');
      _writeLog('Driver install command returned exit code ${proc.exitCode}. Refresh the list to verify.');
    } catch (error) {
      setState(() => _driverOutput = 'Driver installation failed: $error');
    }
  }

  Future<void> _removeDriver() async {
    final driver = _selectedDriver;
    if (driver == null) return;
    final confirmed = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
      title: const Text('Remove driver package?'),
      content: Text('This removes $driver from the Windows driver store and may affect connected devices. Continue only if you recognize this package.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Remove')),
      ],
    ));
    if (confirmed != true) return;
    try {
      final script = "Start-Process -FilePath 'pnputil.exe' -ArgumentList @('/delete-driver', '$driver', '/uninstall') -Verb RunAs -Wait";
      final proc = await Process.run('powershell.exe', ['-NoProfile','-Command',script]);
      _writeLog('Driver removal command for $driver returned exit code ${proc.exitCode}.');
      await _refreshDrivers();
    } catch (error) {
      setState(() => _driverOutput = 'Driver removal failed: $error');
    }
  }

  Widget _driversPanel() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Card(child: Padding(padding: EdgeInsets.all(16), child: Text('Install USB/ADB drivers or manage published Windows driver packages. Driver changes require administrator approval. Removing the wrong package can affect other devices.', style: TextStyle(color: Colors.white70, height: 1.4)))),
      const SizedBox(height: 12),
      Expanded(child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SizedBox(width: 230, child: Card(child: Padding(padding: const EdgeInsets.all(14), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('Operation with Drivers', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 14),
          FilledButton.icon(onPressed: _installDriver, icon: const Icon(Icons.download_rounded), label: const Text('Install INF')),
          const SizedBox(height: 8),
          OutlinedButton.icon(onPressed: _refreshDrivers, icon: const Icon(Icons.refresh_rounded), label: const Text('List installed')),
          const SizedBox(height: 18),
          const Text('Published driver package', style: TextStyle(color: Colors.white60, fontSize: 12)),
          const SizedBox(height: 6),
          DropdownButtonFormField<String>(initialValue: _selectedDriver, isExpanded: true, decoration: const InputDecoration(isDense: true), items: _driverPackages.map((v) => DropdownMenuItem(value: v, child: Text(v))).toList(), onChanged: (v) => setState(() => _selectedDriver = v)),
          const SizedBox(height: 8),
          OutlinedButton.icon(onPressed: _selectedDriver == null ? null : _removeDriver, icon: const Icon(Icons.delete_outline_rounded), label: const Text('Remove selected')),
          const Spacer(),
          OutlinedButton(onPressed: _refreshDrivers, child: const Text('Refresh list')),
        ])))),
        const SizedBox(width: 12),
        Expanded(child: Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [const Text('Log Output Window', style: TextStyle(fontWeight: FontWeight.w700)), const Spacer(), TextButton(onPressed: () => setState(() => _driverOutput = ''), child: const Text('Clear'))]),
          Expanded(child: SingleChildScrollView(child: SelectableText(_driverOutput ?? 'Click “List installed” to inspect driver packages.', style: const TextStyle(fontFamily: 'Consolas', fontSize: 11, color: Colors.white70)))),
        ])))),
      ])),
    ]);
  }


  Widget _settingsPanel() {
    return SingleChildScrollView(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Personalization', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        const SizedBox(height: 12),
        _settingsRow(Icons.palette_outlined, 'App theme', 'Select which app theme to display',
          DropdownButton<String>(
            value: widget.appTheme, underline: const SizedBox.shrink(),
            items: const ['Dark', 'System', 'Light'].map((v) => DropdownMenuItem(value: v, child: Text(v))).toList(),
            onChanged: (v) => widget.onThemeChanged(v ?? 'Dark'),
          )),
        const SizedBox(height: 8),
        _settingsRow(Icons.zoom_in_rounded, 'UI Scale', 'Adjust interface size for your display',
          DropdownButton<String>(
            value: widget.uiScale, underline: const SizedBox.shrink(),
            items: const ['80%', '90%', '100%', '110%', '125%', '140%'].map((v) => DropdownMenuItem(value: v, child: Text(v))).toList(),
            onChanged: (v) => widget.onScaleChanged(v ?? '100%'),
          )),
        const SizedBox(height: 26),
        const Text('About this tool', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        const SizedBox(height: 12),
        ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
            child: Container(
              decoration: BoxDecoration(
                color: const Color(0xAA252830),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.white.withValues(alpha: .08)),
              ),
              child: Column(children: [
                ListTile(
                  leading: const Icon(Icons.bolt_rounded, color: Color(0xFFB8F36B), size: 30),
                  title: const Text('FlasherPro', style: TextStyle(fontWeight: FontWeight.w700)),
                  subtitle: const Text('Version 1.0.0'),
                  trailing: IconButton(
                    tooltip: _aboutExpanded ? 'Collapse' : 'Expand',
                    onPressed: () => setState(() => _aboutExpanded = !_aboutExpanded),
                    icon: AnimatedRotation(turns: _aboutExpanded ? .5 : 0, duration: const Duration(milliseconds: 260), child: const Icon(Icons.expand_more_rounded)),
                  ),
                ),
                AnimatedCrossFade(
                  duration: const Duration(milliseconds: 320),
                  sizeCurve: Curves.easeOutQuart,
                  crossFadeState: _aboutExpanded ? CrossFadeState.showFirst : CrossFadeState.showSecond,
                  firstChild: Column(children: [
                    const Divider(height: 1, color: Color(0x22FFFFFF)),
                    _creditRow(Icons.person_rounded, 'Created by', 'almightygodthor', 'https://github.com/almightygodthor'),
                    const Divider(height: 1, color: Color(0x22FFFFFF)),
                    _creditRow(Icons.send_rounded, 'Community & Support', 'Realme GT Neo 3 Discussion', 'https://t.me/RealmeGTNeo3discussion'),
                    const Divider(height: 1, color: Color(0x22FFFFFF)),
                    _creditRow(Icons.code_rounded, 'Source code', 'FlasherPro on GitHub', 'https://github.com/almightygodthor/oplus_flasherpro'),
                  ]),
                  secondChild: const SizedBox(width: double.infinity),
                ),
              ]),
            ),
          ),
        ),
      ]),
    );
  }

  Widget _settingsRow(IconData icon, String title, String subtitle, Widget control) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xAA252830),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha: .06)),
      ),
      child: Row(children: [
        Icon(icon, color: Colors.white70, size: 22),
        const SizedBox(width: 16),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
          Text(subtitle, style: const TextStyle(color: Colors.white60, fontSize: 12)),
        ])),
        SizedBox(width: 150, child: Align(alignment: Alignment.centerRight, child: control)),
      ]),
    );
  }

  Widget _creditRow(IconData icon, String title, String subtitle, String url) {
    return InkWell(
      onTap: () async {
        try {
          if (Platform.isWindows) {
            await Process.start('rundll32.exe', ['url.dll,FileProtocolHandler', url], mode: ProcessStartMode.detached);
          } else if (Platform.isMacOS) {
            await Process.start('open', [url], mode: ProcessStartMode.detached);
          } else if (Platform.isLinux) {
            await Process.start('xdg-open', [url], mode: ProcessStartMode.detached);
          }
        } catch (error) {
          _writeLog('Could not open link: $error');
        }
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        child: Row(children: [
          Container(width: 34, height: 34, decoration: BoxDecoration(color: const Color(0xFF8D75FF).withValues(alpha: .15), shape: BoxShape.circle), child: Icon(icon, size: 18, color: const Color(0xFF9C8AFF))),
          const SizedBox(width: 14),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
            Text(subtitle, style: const TextStyle(color: Colors.white60, fontSize: 12)),
          ])),
          const Icon(Icons.open_in_new_rounded, size: 16, color: Colors.white60),
          const SizedBox(width: 10),
          const Icon(Icons.chevron_right_rounded, size: 18, color: Colors.white60),
        ]),
      ),
    );
  }

  Widget _platformToolsPanel() {
    final directory = _platformToolsDirectory();
    return Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: 680,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
            child: Card(
              color: const Color(0xFF181A1F).withValues(alpha: 0.82),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.terminal_rounded, size: 38, color: Color(0xFFB8F36B)),
                    const SizedBox(height: 18),
                    const Text('Platform Tools Console', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 8),
                    const Text(
                      'Launch Command Prompt to run adb, fastboot, and other Android platform-tools commands manually.',
                      style: TextStyle(color: Colors.white60, height: 1.5),
                    ),
                    const SizedBox(height: 18),
                    _infoRow('Fastboot executable', directory == null ? 'Not detected' : p.join(directory, 'fastboot.exe')),
                    const SizedBox(height: 18),
                    FilledButton.icon(
                      onPressed: _busy ? null : _openPlatformTools,
                      icon: const Icon(Icons.open_in_new_rounded),
                      label: const Text('Open Platform Tools CMD'),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'If Platform Tools are not bundled, install them and add their folder to your system PATH.',
                      style: TextStyle(color: Colors.white38, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _unpackerPanel() {
    return SingleChildScrollView(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Card(child: Padding(padding: const EdgeInsets.all(20), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Firmware unpacker', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          const Text('Unpack Android OTA payload images with the bundled payload-dumper-go. ZIP and payload files are temporary and are removed after processing.', style: TextStyle(color: Colors.white60, height: 1.5)),
          const SizedBox(height: 18),
          _pathRow('Firmware ZIP', _firmwareArchive, 'Browse ZIP', _chooseFirmwareArchive),
          const SizedBox(height: 12),
          TextField(controller: _firmwareNameController, enabled: !_busy, decoration: const InputDecoration(labelText: 'Firmware folder name (optional)', hintText: 'Defaults to the ZIP filename', prefixIcon: Icon(Icons.drive_file_rename_outline))),
          const SizedBox(height: 16),
          Row(children: [
            Expanded(child: FilledButton.icon(onPressed: _busy ? null : _extractFirmware, icon: const Icon(Icons.inventory_2_outlined), label: Text(_busy ? 'Unpacking…' : 'Unpack firmware'))),
            const SizedBox(width: 10),
            OutlinedButton.icon(onPressed: _busy ? null : () async { final root = await _firmwareLibraryDirectory(); await _openDirectory(_activeFirmwareDirectory ?? root.path); }, icon: const Icon(Icons.folder_open_rounded), label: const Text('Open Destination Folder')),
          ]),
          const SizedBox(height: 18),
          Row(children: [
            Expanded(child: AnimatedSwitcher(duration: const Duration(milliseconds: 220), child: Text(_unpackStatus, key: ValueKey(_unpackStatus), maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white70, fontSize: 12)))),
            Text('${(_unpackProgress * 100).round()}%', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
          ]),
          const SizedBox(height: 8),
          ClipRRect(borderRadius: BorderRadius.circular(99), child: LinearProgressIndicator(value: _busy ? (_unpackProgress > 0 ? _unpackProgress : null) : _unpackProgress, minHeight: 8)),
          if (_busy) const Padding(padding: EdgeInsets.only(top: 10), child: Text('Other actions are disabled while unpacking.', style: TextStyle(color: Colors.white54, fontSize: 11))),
        ]))),
        const SizedBox(height: 16),
        Row(children: [
          const Expanded(child: Text('Saved firmware', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700))),
          IconButton(tooltip: 'Refresh list', onPressed: _busy ? null : _refreshSavedFirmwares, icon: const Icon(Icons.refresh_rounded)),
        ]),
        if (_savedFirmwares.isEmpty)
          const Card(child: Padding(padding: EdgeInsets.all(18), child: Text('No unpacked firmware yet. Completed firmware folders appear here.', style: TextStyle(color: Colors.white60))))
        else
          ..._savedFirmwares.map((firmware) => Card(child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Row(children: [
              const Icon(Icons.folder_copy_outlined, color: Color(0xFFB8F36B), size: 28),
              const SizedBox(width: 12),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(p.basename(firmware.path), style: const TextStyle(fontWeight: FontWeight.w700)),
                Text(firmware.path, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white38, fontSize: 11)),
              ])),
              IconButton(tooltip: 'Open firmware folder', onPressed: () => _openDirectory(firmware.path), icon: const Icon(Icons.folder_open_rounded)),
              IconButton(tooltip: 'Delete firmware', onPressed: _busy ? null : () => _deleteFirmware(firmware), icon: const Icon(Icons.delete_outline_rounded, color: Color(0xFFFF7777))),
            ]),
          ))),
      ]),
    );
  }

  Widget _flasherPanel() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Image selection', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                const Text('Select only images intended for your device. Each filename (without .img) is used as its partition name.', style: TextStyle(color: Colors.white60)),
                const SizedBox(height: 14),
                Row(
                  children: [
                    FilledButton.icon(
                      onPressed: _busy ? null : _chooseImages,
                      icon: const Icon(Icons.add_to_photos_outlined),
                      label: const Text('Select image files'),
                    ),
                    const SizedBox(width: 10),
                    OutlinedButton(onPressed: _images.isEmpty ? null : () => setState(() => _selectedImages.addAll(_images.map((file) => file.path))), child: const Text('Select all')),
                    const SizedBox(width: 8),
                    OutlinedButton(onPressed: _images.isEmpty ? null : () => setState(_selectedImages.clear), child: const Text('Deselect all')),
                    const Spacer(),
                    Text('${_selectedImages.length}/${_images.length} selected', style: const TextStyle(color: Colors.white60, fontSize: 12)),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('FLASHING OPTIONS', style: TextStyle(color: Colors.white54, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1.2)),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text('Skip preloader_raw.img', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                  subtitle: const Text('On by default for every flash session', style: TextStyle(color: Colors.white54, fontSize: 11)),
                  value: _skipPreloaderRaw,
                  activeThumbColor: const Color(0xFFB8F36B),
                  onChanged: _busy ? null : (value) => setState(() => _skipPreloaderRaw = value),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: Card(
            child: _images.isEmpty
                ? const Center(child: Text('No image files selected', style: TextStyle(color: Colors.white38)))
                : ListView.separated(
                    padding: const EdgeInsets.all(8),
                    itemCount: _images.length,
                    separatorBuilder: (_, __) => const Divider(height: 1, color: Color(0xFF2B2D33)),
                    itemBuilder: (context, index) {
                      final file = _images[index];
                      final partition = p.basenameWithoutExtension(file.path);
                      return CheckboxListTile(
                        value: _selectedImages.contains(file.path),
                        onChanged: _busy ? null : (checked) => setState(() {
                          if (checked == true) {
                            _selectedImages.add(file.path);
                          } else {
                            _selectedImages.remove(file.path);
                          }
                        }),
                        title: Text(partition, style: const TextStyle(fontWeight: FontWeight.w600)),
                        subtitle: Text(file.path, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white38, fontSize: 11)),
                        secondary: const Icon(Icons.insert_drive_file_outlined, color: Color(0xFFB8F36B)),
                        controlAffinity: ListTileControlAffinity.leading,
                      );
                    },
                  ),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            OutlinedButton.icon(onPressed: _busy ? null : _checkDevice, icon: const Icon(Icons.usb_rounded), label: const Text('Check device')),
            const Spacer(),
            FilledButton.icon(
              onPressed: _busy ? null : _flashSelected,
              icon: const Icon(Icons.flash_on_rounded),
              label: Text(_busy ? 'Flashing…' : 'Flash selected images'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _logPanel() {
    return Container(
      height: 135,
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
      decoration: BoxDecoration(
        color: const Color(0xFF0B0C0E),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF292B31)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.subject_rounded, size: 16, color: Color(0xFFB8F36B)),
              const SizedBox(width: 8),
              const Text('ACTIVITY LOG', style: TextStyle(fontSize: 10, letterSpacing: 1.5, fontWeight: FontWeight.w700)),
              const Spacer(),
              TextButton(
                onPressed: () => setState(_log.clear),
                child: const Text('Clear', style: TextStyle(fontSize: 11)),
              ),
            ],
          ),
          Expanded(
            child: _log.isEmpty
                ? const Align(alignment: Alignment.centerLeft, child: Text('Waiting for an operation…', style: TextStyle(color: Colors.white30, fontSize: 12)))
                : ListView.builder(
                    reverse: true,
                    itemCount: _log.length,
                    itemBuilder: (context, index) => Padding(
                      padding: const EdgeInsets.only(bottom: 3),
                      child: Text(_log[index], style: const TextStyle(fontFamily: 'Consolas', fontSize: 11, color: Colors.white70)),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _pathRow(String label, String? value, String action, VoidCallback onTap, {IconData? leading}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(color: Colors.white54, fontSize: 12)),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
                decoration: BoxDecoration(color: const Color(0xFF111216), borderRadius: BorderRadius.circular(10), border: Border.all(color: const Color(0xFF30333A))),
                child: Row(children: [
                  if (leading != null) ...[Icon(leading, size: 16, color: const Color(0xFFB8F36B)), const SizedBox(width: 8)],
                  Expanded(child: Text(value ?? 'Choose destination folder', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: value == null ? Colors.white30 : Colors.white70, fontSize: 12))),
                ]),
              ),
            ),
            const SizedBox(width: 10),
            OutlinedButton(onPressed: _busy ? null : onTap, child: Text(action)),
          ],
        ),
      ],
    );
  }

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 150, child: Text(label, style: const TextStyle(color: Colors.white54, fontSize: 12))),
          Expanded(
            child: Text(
              value,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              softWrap: true,
              style: const TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _statusPill(String text, bool active) {
    final color = active ? Colors.orangeAccent : const Color(0xFFB8F36B);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(30),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 6, height: 6, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
          const SizedBox(width: 7),
          Text(text, style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 1)),
        ],
      ),
    );
  }
}
