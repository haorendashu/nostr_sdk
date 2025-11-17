import 'dart:convert';
import 'package:cryptography/cryptography.dart';

class EncryptUtil {
  // AES256 CBC pkcs7padding iv util8 base64
  static Future<String> aesEncrypt(
      String plainText, String keyStr, String ivStr) async {
    // 将字符串转换为UTF-8字节数组
    final plainTextBytes = utf8.encode(plainText);
    final keyBytes = utf8.encode(keyStr);
    final ivBytes = utf8.encode(ivStr);

    // 使用Dart实现的AES CBC
    final algorithm = AesCbc.with256bits(
      macAlgorithm: MacAlgorithm.empty,
    );

    final secretKey = SecretKey(keyBytes);

    // 由于这是同步方法，我们需要使用Future.sync来同步执行异步操作
    final secretBox = await algorithm.encrypt(
      plainTextBytes,
      secretKey: secretKey,
      nonce: ivBytes,
    );
    return base64.encode(secretBox.cipherText);
  }

  static Future<String> aesEncryptBytes(
      List<int> input, String keyStr, String ivStr) async {
    final keyBytes = utf8.encode(keyStr);
    final ivBytes = utf8.encode(ivStr);

    final algorithm = AesCbc.with256bits(
      macAlgorithm: MacAlgorithm.empty,
    );

    final secretKey = SecretKey(keyBytes);

    final secretBox = await algorithm.encrypt(
      input,
      secretKey: secretKey,
      nonce: ivBytes,
    );
    return base64.encode(secretBox.cipherText);
  }

  static Future<String> aesDecrypt(
      String str, String keyStr, String ivStr) async {
    final encryptedData = base64.decode(str);
    final keyBytes = utf8.encode(keyStr);
    final ivBytes = utf8.encode(ivStr);

    final algorithm = AesCbc.with256bits(
      macAlgorithm: MacAlgorithm.empty,
    );

    final secretKey = SecretKey(keyBytes);

    final secretBox = SecretBox(
      encryptedData,
      nonce: ivBytes,
      mac: Mac.empty,
    );

    final decrypted = await algorithm.decrypt(
      secretBox,
      secretKey: secretKey,
    );
    return utf8.decode(decrypted);
  }
}
