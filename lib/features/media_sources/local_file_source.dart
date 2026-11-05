import 'dart:io';

import 'package:file_selector/file_selector.dart';

import '../player/domain/playback_engine.dart';
import 'imported_file_store.dart';

class LocalFileSource {
  LocalFileSource({ImportedFileStore? imports})
    : imports = imports ?? ImportedFileStore();
  final ImportedFileStore imports;

  Future<LocalMedia?> pickVideo() async {
    final file = await openFile(
      acceptedTypeGroups: Platform.isIOS
          ? []
          : [
              const XTypeGroup(
                label: '视频',
                extensions: ['mp4', 'mkv', 'mov', 'm4v', 'webm', 'avi', 'ts'],
                uniformTypeIdentifiers: ['public.movie', 'public.video'],
              ),
            ],
    );
    if (file == null) return null;
    if (!ImportedFileStore.isVideoName(file.name)) {
      throw const FormatException('请选择 MP4、MKV、MOV、M4V、WebM、AVI 或 TS 视频');
    }
    if (Platform.isIOS || Platform.isAndroid) return imports.import(file);
    return LocalMedia(uri: _uri(file.path), name: file.name);
  }

  Future<LocalMedia?> pickSubtitle() async {
    // SRT/ASS may not have registered UTTypes on iOS. Validate after selection.
    final file = await openFile(
      acceptedTypeGroups: Platform.isIOS
          ? []
          : [
              const XTypeGroup(
                label: '字幕',
                extensions: ['srt', 'ass', 'ssa', 'vtt'],
                uniformTypeIdentifiers: ['public.text', 'public.data'],
              ),
            ],
    );
    if (file == null) return null;
    final extension = file.name.split('.').last.toLowerCase();
    if (!const ['srt', 'ass', 'ssa', 'vtt'].contains(extension)) {
      throw const FormatException('请选择 SRT、ASS、SSA 或 VTT 字幕文件');
    }
    if (Platform.isIOS || Platform.isAndroid) return imports.import(file);
    return LocalMedia(uri: _uri(file.path), name: file.name);
  }

  Uri _uri(String path) => path.startsWith('content://')
      ? Uri.parse(path)
      : Uri.file(path, windows: Platform.isWindows);
}
