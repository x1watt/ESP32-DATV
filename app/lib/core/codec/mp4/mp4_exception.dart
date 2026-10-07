/// Thrown when an MP4 file is malformed or not an ISO BMFF file at all.
class Mp4FormatException implements Exception {
  const Mp4FormatException(this.message);

  final String message;

  @override
  String toString() => 'Mp4FormatException: $message';
}
