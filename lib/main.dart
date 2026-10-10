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

class FlasherProApp extends StatelessWidget {
  const FlasherProApp({super.key});

  @override
  Widget build(BuildContext context) {
    const accent = Color(0xFFB8F36B);
    return MaterialApp(
      title: 'FlasherPro',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF101114),
        colorScheme: ColorScheme.fromSeed(
          seedColor: accent,
          brightness: Brightness.dark,
          surface: const Color(0xFF181A1F),
        ),
        cardTheme: CardThemeData(
          color: const Color(0xCC20232B),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: Color(0xFF2A2D34)),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFF111216),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: Color(0xFF30333A)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: Color(0xFF30333A)),
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: accent,
            foregroundColor: const Color(0xFF101114),
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
        ),
      ),
      home: const FlasherHome(),
    );
  }
}

enum FlasherSection { extraTools, logcat, drivers, platformTools, unpacker, flasher }

class FlasherHome extends StatefulWidget {
  const FlasherHome({super.key});

  @override
  State<FlasherHome> createState() => _FlasherHomeState();
}

class _FlasherHomeState extends State<FlasherHome> {
  FlasherSection _section = FlasherSection.platformTools;
  String? _firmwareArchive;
  String? _outputDirectory;
  final List<File> _images = [];
  final Set<String> _selectedImages = {};
  final List<String> _log = [];
  bool _busy = false;
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

  String get _sectionTitle => switch (_section) {
        FlasherSection.extraTools => 'Extra Tools',
        FlasherSection.logcat => 'Logcat',
        FlasherSection.drivers => 'Drivers',
        FlasherSection.platformTools => 'Platform Tools',
        FlasherSection.unpacker => 'Firmware Unpacker',
        FlasherSection.flasher => 'Firmware Flasher',
      };

  void _writeLog(String message) {
    if (!mounted) return;
    setState(() {
      _log.insert(0, '[${DateTime.now().toLocal().toString().substring(11, 19)}] $message');
      if (_log.length > 120) _log.removeLast();
    });
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
        ['/K', 'cd /d "$workingDirectory"'],
        workingDirectory: workingDirectory,
        mode: ProcessStartMode.detached,
        runInShell: false,
      );
      _writeLog(directory == null
          ? 'Opened Command Prompt. Platform Tools were not found beside the app; install them or add them to PATH.'
          : 'Opened Command Prompt in $directory');
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

  Future<void> _chooseOutputDirectory() async {
    final directory = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Choose extraction destination',
    );
    if (directory == null) return;
    setState(() => _outputDirectory = directory);
  }

  Future<void> _extractFirmware() async {
    final archivePath = _firmwareArchive;
    final outputPath = _outputDirectory;
    if (archivePath == null || outputPath == null) {
      _writeLog('Select a ZIP archive and destination directory first.');
      return;
    }

    setState(() => _busy = true);
    try {
      final bytes = await File(archivePath).readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);
      final root = p.normalize(p.absolute(outputPath));
      var extracted = 0;
      for (final entry in archive) {
        final target = p.normalize(p.join(root, entry.name));
        if (target != root && !p.isWithin(root, target)) {
          _writeLog('Skipped unsafe archive path: ${entry.name}');
          continue;
        }
        if (entry.isFile) {
          final file = File(target);
          await file.parent.create(recursive: true);
          final data = entry.readBytes();
          if (data == null) continue;
          await file.writeAsBytes(data, flush: true);
          extracted++;
        } else {
          await Directory(target).create(recursive: true);
        }
      }
      _writeLog('Extraction completed: $extracted files written to $root');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Extracted $extracted files successfully.')),
        );
      }
    } catch (error) {
      _writeLog('Extraction failed: $error');
    } finally {
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
                _navItem(FlasherSection.platformTools, Icons.terminal_rounded, 'Platform Tools'),
                _navItem(FlasherSection.unpacker, Icons.inventory_2_outlined, 'Firmware Unpacker'),
                _navItem(FlasherSection.flasher, Icons.memory_rounded, 'Firmware Flasher'),
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
                                FlasherSection.platformTools => 'Open a ready-to-use Fastboot command window.',
                                FlasherSection.unpacker => 'Extract ZIP firmware packages to a folder you choose.',
                                FlasherSection.flasher => 'Review image files and flash selected partitions.',
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
      FlasherSection.platformTools => _platformToolsPanel(),
      FlasherSection.unpacker => _unpackerPanel(),
      FlasherSection.flasher => _flasherPanel(),
    };
  }

  Widget _extraToolsPanel() {
    return Wrap(spacing: 16, runSpacing: 16, children: [
      _toolTile(Icons.terminal_rounded, 'Platform Tools', 'Open ADB / Fastboot CMD', () => setState(() => _section = FlasherSection.platformTools)),
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
          DropdownButtonFormField<String>(value: _selectedDriver, isExpanded: true, decoration: const InputDecoration(isDense: true), items: _driverPackages.map((v) => DropdownMenuItem(value: v, child: Text(v))).toList(), onChanged: (v) => setState(() => _selectedDriver = v)),
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
      child: SizedBox(
        width: 760,
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Firmware archive', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                const Text('Choose a ZIP package and a destination directory. Encrypted OFP/OPLUS packages are not supported by ZIP extraction.', style: TextStyle(color: Colors.white60, height: 1.5)),
                const SizedBox(height: 20),
                _pathRow('Selected archive', _firmwareArchive, 'Browse ZIP', _chooseFirmwareArchive),
                const SizedBox(height: 12),
                _pathRow('Destination Folder', _outputDirectory, 'Browse folder', _chooseOutputDirectory, leading: Icons.folder_outlined),
                const SizedBox(height: 22),
                FilledButton.icon(
                  onPressed: _busy ? null : _extractFirmware,
                  icon: const Icon(Icons.folder_zip_outlined),
                  label: Text(_busy ? 'Please wait…' : 'Extract firmware'),
                ),
              ],
            ),
          ),
        ),
      ),
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
