# noted_box_template

A minimal box module for Noted: a *sticky label* with one text field and a
colour from a small palette. Copy it to start a new box type.

- `lib/src/sticky_label_codec.dart`: the data side (`BoxCodec`), every member
  commented.
- `lib/src/sticky_label_module.dart`: the widgets (`BoxModule`) and a list of
  the optional hooks.
- `test/`: codec, page format, pass-through of unknown data, and canvas tests.

It is compiled into the app but switched off by default
(`app/lib/main.dart`). The full guide for module authors is
[`docs/box-modules.md`](../../../docs/box-modules.md).
