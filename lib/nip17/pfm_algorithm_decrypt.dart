import 'dart:typed_data';

import 'package:nostr_sdk/utils/string_util.dart';

import '../event.dart';
import '../event_kind.dart';
import 'pfm_aes_gcm_algorithm_decrypt.dart';

abstract class PfmAlgorithmDecrypt {
  static PfmAlgorithmDecrypt? getFromEvent(Event event) {
    if (event.kind == EventKind.PRIVATE_FILE_MESSAGE) {
      String? encryptionAlgorithm;
      String? decryptionKey;
      String? decryptionNonce;

      for (var tag in event.tags) {
        if (tag is List && tag.length > 1) {
          if (tag[0] == "encryption-algorithm") {
            encryptionAlgorithm = tag[1];
          } else if (tag[0] == "decryption-key") {
            decryptionKey = tag[1];
          } else if (tag[0] == "decryption-nonce") {
            decryptionNonce = tag[1];
          }
        }
      }

      if (StringUtil.isNotBlank(encryptionAlgorithm) &&
          StringUtil.isNotBlank(decryptionKey) &&
          StringUtil.isNotBlank(decryptionNonce)) {
        if (encryptionAlgorithm == "aes-gcm") {
          return PfmAesGcmAlgorithmDecrypt(
              encryptionAlgorithm!, decryptionKey!, decryptionNonce!);
        }
      }
    }

    return null;
  }

  Future<Uint8List> decrypt(Uint8List data);
}
