import '../../data/models/chip_identity.dart';
import 'adapters/st_adapter.dart';
import 'vendor_adapter.dart';

/// All curated vendor adapters. Adding a vendor: one adapter file +
/// one entry here + a golden-plan fixture + a detection fixture (see
/// docs/pages/chip-corpus.md, "Adding a vendor").
const vendorAdapters = <VendorCorpusAdapter>[
  StAdapter(),
  // NordicAdapter() lands in the next slice (nrfx tarball; SVDs ship
  // inside its mdk/ tree).
];

/// The adapter covering [chip]'s vendor+family, or null — a normal
/// state (identity known, no curated sources yet), not an error.
VendorCorpusAdapter? adapterFor(ChipIdentity chip) {
  for (final a in vendorAdapters) {
    if (a.canHandle(chip)) return a;
  }
  return null;
}
