// SPDX-License-Identifier: MIT
//
// ╭━━━━╮╱╱╭╮╱╱╱╱╱╭╮╱╱╱╱╱╭╮
// ┃╭╮╭╮┃╱╱┃┃╱╱╱╱╱┃┃╱╱╱╱╱┃┃
// ╰╯┃┃┣┻━┳┫┃╭┳━━╮┃┃╱╱╭━━┫╰━┳━━╮
// ╱╱┃┃┃╭╮┣┫╰╯┫╭╮┃┃┃╱╭┫╭╮┃╭╮┃━━┫
// ╱╱┃┃┃╭╮┃┃╭╮┫╰╯┃┃╰━╯┃╭╮┃╰╯┣━━┃
// ╱╱╰╯╰╯╰┻┻╯╰┻━━╯╰━━━┻╯╰┻━━┻━━╯
pragma solidity ^0.8.9;

import "../../common/ConfigManager.sol";
import "../../libs/LibConstants.sol";
import "../../libs/LibTxDecoder.sol";
import "./V1Utils.sol";

/// @author dantaik <dan@taiko.xyz>
library V1Proposing {
    using LibTxDecoder for bytes;
    using SafeCastUpgradeable for uint256;
    using LibData for LibData.State;

    event BlockCommitted(bytes32 blockHash, uint256 commitHeight);
    event BlockProposed(uint256 indexed id, LibData.BlockMetadata meta);

    function commitBlock(
        LibData.State storage s,
        uint256 commitSlot,
        bytes32 commitHash
    ) public {
        // It's OK to allow committing block when the system is halt.
        // By not checking the halt status, this method will be cheaper.
        //
        // require(!V1Utils.isHalted(s), "L1:halt");

        bytes32 hash = _aggregateCommitHash(commitHash, block.number);

        require(s.commits[msg.sender][commitSlot] != hash, "L1:committed");
        s.commits[msg.sender][commitSlot] = hash;

        emit BlockCommitted(commitHash, block.number);
    }

    function proposeBlock(
        LibData.State storage s,
        bytes[] calldata inputs
    ) public {
        require(!V1Utils.isHalted(s), "L1:halt");

        require(inputs.length == 2, "L1:inputs:size");
        LibData.BlockMetadata memory meta = abi.decode(
            inputs[0],
            (LibData.BlockMetadata)
        );
        bytes calldata txList = inputs[1];

        _validateMetadata(meta);

        bytes32 commitHash = _calculateCommitHash(
            meta.beneficiary,
            meta.txListHash
        );

        require(
            isCommitValid(s, meta.commitSlot, meta.commitHeight, commitHash),
            "L1:notCommitted"
        );

        if (meta.commitSlot == 0) {
            // Special handling of slot 0 for refund; non-zero slots
            // are supposed to managed by node software for reuse.
            // Why:
            // - if use slot 0, a commit's gas cost is 20000 - 4800 + 2900 = 18100
            // - if use non-zero slots, the cost is 20000 for the first time, then
            //   2900 each time afterwards.
            delete s.commits[msg.sender][meta.commitSlot];
        }

        require(
            txList.length > 0 &&
                txList.length <= LibConstants.TAIKO_TXLIST_MAX_BYTES &&
                meta.txListHash == txList.hashTxList(),
            "L1:txList"
        );
        require(
            s.nextBlockId <=
                s.latestVerifiedId + LibConstants.TAIKO_MAX_PROPOSED_BLOCKS,
            "L1:tooMany"
        );

        meta.id = s.nextBlockId;
        meta.l1Height = block.number - 1;
        meta.l1Hash = blockhash(block.number - 1);
        meta.timestamp = uint64(block.timestamp);

        // if multiple L2 blocks included in the same L1 block,
        // their block.mixHash fields for randomness will be the same.
        meta.mixHash = bytes32(block.difficulty);

        s.saveProposedBlock(
            s.nextBlockId,
            LibData.ProposedBlock({metaHash: LibData.hashMetadata(meta)})
        );

        emit BlockProposed(s.nextBlockId++, meta);
    }

    function isCommitValid(
        LibData.State storage s,
        uint256 commitSlot,
        uint256 commitHeight,
        bytes32 commitHash
    ) public view returns (bool) {
        bytes32 hash = _aggregateCommitHash(commitHash, commitHeight);
        return
            s.commits[msg.sender][commitSlot] == hash &&
            block.number >=
            commitHeight + LibConstants.TAIKO_COMMIT_DELAY_CONFIRMATIONS;
    }

    function _validateMetadata(LibData.BlockMetadata memory meta) private pure {
        require(
            meta.id == 0 &&
                meta.l1Height == 0 &&
                meta.l1Hash == 0 &&
                meta.mixHash == 0 &&
                meta.timestamp == 0 &&
                meta.beneficiary != address(0) &&
                meta.txListHash != 0,
            "L1:placeholder"
        );

        require(
            meta.gasLimit <= LibConstants.TAIKO_BLOCK_MAX_GAS_LIMIT,
            "L1:gasLimit"
        );
        require(meta.extraData.length <= 32, "L1:extraData");
    }

    function _calculateCommitHash(
        address beneficiary,
        bytes32 txListHash
    ) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(beneficiary, txListHash));
    }

    function _aggregateCommitHash(
        bytes32 commitHash,
        uint256 commitHeight
    ) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(commitHash, commitHeight));
    }
}
