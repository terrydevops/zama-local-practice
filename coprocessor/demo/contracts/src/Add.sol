// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import {FHE, euint8} from "@fhevm/solidity/lib/FHE.sol";
import {CoprocessorConfig} from "@fhevm/solidity/lib/Impl.sol";

/// One transaction that makes the coprocessor do real work: encrypt two plain numbers,
/// add them, and allow the result to be read. Without any allow the listener would record
/// the sum as "completed" without ever computing it; without makePubliclyDecryptable the
/// KMS refuses to decrypt it for anyone.
contract Add {
    event Sum(address indexed caller, bytes32 handle);

    constructor(address acl, address executor, address kmsVerifier) {
        FHE.setCoprocessor(CoprocessorConfig({
            ACLAddress: acl,
            CoprocessorAddress: executor,
            KMSVerifierAddress: kmsVerifier
        }));
    }

    function add(uint8 a, uint8 b) external returns (bytes32 handle) {
        euint8 sum = FHE.add(FHE.asEuint8(a), FHE.asEuint8(b));
        FHE.allowThis(sum);
        FHE.allow(sum, msg.sender);
        FHE.makePubliclyDecryptable(sum);
        handle = FHE.toBytes32(sum);
        emit Sum(msg.sender, handle);
    }
}
