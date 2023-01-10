// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

// Inspired by and building upon prior work from
//     https://github.com/aragon/evm-storage-proofs and
//     https://github.com/hamdiallam/Solidity-RLP/
// with some added gas optimizations specific to the 
// state trie and account balances.

// Also refer to the following resources to understand 
// RLP encoding/decoding, the Ethereum state trie, and
// the approach taken by this library:
//     https://ethereum.org/en/developers/docs/data-structures-and-encoding/patricia-merkle-trie/
//     https://ethereum.org/en/developers/docs/data-structures-and-encoding/rlp/
//     https://medium.com/shyft-network-media/understanding-trie-databases-in-ethereum-9f03d2c3325d


/// @title Validates Merkle proofs of the state trie to trustlessly retrieve the 
///        balance of an account at a past block.
library LibBalanceProof {
    error InvalidBlockHeaderRLPLength(uint256 len);
    error InvalidBlockHeaderHash(bytes32 expected, bytes32 actual);
    error InvalidNodeHash(bytes32 expected, bytes32 actual);
    error EmptyNode();
    error UnexpectedByte0(string rlpItemName, bytes1 byte0);
    error UnexpectedBalanceLength(uint256 len);
    error InvalidNodeLength(uint256 len);
    error UnexpectedArrayLength(string rlpItemName);
    error EmptyAccountState();
    error UnexpectedFlag(string errorType, uint256 flag);
    error InvalidPartialPath(bytes32 expected, bytes32 actual);
    error InvalidPathLength(uint256 len);
    error IncompletePath();

    uint256 private constant ACCOUNT_BALANCE_INDEX = 1;
    uint256 private constant NIBBLE_BITS = 4;

    uint256 private constant EXTENSION_NODE_EVEN_LENGTH = 0;
    uint256 private constant EXTENSION_NODE_ODD_LENGTH = 1;
    uint256 private constant LEAF_NODE_EVEN_LENGTH = 2;
    uint256 private constant LEAF_NODE_ODD_LENGTH = 3;
    
    uint256 constant STRING_SHORT_START = 0x80;
    uint256 constant STRING_LONG_START  = 0xb8;
    uint256 constant LIST_SHORT_START   = 0xc0;
    uint256 constant LIST_LONG_START    = 0xf8;

    /// @dev Gets the balance of the given account at a past block by 
    ///      traversing the given Merkle proof for the state trie.
    /// @param proof A Merkle proof for the given account's balance in
    ///        the state trie of a past block.
    /// @param blockHeaderRLP The RLP-encoded block header for the past 
    ///        block for which the balance is being queried.
    /// @param blockHash The expected blockhash. Should be equal to the 
    ///        Keccak256 hash of `blockHeaderRLP`. 
    /// @param account The account whose past balance is being queried.
    /// @return accountBalance The proven past balance of the account.
    function getProvenAccountBalance(
        bytes[] memory proof,
        bytes memory blockHeaderRLP,
        bytes32 blockHash,
        address account
    ) 
        internal
        pure
        returns (uint256 accountBalance)
    {
        bytes32 proofPath = keccak256(abi.encodePacked(account));
        bytes32 root = getStateRoot(blockHeaderRLP, blockHash);

        // Returns the account balance as given by a Merkle proof of 
        // the state trie. Reverts if the proof is invalid.
        return getProvenAccountBalance(
            proof,
            root, 
            proofPath
        );
    }

    /// @dev Checks that the given RLP-encoded block header hashes to the
    ///      given block hash, and extracts the state root.
    /// @param blockHeaderRLP The RLP-encoded block header.
    /// @param blockHash The expected block hash for the given header.
    /// @return root The state root extracted from the block header.
    function getStateRoot(bytes memory blockHeaderRLP, bytes32 blockHash) 
        internal
        pure
        returns (bytes32 root)
    {
        // prevent from reading invalid memory
        if (blockHeaderRLP.length <= 123) {
            revert InvalidBlockHeaderRLPLength(blockHeaderRLP.length);
        }
        if (keccak256(blockHeaderRLP) != blockHash) {
            revert InvalidBlockHeaderHash(blockHash, keccak256(blockHeaderRLP));
        }
        // 0x7b = 0x20 (length) + 0x5b (position of state root in header, [91, 123])
        assembly { root := mload(add(blockHeaderRLP, 0x7b)) }
    }

    /// @dev Traverses/validates the given Merkle proof using the given state
    ///      root and trie path to retrieve the balance of an account.
    /// @param proof A Merkle proof for the given account's balance in
    ///        the state trie of a past block.
    /// @param stateRoot The state root of the block for which the account 
    ///        balance is being queried.
    /// @param path The trie path corresponding to the account whose balance
    ///        is being queried.
    /// @return accountBalance The proven past balance of the account.
    function getProvenAccountBalance(
        bytes[] memory proof,
        bytes32 stateRoot,
        bytes32 path
    )
        internal
        pure
        returns (uint256 accountBalance)
    {
        bytes32 expectedHash = stateRoot; // Required hash for the next node
        uint256 pathBitIndex = 0;

        uint256 i = 0;
        uint256 lastNodeIndex  = proof.length - 1;
        for (; i != lastNodeIndex; ) {
            if (expectedHash != keccak256(proof[i])) {
                revert InvalidNodeHash(expectedHash, keccak256(proof[i]));
            }

            // Most nodes will be branch nodes, so optimistically try to 
            // process the node as a branch node.
            (bool isBranchNode, bytes32 childHash) = _processBranchNode(
                proof[i],
                path, 
                pathBitIndex
            );
            if (isBranchNode) {
                expectedHash = childHash;
                // Neither of these can realistically overflow.
                unchecked { 
                    // Increment path index by 1 nibble (4 bits)
                    pathBitIndex += NIBBLE_BITS;
                    ++i; 
                }
                continue;
            }

            // If it is not a branch node, it should be an extension node.
            uint256 partialPathLength;
            (partialPathLength, expectedHash) = _processExtensionNode(
                proof[i],
                path, 
                pathBitIndex
            );
            // partialPathLength <= 256, so neither of these can
            // realistically overflow.
            unchecked {
                pathBitIndex += partialPathLength;
                ++i; 
            }
        }

        if (expectedHash != keccak256(proof[i])) {
            revert InvalidNodeHash(expectedHash, keccak256(proof[i]));
        }
        // The last node in the proof should be a leaf node.
        return _processLeafNode(
            proof[i],
            path, 
            pathBitIndex
        );
    }

    /// @dev Tries to process an RLP-encoded Patricia Merkle Trie node
    ///      as a branch node.
    /// @param nodeRLP The RLP-encoded trie node.
    /// @param path The lookup path for the proof.
    /// @param pathBitIndex The number of bits of the lookup path that 
    ///        have already been processed.
    /// @return isBranchNode Whether or not the given node was in fact 
    ///         a branch node.
    /// @return childHash If the given node was a branch node, the 
    ///         expected hash of the next node in the path.
    function _processBranchNode(
        bytes memory nodeRLP,
        bytes32 path,
        uint256 pathBitIndex
    )
        private
        pure
        returns (bool isBranchNode, bytes32 childHash)
    {
        if (nodeRLP.length == 0) {
            revert EmptyNode();
        }
        
        uint256 byte0;
        assembly { byte0 := byte(0, mload(add(nodeRLP, 0x20))) }

        uint256 payloadOffset;
        if (byte0 >= LIST_LONG_START) {
            // Node is a long list
            unchecked { payloadOffset = byte0 - 0xf6; }
        } else if (byte0 >= LIST_SHORT_START) {
            // Node is a short list
            // TODO: I don't think it's even possible for a branch 
            // node to be a short list
            payloadOffset = 1;
        } else {
            revert UnexpectedByte0("branch node", bytes1(uint8(byte0)));
        }

        uint256 nibble = _getNibble(path, pathBitIndex);

        uint256 currPtr;
        uint256 endPtr;
        assembly {
            currPtr := add(add(nodeRLP, 0x20), payloadOffset)
            endPtr := add(add(nodeRLP, 0x20), mload(nodeRLP))
        }

        uint256 i = 0;
        while (currPtr != endPtr) {
            uint256 itemLength;
            assembly { byte0 := byte(0, mload(currPtr)) }
            // Elements of a branch node should only be 33 bytes (an RLP-encoded
            // child hash) or 1 byte (an RLP-encoded empty string).
            if (byte0 == 0xa0) {
                itemLength = 33;
                assembly {
                    // If we're at the index corresponding to the current nibble
                    // and the item is plausibly a bytes32, preemptively cache 
                    // the value of the item in case it is in fact the hash of the
                    // next node.
                    if eq(i, nibble) {
                        childHash := mload(add(currPtr, 1))
                    }
                }                
            } else if (byte0 == 0x80) {
                itemLength = 1;
            } else {
                return (false, bytes32(0));
            }
            
            assembly {
                currPtr := add(currPtr, itemLength) // Jump over item
                i := add(i, 1)
            }
        }

        if (i == 17) {
            isBranchNode = true;
        } else if (i == 2) {
            isBranchNode = false;
        } else {
            revert InvalidNodeLength(i);
        }
    }

    /// @dev Processes an RLP-encoded Merkle Patricia Trie node as a leaf node.
    ///      Returns the queried account balance from the node. Reverts if it is
    ///      not a properly encoded leaf node.
    /// @param nodeRLP The RLP-encoded trie node.
    /// @param path The lookup path for the proof.
    /// @param pathBitIndex The number of bits of the lookup path that have 
    ///        already been processed.
    /// @return accountBalance The proven past balance of the account.
    function _processLeafNode(
        bytes memory nodeRLP,
        bytes32 path,
        uint256 pathBitIndex
    )
        private
        pure
        returns (uint256 accountBalance)
    {
        (
            uint256 encodedPathPtr, 
            uint256 encodedPathLen,
            uint256 accountStatePtr,
            uint256 accountStateLen
        ) = _decodeLeafNode(nodeRLP);

        (uint256 flag, uint256 partialPathLength) = _decodePartialPath(
            encodedPathPtr,
            encodedPathLen,
            path,
            pathBitIndex
        );

        if (flag != LEAF_NODE_EVEN_LENGTH && flag != LEAF_NODE_ODD_LENGTH) {
            revert UnexpectedFlag("leaf node", flag);
        }
        if (pathBitIndex + partialPathLength != 256) {
            revert IncompletePath();
        }

        accountBalance = _decodeAccountBalance(accountStatePtr, accountStateLen);
    }

    /// @dev Decodes a leaf node into its constituent items, the encoded partial
    ///      path and the account state payload. Reverts if the node is not a 
    ///      properly encoded leaf node.
    /// @param nodeRLP The RLP-encoded trie node.
    /// @return encodedPathPtr Memory pointer to the partial path that the leaf 
    ///         node "skips ahead" by, which should complete the remainder of the 
    ///         full path.
    /// @return encodedPathLen Length in bytes of the partial path. 
    /// @return accountStatePtr Memory pointer to the RLP-encoded account state.
    /// @return accountStateLen Length in bytes of the account state.
    function _decodeLeafNode(bytes memory nodeRLP)
        private
        pure
        returns (
            uint256 encodedPathPtr, 
            uint256 encodedPathLen,
            uint256 accountStatePtr,
            uint256 accountStateLen
        )
    {
        uint256 byte0;
        assembly { byte0 := byte(0, mload(add(nodeRLP, 0x20))) }

        uint256 payloadOffset;
        if (byte0 >= LIST_LONG_START) {
            unchecked { payloadOffset = byte0 - 0xf6; }
        } else {
            // Leaf node must be a long list because the second item 
            // encodes the account state, which is >64 bytes long 
            // (storage root and code hash are 32 bytes each)
            revert UnexpectedByte0("leaf node", bytes1(uint8(byte0)));
        }

        uint256 currPtr;
        uint256 endPtr;
        assembly {
            currPtr := add(add(nodeRLP, 0x20), payloadOffset)
            endPtr := add(add(nodeRLP, 0x20), mload(nodeRLP))
        }

        // First element is the encodedPath
        (encodedPathPtr, encodedPathLen, currPtr) = _encodedPath(currPtr);

        // Second element is the RLP-encoded account state
        // TODO: Why is the account RLP-encoded twice?
        assembly { byte0 := byte(0, mload(currPtr)) }
        if (byte0 < STRING_LONG_START) {
            // Account state encodes storage root and code hash,
            // which are 32 bytes each
            revert UnexpectedByte0("account state", bytes1(uint8(byte0)));
        } else if (byte0 < LIST_SHORT_START) {
            // Long string
            assembly {
                // How many bytes are used to represent the payload length
                let byteLen := sub(byte0, 0xb7) 
                // Skip over byte0
                currPtr := add(currPtr, 1)
                // Read the payload length
                // rightAlignShift = 8 * (32 - byteLen)
                let rightAlignShift := shl(3, sub(32, byteLen))
                let payloadLen := shr(rightAlignShift, mload(currPtr)) 
                // Skip over the payload length bytes
                currPtr := add(currPtr, byteLen)
                // Now currPtr points to the start of the payload
                accountStatePtr := currPtr
                // Store the payload length
                accountStateLen := payloadLen
                // Skip over the payload
                currPtr := add(currPtr, payloadLen)
            }
        } else {
            revert UnexpectedByte0("account state", bytes1(uint8(byte0)));
        }

        if (currPtr != endPtr) {
            // Leaf node should have 2 elements
            revert UnexpectedArrayLength("leaf node");
        }
    }

    /// @dev Decodes the account balance from the RLP-encoded account state.
    ///      Reverts if the account state is improperly encoded.
    /// @param accountStatePtr Memory pointer to the RLP-encoded account state.
    /// @param accountStateLen Length in bytes of the account state.
    /// @return accountBalance The proven past balance of the account.
    function _decodeAccountBalance(
        uint256 accountStatePtr,
        uint256 accountStateLen
    )
        private
        pure
        returns (uint256 accountBalance)
    {
        if (accountStateLen == 0) {
            revert EmptyAccountState();
        }

        uint256 byte0;
        assembly { byte0 := byte(0, mload(accountStatePtr)) }
        uint256 payloadOffset;
        if (byte0 >= LIST_LONG_START) {
            unchecked { payloadOffset = byte0 - 0xf6; }
        } else {
            // Account balance must be a long list because it encodes
            // storage root and code hash, which are 32 bytes each
            revert UnexpectedByte0("account balance", bytes1(uint8(byte0)));
        }

        uint256 currPtr = accountStatePtr + payloadOffset;

        // Skip over nonce
        currPtr += _rlpItemLength(currPtr);

        uint256 len = _rlpItemLength(currPtr);
        if (len == 1) {
            // Account balance is a single byte
            assembly {
                accountBalance := byte(0, mload(currPtr))
            }
        } else if (len <= 33) {
            assembly {
                // Load the balance from memory, skipping over the 
                // first byte which encodes the length of the payload.
                accountBalance := mload(add(currPtr, 1))
                // Shift right so that the balance is right-aligned 
                // in the memory word.
                // rightAlignShift = 8 * (33 - len)
                let rightAlignShift := shl(3, sub(33, len))
                accountBalance := shr(rightAlignShift, accountBalance)
            }
        } else {
            revert UnexpectedBalanceLength(len);
        }
        currPtr += len;

        // Skip over storage root
        assembly { byte0 := byte(0, mload(currPtr)) }
        if (byte0 != 0xa0) { // 32 bytes long
            revert UnexpectedByte0("storage root", bytes1(uint8(byte0)));
        }
        currPtr += 33;

        // Skip over code hash
        assembly { byte0 := byte(0, mload(currPtr)) }
        if (byte0 != 0xa0) { // 32 bytes long
            revert UnexpectedByte0("code hash", bytes1(uint8(byte0)));
        }
        currPtr += 33;

        // currPtr > accountStatePtr, so this cannot underflow.
        unchecked {
            // Account state array should have 4 elements
            if ((currPtr - accountStatePtr) != accountStateLen) {
                revert UnexpectedArrayLength("account state");
            }
        }
    }

    /// @dev Processes an RLP-encoded Merkle Patricia Trie node as an extension
    ///      node. Reverts if it is not a properly encoded extension node.
    /// @param nodeRLP The RLP-encoded trie node.
    /// @param path The lookup path for the proof.
    /// @param pathBitIndex The number of bits of the lookup path that have 
    ///        already been processed.
    /// @return partialPathLength The length of the partial path that the node
    ///         "skips ahead" by.
    /// @return childHash The expected hash of the next node in the path.
    function _processExtensionNode(
        bytes memory nodeRLP,
        bytes32 path,
        uint256 pathBitIndex
    )
        private
        pure
        returns (uint256 partialPathLength, bytes32 childHash)
    {
        uint256 encodedPathPtr;
        uint256 encodedPathLen;
        (encodedPathPtr, encodedPathLen, childHash) = _decodeExtensionNode(nodeRLP);
        
        uint256 flag;
        (flag, partialPathLength) = _decodePartialPath(
            encodedPathPtr,
            encodedPathLen,
            path,
            pathBitIndex
        );
        if (flag != EXTENSION_NODE_EVEN_LENGTH && flag != EXTENSION_NODE_ODD_LENGTH) {
            revert UnexpectedFlag("extension node", flag);
        }
    }

    /// @dev Decodes an extension node into its constituent items, the encoded
    ///      partial path and the child hash. Reverts if the node is not a 
    ///      properly encoded extension node.
    /// @param nodeRLP The RLP-encoded trie node.
    /// @return encodedPathPtr Memory pointer to the partial path that the 
    ///         extension node "skips ahead" by.
    /// @return encodedPathLen Length in bytes of the partial path.
    /// @return childHash The expected hash of the next node in the path.
    function _decodeExtensionNode(bytes memory nodeRLP)
        private
        pure
        returns (uint256 encodedPathPtr, uint256 encodedPathLen, bytes32 childHash)
    {
        uint256 byte0;
        assembly { byte0 := byte(0, mload(add(nodeRLP, 0x20))) }

        uint256 payloadOffset;
        if (byte0 >= LIST_LONG_START) {
            unchecked { payloadOffset = byte0 - 0xf6; }
        } else if (byte0 >= LIST_SHORT_START) {
            payloadOffset = 1;
        } else {
            revert UnexpectedByte0("extension node", bytes1(uint8(byte0)));
        }

        uint256 currPtr;
        uint256 endPtr;
        assembly {
            currPtr := add(add(nodeRLP, 0x20), payloadOffset)
            endPtr := add(add(nodeRLP, 0x20), mload(nodeRLP))
        }

        // First element is the encodedPath
        (encodedPathPtr, encodedPathLen, currPtr) = _encodedPath(currPtr);

        // Second element is the child hash
        assembly { byte0 := byte(0, mload(currPtr)) }
        if (byte0 != 0xa0) {
            revert UnexpectedByte0("child hash", bytes1(uint8(byte0)));
        }
        assembly { 
            childHash := mload(add(currPtr, 1)) 
            currPtr := add(currPtr, 33)
        }
        if (currPtr != endPtr) {
            // Extension node should have 2 elements
            revert UnexpectedArrayLength("extension node");
        }
    }

    /// @dev Given a memory pointer to an RLP-encoded partial path, returns the
    ///      data payload representing the path, and a pointer pointing tot the 
    ///      end of the payload.
    /// @param currPtr Points to the memory at which the RLP-encoded path starts.
    /// @return encodedPathPtr Memory pointer to the partial path that the 
    ///         extension node "skips ahead" by.
    /// @return encodedPathLen Length in bytes of the partial path.
    /// @return newCurrPtr Points to the memory right after the encoded path.
    function _encodedPath(uint256 currPtr)
        private
        pure
        returns (uint256 encodedPathPtr, uint256 encodedPathLen, uint256 newCurrPtr)
    {
        uint256 byte0;
        assembly { byte0 := byte(0, mload(currPtr)) }
        if (byte0 < STRING_SHORT_START) {
            // Single byte
            assembly {
                // encodedPath.ptr = currPtr
                encodedPathPtr := currPtr
                // encodedPath.len = 1
                encodedPathLen := 1
                // currPtr = currPtr + 1;
                newCurrPtr := add(currPtr, 1)
            }
        } else if (byte0 < STRING_LONG_START) {
            // Short string
            assembly {
                // encodedPath.ptr = currPtr + 1
                encodedPathPtr := add(currPtr, 1)
                // encodedPath.len = byte0 - 0x7f
                encodedPathLen := sub(byte0, STRING_SHORT_START)
                newCurrPtr := add(encodedPathPtr, encodedPathLen)
            }
        } else {
            // Encoded path is a string <= 32 bytes long
            revert UnexpectedByte0("encoded path", bytes1(uint8(byte0)));
        }
    }

    /// @dev Decodes the flag and partial path from the first element of an
    ///      extension or leaf node. See: https://ethereum.org/en/developers/docs/data-structures-and-encoding/patricia-merkle-trie/#specification
    /// @param encodedPathPtr Memory pointer to the first element of an extension or
    ///        leaf node. Consists of a one-nibble flag and the partial path itself.
    /// @param encodedPathLen Length in bytes of the encoded path.
    /// @param path The lookup path for the proof.
    /// @param pathBitIndex The number of bits of the lookup path that have 
    ///        already been processed.
    /// @return flag The one-nibble flag prefixing the encoded partial path
    ///         indicating whether the node is an extension or leaf node, and 
    ///         whether the partial path is odd or even in length.
    /// @return partialPathLength The length of the partial path that the node
    ///         "skips ahead" by.
    function _decodePartialPath(
        uint256 encodedPathPtr,
        uint256 encodedPathLen,
        bytes32 path, 
        uint256 pathBitIndex
    )
        private
        pure
        returns (uint256 flag, uint256 partialPathLength)
    {
        if (encodedPathLen == 0 || encodedPathLen > 32) {
            revert InvalidPathLength(encodedPathLen);
        }

        bytes32 partialPath;
        bytes32 expectedPartialPath;
        assembly {
            let encodedPathPayload := mload(encodedPathPtr)
            // First nibble of the encodedPath is a flag
            flag := shr(252, encodedPathPayload)

            // Offset is
            //     1 nibble (4 bits) if flag is odd
            //     2 nibbles (8 bits) if flag is even
            let offset := shl(2, sub(2, and(flag, 1)))
            // Shift left by the offset to remove the flag/padding
            partialPath := shl(offset, encodedPathPayload)
            // partialPathLength = (8 * encodedPathLength - offset) bits
            partialPathLength := sub(shl(3, encodedPathLen), offset)
            let rightAlignShift := sub(256, partialPathLength)
            // Shift right so that the partial path is right-aligned in
            // the word
            partialPath := shr(rightAlignShift, partialPath)
            // Shift `path` left and right so that we're left with the part
            // that should match `partialPath`, right-aligned in the word
            expectedPartialPath := shr(rightAlignShift, shl(pathBitIndex, path))
        }
        // Doing these here because reverts in assembly are so verbose
        if (flag > 3) {
            revert UnexpectedFlag("invalid", flag);
        }
        if (partialPath != expectedPartialPath) {
            revert InvalidPartialPath(expectedPartialPath, partialPath);
        }
    }

    /// @dev Computes the length of an RLP-encoded data stored in memory.
    ///      Refer to https://ethereum.org/en/developers/docs/data-structures-and-encoding/rlp/#definition
    /// @param memPtr The memory pointer at which the RLP-encoded data is located.
    /// @return itemLen The length of the data (including the prefix).
    function _rlpItemLength(uint256 memPtr)
        private
        pure
        returns (uint256 itemLen)
    {
        uint256 byte0;
        assembly { byte0 := byte(0, mload(memPtr)) }

        if (byte0 < STRING_SHORT_START) {
            // Item is a single byte
            itemLen = 1;
        } else if (byte0 < STRING_LONG_START) {
            // Item is a string 0-55 bytes long
            unchecked { itemLen = byte0 - 0x7f; }
        } else if (byte0 < LIST_SHORT_START) {
            // Item is a string >55 bytes long
            assembly {
                // The "length of the length" in bytes
                let byteLen := sub(byte0, 0xb7)
                // Skip over the "length of the length" (1 byte)
                memPtr := add(memPtr, 1)
                // The length of the data payload is the following `byteLen` bytes.
                // Shift right to clean the payload length.
                // rightAlignShift = 8 * (32 - byteLen)
                let rightAlignShift := shl(3, sub(32, byteLen))
                let payloadLen := shr(rightAlignShift, mload(memPtr))
                // The length of the whole RLP item is:
                //     the length of the payload (`payloadLen`) +
                //     the "length of the length" (`byteLen`) +
                //     the "length of the length of the length" (the first byte)
                itemLen := add(payloadLen, add(byteLen, 1))
            }
        } else if (byte0 < LIST_LONG_START) {
            // Item is a list 0-55 bytes long
            unchecked { itemLen = byte0 - 0xbf; }
        } else {
            assembly {
                // The "length of the length" in bytes
                let byteLen := sub(byte0, 0xf7)
                // Skip over the "length of the length" (1 byte)
                memPtr := add(memPtr, 1)
                // The length of the data payload is the following `byteLen` bytes.
                // Shift right to clean the payload length.
                // rightAlignShift = 8 * (32 - byteLen)
                let rightAlignShift := shl(3, sub(32, byteLen))
                let payloadLen := shr(rightAlignShift, mload(memPtr))
                // The length of the whole RLP item is:
                //     the length of the payload (`payloadLen`) +
                //     the "length of the length" (`byteLen`) +
                //     the "length of the length of the length" (the first byte)
                itemLen := add(payloadLen, add(byteLen, 1))
            }
        }
        return itemLen;
    }

    /// @dev Returns the nibble (i.e. 4 bits) at the given bit-index in
    ///      `path`.
    /// @param path The trie lookup path.
    /// @param pathBitIndex The bit-index in path at which the nibble starts.
    /// @return nibble The nibble at the queried index.
    function _getNibble(bytes32 path, uint256 pathBitIndex)
        private
        pure
        returns (uint256 nibble)
    {
        // `shl` shifts path so that the desired nibble is at the top of the word
        // `shr` removes everything but the top 4 bits, so we're left with just the
        // desired nibble, right-aligned in the word.
        assembly { nibble := shr(252, shl(pathBitIndex, path)) }
    }
}
