// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import {EncryptedERC20} from "@fhevm-host-contracts/examples/EncryptedERC20.sol";
import {FHE, euint64, ebool} from "@fhevm-host-contracts/lib/FHE.sol";
import {CoprocessorConfig} from "@fhevm-host-contracts/lib/Impl.sol";

/// The upstream EncryptedERC20 example, unchanged, with two additions for a local check:
/// the coprocessor addresses come from the constructor (the parent reads them from the
/// generated addresses file, which only exists after a hardhat deploy), and transferPlain
/// lets an EOA move tokens without producing an encrypted input, which needs the gateway.
contract PracticeToken is EncryptedERC20 {
    constructor(address acl, address executor, address kmsVerifier) EncryptedERC20("Practice", "PRC") {
        FHE.setCoprocessor(CoprocessorConfig({
            ACLAddress: acl,
            CoprocessorAddress: executor,
            KMSVerifierAddress: kmsVerifier
        }));
    }

    /// Same as transfer(address, euint64) but the amount is encrypted here, trivially.
    function transferPlain(address to, uint64 amount) external returns (bool) {
        euint64 encrypted = FHE.asEuint64(amount);
        ebool canTransfer = FHE.le(encrypted, balanceOf(msg.sender));
        _transfer(msg.sender, to, encrypted, canTransfer);
        return true;
    }
}
