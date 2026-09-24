// How the UI groups files, derived from their media type.

enum FileKind {
  document,
  book,
  image,
  audio,
  video,
  software,
  dataset,
  map,
  archive,
}

FileKind kindForMime(String mime) {
  if (mime.startsWith('image/')) return FileKind.image;
  if (mime.startsWith('audio/')) return FileKind.audio;
  if (mime.startsWith('video/')) return FileKind.video;
  return switch (mime) {
    'application/epub+zip' => FileKind.book,
    'application/zip' ||
    'application/x-tar' ||
    'application/gzip' => FileKind.archive,
    'text/csv' ||
    'application/json' ||
    'application/x-protobuf' => FileKind.dataset,
    'application/gpx+xml' ||
    'application/vnd.google-earth.kml+xml' => FileKind.map,
    'application/x-executable' ||
    'application/vnd.android.package-archive' => FileKind.software,
    _ => FileKind.document,
  };
}
