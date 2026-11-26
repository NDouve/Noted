// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// The export write (design: writing the file, and data integrity): a new file
// is published exclusively, a taken name is replaced only after Noted's own
// prompt and only if it is unchanged, and every outcome has a message.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted/src/export/exclusive_create.dart';
import 'package:noted/src/export/export_write.dart';
import 'package:noted_core/noted_core.dart';

Uint8List b(String s) => Uint8List.fromList(s.codeUnits);

void main() {
  late Directory dir;
  late String target;
  late List<String> asked, askedPutBack;
  var replaceAnswer = true;
  var putBackAnswer = true;
  Future<void> Function()? onReplaceAsk;
  Future<void> Function(String aside)? onPutBackAsk;

  String path(String name) => '${dir.path}${Platform.pathSeparator}$name';
  List<String> names() => [for (final e in dir.listSync()) e.path.split(RegExp(r'[\\/]')).last]..sort();

  ExportWriter writer({
    Future<bool> Function(File, String)? publish,
    ExportReplace? replace,
    Future<bool> Function(String)? hardLinks,
    bool? posix,
    ExclusiveOpener? opener,
    DateTime Function()? now,
    Future<void> Function(String)? afterStaleIdentity,
  }) => ExportWriter(
    askReplace: (name) async {
      asked.add(name);
      await onReplaceAsk?.call();
      return replaceAnswer;
    },
    askPutBack: (name, aside) async {
      askedPutBack.add('$name|${aside.split(RegExp(r'[\\/]')).last}');
      await onPutBackAsk?.call(aside);
      return putBackAnswer;
    },
    publish: publish ?? (tmp, to) => publishExclusive(tmp, to),
    replace: replace,
    hardLinks: hardLinks,
    posix: posix,
    opener: opener,
    now: now,
    afterStaleIdentity: afterStaleIdentity,
  );

  Future<ExportWriteResult> write(ExportWriter w, String content, {String? to}) =>
      w.write(to ?? target, () async => b(content));

  setUp(() {
    dir = Directory.systemTemp.createTempSync('noted_export_write');
    target = path('out.txt');
    asked = [];
    askedPutBack = [];
    replaceAnswer = true;
    putBackAnswer = true;
    onReplaceAsk = null;
    onPutBackAsk = null;
  });

  tearDown(() => dir.deleteSync(recursive: true));

  group('a new file', () {
    test('is written, with a message, and nothing else is left', () async {
      final r = await write(writer(), 'hello');
      expect(r.kind, ExportWriteKind.exported);
      expect(r.message, 'Exported out.txt.');
      expect(File(target).readAsStringSync(), 'hello');
      expect(names(), ['out.txt']);
      expect(asked, isEmpty);
    });

    test('the bytes are made after the housekeeping and may stop the write', () async {
      var made = 0;
      final r = await writer().write(target, () async {
        made++;
        return null;
      });
      expect(r.kind, ExportWriteKind.stopped);
      expect(made, 1);
      expect(names(), isEmpty);
    });
  });

  group('a taken name', () {
    test('is replaced after Noted\'s prompt', () async {
      File(target).writeAsStringSync('old');
      final r = await write(writer(), 'new');
      expect(asked, ['out.txt']);
      expect(r.message, 'Exported out.txt.');
      expect(File(target).readAsStringSync(), 'new');
      expect(names(), ['out.txt'], reason: 'the aside and the temp are gone');
    });

    test('a name taken meanwhile (during the bytes) is asked about, not overwritten silently', () async {
      final r = await writer().write(target, () async {
        File(target).writeAsStringSync('someone else');
        return b('mine');
      });
      expect(asked, ['out.txt']);
      expect(r.exported, isTrue);
      expect(File(target).readAsStringSync(), 'mine');
    });

    test('a declined replace writes nothing and removes the temp', () async {
      File(target).writeAsStringSync('old');
      replaceAnswer = false;
      final r = await write(writer(), 'new');
      expect(r.kind, ExportWriteKind.stopped);
      expect(r.message, isNull);
      expect(File(target).readAsStringSync(), 'old');
      expect(names(), ['out.txt']);
    });

    test('one changed while the prompt was open is not replaced, and the other bytes survive', () async {
      File(target).writeAsStringSync('old');
      onReplaceAsk = () async => File(target).writeAsStringSync('changed meanwhile, longer');
      final r = await write(writer(), 'new');
      expect(r.kind, ExportWriteKind.failed);
      expect(r.message, 'out.txt changed since you chose it. Nothing was written.');
      expect(File(target).readAsStringSync(), 'changed meanwhile, longer');
      expect(names(), ['out.txt'], reason: 'the temp is removed');
    });

    test('one replaced by a file of the same length while the prompt was open is not replaced either', () async {
      File(target).writeAsStringSync('old!');
      onReplaceAsk = () async => File(target).writeAsStringSync('NEW!');
      final r = await write(writer(), 'mine');
      expect(r.message, startsWith('out.txt changed since you chose it.'));
      expect(File(target).readAsStringSync(), 'NEW!');
    });

    test('one changed between the confirm and the replace', () async {
      File(target).writeAsStringSync('old');
      final r = await write(
        writer(
          replace: (tmp, to, id) async {
            File(to).writeAsStringSync('changed after the confirm');
            return replaceIfUnchanged(tmp, to, null, identity: id);
          },
        ),
        'new',
      );
      expect(r.message, 'out.txt changed since you chose it. Nothing was written.');
      expect(File(target).readAsStringSync(), 'changed after the confirm');
      expect(names(), ['out.txt']);
    });

    test('changedKept names the kept path from the result', () async {
      File(target).writeAsStringSync('old');
      final r = await write(
        writer(
          replace: (tmp, to, id) async {
            return replaceIfUnchanged(
              tmp,
              to,
              null,
              identity: id,
              beforeMoveAside: () => File(to).writeAsStringSync('changed'),
              afterRead: () => File(to).writeAsStringSync('newest'),
            );
          },
        ),
        'new',
      );
      expect(r.kind, ExportWriteKind.failed);
      expect(r.message, startsWith('out.txt changed since you chose it. Nothing was written. Your previous out.txt is kept as '));
      final kept = r.message!.split('is kept as ').last;
      expect(kept, endsWith('.'));
      expect(File(kept.substring(0, kept.length - 1)).existsSync(), isTrue);
      expect(File(target).readAsStringSync(), 'newest');
    });

    test('supersededKept names the kept path from the result', () async {
      File(target).writeAsStringSync('old');
      final r = await write(
        writer(
          replace: (tmp, to, id) => replaceIfUnchanged(
            tmp,
            to,
            null,
            identity: id,
            afterRead: () => File(to).writeAsStringSync('another app'),
          ),
        ),
        'new',
      );
      expect(r.kind, ExportWriteKind.failed);
      expect(
        r.message,
        startsWith('out.txt was replaced by another app meanwhile. Nothing was exported. Your previous out.txt is kept as '),
      );
      final kept = r.message!.split('is kept as ').last;
      final keptPath = kept.substring(0, kept.length - 1);
      expect(File(keptPath).readAsStringSync(), 'old');
      expect(File(target).readAsStringSync(), 'another app');
    });

    test('replaced with a kept path, and every path in alsoKept, are named from the result', () async {
      File(target).writeAsStringSync('old');
      final r = await write(
        writer(
          replace: (tmp, to, id) async => const ReplaceResult(ReplaceOutcome.replaced, '/k/one', ['/k/two']),
        ),
        'new',
      );
      expect(r.kind, ExportWriteKind.exported);
      expect(r.message, 'Exported out.txt. Your previous out.txt is kept as /k/one. Also kept as /k/two.');
    });
  });

  group('failures', () {
    test('a failure before publishing leaves nothing but the target as it was', () async {
      File(target).writeAsStringSync('old');
      final r = await write(
        writer(publish: (tmp, to) async => throw const FileSystemException('refused')),
        'new',
      );
      expect(r.kind, ExportWriteKind.failed);
      expect(r.message, 'Could not write out.txt. Nothing was exported.');
      expect(names(), ['out.txt']);
      expect(File(target).readAsStringSync(), 'old');
    });

    test('a sharing violation names the file', () async {
      File(target).writeAsStringSync('old');
      final r = await write(
        writer(
          replace: (tmp, to, id) async => throw FileSystemException('busy', to, const OSError('sharing violation', 32)),
        ),
        'new',
      );
      expect(r.message, 'out.txt is open in another app. Close it and try again.');
      expect(File(target).readAsStringSync(), 'old');
      expect(names(), ['out.txt']);
    }, skip: !Platform.isWindows);

    test('StorageBusy(dataless) and any other StorageBusy', () async {
      File(target).writeAsStringSync('old');
      var r = await write(
        writer(replace: (tmp, to, id) async => throw StorageBusy(StorageBusyReason.dataless, [to])),
        'new',
      );
      expect(r.message, "out.txt isn't downloaded yet.");
      r = await write(
        writer(replace: (tmp, to, id) async => throw StorageBusy(StorageBusyReason.coordination, [to])),
        'new',
      );
      expect(r.message, 'The folder is busy. Try again.');
      expect(names(), ['out.txt']);
    });
  });

  group('Put back', () {
    String aside(String name, {String suffix = 'cas-old'}) => path('$name.4242-1a2b3c4d-5e6f7a8b.$suffix');

    test('a replace that died after the move aside is put back at the next export into the folder', () async {
      // The state a death leaves: no file at the name, the old bytes under the aside.
      File(aside('out.txt')).writeAsStringSync('the old bytes');
      final r = await write(writer(), 'fresh');
      expect(askedPutBack, ['out.txt|out.txt.4242-1a2b3c4d-5e6f7a8b.cas-old']);
      // Put back published the old file; the export then asked about it.
      expect(asked, ['out.txt']);
      expect(r.exported, isTrue);
      expect(File(target).readAsStringSync(), 'fresh');
    });

    test('putBack alone restores the bytes and removes the aside', () async {
      File(aside('out.txt', suffix: 'cas-verified')).writeAsStringSync('the old bytes');
      await writer().putBack(target);
      expect(File(target).readAsStringSync(), 'the old bytes');
      expect(names(), ['out.txt']);
      expect(askedPutBack, hasLength(1));
    });

    test('a declined Put back leaves the aside', () async {
      File(aside('out.txt')).writeAsStringSync('old');
      putBackAnswer = false;
      await writer().putBack(target);
      expect(File(target).existsSync(), isFalse);
      expect(names(), ['out.txt.4242-1a2b3c4d-5e6f7a8b.cas-old']);
    });

    test('nothing is offered while the target exists', () async {
      File(target).writeAsStringSync('here');
      File(aside('out.txt')).writeAsStringSync('old');
      await writer().putBack(target);
      expect(askedPutBack, isEmpty);
      expect(File(target).readAsStringSync(), 'here');
    });

    test('an aside of another name is left alone', () async {
      File(aside('other.txt')).writeAsStringSync('old');
      await writer().putBack(target);
      expect(askedPutBack, isEmpty);
    });

    test('refuses when the target came back during the prompt', () async {
      File(aside('out.txt')).writeAsStringSync('old');
      onPutBackAsk = (_) async => File(target).writeAsStringSync('came back');
      await writer().putBack(target);
      expect(File(target).readAsStringSync(), 'came back');
      expect(names(), ['out.txt', 'out.txt.4242-1a2b3c4d-5e6f7a8b.cas-old']);
    });

    test('an exception from replaceIfUnchanged runs Put back at once', () async {
      File(target).writeAsStringSync('old');
      final r = await write(
        writer(
          replace: (tmp, to, id) async {
            // The target is moved aside, then the replace fails.
            File(to).renameSync(aside('out.txt'));
            throw const FileSystemException('died');
          },
        ),
        'new',
      );
      expect(askedPutBack, ['out.txt|out.txt.4242-1a2b3c4d-5e6f7a8b.cas-old']);
      expect(File(target).readAsStringSync(), 'old', reason: 'put back');
      expect(r.kind, ExportWriteKind.failed);
      expect(names(), ['out.txt']);
    });

    test('skips an aside of a replace this process has in flight', () async {
      File(target).writeAsStringSync('old');
      final w = writer(
        replace: (tmp, to, id) async {
          // Mid-replace: the target is aside, and a Put back must leave it.
          File(to).renameSync(path('out.txt.$pid-1a2b3c4d-5e6f7a8b.cas-old'));
          await w2!.putBack(to);
          File(path('out.txt.$pid-1a2b3c4d-5e6f7a8b.cas-old')).renameSync(to);
          return replaceIfUnchanged(tmp, to, null, identity: id);
        },
      );
      w2 = w;
      await write(w, 'new');
      expect(askedPutBack, isEmpty);
      expect(File(target).readAsStringSync(), 'new');
    });
  });

  group('staging temps', () {
    final longAgo = DateTime.now().subtract(const Duration(days: 3));

    File temp(String name, String content, {DateTime? at}) {
      final f = File(path(name))..writeAsStringSync(content);
      if (at != null) f.setLastModifiedSync(at);
      return f;
    }

    test('one older than a day is removed, a newer one is kept', () async {
      temp('.out.txt.noted-export-aaaa1111.tmp', 'old temp', at: longAgo);
      temp('.out.txt.noted-export-bbbb2222.tmp', 'new temp');
      temp('.other.txt.noted-export-cccc3333.tmp', 'other name', at: longAgo);
      await write(writer(), 'x');
      expect(names(), ['.other.txt.noted-export-cccc3333.tmp', '.out.txt.noted-export-bbbb2222.tmp', 'out.txt']);
    });

    test('an aside of a staging temp is removed like the temp', () async {
      temp('.out.txt.noted-export-aaaa1111.tmp.99-ab-cd.cas-old', 'x', at: longAgo);
      temp('.out.txt.noted-export-aaaa1111.tmp.99-ab-cd.cas-verified', 'x', at: longAgo);
      await write(writer(), 'x');
      expect(names(), ['out.txt']);
    });

    test('one this process holds in flight is kept', () async {
      // While the replace prompt is open the staging temp is held by this export.
      File(target).writeAsStringSync('old');
      late final ExportWriter w;
      w = writer(now: () => DateTime.now().add(const Duration(days: 10)));
      List<String>? during;
      onReplaceAsk = () async {
        await w.removeStaleTemps(target);
        during = names();
      };
      await write(w, 'new');
      expect(during!.where((n) => n.contains('noted-export')), hasLength(1), reason: 'the held temp survived the cleanup');
      expect(names(), ['out.txt']);
    });

    test('one that changed meanwhile survives', () async {
      final f = temp('.out.txt.noted-export-aaaa1111.tmp', 'old temp', at: longAgo);
      await write(
        writer(afterStaleIdentity: (p) async => f.writeAsStringSync('someone wrote this')),
        'x',
      );
      expect(f.existsSync(), isTrue);
      expect(f.readAsStringSync(), 'someone wrote this');
    });
  });

  group('where hard links do not work', () {
    // No exclusive create on this test's platform: a descriptor on a real file.
    ExclusiveOpener ioOpener() => (p) {
      final f = File(p);
      try {
        f.createSync(exclusive: true);
      } on PathExistsException {
        return null;
      }
      return _IoFile(f.openSync(mode: FileMode.writeOnly));
    };

    test('a taken name is refused before any prompt, and nothing leaves its name', () async {
      File(target).writeAsStringSync('old');
      final r = await write(writer(hardLinks: (_) async => false, opener: ioOpener()), 'new');
      expect(r.kind, ExportWriteKind.failed);
      expect(r.message, "Choose a new name; Noted can't safely replace a file here.");
      expect(asked, isEmpty);
      expect(File(target).readAsStringSync(), 'old');
      expect(names(), ['out.txt']);
    });

    test('a new file uses the exclusive create', () async {
      final r = await write(writer(hardLinks: (_) async => false, opener: ioOpener()), 'brand new');
      expect(r.message, 'Exported out.txt.');
      expect(File(target).readAsStringSync(), 'brand new');
      expect(names(), ['out.txt']);
    });

    test('a failed exclusive create removes its partial file, or in the sandbox names it', () async {
      ExclusiveOpener failing() => (p) {
        File(p).createSync();
        return _FailingFile(File(p).openSync(mode: FileMode.writeOnly));
      };
      var r = await write(writer(hardLinks: (_) async => false, opener: failing()), 'data');
      expect(r.kind, ExportWriteKind.failed);
      expect(r.message, 'Could not write out.txt. Nothing was exported.');
      expect(names(), isEmpty, reason: 'the partial file was the bytes written, so it is removed');
      final sandboxed = ExportWriter(
        askReplace: (name) async => true,
        askPutBack: (name, aside) async => true,
        sandboxed: true,
        hardLinks: (_) async => false,
        opener: failing(),
      );
      r = await write(sandboxed, 'data');
      expect(r.message, 'out.txt may be incomplete.');
      expect(names(), ['out.txt']);
    });

    test('a name taken after the check is refused by the exclusive create itself', () async {
      final r = await writer(hardLinks: (_) async => false, opener: ioOpener()).write(target, () async {
        return b('x');
      });
      expect(r.exported, isTrue);
      // Taken between the check and the create: the opener answers "taken".
      File(path('late.txt')).writeAsStringSync('late');
      final r2 = await write(
        writer(hardLinks: (_) async => false, opener: (p) => null),
        'y',
        to: path('late.txt'),
      );
      expect(r2.message, "Choose a new name; Noted can't safely replace a file here.");
      expect(File(path('late.txt')).readAsStringSync(), 'late');
    });

    test('the probe fails when the publish can not link, simulated through the publish seam', () async {
      var publishes = 0;
      final w = writer(
        posix: true,
        opener: ioOpener(),
        publish: (tmp, to) async {
          publishes++;
          throw const FileSystemException('Operation not permitted');
        },
      );
      final r = await write(w, 'data');
      expect(publishes, 1, reason: 'one probe, no real publish');
      expect(r.message, 'Exported out.txt.');
      expect(File(target).readAsStringSync(), 'data');
      expect(names(), ['out.txt'], reason: 'the probe\'s temp is removed');
    });

    test('a probe that links leaves nothing, and the real publish follows', () async {
      final seen = <String>[];
      final w = writer(
        posix: true,
        publish: (tmp, to) {
          seen.add(to.split(RegExp(r'[\\/]')).last);
          return publishExclusive(tmp, to);
        },
      );
      final r = await write(w, 'data');
      expect(r.exported, isTrue);
      expect(seen, hasLength(2));
      expect(seen.first, matches(RegExp(r'^\.out\.txt\.noted-export-[0-9a-f]+\.link\.tmp$')));
      expect(seen.last, 'out.txt');
      expect(names(), ['out.txt']);
    });

    test('a probe interrupted after the link leaves only names the staging cleanup removes', () async {
      final w = writer(
        posix: true,
        opener: ioOpener(),
        publish: (tmp, to) async {
          // The link was made, then the process went away.
          File(tmp.path).renameSync(to);
          throw StateError('interrupted');
        },
      );
      final r = await write(w, 'data');
      expect(r.kind, ExportWriteKind.failed);
      final left = names();
      expect(left, hasLength(1));
      expect(left.single, matches(RegExp(r'^\.out\.txt\.noted-export-[0-9a-f]+\.link\.tmp$')));
      // A later export, a day on, removes it.
      File(path(left.single)).setLastModifiedSync(DateTime.now().subtract(const Duration(days: 2)));
      await write(writer(), 'x');
      expect(names(), ['out.txt']);
    });
  });

  test('other files in the folder are byte-identical afterwards', () async {
    File(path('page.canvas')).writeAsBytesSync([1, 2, 3, 4]);
    File(path('recovery.json')).writeAsBytesSync([5, 6]);
    await write(writer(), 'x');
    expect(File(path('page.canvas')).readAsBytesSync(), [1, 2, 3, 4]);
    expect(File(path('recovery.json')).readAsBytesSync(), [5, 6]);
  });
}

ExportWriter? w2;

class _IoFile implements ExclusiveFile {
  _IoFile(this.raf);
  final RandomAccessFile raf;

  @override
  int write(Uint8List bytes, int offset) {
    raf.writeFromSync(bytes, offset);
    return bytes.length - offset;
  }

  @override
  void sync() => raf.flushSync();

  @override
  void close() => raf.closeSync();
}

/// A descriptor whose first write fails after writing nothing.
class _FailingFile implements ExclusiveFile {
  _FailingFile(this.raf);
  final RandomAccessFile raf;

  @override
  int write(Uint8List bytes, int offset) => throw const FileSystemException('disk full');

  @override
  void sync() {}

  @override
  void close() => raf.closeSync();
}
