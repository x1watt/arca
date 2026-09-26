// The chain's fixed rules (whitepaper, sections 6 to 9). They are protocol
// constants: nobody can vote to change them; a change is new software that
// each node operator chooses to run or not. The testnet keeps the same
// rules with smaller numbers so a whole "day" fits in minutes.

class ChainParams {
  const ChainParams({
    required this.name,
    required this.partitionChunks,
    required this.tickMillis,
    required this.dayTicks,
    required this.blockTicks,
    required this.packMemoryKiB,
    required this.dailyIssuance,
    required this.halvingDays,
    required this.floorIssuance,
    required this.circleFee,
    required this.fraudWindowTicks,
  });

  final String name;

  /// Bytes per chunk and per proven slice.
  static const chunkBytes = 256 * 1024;
  static const sliceBytes = 1024;
  static const slicesPerChunk = chunkBytes ~/ sliceBytes;

  /// Chunks per partition: 32 to 64 GB on mainnet.
  final int partitionChunks;
  int get partitionBytes => partitionChunks * chunkBytes;

  /// The clock: one tick per [tickMillis]; a "day" of [dayTicks] ticks
  /// sets holding proofs, issuance and standing. Difficulty aims at one
  /// block per [blockTicks] ticks.
  final int tickMillis;
  final int dayTicks;
  final int blockTicks;

  int get blocksPerDay => dayTicks ~/ blockTicks;

  /// How often a circle anchors its log: about hourly, and never more
  /// often than every five blocks.
  int get anchorTicks => dayTicks ~/ 24 > blockTicks * 5 ? dayTicks ~/ 24 : blockTicks * 5;

  /// A circle whose last anchor is older than this is cut off: its pool
  /// earns nothing and its collections earn no interest (section 4).
  int get anchorLifeTicks => dayTicks;

  /// A pass lasts a day; its servers then have a day to settle.
  int get passTicks => dayTicks;
  int get passSettleTicks => dayTicks;

  /// Sync scores lose a seventh each day, so they follow what a member
  /// keeps now.
  static const syncScoreDecay = 7;

  /// New marcas on [day]: halving every [halvingDays], never below the floor.
  int issuanceOn(int day) {
    final halvings = day ~/ halvingDays;
    final v = halvings >= 62 ? 0 : dailyIssuance >> halvings;
    return v < floorIssuance ? floorIssuance : v;
  }

  /// Memory of the packing function (Argon2id), per chunk.
  final int packMemoryKiB;

  /// Marcas are counted in grains; 1 marca = 100,000,000 grains.
  static const grainsPerMarca = 100000000;

  /// New marcas per day at genesis, halving every [halvingDays] down to a
  /// permanent [floorIssuance].
  final int dailyIssuance;
  final int halvingDays;
  final int floorIssuance;

  /// Shares of each day's issuance (section 8): bytes kept, and interest.
  static const storageShare = 30;
  static const interestShare = 70;

  /// Copies of a partition or collection the reward curve aims for.
  static const targetCopies = 10;

  /// Share of a keeper's standing that passes on to what they keep from
  /// other circles.
  static const standingPassOn = 3; // one third

  /// Days over which burns for a collection count towards its interest.
  static const interestWindowDays = 30;

  /// Burned when a circle is created, and burned share of a pass.
  final int circleFee;
  static const passBurnPercent = 50;

  /// Ticks during which a wrong block can be proven wrong.
  final int fraudWindowTicks;

  Map<String, Object?> toJson() => {
    'name': name,
    'partitionChunks': partitionChunks,
    'tickMillis': tickMillis,
    'dayTicks': dayTicks,
    'blockTicks': blockTicks,
    'packMemoryKiB': packMemoryKiB,
    'dailyIssuance': dailyIssuance,
    'halvingDays': halvingDays,
    'floorIssuance': floorIssuance,
    'circleFee': circleFee,
    'fraudWindowTicks': fraudWindowTicks,
  };

  factory ChainParams.fromJson(Map m) => ChainParams(
    name: m['name'] as String,
    partitionChunks: m['partitionChunks'] as int,
    tickMillis: m['tickMillis'] as int,
    dayTicks: m['dayTicks'] as int,
    blockTicks: m['blockTicks'] as int,
    packMemoryKiB: m['packMemoryKiB'] as int,
    dailyIssuance: m['dailyIssuance'] as int,
    halvingDays: m['halvingDays'] as int,
    floorIssuance: m['floorIssuance'] as int,
    circleFee: m['circleFee'] as int,
    fraudWindowTicks: m['fraudWindowTicks'] as int,
  );

  static const mainnet = ChainParams(
    name: 'arca-mainnet',
    partitionChunks: 131072, // 32 GiB
    tickMillis: 1000,
    dayTicks: 86400,
    blockTicks: 60,
    packMemoryKiB: 65536,
    dailyIssuance: 100000 * grainsPerMarca,
    halvingDays: 4 * 365,
    floorIssuance: 1000 * grainsPerMarca,
    circleFee: 3000 * grainsPerMarca,
    fraudWindowTicks: 86400,
  );

  static const testnet = ChainParams(
    name: 'arca-testnet',
    partitionChunks: 256, // 64 MiB
    tickMillis: 1000,
    dayTicks: 600,
    blockTicks: 10,
    packMemoryKiB: 32768, // 1,355x on the desktop benchmark (8 MB: 408x, 64 MB: 3,050x)
    dailyIssuance: 100000 * grainsPerMarca,
    halvingDays: 30,
    floorIssuance: 1000 * grainsPerMarca,
    circleFee: 3000 * grainsPerMarca,
    fraudWindowTicks: 600,
  );
}
