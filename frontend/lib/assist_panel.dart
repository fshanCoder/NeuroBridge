import 'dart:async';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

typedef AssistChoice = (String, VoidCallback);

class AssistPanel extends StatefulWidget {
  const AssistPanel(
      {super.key,
      required this.choices,
      required this.initialScan,
      required this.initialDwell,
      required this.onMode,
      required this.scanMs,
      required this.dwellMs});
  final List<AssistChoice> choices;
  final bool initialScan, initialDwell;
  final void Function(bool, bool) onMode;
  final int scanMs, dwellMs;
  @override
  State<AssistPanel> createState() => _AssistPanelState();
}

class _AssistPanelState extends State<AssistPanel> {
  Timer? scan, dwell;
  int index = 0;
  bool scanning = false, dwelling = false;
  String? hover;
  final focus = FocusNode();
  final targets = <String, GlobalKey>{};
  @override
  void initState() {
    super.initState();
    dwelling = widget.initialDwell;
    if (widget.initialScan) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) toggleScan();
      });
    }
  }

  @override
  void dispose() {
    scan?.cancel();
    dwell?.cancel();
    focus.dispose();
    super.dispose();
  }

  void toggleScan() {
    scan?.cancel();
    setState(() => scanning = !scanning);
    widget.onMode(scanning, dwelling);
    if (scanning) {
      focus.requestFocus();
      scan = Timer.periodic(Duration(milliseconds: widget.scanMs), (_) {
        if (mounted) {
          setState(() => index = (index + 1) % widget.choices.length);
          final target = targets[widget.choices[index].$1]?.currentContext;
          if (target != null) {
            Scrollable.ensureVisible(target,
                alignmentPolicy:
                    ScrollPositionAlignmentPolicy.keepVisibleAtEnd);
          }
        }
      });
    }
  }

  void choose(int i) {
    widget.choices[i].$2();
  }

  void enter(int i) {
    if (!dwelling || hover == widget.choices[i].$1) return;
    dwell?.cancel();
    final label = widget.choices[i].$1;
    setState(() => hover = label);
    dwell = Timer(Duration(milliseconds: widget.dwellMs), () {
      if (mounted && hover == label && widget.choices[i].$1 == label) choose(i);
    });
  }

  @override
  Widget build(BuildContext context) => Focus(
      focusNode: focus,
      autofocus: true,
      onKeyEvent: (_, e) {
        if (scanning &&
            (e.logicalKey == LogicalKeyboardKey.space ||
                e.logicalKey == LogicalKeyboardKey.enter)) {
          if (e is KeyDownEvent) choose(index);
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Wrap(spacing: 8, children: [
          OutlinedButton(
              onPressed: toggleScan,
              child: Text(scanning ? 'Pause scanning' : 'Start scanning')),
          FilterChip(
              label: const Text('Dwell selection'),
              selected: dwelling,
              onSelected: (v) {
                dwell?.cancel();
                setState(() {
                  dwelling = v;
                  widget.onMode(scanning, v);
                  hover = null;
                });
              }),
        ]),
        if (scanning)
          FilledButton(
              onPressed: () => choose(index),
              child: Text('Select highlighted: ${widget.choices[index].$1}')),
        if (scanning)
          const Text('Press Space or Enter to select the highlighted action.'),
        if (dwelling)
          Text(
              'Hold the pointer over a choice for ${widget.dwellMs / 1000} seconds.'),
        for (final (i, choice) in widget.choices.indexed)
          MouseRegion(
              key: targets.putIfAbsent(choice.$1, () => GlobalKey()),
              onHover: (_) => enter(i),
              onExit: (_) {
                dwell?.cancel();
                if (mounted) setState(() => hover = null);
              },
              child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                          minimumSize: const Size(56, 56),
                          side: BorderSide(
                              width:
                                  scanning && index == i || hover == choice.$1
                                      ? 4
                                      : 1,
                              color: const Color(0xff125e59))),
                      onPressed: () => choose(i),
                      child: Text(choice.$1)))),
      ]));
}
