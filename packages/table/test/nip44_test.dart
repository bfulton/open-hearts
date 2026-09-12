/// NIP-44 version 2 against the published vectors
/// (github.com/paulmillr/nip44, nip44.vectors.json, beside this file):
/// conversation keys from real secp256k1 secrets, message keys from
/// nonces, the padding, ten sealed messages with their nonces, a long
/// one by its hashes, and what must be refused.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:table/table.dart';
import 'package:test/test.dart';

Uint8List unhex(String hex) => Uint8List.fromList([for (var i = 0; i < hex.length; i += 2) int.parse(hex.substring(i, i + 2), radix: 16)]);
String hex(List<int> bytes) => [for (final b in bytes) b.toRadixString(16).padLeft(2, '0')].join();

void main() {
  final vectors = (jsonDecode(File('test/nip44.vectors.json').readAsStringSync()) as Map)['v2'] as Map;
  final valid = vectors['valid'] as Map;
  final invalid = vectors['invalid'] as Map;

  test('conversation keys from the shared point of two real keys', () {
    final cases = valid['get_conversation_key'] as List;
    expect(cases.length, greaterThan(30));
    for (final c in cases) {
      final signer = SchnorrSigner.fromSecret(c['sec1'] as String);
      final key = Nip44.conversationKey(signer.sharedXWith(c['pub2'] as String));
      expect(hex(key), c['conversation_key'], reason: 'sec1 ${c['sec1']}');
    }
  });

  test('what is not a key or a secret is refused', () {
    for (final c in invalid['get_conversation_key'] as List) {
      expect(() => Nip44.conversationKey(SchnorrSigner.fromSecret(c['sec1'] as String).sharedXWith(c['pub2'] as String)),
          throwsA(anything),
          reason: c['note'] as String);
    }
  });

  test('message keys from the conversation key and a nonce', () {
    final m = valid['get_message_keys'] as Map;
    final conversationKey = unhex(m['conversation_key'] as String);
    for (final k in m['keys'] as List) {
      final keys = Nip44.messageKeys(conversationKey, unhex(k['nonce'] as String));
      expect(hex(keys.chachaKey), k['chacha_key']);
      expect(hex(keys.chachaNonce), k['chacha_nonce']);
      expect(hex(keys.hmacKey), k['hmac_key']);
    }
  });

  test('padded lengths', () {
    for (final pair in valid['calc_padded_len'] as List) {
      expect(Nip44.paddedLength(pair[0] as int), pair[1], reason: 'length ${pair[0]}');
    }
    expect(() => Nip44.paddedLength(0), throwsArgumentError);
  });

  test('sealing with a given nonce gives the vector, and opens again', () {
    for (final c in valid['encrypt_decrypt'] as List) {
      final a = SchnorrSigner.fromSecret(c['sec1'] as String);
      final b = SchnorrSigner.fromSecret(c['sec2'] as String);
      final key = Nip44.conversationKey(a.sharedXWith(b.publicKey));
      expect(hex(key), c['conversation_key']);
      expect(hex(Nip44.conversationKey(b.sharedXWith(a.publicKey))), c['conversation_key'], reason: 'the same from either end');
      final payload = Nip44.encrypt(key, c['plaintext'] as String, nonce: unhex(c['nonce'] as String));
      expect(payload, c['payload']);
      expect(Nip44.decrypt(key, payload), c['plaintext']);
    }
  });

  test('a long message, by its hashes', () {
    for (final c in valid['encrypt_decrypt_long_msg'] as List) {
      final key = unhex(c['conversation_key'] as String);
      final plaintext = (c['pattern'] as String) * (c['repeat'] as int);
      expect(sha256.convert(utf8.encode(plaintext)).toString(), c['plaintext_sha256']);
      final payload = Nip44.encrypt(key, plaintext, nonce: unhex(c['nonce'] as String));
      expect(sha256.convert(utf8.encode(payload)).toString(), c['payload_sha256']);
      expect(Nip44.decrypt(key, payload), plaintext);
    }
  });

  test('a fresh nonce every time, and the text is not in the payload', () {
    final a = SchnorrSigner.generate();
    final b = SchnorrSigner.generate();
    final key = Nip44.conversationKey(a.sharedXWith(b.publicKey));
    const text = '{"type":"ice","candidate":"candidate:1 1 udp 2113937151 192.168.1.20 54321 typ host"}';
    final one = Nip44.encrypt(key, text);
    final two = Nip44.encrypt(key, text);
    expect(one, isNot(two));
    expect(utf8.decode(base64.decode(one), allowMalformed: true), isNot(contains('192.168')));
    expect(Nip44.decrypt(key, one), text);
    expect(Nip44.decrypt(Nip44.conversationKey(b.sharedXWith(a.publicKey)), two), text);
    // Another key opens nothing.
    final c = SchnorrSigner.generate();
    expect(() => Nip44.decrypt(Nip44.conversationKey(c.sharedXWith(a.publicKey)), one), throwsFormatException);
  });

  test('texts too short or too long are refused', () {
    final key = Uint8List(32);
    for (final n in invalid['encrypt_msg_lengths'] as List) {
      expect(() => Nip44.encrypt(key, 'a' * (n as int)), throwsArgumentError, reason: 'length $n');
    }
  });

  test('payloads that are not sound are refused', () {
    for (final c in invalid['decrypt'] as List) {
      expect(() => Nip44.decrypt(unhex(c['conversation_key'] as String), c['payload'] as String), throwsFormatException,
          reason: c['note'] as String);
    }
  });
}
