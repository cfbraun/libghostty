@Tags(['ffi'])
library;

import 'dart:convert';

import 'package:flterm/src/controller/terminal_controller.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show KeyEventResult;
import 'package:flutter_test/flutter_test.dart';

/// On macOS the Option key composes characters on BOTH sides (there is no
/// AltGr). When a composed character is produced, the Alt modifier was consumed
/// to make it, so under the Kitty keyboard protocol the terminal must emit that
/// text — not report it as `Alt+<base key>`.
///
/// Regression test for: German layout, left Option+L (`@`) / Option+N (`~`)
/// arriving in Claude Code (Kitty flags `>5u`) as `\e[108;3u` / `\e[110;3u`
/// instead of `@` / `~`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('macOS Option-composed char under the Kitty keyboard protocol', () {
    late TerminalController controller;
    late ViewAttachment attachment;
    late List<int> output;

    setUp(() {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      controller = TerminalController();
      attachment = ViewAttachment(controller);
      output = <int>[];
      controller.onOutput = output.addAll;
    });

    tearDown(() {
      attachment.dispose();
      controller.dispose();
      HardwareKeyboard.instance.clearState();
      debugDefaultTargetPlatformOverride = null;
    });

    // Enable exactly what Claude Code pushes: Kitty keyboard, flags = 5.
    void enableKitty() =>
        controller.write(Uint8List.fromList(utf8.encode('\x1b[>5u')));

    test('left Option+L emits "@", not Alt+l', () async {
      enableKitty();
      await simulateKeyDownEvent(LogicalKeyboardKey.altLeft);
      final result = attachment.handleKeyEvent(
        const KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.keyL,
          logicalKey: LogicalKeyboardKey.keyL,
          character: '@',
          timeStamp: Duration.zero,
        ),
      );
      expect(result, KeyEventResult.handled);
      expect(utf8.decode(output), '@');
    });

    test('left Option+N (dead tilde committed) emits "~", not Alt+n', () async {
      enableKitty();
      await simulateKeyDownEvent(LogicalKeyboardKey.altLeft);
      final result = attachment.handleKeyEvent(
        const KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.keyN,
          logicalKey: LogicalKeyboardKey.keyN,
          character: '~',
          timeStamp: Duration.zero,
        ),
      );
      expect(result, KeyEventResult.handled);
      expect(utf8.decode(output), '~');
    });

    test('safety: Option+key with no composed character still reports Alt',
        () async {
      // When Option produces no layout character, the modifier was NOT consumed
      // and must still be reported (so real Alt bindings keep working).
      enableKitty();
      await simulateKeyDownEvent(LogicalKeyboardKey.altLeft);
      attachment.handleKeyEvent(
        // No character: Option produced no layout character here.
        const KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.keyL,
          logicalKey: LogicalKeyboardKey.keyL,
          timeStamp: Duration.zero,
        ),
      );
      // key 'l' (108) reported with the alt modifier (`;3`).
      expect(utf8.decode(output), '\x1b[108;3u');
    });
  });
}
