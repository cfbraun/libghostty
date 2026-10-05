@Tags(['ffi'])
library;

import 'dart:convert';

import 'package:flterm/src/controller/terminal_controller.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show KeyEventResult;
import 'package:flutter_test/flutter_test.dart';

/// macOS Option-key composition under the Kitty keyboard protocol (German
/// layout; reported via Claude Code, which pushes Kitty flags `>5u`).
///
/// Two cases, two mechanisms:
///  - An Option combo that commits a character immediately (Option+L → `@`):
///    Alt was consumed to produce it, so the encoder must emit the text, not
///    `Alt+l`. Handled by `consumedModifiersFor` (either Option composes).
///  - A dead key (Option+N): the keydown carries NO character — macOS holds the
///    composition and commits (`~`) on the next key. The keydown is IGNORED
///    so the IME commits and the composition is not aborted; emitting `Alt+n`
///    breaks both. The committed text flows through the IME/text-input path,
///    which a unit test cannot drive faithfully, so the dead-key test here
///    asserts the suppression half; the full `~` is verified in a live build.
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

    test('left Option+N dead-key press is ignored (not emitted as Alt+n)',
        () async {
      enableKitty();
      await simulateKeyDownEvent(LogicalKeyboardKey.altLeft);
      final result = attachment.handleKeyEvent(
        // Dead key: macOS delivers no character on the Option+N keydown.
        const KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.keyN,
          logicalKey: LogicalKeyboardKey.keyN,
          timeStamp: Duration.zero,
        ),
      );
      expect(result, KeyEventResult.ignored);
      expect(output, isEmpty);
    });

    test('safety: Option+Right (real Alt binding) is still emitted', () async {
      // A functional key under Option has no layout character and
      // unshiftedCodepoint 0, so it is not a composition and must still be sent
      // (Alt+Right word motion, etc.) — never swallowed by the dead-key path.
      enableKitty();
      await simulateKeyDownEvent(LogicalKeyboardKey.altLeft);
      final result = attachment.handleKeyEvent(
        const KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.arrowRight,
          logicalKey: LogicalKeyboardKey.arrowRight,
          timeStamp: Duration.zero,
        ),
      );
      expect(result, KeyEventResult.handled);
      expect(output, isNotEmpty);
    });
  });
}
