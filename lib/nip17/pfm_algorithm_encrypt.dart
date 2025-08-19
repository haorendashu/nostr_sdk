import 'dart:typed_data';

abstract class PfmAlgorithmEncrypt {
  List<List<dynamic>> encryptInfoToTags();

  Future<Uint8List> encrypt(Uint8List data);
}
