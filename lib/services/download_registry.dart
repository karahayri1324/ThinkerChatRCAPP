/// Local paths currently claimed by an in-flight download.
///
/// A download's file is not created until its first chunk lands, so an
/// existence check alone can't stop two concurrent transfers of the same
/// basename from picking the same path. The same registry lets the downloads
/// manager hide files that are still being written.
class DownloadRegistry {
  DownloadRegistry._();

  static final Set<String> activePaths = <String>{};

  static bool isActive(String path) => activePaths.contains(path);
  static void reserve(String path) => activePaths.add(path);
  static void release(String path) => activePaths.remove(path);
}
