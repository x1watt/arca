import 'dart:convert';
import 'dart:io';

import 'package:arca_core/src/library/library.dart';
import 'package:arca_core/src/library/sidecars.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('arca_sidecars'));
  tearDown(() => tmp.delete(recursive: true));

  Future<Library> openLib() => Library.open(File('${tmp.path}/collections.json'));

  test('names follow the file, and keep the extension when two files share a stem', () async {
    final d = await Directory('${tmp.path}/d').create();
    await File('${d.path}/Talk.webm').writeAsString('v');
    await File('${d.path}/Song.mp3').writeAsString('a');
    await File('${d.path}/Song.flac').writeAsString('b');
    final s = Sidecars();
    expect(s.manifestOf('${d.path}/Talk.webm'), '${d.path}/Talk.arca.json');
    expect(s.subtitlePath('${d.path}/Talk.webm', 'en'), '${d.path}/Talk.en.srt');
    expect(s.manifestOf('${d.path}/Song.mp3'), '${d.path}/Song.mp3.arca.json');
    await File('${d.path}/Talk.en.srt').writeAsString('1');
    await File('${d.path}/Talk.srt').writeAsString('1');
    await File('${d.path}/Talking.en.srt').writeAsString('1');
    s.changed(d.path);
    expect([for (final x in s.subtitlesOf('${d.path}/Talk.webm')) x.language], ['en', null]);
  });

  test('manifest written beside each file, and read back when the folder is adopted elsewhere', () async {
    final src = await Directory('${tmp.path}/src').create();
    await File('${src.path}/Talk.webm').writeAsString('video bytes');
    final lib = await openLib();
    final col = await lib.create(name: 'A', folder: src.path, baseFolder: tmp.path);
    await lib.updateFile(col.id, 'Talk.webm', title: 'A talk', tags: ['radio']);
    await File('${src.path}/Talk.en.srt').writeAsString('1\n00:00:00,000 --> 00:00:01,000\nHi\n');
    final m = jsonDecode(await File('${src.path}/Talk.arca.json').readAsString()) as Map;
    expect(m['format'], manifestFormat);
    expect(m['title'], 'A talk');
    expect(m['sha256'], col.files.single.sha256);

    // Copied by hand to another folder and adopted by a second library.
    final copy = await Directory('${tmp.path}/copy').create();
    for (final e in src.listSync().whereType<File>()) {
      await e.copy('${copy.path}/${e.path.split('/').last}');
    }
    final lib2 = await Library.open(File('${tmp.path}/other.json'));
    final col2 = await lib2.create(name: 'B', folder: copy.path, baseFolder: tmp.path);
    expect(col2.files.map((f) => f.path), ['Talk.webm'], reason: 'sidecars are not files of their own');
    expect(col2.files.single.title, 'A talk');
    expect(col2.files.single.tags, ['radio']);
  });

  test('adding a file brings its sidecars along, renamed with it', () async {
    final lib = await openLib();
    final col = await lib.create(name: 'C', baseFolder: tmp.path);
    final out = await Directory('${tmp.path}/outside').create();
    await File('${out.path}/Talk.webm').writeAsString('v');
    await File('${out.path}/Talk.de.srt').writeAsString('1');
    await File('${col.folder}/Talk.webm').writeAsString('already here');
    await lib.addFiles(col.id, ['${out.path}/Talk.webm']);
    final names = Directory(col.folder).listSync().map((e) => e.path.split('/').last).toSet();
    expect(names, containsAll(['Talk (2).webm', 'Talk (2).de.srt', 'Talk (2).arca.json']));

    await lib.removeFile(col.id, 'Talk (2).webm', deleteFromDisk: true);
    final after = Directory(col.folder).listSync().map((e) => e.path.split('/').last).toSet();
    expect(after.where((n) => n.startsWith('Talk (2)')), isEmpty);
  });

  test('a manifest for other bytes is ignored', () async {
    final d = await Directory('${tmp.path}/m').create();
    await File('${d.path}/x.txt').writeAsString('new bytes');
    await File('${d.path}/x.arca.json').writeAsString(jsonEncode({'sha256': '00', 'title': 'Old'}));
    final lib = await openLib();
    final col = await lib.create(name: 'D', folder: d.path, baseFolder: tmp.path);
    expect(col.files.single.title, 'x');
  });

  test('the owner picks the collection picture; removing the file clears it', () async {
    final d = await Directory('${tmp.path}/cv').create();
    await File('${d.path}/a.jpg').writeAsString('a');
    final lib = await openLib();
    final col = await lib.create(name: 'E', folder: d.path, baseFolder: tmp.path);
    expect(col.cover, isNull);
    await lib.setCover(col.id, 'a.jpg');
    expect((await openLib()).byId(col.id).cover, 'a.jpg');
    expect(() => lib.setCover(col.id, 'missing.jpg'), throwsA(isA<LibraryException>()));
    await lib.removeFile(col.id, 'a.jpg');
    expect(col.cover, isNull);
  });
}
