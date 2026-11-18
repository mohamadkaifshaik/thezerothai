/// The host port the driver serves the vectors on: 8089 unless the run passes
/// `--dart-define=MLS_VECTORS_PORT=n` (and the driver gets the same number in
/// its MLS_VECTORS_PORT environment variable).
const vectorsPort = int.fromEnvironment('MLS_VECTORS_PORT', defaultValue: 8089);
