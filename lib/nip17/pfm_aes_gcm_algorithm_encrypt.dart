import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:hex/hex.dart';
import 'dart:math' as math;

import 'pfm_algorithm_encrypt.dart';

class PfmAesGcmAlgorithmEncrypt extends PfmAlgorithmEncrypt {
  late final Uint8List _key;
  late final Uint8List _nonce;

  PfmAesGcmAlgorithmEncrypt() {
    final random = math.Random.secure();

    // 生成32字节的密钥 (AES-256)
    _key = Uint8List(32);
    for (int i = 0; i < _key.length; i++) {
      _key[i] = random.nextInt(256);
    }

    // 生成12字节的nonce (GCM推荐长度)
    _nonce = Uint8List(12);
    for (int i = 0; i < _nonce.length; i++) {
      _nonce[i] = random.nextInt(256);
    }
  }

  AesGcm _getAlgorithm() {
    final keyLength = _key.length;
    switch (keyLength) {
      case 16:
        return AesGcm.with128bits(nonceLength: _nonce.length);
      case 24:
        return AesGcm.with192bits(nonceLength: _nonce.length);
      case 32:
        return AesGcm.with256bits(nonceLength: _nonce.length);
      default:
        throw StateError(
            'Invalid key length: $keyLength bytes. Key must be 16, 24, or 32 bytes long.');
    }
  }

  @override
  Future<Uint8List> encrypt(Uint8List data) async {
    final algorithm = _getAlgorithm();
    final secretKey = SecretKey(_key);

    final secretBox = await algorithm.encrypt(
      data,
      secretKey: secretKey,
      nonce: _nonce,
    );

    return Uint8List.fromList(
        [...secretBox.cipherText, ...secretBox.mac.bytes]);
  }

  @override
  List<List<dynamic>> encryptInfoToTags() {
    return [
      ["encryption-algorithm", "aes-gcm"],
      ["decryption-key", HEX.encode(_key)],
      ["decryption-nonce", HEX.encode(_nonce)],
    ];
  }
}
