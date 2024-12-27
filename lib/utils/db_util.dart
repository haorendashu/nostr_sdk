
import 'dart:io';

import 'package:nostr_sdk/utils/string_util.dart';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

import 'platform_util.dart';

class DBUtil {

  static Future<String> getPath(String dbName) async {
    String path = dbName;

    if (!PlatformUtil.isWeb()) {
      if (Platform.isLinux) {
         var databasesPath = Platform.environment["HOME"];
         path = join(databasesPath!, ".dart_tool", "sqflite_common_ffi", "databases", dbName);
      } else {
        var databasesPath = await getDatabasesPath();
        path = join(databasesPath, dbName);
      }
    }

    return path;
  }

}