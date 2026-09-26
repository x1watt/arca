// The chain's fixed rules (whitepaper, sections 6 to 9). They are protocol
// constants: nobody can vote to change them; a change is new software that
// each node operator chooses to run or not. The testnet keeps the same
// rules with smaller numbers so a whole "day" fits in minutes.

class ChainParams {
  const ChainParams({
    required this.name,
    required this.partitionChunks,
    required this.tickSeconds,
    required this.dayTicks,
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

  /// The clock: one tick per [tickSeconds]; a "day" of [dayTicks] ticks
  /// sets holding proofs, issuance and standing.
  final int tickSeconds;
  final int dayTicks;

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

  /// Share of a steward's standing that passes on to what they keep from
  /// other circles.
  static const standingPassOn = 3; // one third

  /// Burned when a circle is created, and burned share of a pass.
  final int circleFee;
  static const passBurnPercent = 50;

  /// Ticks during which a wrong block can be proven wrong.
  final int fraudWindowTicks;

  static const mainnet = ChainParams(
    name: 'arca-mainnet',
    partitionChunks: 131072, // 32 GiB
    tickSeconds: 1,
    dayTicks: 86400,
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
    tickSeconds: 1,
    dayTicks: 600,
    packMemoryKiB: 32768, // 1,355x on the desktop benchmark (8 MB: 408x, 64 MB: 3,050x)
    dailyIssuance: 100000 * grainsPerMarca,
    halvingDays: 30,
    floorIssuance: 1000 * grainsPerMarca,
    circleFee: 3000 * grainsPerMarca,
    fraudWindowTicks: 600,
  );
}
