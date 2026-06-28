{ lib, rustPlatform }:

# A zero-dependency std-only binary. buildRustPackage with an empty cargoLock
# needs nothing fetched from crates.io, so this builds fully offline.
rustPlatform.buildRustPackage {
  pname = "hello-vvm";
  version = "0.1.0";

  src = lib.cleanSource ./..;

  cargoLock.lockFile = ../Cargo.lock;

  meta = {
    description = "A tiny standard-library-only vacationvm-style service (Unix-socket HTTP)";
    mainProgram = "hello-vvm";
    license = lib.licenses.agpl3Plus;
    platforms = lib.platforms.unix;
  };
}
