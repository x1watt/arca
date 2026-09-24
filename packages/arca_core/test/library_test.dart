import 'dart:io';

import 'package:arca_core/src/library/library.dart';
import 'package:crypto/crypto.dart' as c;
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('arca_lib'));
  tearDown(() async => tmp.delete(recursive: true));

  test('hashes match independent SHA-256 and SHA-1', () async {
    final f = File('${tmp.path}/a.bin')..writeAsBytesSync(List.generate(300000, (i) => i % 251));
    final (s256, s1, size) = await hashFile(f);
    final bytes = f.readAsBytesSync();
    expect(s256, c.sha256.convert(bytes).toString());
    expect(s1, c.sha1.convert(bytes).toString());
    expect(size, 300000);
  });

  test('detects common types from content, not only the name', () async {
    final png = File('${tmp.path}/pic.dat')..writeAsBytesSync([0x89, 0x50, 0x4E, 0x47, 0, 0, 0, 0]);
    final pdf = File('${tmp.path}/doc')..writeAsStringSync('%PDF-1.7 ...');
    final txt = File('${tmp.path}/notes.txt')..writeAsStringSync('hello');
    expect(await detectMime(png), 'image/png');
    expect(await detectMime(pdf), 'application/pdf');
    expect(await detectMime(txt), 'text/plain');
  });

  test('creates a collection, copies files and folders in, and survives a restart', () async {
    final base = '${tmp.path}/Arca';
    final src = Directory('${tmp.path}/src')..createSync();
    File('${src.path}/guide.pdf').writeAsStringSync('%PDF-1.4 guide');
    Directory('${src.path}/photos').createSync();
    File('${src.path}/photos/one.jpg').writeAsBytesSync([0xFF, 0xD8, 0xFF, 0xE0]);
    File('${src.path}/photos/.hidden').writeAsStringSync('skip me');

    var lib = await Library.open(File('${tmp.path}/collections.json'));
    final col = await lib.create(name: 'Radio: manuals', description: 'Old manuals', baseFolder: base);
    expect(col.folder, '$base/Radio_ manuals');
    expect(col.circle, Commons.id);
    expect(await lib.addFiles(col.id, ['${src.path}/guide.pdf', '${src.path}/photos']), 2);
    expect(File('${col.folder}/guide.pdf').existsSync(), isTrue);
    expect(File('${col.folder}/photos/one.jpg').existsSync(), isTrue);

    // Adding the same name again keeps both copies.
    await lib.addFiles(col.id, ['${src.path}/guide.pdf']);
    expect(lib.byId(col.id).files.map((f) => f.path), containsAll(['guide.pdf', 'guide (2).pdf']));

    await lib.updateFile(col.id, 'guide.pdf', title: 'The guide', tags: ['NVIS Antenna', '', 'hf']);
    lib = await Library.open(File('${tmp.path}/collections.json'));
    final g = lib.byId(col.id).files.firstWhere((f) => f.path == 'guide.pdf');
    expect(g.title, 'The guide');
    expect(g.tags, ['nvis-antenna', 'hf']);
    expect(g.mime, 'application/pdf');
    expect(lib.byId(col.id).files.firstWhere((f) => f.path == 'photos/one.jpg').mime, 'image/jpeg');
  });

  test('adopts an existing folder with its files', () async {
    final dir = Directory('${tmp.path}/existing')..createSync();
    File('${dir.path}/a.txt').writeAsStringSync('a');
    File('${dir.path}/b.txt').writeAsStringSync('bb');
    final lib = await Library.open(File('${tmp.path}/collections.json'));
    final col = await lib.create(name: 'Existing', folder: dir.path, baseFolder: tmp.path);
    expect(col.files.length, 2);
    expect(col.size, 3);
    await expectLater(
      lib.create(name: 'Again', folder: dir.path, baseFolder: tmp.path),
      throwsA(isA<LibraryException>()),
    );
  });

  test('removing keeps files on disk unless asked', () async {
    final lib = await Library.open(File('${tmp.path}/collections.json'));
    final col = await lib.create(name: 'C', baseFolder: tmp.path);
    final f = File('${tmp.path}/x.txt')..writeAsStringSync('x');
    await lib.addFiles(col.id, [f.path]);
    await lib.removeFile(col.id, 'x.txt');
    expect(File('${col.folder}/x.txt').existsSync(), isTrue);
    await lib.addFiles(col.id, ['${col.folder}/x.txt']);
    await lib.removeFile(col.id, 'x.txt', deleteFromDisk: true);
    expect(File('${col.folder}/x.txt').existsSync(), isFalse);
    await lib.removeCollection(col.id);
    expect(lib.collections, isEmpty);
    expect(Directory(col.folder).existsSync(), isTrue);
  });
}
