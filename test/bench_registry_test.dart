/// Bench registry tests (bench_registry.dart): 31 verdict units,
/// 15 IMPLEMENT / 16 QUEUED-BLOCKED, every entry sourced with a
/// pass bar, every blocked entry with a blocker + unblock line.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:outride/services/bench_registry.dart';

bool _isImplement(BenchEntry e) =>
    e.kind == BenchVerdictKind.implement;
bool _isQueued(BenchEntry e) =>
    e.kind == BenchVerdictKind.queuedBlocked;

void main() {
  group('benchRegistry', () {
    test('31 verdict units: 15 IMPLEMENT, 16 QUEUED-BLOCKED', () {
      expect(benchRegistry.length, 31);
      final impl = benchRegistry.where(_isImplement).toList();
      final queued = benchRegistry.where(_isQueued).toList();
      expect(impl.length, 15);
      expect(queued.length, 16);
      expect(impl.length + queued.length, benchRegistry.length);
    });

    test('ids unique', () {
      final ids = benchRegistry.map((e) => e.id).toSet();
      expect(ids.length, benchRegistry.length);
    });

    test('every entry has a non-empty source and pass bar', () {
      for (final e in benchRegistry) {
        expect(e.source, isNotEmpty, reason: '${e.id} source');
        expect(e.passBar, isNotEmpty, reason: '${e.id} passBar');
        expect(e.title, isNotEmpty, reason: '${e.id} title');
      }
    });

    test('every IMPLEMENT entry has a harness', () {
      for (final e in benchRegistry.where(_isImplement)) {
        expect(e.harness, isNotNull, reason: '${e.id} harness');
      }
    });

    test('every QUEUED entry has no harness, a blocker, and an '
        'unblock line', () {
      for (final e in benchRegistry.where(_isQueued)) {
        expect(e.harness, isNull, reason: '${e.id} harness');
        expect(e.blocker, isNotEmpty, reason: '${e.id} blocker');
        expect(e.unblock, isNotEmpty, reason: '${e.id} unblock');
      }
    });

    test('B5 group: five arms under one group', () {
      final b5 = benchRegistry
          .where((e) => e.group == 'B5 — CI bench arms')
          .toList();
      expect(b5.length, 5);
      expect(b5.map((e) => e.id),
          containsAll(['B5.1', 'B5.2', 'B5.3', 'B5.4', 'B5.5']));
      expect(b5.where(_isQueued).length, 2);
    });

    test('B5.2 Split CI is QUEUED-BLOCKED with the covariance blocker',
        () {
      final b52 = benchRegistry.firstWhere((e) => e.id == 'B5.2');
      expect(_isQueued(b52), isTrue);
      expect(b52.harness, isNull);
      expect(b52.blocker, contains('isotropic'));
      expect(b52.unblock, isNotEmpty);
    });

    test('row pill counts 12 runnable non-group entries', () {
      expect(benchRunnableEntryCount, 12);
    });

    test('B10 cost arm stays queued inside an implement row', () {
      final b10 = benchRegistry.firstWhere((e) => e.id == 'B10');
      expect(_isImplement(b10), isTrue);
      expect(b10.caveat, isNotEmpty);
    });

    test('B7 carries the S3 SISO phase caveat (R6)', () {
      final b7 = benchRegistry.firstWhere((e) => e.id == 'B7');
      expect(b7.caveat, isNotEmpty);
      expect(b7.caveat, contains('SISO'));
    });

    test('B4 carries the wall-clock note (R4)', () {
      final b4 = benchRegistry.firstWhere((e) => e.id == 'B4');
      expect(b4.caveat, isNotEmpty);
      expect(b4.caveat, contains('wall-clock'));
    });
  });
}
