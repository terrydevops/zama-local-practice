#!/bin/bash
# forge build for the demo contracts. The upstream EncryptedERC20 pulls in CoprocessorSetup,
# which imports host-contracts/addresses/FHEVMHostAddresses.sol; hardhat writes that file at
# deploy time and it is gitignored upstream. A zero-address stub is enough to compile:
# PracticeToken sets the real addresses in its constructor.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
FHEVM_DIR=${FHEVM_DIR:-$HERE/../../../../zama-ai-repos/fhevm}
export PATH="$HOME/.foundry/bin:$PATH"
STUB=$FHEVM_DIR/host-contracts/addresses/FHEVMHostAddresses.sol
if [ ! -f "$STUB" ]; then
  mkdir -p "$(dirname "$STUB")"
  cat > "$STUB" <<'SOL'
// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;
// Placeholder written by the practice demo build; a hardhat deploy overwrites it.
address constant aclAdd = address(0);
address constant fhevmExecutorAdd = address(0);
address constant kmsVerifierAdd = address(0);
address constant inputVerifierAdd = address(0);
address constant hcuLimitAdd = address(0);
address constant pauserSetAdd = address(0);
address constant protocolConfigAdd = address(0);
address constant kmsGenerationAdd = address(0);
SOL
fi
cd "$HERE" && forge build "$@"
