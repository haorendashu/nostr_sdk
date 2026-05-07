import '../nostr.dart';
import 'blossom_util.dart';

class BolssomUploader {
  static Future<String?> upload(Nostr nostr, String endPoint, String filePath,
      {String? fileName}) async {
    final descriptor = await BlossomUtil.upload(
      nostr,
      endPoint,
      filePath,
      fileName: fileName,
    );
    return descriptor?.url;
  }
}
