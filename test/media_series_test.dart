import 'package:flutter_test/flutter_test.dart';
import 'package:orvex/features/library/domain/media_series.dart';
import 'package:orvex/features/folder_library/folder_library.dart';
import 'package:orvex/features/folder_library/folder_models.dart';
import 'package:orvex/features/player/domain/playback_engine.dart';

LocalMedia video(String name, {String root = 'root', String? id}) => LocalMedia(
  uri: Uri(scheme: 'orvex-folder', host: root, path: '/${id ?? name.hashCode}'),
  name: name,
  folderRoot: root,
  folderFile: id ?? name,
);
void main() {
  test('common release names become one series and sort by episode, preserving copies', () {
    final files = [
      video('[Fabre-RAW] Detective Conan 0610 [NetflixJP] [1080p].mkv'),
      video('[SBSUB] Detective Conan 0608 [WEBRIP].mp4'),
      video('[Other] Detective Conan 0608 [720p].mkv', id: 'other'),
    ];
    final groups = groupSeries(files);
    expect(groups.length, 1);
    expect(groups.single.identity.query, 'Detective Conan');
    expect(groups.single.media.map((m) => identifySeries(m).episode), [
      608,
      608,
      610,
    ]);
    expect(groups.single.media.map((m) => m.resumeKey).toSet().length, 3);
    expect(files.first.name, contains('Fabre-RAW'));
  });
  test('seasons, explicit years, separate sources and standalone films stay distinct', () {
    final groups = groupSeries([
      video('作品 S01E01.mkv'),
      video('作品 S02E01.mkv'),
      video('作品 (2023) - 01.mkv'),
      video('作品 (2024) - 01.mkv'),
      video('作品 S01E02.mkv', root: 'other-root'),
      video('我的旅行.mp4'),
      video('我的旅行.mp4', id: 'another-copy'),
    ]);
    expect(groups.length, 7);
  });
  test(
    'numeric episode folders use meaningful title context across range folders',
    () {
      final library = FolderLibrary();
      library.loading = false;
      library.roots.add(
        FolderRoot(id: 'root', name: '名侦探柯南', grant: '', location: ''),
      );
      library.entries.addAll([
        FolderEntry(
          id: 'one',
          rootId: 'root',
          path: 'TV/0001-0123/第1集.mp4',
          directory: false,
        ),
        FolderEntry(
          id: 'ten',
          rootId: 'root',
          path: 'TV/0001-0123/第10集.mp4',
          directory: false,
        ),
        FolderEntry(
          id: 'two',
          rootId: 'root',
          path: 'TV/0124-0173/第2集.mp4',
          directory: false,
        ),
      ]);
      library.changed();
      final group = library.series(const []).single;
      expect(group.identity.title, '名侦探柯南');
      expect(group.media.map((m) => library.identityFor(m).episode), [
        1,
        2,
        10,
      ]);
      expect(library.seriesMembers(group.media.last, const []).length, 3);
      library.dispose();
    },
  );
  test(
    'season-only file names and season folders keep their season context',
    () {
      final one = identifySeries(video('S01E01.mkv'), folderTitle: '作品');
      final two = identifySeries(video('S02E01.mkv'), folderTitle: '作品');
      expect(identifySeries(video('S02E01.mkv')).query, isEmpty);
      expect(one.key, isNot(two.key));
      expect(two.query, '作品 第2季');
      final fromFolder = identifySeries(
        video('第1集.mkv'),
        folderTitle: '作品',
        folderSeason: 2,
      );
      expect(fromFolder.key, two.key);
    },
  );
}
