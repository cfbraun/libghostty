@Tags(['ffi'])
library;

import 'dart:convert';

import 'package:flterm/src/controller/terminal_controller.dart';
import 'package:flterm/src/foundation.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libghostty/libghostty.dart'
    show Mods, RgbColor, Terminal, TerminalScreen;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ViewAttachment', () {
    late TerminalController controller;
    late ViewAttachment attachment;

    setUp(() {
      controller = TerminalController();
      attachment = ViewAttachment(controller);
    });

    tearDown(() {
      attachment.dispose();
      controller.dispose();
    });

    RgbColor rgb(Color color) => RgbColor(
      (color.r * 255).round().clamp(0, 255),
      (color.g * 255).round().clamp(0, 255),
      (color.b * 255).round().clamp(0, 255),
    );

    group('ownership', () {
      test('rejects a second active view attachment', () {
        expect(() => ViewAttachment(controller), throwsA(isA<StateError>()));
      });

      test('stale attachment disposal does not detach a newer view', () {
        final first = attachment;
        first.dispose();
        final second = ViewAttachment(controller);
        attachment = second;

        first.dispose();

        expect(() => ViewAttachment(controller), throwsA(isA<StateError>()));
      });
    });

    group('interaction state', () {
      test('starts without virtual modifiers', () {
        expect(attachment.readVirtualMods(), const Mods.none());
      });

      test('projects only interaction changes', () {
        var notifications = 0;
        attachment.interaction.addListener(() => notifications++);

        controller.toggleMod(const Mods.ctrl());

        expect(notifications, 0);

        controller.write(Uint8List.fromList(utf8.encode('\x1b[?1049h')));

        expect(notifications, 1);
        expect(
          attachment.interaction.value.activeScreen,
          TerminalScreen.alternate,
        );
      });
    });

    group('applyTheme', () {
      void replaceWithRestored({bool preserveSnapshotColors = true}) {
        final source = Terminal(cols: 12, rows: 3)
          ..foreground = const RgbColor(12, 34, 56)
          ..background = const RgbColor(65, 43, 21);
        addTearDown(source.dispose);
        attachment.dispose();
        controller.dispose();
        controller = TerminalController.fromSnapshot(
          source.encodeSnapshot(),
          progressive: false,
          preserveSnapshotColors: preserveSnapshotColors,
        );
        attachment = ViewAttachment(controller);
      }

      test('applies view colors to the terminal session', () {
        final theme = TerminalTheme.dark();

        attachment.applyTheme(theme);

        final terminal = (controller as TerminalSession).terminal;

        expect(terminal.foreground, rgb(theme.foreground));
        expect(terminal.background, rgb(theme.background));
        expect(terminal.palette[1], rgb(theme.palette[1]));
      });

      test('preserves snapshot colors on initial attachment', () {
        replaceWithRestored();

        attachment.applyTheme(TerminalTheme.dark(), initial: true);

        expect(
          (
            (controller as TerminalSession).terminal.foreground,
            (controller as TerminalSession).terminal.background,
          ),
          (const RgbColor(12, 34, 56), const RgbColor(65, 43, 21)),
        );
      });

      test('applies a later theme after preserving snapshot colors', () {
        replaceWithRestored();
        final theme = TerminalTheme.light();
        attachment.applyTheme(TerminalTheme.dark(), initial: true);

        attachment.applyTheme(theme);

        final terminal = (controller as TerminalSession).terminal;
        expect(
          (terminal.foreground, terminal.background),
          (rgb(theme.foreground), rgb(theme.background)),
        );
      });

      test('applies initial colors when preservation is disabled', () {
        replaceWithRestored(preserveSnapshotColors: false);
        final theme = TerminalTheme.dark();

        attachment.applyTheme(theme, initial: true);

        final terminal = (controller as TerminalSession).terminal;
        expect(
          (terminal.foreground, terminal.background),
          (rgb(theme.foreground), rgb(theme.background)),
        );
      });
    });

    group('handleViewportRowChanged', () {
      test('applies viewport row intents to the terminal session', () {
        controller.write(
          Uint8List.fromList(
            List.filled(40, 'scrollback row\r\n').join().codeUnits,
          ),
        );

        attachment.handleViewportRowChanged(0);

        expect(controller.scrollbar.offset, 0);
      });
    });

    group('attach and detach', () {
      testWidgets('owns view services locally', (tester) async {
        final focusNode = _InspectableFocusNode();
        final scrollController = ScrollController();
        addTearDown(focusNode.dispose);
        addTearDown(scrollController.dispose);

        await tester.pumpWidget(
          Focus(focusNode: focusNode, child: const SizedBox()),
        );
        attachment.attach(focusNode, scrollController, viewId: 0);

        focusNode.requestFocus();
        await tester.pump();

        expect(focusNode.hasFocus, isTrue);

        attachment.detach();

        expect(attachment.preeditText, isEmpty);
      });

      testWidgets('does not duplicate a focus listener when reattached', (
        tester,
      ) async {
        final focusNode = _InspectableFocusNode();
        final scrollController = ScrollController();
        addTearDown(focusNode.dispose);
        addTearDown(scrollController.dispose);

        await tester.pumpWidget(
          Focus(focusNode: focusNode, child: const SizedBox()),
        );

        final initiallyHasListeners = focusNode.hasFocusListeners;
        attachment.attach(focusNode, scrollController, viewId: 0);
        final hasListenersAfterAttach = focusNode.hasFocusListeners;

        attachment.attach(focusNode, scrollController, viewId: 1);

        expect(focusNode.hasFocusListeners, hasListenersAfterAttach);
        attachment.detach();
        expect(focusNode.hasFocusListeners, initiallyHasListeners);
      });
    });

    group('dispose', () {
      test('leaves the application-owned controller usable', () {
        final output = <Uint8List>[];
        controller.onOutput = output.add;

        attachment.dispose();
        controller.sendText('ready');

        expect(utf8.decode(output.single), 'ready');
      });

      test('stops publishing interaction changes', () {
        var notifications = 0;
        attachment.interaction.addListener(() => notifications++);

        attachment.dispose();
        controller.write(Uint8List.fromList(utf8.encode('\x1b[?1049h')));

        expect(notifications, 0);
      });
    });

    group('dead keys under Kitty keyboard', () {
      late List<int> output;

      setUp(() {
        debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
        output = <int>[];
        controller.onOutput = output.addAll;
        // Enable the Kitty keyboard protocol so an unmodified printable press
        // would otherwise be encoded and sent to the PTY.
        controller.write(Uint8List.fromList(utf8.encode('\x1b[>1u')));
      });

      tearDown(() {
        debugDefaultTargetPlatformOverride = null;
      });

      KeyDownEvent keyDown(
        PhysicalKeyboardKey physical,
        LogicalKeyboardKey logical, {
        String? character,
      }) {
        return KeyDownEvent(
          physicalKey: physical,
          logicalKey: logical,
          character: character,
          timeStamp: Duration.zero,
        );
      }

      test('a dead key with a null character is ignored and reaches no '
          'PTY', () {
        final result = attachment.handleKeyEvent(
          keyDown(
            PhysicalKeyboardKey.bracketLeft,
            LogicalKeyboardKey.bracketLeft,
          ),
        );

        expect(result, KeyEventResult.ignored);
        expect(output, isEmpty);
      });

      test('a dead key delivered as a bare acute is ignored', () {
        final result = attachment.handleKeyEvent(
          keyDown(
            PhysicalKeyboardKey.bracketLeft,
            LogicalKeyboardKey.bracketLeft,
            character: '´',
          ),
        );

        expect(result, KeyEventResult.ignored);
        expect(output, isEmpty);
      });

      test('a plain printable key still encodes to the PTY', () {
        final result = attachment.handleKeyEvent(
          keyDown(
            PhysicalKeyboardKey.keyA,
            LogicalKeyboardKey.keyA,
            character: 'a',
          ),
        );

        expect(result, KeyEventResult.handled);
        expect(output, isNotEmpty);
      });

      test('Enter is not treated as a dead key and reaches the PTY', () {
        final result = attachment.handleKeyEvent(
          keyDown(PhysicalKeyboardKey.enter, LogicalKeyboardKey.enter),
        );

        expect(result, KeyEventResult.handled);
        expect(output, isNotEmpty);
      });
    });

    group('super shortcuts', () {
      late List<int> output;

      setUp(() {
        debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
        output = <int>[];
        controller.onOutput = output.addAll;
      });

      tearDown(() {
        HardwareKeyboard.instance.clearState();
        debugDefaultTargetPlatformOverride = null;
      });

      KeyDownEvent keyDown(
        PhysicalKeyboardKey physical,
        LogicalKeyboardKey logical, {
        String? character,
      }) {
        return KeyDownEvent(
          physicalKey: physical,
          logicalKey: logical,
          character: character,
          timeStamp: Duration.zero,
        );
      }

      test('Cmd+` is ignored and reaches no PTY', () async {
        await simulateKeyDownEvent(LogicalKeyboardKey.metaLeft);

        final result = attachment.handleKeyEvent(
          keyDown(
            PhysicalKeyboardKey.backquote,
            LogicalKeyboardKey.backquote,
            character: '`',
          ),
        );

        expect(result, KeyEventResult.ignored);
        expect(output, isEmpty);
      });

      test('Cmd+` under Kitty is ignored and reaches no PTY', () async {
        controller.write(Uint8List.fromList(utf8.encode('\x1b[>1u')));
        await simulateKeyDownEvent(LogicalKeyboardKey.metaLeft);

        final result = attachment.handleKeyEvent(
          keyDown(
            PhysicalKeyboardKey.backquote,
            LogicalKeyboardKey.backquote,
            character: '`',
          ),
        );

        expect(result, KeyEventResult.ignored);
        expect(output, isEmpty);
      });

      test('Ctrl+C still reaches the PTY', () async {
        await simulateKeyDownEvent(LogicalKeyboardKey.controlLeft);

        final result = attachment.handleKeyEvent(
          keyDown(PhysicalKeyboardKey.keyC, LogicalKeyboardKey.keyC),
        );

        expect(result, KeyEventResult.handled);
        expect(output, [0x03]);
      });

      test('Cmd+Left still encodes to the PTY', () async {
        await simulateKeyDownEvent(LogicalKeyboardKey.metaLeft);

        final result = attachment.handleKeyEvent(
          keyDown(PhysicalKeyboardKey.arrowLeft, LogicalKeyboardKey.arrowLeft),
        );

        expect(result, KeyEventResult.handled);
        expect(utf8.decode(output), '\x1b[1;9D');
      });
    });
  });
}

final class _InspectableFocusNode extends FocusNode {
  bool get hasFocusListeners => hasListeners;
}
