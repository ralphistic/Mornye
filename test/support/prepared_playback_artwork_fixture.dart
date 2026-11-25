import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const preparedArtworkBackend = MethodChannel('com.zarz.mornye/backend');

Future<Uint8List> artworkPng(int index) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawColor(
    ui.Color.fromARGB(255, index, 255 - index, 77), ui.BlendMode.src,
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(64, 64);
  picture.dispose();
  try {
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
    return bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes);
  } finally {
    image.dispose();
  }
}

Future<void> writeArtworkFlac(File file, List<int> image) async {
  List<int> be32(int n) => [
    (n >> 24) & 255, (n >> 16) & 255, (n >> 8) & 255, n & 255,
  ];
  final picture = [
    ...be32(3), ...be32(9), ...ascii.encode('image/png'), ...be32(0),
    ...be32(64), ...be32(64), ...be32(32), ...be32(0),
    ...be32(image.length), ...image,
  ];
  // Keep the file length constant even when the picture PNG has a different
  // byte length, so an edit can deliberately preserve size and modification time.
  final padding = 4096 - picture.length;
  await file.writeAsBytes([
    ...ascii.encode('fLaC'), 0, 0, 0, 34, ...List<int>.filled(34, 0),
    6, ...be32(picture.length).skip(1), ...picture,
    0x81, ...be32(padding).skip(1), ...List<int>.filled(padding, 0),
    0xff, 0xf8,
  ]);
}

/// The test channel reads the actual fixture's PICTURE block. The Rust
/// integration fixture separately exercises the real native extractor.
Future<Uint8List> readArtworkPicture(String path) async {
  final bytes = await File(path).readAsBytes();
  final data = ByteData.sublistView(bytes);
  var offset = 46;
  int next32() {
    final value = data.getUint32(offset);
    offset += 4;
    return value;
  }
  next32(); // picture type
  final mime = next32();
  offset += mime;
  final description = next32();
  offset += description + 16;
  final length = next32();
  return Uint8List.sublistView(bytes, offset, offset + length);
}

void mockPreparedArtworkExtraction(List<String> calls) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(preparedArtworkBackend, (call) async {
    if (call.method != 'extractCoverToFile') {
      return jsonEncode({'error': 'not available in test'});
    }
    final args = call.arguments as Map;
    final source = args['audio_path'] as String;
    calls.add(source);
    await File(args['output_path'] as String).writeAsBytes(
      await readArtworkPicture(source),
    );
    return jsonEncode({'success': true});
  });
}

void clearPreparedArtworkExtraction() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(preparedArtworkBackend, null);
}
