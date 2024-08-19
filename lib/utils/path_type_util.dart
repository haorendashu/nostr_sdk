import 'base64.dart';

class PathTypeUtil {
  static String? getPathType(String path) {
    if (path.indexOf(BASE64.PREFIX) == 0) {
      return "image";
    }

    var strs = path.split("?");
    strs = strs[0].split("#");
    var index = strs[0].lastIndexOf(".");
    if (index == -1) {
      return null;
    }

    path = strs[0];
    var n = path.substring(index);
    n = n.toLowerCase();

    if (n == ".png" ||
        n == ".jpg" ||
        n == ".jpeg" ||
        n == ".gif" ||
        n == ".webp") {
      return "image";
    } else if (n == ".mp4" ||
        n == ".mov" ||
        n == ".m4v" ||
        n == ".wmv" ||
        n == ".m3u8") {
      return "video";
    } else if (n == ".mp3" || n == ".m4a" || n == ".wav" || n == ".midi") {
      return "audio";
    } else {
      if (path.contains("void.cat/d/")) {
        return "image";
      }
      return "link";
    }
  }
}
