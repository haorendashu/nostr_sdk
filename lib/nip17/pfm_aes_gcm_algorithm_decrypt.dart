import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:hex/hex.dart';

import 'pfm_algorithm_decrypt.dart';

class PfmAesGcmAlgorithmDecrypt extends PfmAlgorithmDecrypt {
  String encryptionAlgorithm;
  final Uint8List decryptionKey;
  final Uint8List decryptionNonce;

  PfmAesGcmAlgorithmDecrypt(this.encryptionAlgorithm, String decryptionKeyText,
      String decryptionNonceText)
      : decryptionKey =
            Uint8List.fromList(HEX.decoder.convert(decryptionKeyText)),
        decryptionNonce =
            Uint8List.fromList(HEX.decoder.convert(decryptionNonceText));

  AesGcm _getAlgorithm() {
    var nonceLength = decryptionNonce.length;
    switch (decryptionKey.length) {
      case 16:
        return AesGcm.with128bits(
          nonceLength: nonceLength,
        );
      case 24:
        return AesGcm.with192bits(
          nonceLength: nonceLength,
        );
      case 32:
        return AesGcm.with256bits(
          nonceLength: nonceLength,
        );
      default:
        throw StateError('Invalid key length: ${decryptionKey.length} bytes. '
            'Key must be 16, 24, or 32 bytes long.');
    }
  }

  @override
  Future<Uint8List> decrypt(Uint8List data) async {
    final secretKey = SecretKey(decryptionKey);

    final algorithm = _getAlgorithm();

    final macBytes = data.sublist(data.length - 16);
    final cipherText = data.sublist(0, data.length - 16);

    final secretBox = SecretBox(
      cipherText,
      nonce: decryptionNonce,
      mac: Mac(macBytes),
    );

    return Uint8List.fromList(await algorithm.decrypt(
      secretBox,
      secretKey: secretKey,
    ));
  }
}
