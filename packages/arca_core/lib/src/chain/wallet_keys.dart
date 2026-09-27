// A profile's private wallet keys and its stealth outputs
// (docs/architecture.md, 10, private marcas).
//
// Two keys, both derived from the profile's secret so there is nothing new
// to back up: the spend key b (B = b·G), which only the owner holds, and
// the scan key a (A = a·G), which finds and reads what the wallet
// receives and can be handed to an auditor. The address is A and B.
//
// A payment to (A, B) needs no answer from the receiver: the sender picks e
// and publishes R = e·G; both then know t = H(e·A) = H(a·R). The output's
// one-time key is K = t·G + B (its secret, t + b, needs b), its blinding is
// derived from t, and its value is encrypted with a mask from t. Outputs
// to one address share nothing an outsider can link.

import 'dart:math';
import 'dart:typed_data';

import '../crypto/curve.dart';
import '../crypto/pedersen.dart';
import '../nostr/nip19.dart';

class WalletAddress {
  const WalletAddress(this.scan, this.spend);

  /// A = a·G and B = b·G.
  final Point scan, spend;

  static const hrp = 'marca';

  String get encoded => bech32Encode(hrp, [...scan.encoded, ...spend.encoded]);

  /// The address in [text], or null.
  static WalletAddress? parse(String text) {
    try {
      final (h, data) = bech32Decode(text.trim());
      if (h != hrp || data.length != 66) return null;
      final a = Point.decode(data.sublist(0, 33)), b = Point.decode(data.sublist(33));
      if (a == null || b == null || a.isInfinity || b.isInfinity) return null;
      return WalletAddress(a, b);
    } on FormatException {
      return null;
    }
  }

  @override
  bool operator ==(Object other) => other is WalletAddress && other.scan == scan && other.spend == spend;

  @override
  int get hashCode => encoded.hashCode;
}

class WalletKeys {
  WalletKeys._(this.scanKey, this.spendKey);

  /// The keys of the profile with [secret] (its Nostr secret key).
  factory WalletKeys.of(List<int> secret) =>
      WalletKeys._(hashToScalar('arca/wallet/scan', [secret]), hashToScalar('arca/wallet/spend', [secret]));

  /// a, which reads; null in a view-only wallet.
  final BigInt scanKey;

  /// b, which spends; null for an auditor's view-only wallet.
  final BigInt? spendKey;

  late final address = WalletAddress(Point.g * scanKey, Point.g * spendKey!);

  /// The keys an auditor needs to see what this wallet receives and
  /// spends, not to spend: a and B, as text.
  String get viewKey => bech32Encode('marcaview', [...scalarBytes(scanKey), ...address.spend.encoded]);

  /// A view-only wallet from [viewKey], or null.
  static ViewKeys? parseViewKey(String viewKey) {
    try {
      final (h, data) = bech32Decode(viewKey.trim());
      if (h != 'marcaview' || data.length != 65) return null;
      final a = scalarOf(data.sublist(0, 32));
      final b = Point.decode(data.sublist(32));
      if (a == BigInt.zero || a >= curveN || b == null) return null;
      return ViewKeys(a, b);
    } on FormatException {
      return null;
    }
  }

  ViewKeys get view => ViewKeys(scanKey, address.spend);

  /// The secret of the one-time key of an output this wallet found.
  BigInt oneTimeSecret(BigInt t) => (t + spendKey!) % curveN;
}

/// What reading a wallet takes: a and B.
class ViewKeys {
  const ViewKeys(this.scanKey, this.spend);
  final BigInt scanKey;
  final Point spend;

  /// Whether the output with [r] (R), [k] (K) and [tag] is this wallet's;
  /// its shared secret t when it is.
  BigInt? recognise(Point r, Point k, int tag) {
    final t = sharedSecret(r * scanKey);
    if (viewTag(t) != tag) return null;
    return Point.g * t + spend == k ? t : null;
  }
}

/// t from the shared point e·A = a·R.
BigInt sharedSecret(Point shared) => hashToScalar('arca/stealth', [shared]);

/// The output's blinding, from t.
BigInt stealthBlinding(BigInt t) => hashToScalar('arca/blind', [t]);

/// One byte from t: a wallet that scans skips 255 outputs in 256 after
/// one multiplication, without checking K.
int viewTag(BigInt t) => (hashToScalar('arca/tag', [t]) & BigInt.from(0xff)).toInt();

/// The 64-bit mask the value is encrypted with.
BigInt _valueMask(BigInt t) => hashToScalar('arca/value', [t]) & ((BigInt.one << 64) - BigInt.one);

/// [value] encrypted under t, and back: the same operation.
BigInt maskValue(BigInt value, BigInt t) => value ^ _valueMask(t);

/// A new output's public parts and what its sender knows.
class StealthOutput {
  StealthOutput._(this.commitment, this.r, this.k, this.tag, this.encryptedValue, this.value, this.blinding, this.e);

  /// A payment of [value] grains to [to].
  factory StealthOutput.to(WalletAddress to, BigInt value, {Random? random}) {
    final e = randomScalar(random);
    final t = sharedSecret(to.scan * e);
    final blinding = stealthBlinding(t);
    return StealthOutput._(
      commit(value, blinding),
      Point.g * e,
      Point.g * t + to.spend,
      viewTag(t),
      maskValue(value, t),
      value,
      blinding,
      e,
    );
  }

  final Point commitment, r, k;
  final int tag;
  final BigInt encryptedValue;

  /// Known to the sender: the value, the blinding, and e (a payment proof).
  final BigInt value, blinding, e;
}

/// The value a recognised output holds, checked against its commitment;
/// null when it does not open.
BigInt? openOutput(Point commitment, BigInt encryptedValue, BigInt t) {
  final v = maskValue(encryptedValue, t);
  return commit(v, stealthBlinding(t)) == commitment ? v : null;
}

/// A payment proof: e for the output with R and K shows it paid [to] the
/// value its commitment opens to. Anyone can check it.
BigInt? checkPaymentProof(BigInt e, WalletAddress to, Point r, Point k, Point commitment, BigInt encryptedValue) {
  if (Point.g * e != r) return null;
  final t = sharedSecret(to.scan * e);
  if (Point.g * t + to.spend != k) return null;
  return openOutput(commitment, encryptedValue, t);
}

Uint8List valueBytes(BigInt v) => scalarBytes(v).sublist(24);
