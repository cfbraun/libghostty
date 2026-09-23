import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:libghostty/libghostty.dart'
    show MouseAction, MouseButton, Position;
import 'package:meta/meta.dart';

import '../foundation.dart';
import '../interaction/selection_session.dart';
import '../links/link_interaction.dart';
import '../links/link_settings.dart';
import '../view/view_attachment.dart';
import 'input_message.dart';
import 'primitive_gesture_detector.dart';
import 'scroll_gesture_region.dart';

/// Owns pointer-sequence arbitration for one terminal view.
///
/// It keeps mouse reporting, selection, link activation, and cancellation on
/// the same pointer identity. Terminal-directed wheel, touch, and trackpad
/// motion is delegated to [ScrollGestureRegion]. All resulting terminal
/// actions cross [ViewAttachment] as normalized values.
///
/// Pointer ownership is decided once per sequence. Modifier changes may alter
/// the shape of an active selection, but they do not transfer the sequence to
/// link activation or terminal mouse reporting. Cancellation releases every
/// owned interaction before another pointer can claim it.
@internal
final class InteractionRegion extends StatefulWidget {
  final Widget child;
  final CellMetrics metrics;
  final LinkInteraction links;
  final ViewAttachment attachment;
  final ScrollPhysics scrollPhysics;
  final ViewInteractionState interaction;
  final TerminalGestureSettings settings;
  final ScrollController? scrollController;
  final ValueChanged<ActivatedLink>? onLinkActivate;

  const InteractionRegion({
    super.key,
    required this.child,
    required this.links,
    required this.metrics,
    required this.attachment,
    required this.interaction,
    this.onLinkActivate,
    this.scrollController,
    this.settings = const TerminalGestureSettings(),
    this.scrollPhysics = const ClampingScrollPhysics(),
  });

  @override
  State<InteractionRegion> createState() => _InteractionRegionState();
}

final class _InteractionRegionState extends State<InteractionRegion> {
  static const _mouseButtons = <int, MouseButton>{
    kPrimaryMouseButton: .left,
    kMiddleMouseButton: .middle,
    kSecondaryMouseButton: .right,
    kBackMouseButton: .eight,
    kForwardMouseButton: .nine,
  };
  static const _supportedMouseButtons =
      kPrimaryMouseButton |
      kMiddleMouseButton |
      kSecondaryMouseButton |
      kBackMouseButton |
      kForwardMouseButton;

  final _activePointers = <int, _TrackedPointer>{};
  Timer? _autoScrollTimer;
  _DragState? _drag;
  int? _interactionPointer;
  Duration? _interactionTimeStamp;
  var _linkPressActive = false;
  Position? _pressCell;
  var _terminalDragActive = false;
  var _terminalOwnsInteraction = false;

  ViewAttachment get _attachment => widget.attachment;

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: _handleTrackedDown,
      onPointerMove: _handleTrackedMove,
      onPointerHover: _handleTrackedHover,
      onPointerUp: _handleTrackedUp,
      onPointerCancel: _handleTrackedCancel,
      child: ScrollGestureRegion(
        metrics: widget.metrics,
        attachment: widget.attachment,
        physics: widget.scrollPhysics,
        interaction: widget.interaction,
        onScrollStart: _handleScrollStart,
        child: PrimitiveGestureDetector(
          onTapDown: _handleTapDown,
          onTapUp: _handleTapUp,
          onDragStart: _handleDragStart,
          onDragUpdate: _handleDragUpdate,
          onDragEnd: _endDrag,
          onLongPressStart: _handleLongPressStart,
          onLongPressMoveUpdate: _handleLongPressMoveUpdate,
          onLongPressUp: _endDrag,
          child: widget.child,
        ),
      ),
    );
  }

  @override
  void didUpdateWidget(InteractionRegion oldWidget) {
    super.didUpdateWidget(oldWidget);
    final attachmentChanged = widget.attachment != oldWidget.attachment;
    if (attachmentChanged) {
      _interactionPointer = null;
      _interactionTimeStamp = null;
      _terminalDragActive = false;
      _terminalOwnsInteraction = false;
    }
    if (widget.links != oldWidget.links && _linkPressActive) {
      _linkPressActive = false;
      oldWidget.links.cancel();
    }
    if (widget.metrics != oldWidget.metrics || attachmentChanged) {
      final attachment = attachmentChanged
          ? oldWidget.attachment
          : widget.attachment;
      _cancelSelectionInteraction(attachment);
      if (!attachmentChanged) attachment.invalidateSelection();
    }
    if (attachmentChanged) _releaseTrackedPointers(oldWidget.attachment);
  }

  @override
  void dispose() {
    _cancelSelectionInteraction(widget.attachment);
    _releaseTrackedPointers(widget.attachment);
    super.dispose();
  }

  void _autoScrollTick(Timer timer) {
    final scrollController = widget.scrollController;
    if (scrollController == null || !scrollController.hasClients) {
      _stopAutoScroll();
      return;
    }

    final drag = _drag;
    if (drag == null) {
      _stopAutoScroll();
      return;
    }

    _attachment.updateSelectionAutoscroll(
      SelectionAutoscrollInput(
        cell: drag.cell,
        pixelX: drag.localPosition.dx,
        pixelY: drag.localPosition.dy,
        rectangle: drag.lastRectangle,
      ),
    );
  }

  MouseButton? _buttonForDownEvent(PointerDownEvent event) {
    return switch (event.kind) {
      .touch => .left,
      .mouse => _mouseButtonForBit(
        smallestButton(event.buttons & _supportedMouseButtons),
      ),
      .stylus || .invertedStylus => _stylusButtonForMask(event.buttons),
      _ => null,
    };
  }

  void _cancelLinkPress() {
    if (!_linkPressActive) return;
    _linkPressActive = false;
    widget.links.cancel();
  }

  void _cancelSelectionInteraction(
    ViewAttachment attachment, {
    bool clearSelection = false,
  }) {
    if (clearSelection || _drag != null || _pressCell != null) {
      attachment.cancelSelectionGesture();
    }
    _cancelLinkPress();
    _clearDrag();
    _pressCell = null;
  }

  void _cancelSelectionPress() {
    if (_pressCell == null) return;
    _attachment.cancelSelectionGesture();
    _pressCell = null;
  }

  void _clearDrag() {
    if (_drag == null) return;
    HardwareKeyboard.instance.removeHandler(_handleModifierKey);
    _stopAutoScroll();
    _drag = null;
  }

  void _endDrag() {
    if (_terminalDragActive) {
      _terminalDragActive = false;
      _terminalOwnsInteraction = false;
      return;
    }
    final drag = _drag;
    if (drag == null) return;
    _releaseSelectionPress(drag.cell);
    _clearDrag();
    _cancelLinkPress();
    _terminalOwnsInteraction = false;
  }

  void _handleDragStart(DragStartDetails details) {
    _attachment.requestFocus();
    _cancelLinkPress();
    if (_terminalOwnsInteraction) {
      _terminalDragActive = true;
      return;
    }
    if (!widget.settings.dragSelection) {
      _cancelSelectionPress();
      return;
    }

    _startDrag(
      details.localPosition,
      beginPress: _pressCell == null,
      timeStamp: details.sourceTimeStamp ?? _interactionTimeStamp,
    );
  }

  void _handleDragUpdate(DragUpdateDetails details) {
    if (_drag != null) _updateDrag(details.localPosition);
  }

  void _handleLongPressMoveUpdate(LongPressMoveUpdateDetails details) {
    if (_drag != null) _updateDrag(details.localPosition);
  }

  void _handleLongPressStart(LongPressStartDetails details) {
    _attachment.requestFocus();
    if (_terminalOwnsInteraction) return;
    if (!widget.settings.longPressSelection) {
      _cancelSelectionPress();
      return;
    }
    _startDrag(
      details.localPosition,
      rectangle: widget.settings.longPressSelectionShape == .rectangle,
      beginPress: _pressCell == null,
      timeStamp: _interactionTimeStamp,
    );
  }

  bool _handleModifierKey(KeyEvent _) {
    final drag = _drag;
    if (drag != null) _updateDrag(drag.localPosition);
    return false;
  }

  void _handleScrollStart(PointerDeviceKind kind) {
    _cancelSelectionInteraction(_attachment, clearSelection: true);
    if (kind == .touch) {
      _attachment.requestFocus();
      _activePointers.removeWhere((_, pointer) => pointer.kind == .touch);
    }
  }

  void _handleSelectionPress(Offset position, Duration? timeStamp) {
    final settings = widget.settings;
    final cell = widget.metrics.cellAt(position);
    _attachment.handleSelectionPress(
      SelectionPressInput(
        cell: cell,
        pixelX: position.dx,
        pixelY: position.dy,
        behaviors: settings.selectionBehaviors,
        wordBoundaries: settings.wordBoundaries,
        repeatDistance: kDoubleTapSlop,
        repeatInterval: kDoubleTapTimeout,
        timeStamp: timeStamp ?? Duration.zero,
        fullWidthLine: settings.lineSelectMode == .full,
      ),
    );
    _pressCell = cell;
  }

  void _handleTapDown(TapDownDetails details, Duration timeStamp) {
    _attachment.requestFocus();
    if (_terminalOwnsInteraction) return;
    if (widget.links.handlePress(
      localPosition: details.localPosition,
      metrics: widget.metrics,
      pointerKind: details.kind ?? .mouse,
      virtualMods: _attachment.virtualMods,
    )) {
      _linkPressActive = true;
      _cancelSelectionPress();
      return;
    }
    _handleSelectionPress(details.localPosition, timeStamp);
  }

  void _handleTapUp(TapUpDetails details) {
    if (_linkPressActive) {
      _linkPressActive = false;
      final link = widget.links.handleRelease(
        localPosition: details.localPosition,
        metrics: widget.metrics,
      );
      if (link != null) widget.onLinkActivate?.call(link);
      _terminalOwnsInteraction = false;
      return;
    }
    if (_terminalOwnsInteraction) {
      _terminalOwnsInteraction = false;
      return;
    }
    if (_pressCell == null && _isMouseTracked()) {
      return;
    }
    _releaseSelectionPress(widget.metrics.cellAt(details.localPosition));
  }

  void _handleTrackedCancel(PointerCancelEvent event) {
    final pointer = _activePointers[event.pointer];
    if (pointer != null && pointer.kind != .touch) {
      _releaseTrackedPointer(event.pointer, event.localPosition);
    } else {
      _activePointers.remove(event.pointer);
    }
    if (_interactionPointer != event.pointer) return;
    _interactionPointer = null;
    _interactionTimeStamp = null;
    _terminalDragActive = false;
    _terminalOwnsInteraction = false;
    _cancelSelectionPress();
    _cancelLinkPress();
    _clearDrag();
  }

  void _handleTrackedDown(PointerDownEvent event) {
    if (_activePointers.containsKey(event.pointer)) return;
    // A modified click on a link opens the link even when the application
    // tracks the mouse; the tap handler then claims it as a link press.
    final tracked = _isMouseTracked() && !_linkClaimsPress(event);
    final button = tracked ? _buttonForDownEvent(event) : null;
    if (_interactionPointer == null) {
      _interactionPointer = event.pointer;
      _interactionTimeStamp = event.timeStamp;
      _terminalOwnsInteraction = button != null;
    }
    if (!tracked) return;
    if (button == null) return;
    if (event.kind == .touch && _interactionPointer != event.pointer) return;

    final pointer = _TrackedPointer(
      button: button,
      buttons: 0,
      kind: event.kind,
      position: event.localPosition,
      tapCandidate: event.kind == .touch,
    );
    _activePointers[event.pointer] = pointer;
    if (event.kind == .mouse) {
      _updateMouseButtons(pointer, event.buttons, event.localPosition);
      return;
    }
    if (event.kind == .stylus || event.kind == .invertedStylus) {
      _updateStylusButton(pointer, event.buttons, event.localPosition);
    }
  }

  void _handleTrackedHover(PointerHoverEvent event) {
    if (!_isMouseTracked()) return;
    if (!_isHoverKind(event.kind)) return;
    _sendMouseEvent(.motion, event.localPosition);
  }

  void _handleTrackedMove(PointerMoveEvent event) {
    final pointer = _activePointers[event.pointer];
    if (pointer == null) return;
    if (pointer.tapCandidate &&
        (event.localPosition - pointer.downPosition).distance > kTouchSlop) {
      pointer.tapCandidate = false;
    }
    final moved = pointer.position != event.localPosition;
    if (pointer.kind == .mouse) {
      _updateMouseButtons(pointer, event.buttons, event.localPosition);
      if (!moved) return;
    } else if (pointer.kind == .stylus || pointer.kind == .invertedStylus) {
      _updateStylusButton(pointer, event.buttons, event.localPosition);
      if (!moved) return;
    } else {
      pointer.position = event.localPosition;
    }
    if (pointer.kind == .touch) return;
    _sendMouseEvent(
      .motion,
      event.localPosition,
      button: pointer.buttons == 0 ? null : pointer.button,
    );
  }

  void _handleTrackedUp(PointerUpEvent event) {
    _releaseTrackedPointer(event.pointer, event.localPosition);
    if (_interactionPointer == event.pointer) {
      _interactionPointer = null;
      _interactionTimeStamp = null;
    }
  }

  bool _isBlockModifierPressed() {
    final modifier = widget.settings.blockSelectionModifier;
    if (modifier == null) return false;
    final keyboard = HardwareKeyboard.instance;
    final mods = _attachment.virtualMods;
    return switch (modifier) {
      .alt => keyboard.isAltPressed || mods.hasAlt,
      .meta => keyboard.isMetaPressed || mods.hasSuper,
      .shift => keyboard.isShiftPressed || mods.hasShift,
      .control => keyboard.isControlPressed || mods.hasCtrl,
    };
  }

  bool _isHoverKind(PointerDeviceKind kind) => switch (kind) {
    .mouse || .stylus || .invertedStylus => true,
    _ => false,
  };

  bool _linkClaimsPress(PointerDownEvent event) {
    if (event.kind != .mouse) return false;
    return widget.links.claimsModifiedPress(
      localPosition: event.localPosition,
      metrics: widget.metrics,
      virtualMods: _attachment.virtualMods,
    );
  }

  bool _isMouseTracked() {
    return _attachment.mouseTracking != .none &&
        !HardwareKeyboard.instance.isShiftPressed &&
        !_attachment.virtualMods.hasShift;
  }

  MouseButton? _mouseButtonForBit(int button) => _mouseButtons[button];

  void _releaseSelectionPress([Position? cell]) {
    cell ??= _pressCell;
    if (cell == null) return;
    _attachment.handleSelectionRelease(cell);
    _pressCell = null;
  }

  void _releaseTrackedPointer(
    int pointerId,
    Offset position, {
    ViewAttachment? attachment,
  }) {
    final pointer = _activePointers[pointerId];
    if (pointer == null) return;
    pointer.position = position;
    if (pointer.kind == .mouse) {
      _updateMouseButtons(pointer, 0, position, attachment: attachment);
    } else if (pointer.kind == .stylus || pointer.kind == .invertedStylus) {
      _updateStylusButton(pointer, 0, position, attachment: attachment);
    } else if (pointer.kind == .touch && pointer.tapCandidate) {
      pointer.buttons = kPrimaryButton;
      _sendMouseEvent(
        .press,
        position,
        button: pointer.button,
        attachment: attachment,
      );
      pointer.buttons = 0;
      _sendMouseEvent(
        .release,
        position,
        button: pointer.button,
        attachment: attachment,
      );
    }
    _activePointers.remove(pointerId);
  }

  void _releaseTrackedPointers(ViewAttachment attachment) {
    _activePointers.removeWhere((_, pointer) => pointer.kind == .touch);
    while (_activePointers.isNotEmpty) {
      final entry = _activePointers.entries.first;
      _releaseTrackedPointer(
        entry.key,
        entry.value.position,
        attachment: attachment,
      );
    }
  }

  void _sendMouseEvent(
    MouseAction action,
    Offset position, {
    MouseButton? button,
    ViewAttachment? attachment,
  }) {
    final target = attachment ?? _attachment;
    target.handleMouseEvent(
      MouseInput(
        action: action,
        anyButtonPressed: _activePointers.values.any(
          (pointer) => pointer.buttons != 0,
        ),
        button: button,
        mods: target.currentMods,
        pixelX: position.dx,
        pixelY: position.dy,
      ),
    );
  }

  void _startAutoScroll() {
    if (_autoScrollTimer != null) return;
    final scrollController = widget.scrollController;
    if (scrollController == null || !scrollController.hasClients) return;
    _autoScrollTimer = Timer.periodic(
      const Duration(milliseconds: 50),
      _autoScrollTick,
    );
  }

  void _startDrag(
    Offset position, {
    bool rectangle = false,
    bool beginPress = false,
    required Duration? timeStamp,
  }) {
    final cell = widget.metrics.cellAt(position);
    final block = rectangle || _isBlockModifierPressed();
    if (_drag == null) HardwareKeyboard.instance.addHandler(_handleModifierKey);
    _drag = _DragState(
      cell,
      position,
      fixedRectangle: rectangle,
      lastRectangle: block,
    );
    if (beginPress) _handleSelectionPress(position, timeStamp);
  }

  void _stopAutoScroll() {
    _autoScrollTimer?.cancel();
    _autoScrollTimer = null;
  }

  MouseButton? _stylusButtonForMask(int buttons) {
    const supported =
        kStylusContact | kPrimaryStylusButton | kSecondaryStylusButton;
    if (buttons & ~supported != 0) return null;
    final barrel = buttons & (kPrimaryStylusButton | kSecondaryStylusButton);
    return switch (barrel) {
      0 when buttons == kStylusContact => .left,
      kPrimaryStylusButton => .right,
      kSecondaryStylusButton => .middle,
      _ => null,
    };
  }

  void _updateDrag(Offset position) {
    final drag = _drag;
    if (drag == null) return;
    final cell = widget.metrics.cellAt(position);
    drag.cell = cell;
    drag.localPosition = position;

    final visibleRows = _attachment.terminal.geometry.rows;
    if (visibleRows > 0) {
      if (cell.row < 0 || cell.row >= visibleRows) {
        _startAutoScroll();
      } else {
        _stopAutoScroll();
      }
    }

    final clampedRow = visibleRows > 0
        ? cell.row.clamp(0, visibleRows - 1)
        : cell.row;
    final clampedCell = Position(row: clampedRow, col: cell.col);
    final rectangle = drag.fixedRectangle || _isBlockModifierPressed();
    if (clampedCell == drag.lastCell && rectangle == drag.lastRectangle) {
      return;
    }
    drag.lastCell = clampedCell;
    drag.lastRectangle = rectangle;

    _attachment.updateSelectionDrag(
      SelectionDragInput(
        cell: clampedCell,
        pixelX: position.dx,
        pixelY: position.dy,
        rectangle: rectangle,
      ),
    );
  }

  void _updateMouseButtons(
    _TrackedPointer pointer,
    int buttons,
    Offset position, {
    ViewAttachment? attachment,
  }) {
    final nextButtons = buttons & _supportedMouseButtons;
    final previousButtons = pointer.buttons;
    final removed = previousButtons & ~nextButtons;
    final added = nextButtons & ~previousButtons;
    pointer.buttons = nextButtons;

    for (final entry in _mouseButtons.entries) {
      if (removed & entry.key == 0) continue;
      _sendMouseEvent(
        .release,
        position,
        button: entry.value,
        attachment: attachment,
      );
    }

    for (final entry in _mouseButtons.entries) {
      if (added & entry.key == 0) continue;
      pointer.button = entry.value;
      _sendMouseEvent(
        .press,
        position,
        button: entry.value,
        attachment: attachment,
      );
    }

    if (pointer.buttons != 0 &&
        !_mouseButtons.entries.any(
          (entry) =>
              entry.value == pointer.button && pointer.buttons & entry.key != 0,
        )) {
      pointer.button = _mouseButtonForBit(smallestButton(pointer.buttons))!;
    }
    pointer.position = position;
  }

  void _updateStylusButton(
    _TrackedPointer pointer,
    int buttons,
    Offset position, {
    ViewAttachment? attachment,
  }) {
    final previousButton = pointer.buttons == 0 ? null : pointer.button;
    final nextButton = _stylusButtonForMask(buttons);
    pointer.buttons = nextButton == null ? 0 : kPrimaryButton;

    if (previousButton != nextButton) {
      if (previousButton != null) {
        _sendMouseEvent(
          .release,
          position,
          button: previousButton,
          attachment: attachment,
        );
      }
      if (nextButton != null) {
        pointer.button = nextButton;
        _sendMouseEvent(
          .press,
          position,
          button: nextButton,
          attachment: attachment,
        );
      }
    }
    pointer.position = position;
  }
}

final class _DragState {
  final bool fixedRectangle;
  Position cell;
  Position? lastCell;
  bool lastRectangle;
  Offset localPosition;

  _DragState(
    this.cell,
    this.localPosition, {
    required this.fixedRectangle,
    required this.lastRectangle,
  });
}

final class _TrackedPointer {
  final Offset downPosition;
  final PointerDeviceKind kind;
  MouseButton button;
  int buttons;
  Offset position;
  bool tapCandidate;

  _TrackedPointer({
    required this.button,
    required this.buttons,
    required this.kind,
    required this.position,
    required this.tapCandidate,
  }) : downPosition = position;
}
