// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// The formats an import knows, by file extension.
enum ImportFormat {
  text('Text', {'txt'}),
  markdown('Markdown', {'md', 'markdown'}),
  word('Word', {'docx'}),
  sheet('Excel', {'xlsx'}),
  csv('Table', {'csv', 'tsv'}),
  pdf('PDF', {'pdf'}),
  slides('PowerPoint', {'pptx'}),
  image('Image', {'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'});

  const ImportFormat(this.label, this.extensions);

  final String label;
  final Set<String> extensions;

  /// The format of a file called [name], or null if it isn't one.
  static ImportFormat? of(String name) {
    final dot = name.lastIndexOf('.');
    if (dot < 0) return null;
    final ext = name.substring(dot + 1).toLowerCase();
    for (final f in values) {
      if (f.extensions.contains(ext)) return f;
    }
    return null;
  }

  /// Every extension an import takes.
  static Set<String> get allExtensions => {for (final f in values) ...f.extensions};
}

/// The extensions the open dialog offers.
List<String> get importPickerExtensions => [
  for (final f in ImportFormat.values) ...f.extensions,
];

/// One way a format can be imported.
enum ImportChoice {
  asText('As text', _note),
  asTable('As a table', _note),
  asImage('As an image', _image),
  pagesAsImages('Pages as images', _image),
  slidesAsImages('Slides as images', _image),
  asFile('As a file', _file);

  const ImportChoice(this.label, this.typeId);

  final String label;

  /// The type of the box it makes.
  final String typeId;

  /// Whether it is made of note blocks.
  bool get makesNotes => this == asText || this == asTable;
}

const String _note = 'noted.note';
const String _image = 'noted.image';
const String _file = 'noted.file';

/// What this device can render as images.
final class ImportCapabilities {
  const ImportCapabilities({
    this.pdfPages = false,
    this.sheetImages = false,
    this.wordPageImages = false,
    this.slideImages = false,
  });

  /// PDF pages as images: needs the platform renderer (stage B).
  final bool pdfPages;

  /// A sheet as an image, drawn from the parsed tables (stage B).
  final bool sheetImages;

  /// Word pages and slides as images need an Office layout engine; no
  /// platform has one the import can use.
  final bool wordPageImages;
  final bool slideImages;
}

/// A choice in the dialog: on, or off with the reason it shows.
final class ImportOption {
  const ImportOption(this.choice, {this.off});

  final ImportChoice choice;

  /// Why it can't be chosen, or null.
  final String? off;

  bool get enabled => off == null;
}

/// The choices of [format], the first enabled one the default. A choice whose
/// box type the page disallows is off with "Not allowed on this page".
List<ImportOption> importOptions(
  ImportFormat format,
  ImportCapabilities caps, {
  Set<String> disallowed = const {},
}) {
  ImportOption opt(ImportChoice c, [String? unavailable]) {
    if (unavailable != null) return ImportOption(c, off: unavailable);
    return ImportOption(c, off: disallowed.contains(c.typeId) ? 'Not allowed on this page' : null);
  }

  String cant(String what) => "This device can't show $what as images";
  return switch (format) {
    ImportFormat.text || ImportFormat.markdown => [opt(ImportChoice.asText), opt(ImportChoice.asFile)],
    ImportFormat.word => [
      opt(ImportChoice.asText),
      opt(ImportChoice.asImage, caps.wordPageImages ? null : cant('Word pages')),
      opt(ImportChoice.asFile),
    ],
    ImportFormat.sheet || ImportFormat.csv => [
      opt(ImportChoice.asTable),
      opt(ImportChoice.asImage, caps.sheetImages ? null : cant('sheets')),
      opt(ImportChoice.asFile),
    ],
    ImportFormat.pdf => [
      opt(ImportChoice.pagesAsImages, caps.pdfPages ? null : cant('PDF pages')),
      opt(ImportChoice.asFile),
    ],
    ImportFormat.slides => [
      opt(ImportChoice.slidesAsImages, caps.slideImages ? null : cant('slides')),
      opt(ImportChoice.asFile),
    ],
    ImportFormat.image => const [],
  };
}

/// Whether [format] has a choice besides a file box on this device and page,
/// so that dropping it asks. One that doesn't is added as a file, as before.
bool importAsks(ImportFormat format, ImportCapabilities caps, Set<String> disallowed) =>
    importOptions(format, caps, disallowed: disallowed).any((o) => o.enabled && o.choice != ImportChoice.asFile);
