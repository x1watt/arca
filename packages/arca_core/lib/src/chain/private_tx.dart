// Private transactions (docs/architecture.md, 10): Mimblewimble with
// stealth outputs, as in Litecoin's MWEB, fitted to a state-only chain.
//
// A transaction spends outputs (inputs), creates outputs, and carries one
// kernel:
//
//   input:  the commitment C of an unspent output, signed by its one-time
//           key K (only the receiver knows its secret);
//   output: C = r*G + v*H, with R, K, a view tag, the value encrypted to
//           the receiver, and a range proof that 0 <= v < 2^64;
//   kernel: the excess E, signed by E, and pub, marcas moved in (+) from
//           the signer's public balance or out (-) to it.
//
// It balances when sum(C_out) - sum(C_in) - pub*H = E: the signature by E shows E
// has no H part, so no marcas were made. Every signature covers the whole
// transaction (the message below), so nothing can be swapped. A payment
// between wallets has pub = 0 and no account at all; moving marcas between
// a public balance and the private side is signed by that balance's key.
//
// The state keeps the unspent outputs (without their proofs), the sum of
// every excess and the private supply, so anyone can check from a snapshot
// that sum(C) over all outputs = excessSum + supply*H: no marcas were created
// on the private side (auditSupply).

import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart' as c;

import '../crypto/bulletproof.dart';
import '../crypto/curve.dart';
import '../crypto/hex.dart';
import '../crypto/pedersen.dart';
import '../crypto/point_schnorr.dart';
import 'state.dart';
import 'tx.dart';
import 'wallet_keys.dart';

const maxPrivateInputs = 64;
const maxPrivateOutputs = 16;

/// What an unspent output keeps in the state (its commitment is the key).
class OutputEntry {
  const OutputEntry(this.r, this.k, this.tag, this.encryptedValue);

  final Point r, k;
  final int tag;
  final BigInt encryptedValue;

  Map<String, Object?> toJson() => {
    'r': toHex(r.encoded),
    'k': toHex(k.encoded),
    'tag': tag,
    'v': toHex(valueBytes(encryptedValue)),
  };

  static OutputEntry? fromJson(Map m) {
    try {
      final r = Point.decode(fromHex(m['r'] as String)), k = Point.decode(fromHex(m['k'] as String));
      final tag = m['tag'] as int;
      final v = fromHex(m['v'] as String);
      if (r == null || k == null || r.isInfinity || k.isInfinity || tag < 0 || tag > 255 || v.length != 8) return null;
      return OutputEntry(r, k, tag, scalarOf(v));
    } on Object {
      return null;
    }
  }
}

/// What the kernel and the input signatures sign: everything but the
/// signatures.
List<int> privateMessage(String from, int nonce, Map<String, Object?> body) {
  final unsigned = {
    'inputs': [for (final i in body['inputs'] as List? ?? const []) (i as Map)['c']],
    'outputs': body['outputs'],
    'excess': (body['kernel'] as Map?)?['excess'],
    'pub': (body['kernel'] as Map?)?['pub'],
  };
  return c.sha256.convert(utf8.encode(canonicalJson(['arca-private-v1', from, nonce, unsigned]))).bytes;
}

/// Checks and applies a private transaction to [s].
void applyPrivate(ChainState s, Tx tx) {
  final b = tx.body;
  final inputs = (b['inputs'] as List? ?? const []).cast<Map>();
  final outputs = (b['outputs'] as List? ?? const []).cast<Map>();
  final kernel = b['kernel'] as Map? ?? const {};
  final pub = kernel['pub'] as int? ?? 0;
  if (inputs.length > maxPrivateInputs || outputs.length > maxPrivateOutputs) {
    throw const ChainError('too many inputs or outputs');
  }
  if (inputs.isEmpty && pub <= 0) throw const ChainError('a private transaction spends something');
  if (pub != 0 && tx.from.isEmpty) throw const ChainError('moving public marcas needs the balance\'s signature');
  if (pub == 0 && tx.from.isNotEmpty) throw const ChainError('a private payment names no account');
  final message = privateMessage(tx.from, tx.nonce, b);
  // The kernel.
  final excess = _point(kernel['excess']);
  if (excess == null || excess.isInfinity) throw const ChainError('bad excess');
  if (!pointVerify(excess, message, _bytes(kernel['sig']))) throw const ChainError('bad kernel signature');
  // Inputs: unspent outputs, each signed by its one-time key.
  var sum = Point.infinity;
  final seen = <String>{};
  for (final i in inputs) {
    final key = '${i['c']}';
    if (!seen.add(key)) throw const ChainError('an output spent twice');
    final raw = s.outputs[key];
    final entry = raw == null ? null : OutputEntry.fromJson(jsonDecode(raw) as Map);
    if (entry == null) throw const ChainError('no such unspent output');
    if (!pointVerify(entry.k, message, _bytes(i['sig']))) throw const ChainError('an input not signed by its owner');
    sum -= _point(key)!;
    s.outputs.remove(key);
  }
  // Outputs: new, each with its range proof.
  for (final o in outputs) {
    final key = '${o['c']}';
    final commitment = _point(key);
    if (commitment == null || commitment.isInfinity) throw const ChainError('bad commitment');
    if (!seen.add(key) || s.outputs.containsKey(key)) throw const ChainError('an output that exists already');
    final entry = OutputEntry.fromJson(o);
    if (entry == null) throw const ChainError('bad output');
    final proof = RangeProof.fromBytes(_bytes(o['proof']));
    if (proof == null || !proof.verify(commitment)) throw const ChainError('bad range proof');
    sum += commitment;
    s.outputs[key] = canonicalJson(entry.toJson());
  }
  if (sum - valueBase * BigInt.from(pub) != excess) throw const ChainError('does not balance');
  // The public side.
  if (pub > 0) {
    final have = s.balanceOf(tx.from);
    if (have < pub) throw ChainError('balance $have, needs $pub');
    s.balances[tx.from] = have - pub;
    if (s.balances[tx.from] == 0) s.balances.remove(tx.from);
  } else if (pub < 0) {
    s.balances[tx.from] = s.balanceOf(tx.from) - pub;
  }
  s.privateSupply += pub;
  s.excessSum = s.excessSum + excess;
}

/// Whether the private side holds no more than was moved into it: sum(C) over
/// every unspent output = excessSum + supply*H. Null when it holds, else
/// why not.
String? auditSupply(ChainState s) {
  var sum = Point.infinity;
  for (final key in s.outputs.raw.keys) {
    final p = _point(key);
    if (p == null) return 'an output\'s commitment cannot be read';
    sum += p;
  }
  if (s.privateSupply < 0) return 'the private supply is negative';
  if (sum != s.excessSum + valueBase * BigInt.from(s.privateSupply)) {
    return 'the outputs do not add up to what was moved in';
  }
  return null;
}

/// Whether every marca is accounted for: what was issued minus what was
/// burned equals the public balances, the circles' pools, the passes still
/// open, and the private supply. Null when it holds, else the numbers.
String? auditMoney(ChainState s) {
  var public = 0, pools = 0, passes = 0;
  for (final v in s.balances.raw.values) {
    public += v;
  }
  for (final c in s.circles.raw.values) {
    pools += c.pool;
  }
  for (final p in s.passes.raw.values) {
    passes += p.price;
  }
  final held = public + pools + passes + s.privateSupply;
  if (held == s.issued - s.burned) return null;
  return 'issued ${s.issued} - burned ${s.burned} = ${s.issued - s.burned}, but public $public + pools $pools'
      ' + open passes $passes + private ${s.privateSupply} = $held';
}

Point? _point(Object? hex) {
  try {
    return Point.decode(fromHex('$hex'));
  } on Object {
    return null;
  }
}

List<int> _bytes(Object? hex) {
  try {
    return fromHex('$hex');
  } on Object {
    return const [];
  }
}

// ---- Building ----

/// An output this wallet owns: its commitment, value, blinding and the
/// shared secret its one-time key comes from.
class Owned {
  const Owned({required this.commitment, required this.value, required this.blinding, required this.t});
  final String commitment;
  final BigInt value, blinding, t;

  Map<String, Object?> toJson() => {'c': commitment, 'v': '$value', 'r': '$blinding', 't': '$t'};

  factory Owned.fromJson(Map m) => Owned(
    commitment: m['c'] as String,
    value: BigInt.parse(m['v'] as String),
    blinding: BigInt.parse(m['r'] as String),
    t: BigInt.parse(m['t'] as String),
  );
}

/// Signs [message] for spending [input]: with t + b, which needs the spend
/// key (the core holds it; the chain worker asks for the signature).
typedef InputSigner = Future<List<int>> Function(Owned input, List<int> message);

/// An [InputSigner] with the keys at hand (tests, tools).
InputSigner localSigner(WalletKeys keys) => (i, message) async => pointSign(keys.oneTimeSecret(i.t), message);

/// The body of a private transaction spending [inputs] into [payments]
/// (address and value), with [pub] moved in (+) or out (-), signed by
/// [from]'s nonce when pub is not zero. The caller signs the envelope when
/// [from] is set. Returns the body and the outputs made (for the sender's
/// records, and a payment proof).
Future<({Map<String, Object?> body, List<StealthOutput> made})> buildPrivate({
  required InputSigner signInput,
  required List<Owned> inputs,
  required List<(WalletAddress, BigInt)> payments,
  int pub = 0,
  String from = '',
  int nonce = 0,
  Random? random,
}) async {
  final made = [for (final (to, v) in payments) StealthOutput.to(to, v, random: random)];
  var excessSecret = BigInt.zero;
  for (final o in made) {
    excessSecret += o.blinding;
  }
  for (final i in inputs) {
    excessSecret -= i.blinding;
  }
  excessSecret %= curveN;
  final excess = Point.g * excessSecret;
  final outputs = [
    for (final o in made)
      {
        'c': toHex(o.commitment.encoded),
        'r': toHex(o.r.encoded),
        'k': toHex(o.k.encoded),
        'tag': o.tag,
        'v': toHex(valueBytes(o.encryptedValue)),
        'proof': toHex(RangeProof.prove(o.value, o.blinding, commitment: o.commitment, random: random).bytes),
      },
  ];
  final unsigned = <String, Object?>{
    'inputs': [
      for (final i in inputs) {'c': i.commitment},
    ],
    'outputs': outputs,
    'kernel': {'excess': toHex(excess.encoded), 'pub': pub},
  };
  final message = privateMessage(from, nonce, unsigned);
  final body = <String, Object?>{
    'inputs': [
      for (final i in inputs) {'c': i.commitment, 'sig': toHex(await signInput(i, message))},
    ],
    'outputs': outputs,
    'kernel': {'excess': toHex(excess.encoded), 'pub': pub, 'sig': toHex(pointSign(excessSecret, message))},
  };
  return (body: body, made: made);
}
