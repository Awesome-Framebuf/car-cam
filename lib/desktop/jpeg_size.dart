import 'dart:typed_data';

/// Width and height from a JPEG's start-of-frame marker, or null.
(int, int)? jpegSize(Uint8List j) {
  var i = 2;
  while (i + 9 < j.length) {
    if (j[i] != 0xFF) return null;
    final marker = j[i + 1];
    final len = (j[i + 2] << 8) | j[i + 3];
    if (marker >= 0xC0 && marker <= 0xC3) {
      final h = (j[i + 5] << 8) | j[i + 6];
      final w = (j[i + 7] << 8) | j[i + 8];
      return (w, h);
    }
    i += 2 + len;
  }
  return null;
}
