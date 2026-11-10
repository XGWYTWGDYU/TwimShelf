import 'package:file_selector/file_selector.dart' show XFile;
import 'package:flutter/painting.dart';
import 'dart:io';
import 'dart:typed_data';

Future<Uint8List> readFileBytes(String path) => File(path).readAsBytes();

Future<bool> fileExists(String path) => File(path).exists();

Future<void> ensureDirectory(String path) async => Directory(path).create(recursive: true);

/// An image file of the core's, for an [Image].
ImageProvider localFileImage(String path) => FileImage(File(path));

/// A small text file's contents, or null when it does not exist.
Future<String?> readText(String path) async {
  final f = File(path);
  return await f.exists() ? f.readAsString() : null;
}

/// Writes a small text file whole (a crash leaves the old one or the new one, never half).
Future<void> writeText(String path, String text) async {
  final f = File(path);
  await f.parent.create(recursive: true);
  final tmp = File('$path.${DateTime.now().microsecondsSinceEpoch}.partial');
  await tmp.writeAsString(text, flush: true);
  await tmp.rename(path);
}

Future<void> movePath(String from, String to) async => File(from).rename(to);

Future<void> deletePath(String path) async {
  final t = await FileSystemEntity.type(path);
  if (t == FileSystemEntityType.directory) {
    await Directory(path).delete(recursive: true);
  } else if (t != FileSystemEntityType.notFound) {
    await File(path).delete();
  }
}

/// The web build's server makes video posters; the apps make their own (video.dart).
Future<String?> serverPoster(String path, int side, {required bool whole}) async => null;

/// Only the web build asks the server for a smaller picture.
Future<Uint8List?> scaledImageBytes(String path, int side) async => null;

/// A file the user picked, as a path the core can read: where it is.
Future<String> pickedPath(XFile file) async => file.path;

/// The apps save into a folder the user chooses (or share the file): nothing to hand over.
Future<void> downloadToBrowser(String path) async {}
