/// Stub `createTilePackDbImpl` — replaced by the IO implementation
/// on `dart.library.io` via the conditional import in
/// `tile_pack_db.dart`. This file exists only so the conditional
/// import has a default target.
library;

import 'tile_pack_db.dart';

TilePackDb createTilePackDbImpl(String path) =>
    throw UnsupportedError('Tile packs need a native SQLite database.');
