import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/services.dart';
import 'package:libghostty/libghostty.dart' show Mods;
import 'package:meta/meta.dart';

@internal
Mods consumedModifiersFor(
  String? character, {
  required int unshiftedCodepoint,
  required Mods mods,
}) {
  if (character == null || unshiftedCodepoint == 0) return const .none();

  final codepoints = character.runes.iterator;
  if (!codepoints.moveNext()) return const .none();
  final codepoint = codepoints.current;
  if (codepoints.moveNext() || codepoint == unshiftedCodepoint) {
    return const .none();
  }

  var consumedMods = const Mods.none();
  if (mods.hasShift) consumedMods |= const .shift();

  final keyboard = HardwareKeyboard.instance;
  // We only reach this point when a composed character that differs from the
  // base key was produced, so whichever Alt is held was consumed to make it.
  // macOS has no AltGr: both Option keys compose (there is no left-Alt-is-Meta
  // / right-Alt-is-AltGr split), so either side counts. Elsewhere only the
  // right Alt (AltGr) composes; the left Alt stays Meta and is not consumed.
  final altComposed = defaultTargetPlatform == TargetPlatform.macOS
      ? mods.hasAlt
      : mods.hasAlt && keyboard.isLogicalKeyPressed(.altRight);
  if (altComposed) {
    consumedMods |= const .alt();
    if (keyboard.isControlPressed) consumedMods |= const .ctrl();
  }
  return consumedMods;
}

@internal
Mods readPointerModifiers(Mods virtualMods) {
  var mods = virtualMods;
  final keyboard = HardwareKeyboard.instance;
  if (keyboard.isShiftPressed) mods |= const .shift();
  if (keyboard.isControlPressed) mods |= const .ctrl();
  if (keyboard.isAltPressed) mods |= const .alt();
  if (keyboard.isMetaPressed) mods |= const .superKey();
  return mods;
}
