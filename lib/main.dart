import 'dart:io';

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
          color: const Color(0xFF181A1F),
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

enum FlasherSection { platformTools, unpacker, flasher }

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

  String get _sectionTitle => switch (_section) {
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
    if (directory == null) {
      await Process.start(
        'cmd.exe',
        ['/K', 'where fastboot'],
        workingDirectory: Directory.current.path,
      );
      _writeLog('Opened Command Prompt. Platform Tools were not found beside the application; install them or add them to PATH.');
      return;
    }
    await Process.start(
      'cmd.exe',
      ['/K'],
      workingDirectory: directory,
      runInShell: true,
    );
    _writeLog('Opened Command Prompt in $directory');
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
        .toList();
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
      body: Row(
        children: [
          Container(
            width: 235,
            padding: const EdgeInsets.fromLTRB(18, 24, 14, 18),
            decoration: const BoxDecoration(
              color: Color(0xFF15161A),
              border: Border(right: BorderSide(color: Color(0xFF292B31))),
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
                  Expanded(child: _sectionContent()),
                  const SizedBox(height: 18),
                  _logPanel(),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _navItem(FlasherSection section, IconData icon, String label) {
    final selected = _section == section;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => setState(() => _section = section),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
          decoration: BoxDecoration(
            color: selected ? const Color(0xFF282C23) : Colors.transparent,
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
      FlasherSection.platformTools => _platformToolsPanel(),
      FlasherSection.unpacker => _unpackerPanel(),
      FlasherSection.flasher => _flasherPanel(),
    };
  }

  Widget _platformToolsPanel() {
    final directory = _platformToolsDirectory();
    return Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: 680,
        child: Card(
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
                const Text('Launch Command Prompt to run adb, fastboot, and other Android platform-tools commands manually.', style: TextStyle(color: Colors.white60, height: 1.5)),
                const SizedBox(height: 18),
                _infoRow('Fastboot executable', directory == null ? 'Not detected' : p.join(directory, 'fastboot.exe')),
                const SizedBox(height: 18),
                FilledButton.icon(
                  onPressed: _busy ? null : _openPlatformTools,
                  icon: const Icon(Icons.open_in_new_rounded),
                  label: const Text('Open Platform Tools CMD'),
                ),
                const SizedBox(height: 12),
                const Text('If Platform Tools are not bundled, install them and add their folder to your system PATH.', style: TextStyle(color: Colors.white38, fontSize: 12)),
              ],
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
                _pathRow('Output directory', _outputDirectory, 'Choose folder', _chooseOutputDirectory),
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

  Widget _pathRow(String label, String? value, String action, VoidCallback onTap) {
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
                child: Text(value ?? 'Nothing selected', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: value == null ? Colors.white30 : Colors.white70, fontSize: 12)),
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
