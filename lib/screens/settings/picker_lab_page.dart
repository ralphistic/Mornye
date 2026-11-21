import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

/// Read-only diagnostic screen. None of its experiments change library state.
class PickerLabPage extends StatefulWidget {
  const PickerLabPage({super.key});

  @override
  State<PickerLabPage> createState() => _PickerLabPageState();
}

class _PickerLabPageState extends State<PickerLabPage> {
  static const _channel = MethodChannel('com.zarz.mornye/backend');
  String _log = '';
  String _status = 'Ready';
  bool _flutterPickerActive = false;
  int _flutterSerial = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    if (!Platform.isIOS) return;
    await _channel.invokeMethod<void>('pickerLabEnvironment');
    await _refresh();
  }

  Future<void> _refresh() async {
    try {
      final value = await _channel.invokeMethod<String>('pickerLabLogs') ?? '';
      if (mounted) setState(() => _log = value);
    } catch (error) {
      if (mounted) setState(() => _status = 'Log error: $error');
    }
  }

  Future<void> _event(String message) async {
    await _channel.invokeMethod<void>('pickerLabEvent', {'message': message});
  }

  Future<void> _start(String id) async {
    if (!Platform.isIOS) {
      setState(() => _status = 'iOS only');
      return;
    }
    if (id == 'E') {
      if (_flutterPickerActive) {
        setState(() => _status = 'E already active');
        return;
      }
      _flutterPickerActive = true;
      final serial = ++_flutterSerial;
      await _event('E begin file_picker.getDirectoryPath');
      unawaited(
        Future<void>.delayed(const Duration(seconds: 10), () async {
          if (_flutterPickerActive && _flutterSerial == serial) {
            await _event('E NO RESULT CALLBACK AFTER 10 SECONDS');
            await _refresh();
          }
        }),
      );
      try {
        final path = await FilePicker.getDirectoryPath();
        await _event(
          'E returned path=${path == null ? "null/cancel" : "non-null"}',
        );
        if (path != null) {
          try {
            final directory = Directory(path);
            final count = await directory.list(followLinks: false).length;
            await _event('E one-time enumeration succeeded entries=$count');
          } catch (error) {
            await _event('E enumeration error=$error');
          }
        }
      } catch (error) {
        await _event('E picker error=$error');
      } finally {
        _flutterPickerActive = false;
        await _refresh();
      }
      return;
    }
    try {
      final result = await _channel.invokeMethod<String>('pickerLabStart', {
        'id': id,
      });
      if (mounted) setState(() => _status = result ?? 'Picker requested');
    } catch (error) {
      await _event('$id invocation error=$error');
      if (mounted) setState(() => _status = '$id error: $error');
    }
    await _refresh();
  }

  Future<void> _clear() async {
    await _channel.invokeMethod<void>('pickerLabClear');
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final tests = <(String, String)>[
      ('A', 'Current isolated-window folder picker'),
      ('B', 'Root-controller folder picker'),
      ('C', 'SwiftUI fileImporter folder picker'),
      ('D', 'Native audio-file picker'),
      ('E', 'Flutter file_picker folder picker'),
    ];
    return Scaffold(
      appBar: AppBar(title: const Text('Picker Lab')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Diagnostic only. Nothing selected here is added to your library. '
            'Wait 10 seconds when a picker hangs. Force-close and reopen '
            'Mornye if necessary; the log survives restarts.',
          ),
          const SizedBox(height: 12),
          for (final (id, title) in tests)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: OutlinedButton(
                onPressed: () => _start(id),
                child: Text('$id · $title'),
              ),
            ),
          Text('Status: $_status'),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            children: [
              TextButton(onPressed: _refresh, child: const Text('Refresh log')),
              TextButton(
                onPressed: () async {
                  await _refresh();
                  await Clipboard.setData(ClipboardData(text: _log));
                  if (mounted) setState(() => _status = 'Log copied');
                },
                child: const Text('Copy'),
              ),
              TextButton(
                onPressed: () async {
                  await _refresh();
                  await SharePlus.instance.share(ShareParams(text: _log));
                },
                child: const Text('Share'),
              ),
              TextButton(onPressed: _clear, child: const Text('Clear log')),
            ],
          ),
          SelectableText(
            _log.isEmpty ? 'No diagnostic events yet.' : _log,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
        ],
      ),
    );
  }
}
