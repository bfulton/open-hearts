/// What the phones' backups leave out: the device's secret key, and
/// only that (lib/secret_store.dart).
///
/// Android is told by files, read here as XML: the manifest turns on two
/// sets of rules, one for Android 12 and later (a backup to Google and a
/// transfer to a new phone) and one for 11 and earlier, and each leaves
/// out the preferences file the key is kept in. The iPhone is told by
/// its native side, which no test here can run; this holds the text of
/// it to what the Dart side asks (the simulator in CI,
/// integration_test/native_libs_test.dart, runs it).
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_hearts/secret_store.dart';
import 'package:open_hearts/secret_store_io.dart' show identityChannel;
import 'package:xml/xml.dart';

const _main = 'android/app/src/main';

XmlElement _root(String file) => XmlDocument.parse(File('$_main/$file').readAsStringSync()).rootElement;

/// What the `exclude` rules in [section] leave out, as `domain/path`.
Set<String> _excluded(XmlElement section) => {
      for (final rule in section.findElements('exclude')) '${rule.getAttribute('domain')}/${rule.getAttribute('path')}',
    };

void main() {
  /// The key's file as the rules name it: the file the Dart store keeps
  /// the key in, which holds nothing else.
  final keyFile = 'sharedpref/$identityFile.xml';

  test('the manifest turns on both sets of rules, and leaves backup itself on', () {
    final application = _root('AndroidManifest.xml').getElement('application')!;
    expect(application.getAttribute('android:dataExtractionRules'), '@xml/data_extraction_rules');
    expect(application.getAttribute('android:fullBackupContent'), '@xml/backup_rules');
    expect(application.getAttribute('android:allowBackup'), anyOf(isNull, 'true'), reason: 'the rest of the app is still backed up');
  });

  test('Android 12 and later: neither a backup nor a transfer to a new phone carries the key, and both carry the rest', () {
    final rules = _root('res/xml/data_extraction_rules.xml');
    expect(rules.name.local, 'data-extraction-rules');
    for (final to in ['cloud-backup', 'device-transfer']) {
      final section = rules.getElement(to);
      expect(section, isNotNull, reason: '$to has rules');
      expect(_excluded(section!), {keyFile}, reason: '$to leaves out the key\'s file, and nothing else');
      expect(section.findElements('include'), isEmpty, reason: 'an include would leave out everything it does not name');
    }
  });

  test('Android 11 and earlier: the backup leaves out the key, and carries the rest', () {
    final rules = _root('res/xml/backup_rules.xml');
    expect(rules.name.local, 'full-backup-content');
    expect(_excluded(rules), {keyFile});
    expect(rules.findElements('include'), isEmpty);
  });

  test('the iPhone\'s native side answers the two calls the Dart side makes, on the channel it makes them on', () {
    final swift = File('ios/Runner/AppDelegate.swift').readAsStringSync();
    expect(swift, contains('name: "$identityChannel"'));
    expect(swift, contains('case "directory":'));
    expect(swift, contains('case "excludeFromBackup":'));
    expect(swift, contains('isExcludedFromBackup = true'));
    final dart = File('lib/secret_store_io.dart').readAsStringSync();
    expect(dart, contains("invokeMethod<String>('directory')"));
    expect(dart, contains("invokeMethod<bool>('excludeFromBackup'"));
  });
}
