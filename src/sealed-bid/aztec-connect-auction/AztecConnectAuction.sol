// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "aztec-connect-bridges/bridges/base/BridgeBase.sol";
import "rollup-encoder/libraries/AztecTypes.sol";
import "rollup-encoder/interfaces/IRollupProcessor.sol";
import "solmate/tokens/ERC721.sol";
import "solmate/utils/ReentrancyGuard.sol";
import "solmate/utils/SafeTransferLib.sol";
import "./IAztecConnectAuctionErrors.sol";


contract AztecConnectAuction is IAztecConnectAuctionErrors, BridgeBase, ReentrancyGuard {
    using SafeTransferLib for address;

    /// @notice The base unit for bids. The reserve price and bid value parameters
    ///         for this contract's functions are denominated in this base unit, 
    ///         _not_ wei. 1000 gwei = 1e12 wei.
    uint256 public constant BID_BASE_UNIT = 1000 gwei;

    /// @dev Sentinel value used in the `commitments` mapping to indicate that a
    ///      commitment is "in progress", i.e. collateral has been deposited but
    ///      the hash commitment has not been written yet.
    bytes28 private constant IN_PROGRESS = bytes28(uint224(1));

    /// @dev Representation of an auction in storage. Occupies three slots.
    /// @param paramsHash Equal to the following: 
    ///        `bytes24(keccak256(auctionId, seller, tokenContract, tokenId))`
    /// @param endOfBiddingPeriod The unix timestamp after which bids can no
    ///        longer be placed.
    /// @param endOfRevealPeriod The unix timestamp after which commitments can
    ///        no longer be opened.
    /// @param highestBidder The bidder that placed the highest bid.
    /// @param highestBid The value of the highest bid revealed so far, or 
    ///        the reserve price if no bids have exceeded it. In bid base units
    ///        (1000 gwei).
    /// @param secondHighestBid The value of the second-highest bid revealed
    ///        so far, or the reserve price if no two bids have exceeded it.
    ///        In bid base units (1000 gwei).
    /// @param pendingWithdrawals Keeps track of collateral that can be withdrawn
    ///        by bidders once the auction has ended. Collateral can be withdrawn
    ///        to Ethereum or to Aztec.
    struct Auction {
        bytes24 paramsHash;
        uint32 endOfBiddingPeriod;
        uint32 endOfRevealPeriod;
        // =====================
        address highestBidder;
        uint48 highestBid;
        uint48 secondHighestBid;
        // =====================
        mapping(uint256 => PendingWithdrawal) pendingWithdrawals;
    }

    /// @dev Representation of a bid commitment in storage. 
    /// @param hash The hash commitment provided by the bidder.
    ///        Should equal the following:
    ///         `bytes28(keccak256(abi.encode(auctionId, bidder, bidValue, salt)))`.
    /// @param timestamp The block timestamp at which this commitment
    ///        was recorded. For a commitment to be valid for a particular
    ///        auction, this must be <= auction.endOfBiddingPeriod.
    struct Commitment {
        bytes28 hash;
        uint32 timestamp;
    }

    /// @dev Struct containing fields needed to open a bid commitment. 
    /// @param virtualAssetId The ID of the virtual asset burned to make 
    ///        the commitment.
    /// @param collateral The amount of collateral locked with the commitment.
    ///        Denominated in bid base units (1000 gwei).
    /// @param salt The random input used to obfuscate the commitment.
    struct BidOpening {
        uint256 virtualAssetId;
        uint48 collateral;
        bytes32 salt;
    }

    /// @dev Tracks a pending collateral withdrawal in storage.
    /// @param amount The amount of collateral to be withdrawn.
    /// @param l1Address The L1 address that revealed the commitment, 
    ///        and can execute this withdrawal on L1. 
    struct PendingWithdrawal {
        uint96 amount;
        address l1Address;
    }

    /// @notice Emitted when an auction is created.
    /// @param auctionId The unique identifier of the auction.
    /// @param tokenContract The address of the ERC721 contract for the asset
    ///        being auctioned.
    /// @param tokenId The ERC721 token ID of the asset being auctioned.
    /// @param seller The address selling the auctioned asset.
    /// @param bidPeriod The duration of the bidding period, in seconds.
    /// @param revealPeriod The duration of the commitment reveal period, 
    ///        in seconds.
    /// @param reservePrice The minimum price (in wei) that the asset will be sold
    ///        for. If not bids exceed this price, the asset is returned to `seller`.
    event AuctionCreated(
        uint64 auctionId,
        address tokenContract,
        uint256 tokenId,
        address seller,
        uint32 bidPeriod,
        uint32 revealPeriod,
        uint256 reservePrice
    );

    /// @notice Emitted when a bid is revealed.
    /// @param auctionId The unique identifier of the auction that the bid
    ///        was for.
    /// @param bidder The L1 address of the bidder whose bid was revealed.
    /// @param bidValue The value of the bid in wei.
    /// @param totalCollateral The total amount of collateral that was 
    ///        backing the bid (>= bidValue).
    /// @param withdrawalId The ID of the virtual asset that can be burned
    ///        to withdraw collateral to Aztec. Equal to 0 if the collateral
    ///        was immediately withdrawn to L1.
    event BidRevealed(
        uint64 auctionId,
        address bidder,
        uint256 bidValue,
        uint256 totalCollateral,
        uint256 withdrawalId
    );

    /// @notice Emitted when an auction is settled.
    /// @param auctionId The unique identifier of the auction.
    /// @param winner The bidder who won the auction, if any.
    /// @param settledPrice The amount the winner paid to the seller,
    ///        in wei. Equal to 0 if no bids exceeded the reserve price.
    event AuctionEnded(
        uint64 auctionId,
        address winner,
        uint256 settledPrice
    );

    /// @notice A mapping storing bid commitments. The first index is the 
    ///         ID of the virtual asset burnded to create the commitment. 
    ///         The second index is the amount of collateral (in bid base 
    ///         units) associated with the commitment.
    mapping(uint256 => mapping(uint48 => Commitment)) public commitments;

    /// @notice A mapping storing auction parameters and state, indexed by
    ///         auction ID.
    mapping(uint64 => Auction) public auctions;

    uint64 public nextAuctionId = 1;

    constructor(address _rollupProcessor)
        BridgeBase(_rollupProcessor)
    {}

    /// @notice Creates an auction for the given ERC721 asset with the given
    ///         auction parameters.
    /// @param tokenContract The address of the ERC721 contract for the asset
    ///        being auctioned.
    /// @param tokenId The ERC721 token ID of the asset being auctioned.
    /// @param bidPeriod The duration of the bidding period, in seconds.
    /// @param revealPeriod The duration of the commitment reveal period, 
    ///        in seconds.
    /// @param reservePrice The minimum price that the asset will be sold for.
    ///        If not bids exceed this price, the asset is returned to `seller`.
    ///        In bid base units (1000 gwei).
    function createAuction(
        address tokenContract,
        uint256 tokenId,
        uint32 bidPeriod,
        uint32 revealPeriod,
        uint48 reservePrice
    )
        external 
        nonReentrant
    {
        uint64 auctionId = nextAuctionId++;
        Auction storage auction = auctions[auctionId];

        if (bidPeriod < 1 hours) {
            revert BidPeriodTooShort(bidPeriod);
        }
        if (revealPeriod < 1 hours) {
            revert RevealPeriodTooShort(revealPeriod);
        }
        auction.paramsHash = bytes24(keccak256(abi.encode(
            auctionId,
            msg.sender,
            tokenContract,
            tokenId
        )));
        auction.endOfBiddingPeriod = uint32(block.timestamp) + bidPeriod;
        auction.endOfRevealPeriod = uint32(block.timestamp) + bidPeriod + revealPeriod;
        auction.highestBidder = address(0);
        // Both highest and second-highest bid are set to the reserve price.
        // Any winning bid must be at least this price, and the winner will 
        // pay at least this price.
        auction.highestBid = reservePrice;
        auction.secondHighestBid = reservePrice;
        
        // Reverts if msg.sender does not hold the token.
        ERC721(tokenContract).transferFrom(msg.sender, address(this), tokenId);

        emit AuctionCreated(
            auctionId,
            tokenContract,
            tokenId,
            msg.sender,
            bidPeriod,
            revealPeriod,
            reservePrice * BID_BASE_UNIT
        );
    }

    /// @notice The Aztec Connect bridge interface function. Only callable by
    ///         the Aztec rollup processor. Used to (1) make commitments from
    ///         Aztec and (2) withdraw ETH to Aztec once an auction is over.
    /// 
    ///         Note that (1) requires two separate L2 transactions (and thus
    ///         two separate `convert` calls):
    ///           1a. This will lock the collateral and mint (2^256 - 1) 
    ///               units of the virtual asset. The collateral amount is 
    ///               recorded and associated with the virtual asset ID.
    ///               Expected parameters: 
    ///                 inputAssetA = ETH
    ///                 outputAssetA = VIRTUAL
    ///                 inputValue = collateral amount (must be divisible by 1000 gwei)
    ///                 auxData = inputValue / 1000 gwei
    ///           1b. This burns the virtual asset from the previous step, 
    ///               in an amount that encodes the commitment hash.
    ///               Expected parameters:
    ///                 inputAssetA = VIRTUAL (outputAssetA from step 1a)
    ///                 outputAssetA = NOT_USED
    ///                 inputValue = uint256(commitmentHash)
    ///                 auxData = auxData from step 1a
    /// 
    ///         To withdraw ETH to Aztec once an auction is over, the following 
    ///         parameters are expected:
    ///                 inputAssetA = VIRTUAL
    ///                 outputAssetA = ETH
    ///                 inputValue = any non-zero value
    ///                 auxData = auctionId
    ///         where `inputAssetA` is the virtual asset corresponding to the 
    ///         withdrawalId as emitted in the `BidRevealed` event. The bidder
    ///         should have (2^256 - 1 - uint256(commitmentHash)) units left of
    ///         this virtual asset after step 1b. The virtual asset serves as a
    ///         "withdrawal voucher" that can be burned to withdraw the unused
    ///         bid collateral to Aztec.
    function convert(
        AztecTypes.AztecAsset calldata inputAssetA,
        AztecTypes.AztecAsset calldata /* inputAssetB */,
        AztecTypes.AztecAsset calldata outputAssetA,
        AztecTypes.AztecAsset calldata /* outputAssetB */,
        uint256 inputValue,
        uint256 interactionNonce,
        uint64 auxData,
        address /* rollupBeneficiary */
    )
        external
        payable
        override(BridgeBase)
        nonReentrant
        onlyRollup
        returns (
            uint256 outputValueA,
            uint256 /* outputValueB */,
            bool /* isAsync */
        )
    {
        if (
            inputAssetA.assetType == AztecTypes.AztecAssetType.ETH &&
            outputAssetA.assetType == AztecTypes.AztecAssetType.VIRTUAL
        ) {
            ////////// COMMIT STEP 1 (deposit collateral) //////////

            // This check prevents an attacker from "stealing" some of the 
            // output virtual asset by trying to get their deposit transaction
            // batched with the legitimate one. 
            if (inputValue != uint256(auxData) * BID_BASE_UNIT) {
                revert InputValueAuxDataMismatch(inputValue, auxData);
            }
            // Stage the storage slot for step 2. 
            commitments[outputAssetA.id][_downcast(auxData)].hash = IN_PROGRESS;
            // Output (2^256 - 1) of the virtual asset so its amount can be 
            // used to write an arbtirary hash commitment in step 2. 
            outputValueA = type(uint256).max;
        } else if (
            inputAssetA.assetType == AztecTypes.AztecAssetType.VIRTUAL &&
            outputAssetA.assetType == AztecTypes.AztecAssetType.VIRTUAL
        ) {
            ////////// COMMIT STEP 2 (record hash commitment) //////////

            if (inputValue == 0) {
                revert ZeroInputValue();
            }
            // The following checks that there was an associated collateral
            // deposit transaction. 
            Commitment storage commitment = commitments[inputAssetA.id][_downcast(auxData)];

            if (commitment.hash != IN_PROGRESS) {
                revert UnexpectedCommitmentHash(IN_PROGRESS, commitment.hash);
            }
            // Write the hash commitment. Note that `inputValue` is being used 
            // as a hack here to communicate a 28-byte hash commitment. 
            // So `bytes32(inputValue)` should equal:
            //      keccak256(abi.encode(auctionId, bidder, bidValue, salt))
            // where `bidValue` is the sum of constituent pieces of collateral.
            commitment.hash = bytes28(uint224(inputValue));
            commitment.timestamp = uint32(block.timestamp);
        } else if (
            inputAssetA.assetType == AztecTypes.AztecAssetType.VIRTUAL &&
            outputAssetA.assetType == AztecTypes.AztecAssetType.ETH
        ) {
            ////////// WITHDRAW COLLATERAL (to Aztec) //////////

            Auction storage auction = auctions[auxData];
            if (_isActive(auction)) {
                revert AuctionIsStillActive();
            }
            if (inputValue == 0) {
                revert ZeroInputValue();
            }

            // Process pending withdrawal associated with the given virtual asset.
            outputValueA = auction.pendingWithdrawals[inputAssetA.id].amount;
            // Clear storage slot to recoup gas and prevent double spends.
            auction.pendingWithdrawals[inputAssetA.id] = PendingWithdrawal(0, address(0));
            // Send ETH to rollup processor.
            IRollupProcessor(ROLLUP_PROCESSOR).receiveEthFromBridge{value: outputValueA}(interactionNonce);
        } else {
            revert UnexpectedAssets();
        }
    }

    /// @notice Reveals the value of a bid that was previously committed to. 
    /// @param auctionId The unique identifier of the auction.
    /// @param bidValue The value of the bid. In bid base units (1000 gwei).
    /// @param openings An array of `BidOpening` structs, each corresponding 
    ///        to one constituent commitment of the bid.
    /// @param withdrawImmediatelyIfPossible If true, and the revealed bid is
    ///        not in the running to win the auction, immediately withdraws
    ///        the bid collateral to msg.sender.
    function revealBid(
        uint64 auctionId,
        uint48 bidValue,
        BidOpening[] memory openings,
        bool withdrawImmediatelyIfPossible
    )
        external
        nonReentrant
    {
        if (openings.length == 0) {
            revert EmptyOpeningsArray();
        }
        Auction storage auction = auctions[auctionId];
        if (
            block.timestamp <= auction.endOfBiddingPeriod ||
            block.timestamp > auction.endOfRevealPeriod
        ) {
            revert NotInRevealPeriod();
        }

        uint48 totalCollateral = 0;
        // Prepare memory for computing hash commitments.
        bytes memory hashInput = abi.encode(
            auctionId,
            msg.sender,
            bidValue,
            0 // Placeholder for salt
        );
        for (uint256 i = 0; i != openings.length; ++i) {
            BidOpening memory opening = openings[i];
            bytes32 salt = opening.salt;
            bytes28 computedHash;
            // Swap out the salt value in memory, then compute the hash
            // for this commitment.
            assembly {
                mstore(add(hashInput, 0x80), salt)
                computedHash := keccak256(add(hashInput, 0x20), 0x80)
            }
            Commitment storage commitment = commitments
                [opening.virtualAssetId]
                [opening.collateral];
            if (computedHash != commitment.hash) {
                revert UnexpectedCommitmentHash(computedHash, commitment.hash);
            }
            if (commitment.timestamp > auction.endOfBiddingPeriod) {
                revert CommitedAfterBiddingPeriod(
                    auction.endOfBiddingPeriod, 
                    commitment.timestamp
                );
            }
            // Clear the storage slot for this commitment.
            commitments[opening.virtualAssetId][opening.collateral] = Commitment(0, 0);
            // Add this piece of collateral to the running total.
            totalCollateral += opening.collateral;
        }

        // Bid can be overcollateralized, but not undercollateralized.
        if (totalCollateral < bidValue) {
            revert InsufficientCollateral(
                uint256(bidValue) * BID_BASE_UNIT,
                uint256(totalCollateral) * BID_BASE_UNIT
            );
        }

        uint256 withdrawalAmount = totalCollateral * BID_BASE_UNIT;
        uint48 currentHighestBid = auction.highestBid;
        if (bidValue > currentHighestBid) {
            // Update record of (second-)highest bid
            auction.highestBidder = msg.sender;
            auction.highestBid = bidValue;
            auction.secondHighestBid = currentHighestBid;
            
            // Record a pending withdrawal. The bidder can withdraw their ETH on 
            // L1, or on Aztec by burning one of thier leftover units of the first 
            // virtual asset.
            auction.pendingWithdrawals[openings[0].virtualAssetId] = PendingWithdrawal({
                amount: uint96(withdrawalAmount),
                l1Address: msg.sender
            });
        } else {
            if (bidValue > auction.secondHighestBid) {
                // Update record of second-highest bid
                auction.secondHighestBid = bidValue;
            }
            if (withdrawImmediatelyIfPossible) {
                // This bidder is not in the running to win the auction,
                // so we can immediately withdraw their collateral.
                msg.sender.safeTransferETH(withdrawalAmount);
                emit BidRevealed(
                    auctionId,
                    msg.sender,
                    bidValue * BID_BASE_UNIT,
                    withdrawalAmount,
                    0
                );
                return;
            } else {
                // Record a pending withdrawal. The bidder can withdraw their ETH on 
                // L1, or on Aztec by burning one of their leftover units of the first 
                // virtual asset.
                auction.pendingWithdrawals[openings[0].virtualAssetId] = PendingWithdrawal({
                    amount: uint96(withdrawalAmount),
                    l1Address: msg.sender
                });
            }
        }

        emit BidRevealed(
            auctionId,
            msg.sender,
            bidValue * BID_BASE_UNIT,
            withdrawalAmount,
            openings[0].virtualAssetId
        );
    }

    /// @notice Ends an active auction. Can only end an auction if the bid reveal
    ///         phase is over. Disburses the auction proceeds to the seller. 
    ///         Transfers the auctioned asset to the winning bidder. If no bidder 
    ///         exceeded the auction's reserve price, returns the asset to the seller.
    /// @param auctionId The unique identifier of the auction.
    /// @param seller The address selling the auctioned asset.
    /// @param tokenContract The address of the ERC721 contract for the asset auctioned.
    /// @param tokenId The ERC721 token ID of the asset auctioned.
    /// @param withdrawalId The withdrawalId associated with the winning bid. Needed
    ///        to debit the settled price from the winner's withdrawal.
    function endAuction(
        uint64 auctionId,
        address seller,
        address tokenContract,
        uint256 tokenId,
        uint256 withdrawalId
    )
        external
        nonReentrant
    {
        Auction storage auction = auctions[auctionId];
        bytes24 expectedParamsHash = bytes24(keccak256(abi.encode(
            auctionId,
            seller,
            tokenContract,
            tokenId
        )));
        if (auction.paramsHash != expectedParamsHash) {
            revert UnexpectedParamsHash(expectedParamsHash, auction.paramsHash);
        }
        if (block.timestamp <= auction.endOfRevealPeriod) {
            revert RevealPeriodOngoing();
        }

        // Mark auction as inactive (enabling withdrawals).
        auction.paramsHash = bytes24(0);

        address highestBidder = auction.highestBidder;
        if (highestBidder == address(0)) {
            // No winner, return asset to seller.
            ERC721(tokenContract).transferFrom(
                address(this), 
                seller, 
                tokenId
            );
            emit AuctionEnded(
                auctionId,
                address(0),
                0
            );
        } else {
            // Transfer auctioned asset to highest bidder.
            ERC721(tokenContract).transferFrom(
                address(this), 
                highestBidder, 
                tokenId
            );
            // Winner pays the second-highest bid amount.
            uint256 settledPrice = auction.secondHighestBid * BID_BASE_UNIT;
            // Unchecked raw transfer to prevent a smart contract seller from
            // bricking withdrawals with a reverting `receive` function.
            seller.call{value: settledPrice}("");
            // Deduct the settled price from the winner's pending withdrawal.
            PendingWithdrawal memory withdrawal = auction.pendingWithdrawals[withdrawalId];
            if (withdrawal.l1Address != highestBidder) {
                revert InvalidWithdrawalAddress(withdrawal.l1Address, highestBidder);
            }
            // Note that the winner may have multiple pending withdrawals for the 
            // auction. In this case, this doesn't necessarily have to be the withdrawal
            // associated with the winning bid, as long as the winner is debited in the
            // correct amount, which is guaranteed by the underflow check on this 
            // subtraction. 
            auction.pendingWithdrawals[withdrawalId].amount -= uint96(settledPrice);
            emit AuctionEnded(
                auctionId,
                highestBidder,
                settledPrice
            );
        }
    }

    /// @notice Withdraws collateral. Bidder must have opened their bid commitment
    ///         and auction must have ended.
    /// @param auctionId The unique identifier of the auction.
    /// @param withdrawalId The withdrawal ID as emitted in the `BidRevealed` event.
    function withdrawCollateral(uint64 auctionId, uint256 withdrawalId)
        external
        nonReentrant
    {
        Auction storage auction = auctions[auctionId];
        if (_isActive(auction)) {
            revert AuctionIsStillActive();
        }

        PendingWithdrawal memory withdrawal = auction.pendingWithdrawals[withdrawalId];
        // msg.sender must match the address recorded during the `revealBid` transaction.
        if (withdrawal.l1Address != msg.sender) {
            revert InvalidWithdrawalAddress(withdrawal.l1Address, msg.sender);
        }
        // Clear storage slot to recoup gas and prevent double spends.
        auction.pendingWithdrawals[withdrawalId] = PendingWithdrawal(0, address(0));
        // Return ETH.
        msg.sender.safeTransferETH(withdrawal.amount);
    }

    /// @dev Whether the given auction is active (was created and has not
    ///      ended yet). Pending withdrawals cannot be executed while the
    ///      auction is active.
    function _isActive(Auction storage auction)
        private
        view
        returns (bool active)
    {
        return auction.paramsHash != 0;
    }

    /// @dev Safely downcasts `uint64 auxData` into a `uint48`.
    function _downcast(uint64 auxData)
        private
        pure
        returns (uint48)
    {
        if (auxData > type(uint48).max) {
            revert DowncastOverflow();
        }
        return uint48(auxData);
    }
}