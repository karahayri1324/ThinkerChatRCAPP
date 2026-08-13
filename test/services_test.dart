import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:rc_app/services/command_history_service.dart';
import 'package:rc_app/services/server_history_service.dart';
import 'package:rc_app/services/terminal_history_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('CommandHistoryService', () {
    test('add + navigate previous/next', () async {
      final h = CommandHistoryService.instance;
      await h.load();
      await h.add('ls');
      await h.add('pwd');
      await h.add('top');

      expect(h.previous(), 'top');
      expect(h.previous(), 'pwd');
      expect(h.previous(), 'ls');
      expect(h.previous(), 'ls'); // clamped at oldest
      expect(h.next(), 'pwd');
      expect(h.next(), 'top');
      expect(h.next(), ''); // past newest -> clear input
      expect(h.next(), isNull); // not navigating anymore
    });

    test('skips blanks and consecutive duplicates, re-adds move to front',
        () async {
      final h = CommandHistoryService.instance;
      await h.load();
      await h.add('a');
      await h.add('a');
      await h.add('   ');
      await h.add('b');
      await h.add('a');
      expect(h.entries, ['b', 'a']);
    });

    test('persists across instances and caps at 50', () async {
      final h = CommandHistoryService.instance;
      await h.load();
      for (var i = 0; i < 60; i++) {
        await h.add('cmd$i');
      }
      final h2 = CommandHistoryService.instance;
      await h2.load();
      expect(h2.entries.length, 50);
      expect(h2.entries.last, 'cmd59');
      expect(h2.entries.first, 'cmd10');
    });
  });

  group('ServerHistoryService', () {
    test('record upserts by URL and sorts newest first', () async {
      await ServerHistoryService.record('https://a.com', 'alice');
      await ServerHistoryService.record('https://b.com', 'bob');
      await ServerHistoryService.record('https://a.com', 'alice2');

      final profiles = await ServerHistoryService.load();
      expect(profiles.length, 2);
      expect(profiles.first.url, 'https://a.com');
      expect(profiles.first.username, 'alice2');
    });

    test('caps stored profiles at 8', () async {
      for (var i = 0; i < 12; i++) {
        await ServerHistoryService.record('https://s$i.com', 'u');
      }
      final profiles = await ServerHistoryService.load();
      expect(profiles.length, 8);
      expect(profiles.first.url, 'https://s11.com');
    });

    test('remove deletes a profile', () async {
      await ServerHistoryService.record('https://a.com', 'alice');
      await ServerHistoryService.record('https://b.com', 'bob');
      await ServerHistoryService.remove('https://a.com');
      final profiles = await ServerHistoryService.load();
      expect(profiles.map((p) => p.url), ['https://b.com']);
    });

    test('survives corrupt stored JSON', () async {
      SharedPreferences.setMockInitialValues({'server_profiles': '{not json'});
      expect(await ServerHistoryService.load(), isEmpty);
    });
  });

  group('TerminalHistoryService', () {
    test('save + restore round trip', () async {
      await TerminalHistoryService.saveOutput('1', 'hello\nworld');
      expect(await TerminalHistoryService.getOutput('1'), 'hello\nworld');
    });

    test('caps lines per shell at 500', () async {
      final lines = List.generate(600, (i) => 'line$i').join('\n');
      await TerminalHistoryService.saveOutput('1', lines);
      final saved = await TerminalHistoryService.getOutput('1');
      expect(saved!.split('\n').length, 500);
      expect(saved.split('\n').last, 'line599');
    });

    test('evicts oldest shells numerically beyond 10', () async {
      for (var i = 1; i <= 11; i++) {
        await TerminalHistoryService.saveOutput('$i', 'shell $i');
      }
      final ids = await TerminalHistoryService.getSavedShellIds();
      expect(ids.length, 10);
      expect(ids.contains('1'), isFalse); // oldest evicted, not '10'
      expect(ids.contains('10'), isTrue);
      expect(ids.contains('11'), isTrue);
    });

    test('clearShell and clearAll', () async {
      await TerminalHistoryService.saveOutput('1', 'a');
      await TerminalHistoryService.saveOutput('2', 'b');
      await TerminalHistoryService.clearShell('1');
      expect(await TerminalHistoryService.getOutput('1'), isNull);
      expect(await TerminalHistoryService.getOutput('2'), 'b');
      await TerminalHistoryService.clearAll();
      expect(await TerminalHistoryService.getOutput('2'), isNull);
    });
  });
}
