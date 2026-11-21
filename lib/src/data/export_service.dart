import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../api/api_client.dart';
import '../api/api_exception.dart';

/// The two formats the 1.5.0 server actually serves. There is no PDF export in
/// the route table; pretending otherwise would be a screen that always fails.
enum ExportFormat { json, zip }

class ExportCancelled implements Exception {
  const ExportCancelled();
}

class ExportFile {
  const ExportFile(this.path, this.bytes, this.format);
  final String path;
  final int bytes;
  final ExportFormat format;

  String get name => p.basename(path);

  String get mime => format == ExportFormat.zip ? 'application/zip' : 'application/json';
}

/// Downloads `GET /api/v1/export?format=…` to a temporary file.
///
/// The response is streamed, so a large account shows real progress and the
/// cancel button can stop reading; the server keeps building its answer until
/// the connection closes, which is the part a client cannot abort.
class ExportService {
  const ExportService({Future<Directory> Function()? directory}) : _directory = directory;

  /// Test seam: the plugin-backed temporary directory by default.
  final Future<Directory> Function()? _directory;

  Future<ExportFile> download(
    ApiClient client, {
    required ExportFormat format,
    void Function(int received, int total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final http.StreamedResponse response;
    try {
      response = await client.openStream('/api/v1/export', query: {'format': format.name});
    } on Object {
      rethrow;
    }
    if (response.statusCode >= 400) {
      final body = await response.stream.bytesToString();
      throw ApiException.fromBody(response.statusCode, body);
    }
    final total = response.contentLength ?? -1;
    final builder = BytesBuilder(copy: false);
    var received = 0;
    await for (final chunk in response.stream) {
      if (isCancelled?.call() == true) throw const ExportCancelled();
      builder.add(chunk);
      received += chunk.length;
      onProgress?.call(received, total);
    }
    final dir = await (_directory ?? getTemporaryDirectory)();
    final name = format == ExportFormat.zip ? 'opentodo-export.zip' : 'opentodo-export.json';
    final file = File(p.join(dir.path, name));
    await file.writeAsBytes(builder.takeBytes(), flush: true);
    return ExportFile(file.path, received, format);
  }
}
