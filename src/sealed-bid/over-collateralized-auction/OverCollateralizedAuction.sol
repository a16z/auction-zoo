// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "solmate/tokens/ERC721.sol";
import "solmate/utils/ReentrancyGuard.sol";
import "solmate/utils/SafeTransferLib.sol";
import "./IOverCollateralizedAuctionErrors.sol";

/// @title An on-chain, over-collateralization, sealed-bid, second-price auction
contract OverCollateralizedAuction is IOverCollateralizedAuctionErrors, ReentrancyGuard {
    using SafeTransferLib for address;

    /// @dev Representation of an auction in storage. Occupies three slots.
    /// @param seller The address selling the auctioned asset.
    /// @param startTime The unix timestamp at which bidding can start.
    /// @param endOfBiddingPeriod The unix timestamp after which bids can no
    ///        longer be placed.
    /// @param endOfRevealPeriod The unix timestamp after which commitments can
    ///        no longer be opened.
    /// @param numUnrevealedBids The number of bid commitments that have not
    ///        yet been opened.
    /// @param highestBid The value of the highest bid revealed so far, or 
    ///        the reserve price if no bids have exceeded it.
    /// @param secondHighestBid The value of the second-highest bid revealed
    ///        so far, or the reserve price if no two bids have exceeded it.
    /// @param highestBidder The bidder that placed the highest bid.
    /// @param index Auctions selling the same asset (i.e. tokenContract-tokenId
    ///        pair) share the same storage. This value is incremented for 
    ///        each new auction of a particular asset.
    struct Auction {
        address seller;
        uint32 startTime;
        uint32 endOfBiddingPeriod;
        uint32 endOfRevealPeriod;
        // =====================
        uint64 numUnrevealedBids;
        uint96 highestBid;
        uint96 secondHighestBid;
        // =====================
        address highestBidder;
        uint64 index;
    }

    /// @dev Representation of a bid in storage. Occupies one slot.
    /// @param commitment The hash commitment of a bid value.
    /// @param collateral The amount of collateral backing the bid.
    struct Bid {
        bytes20 commitment;
        uint96 collateral;
    }

    /// @notice Emitted when an auction is created.
    /// @param tokenContract The address of the ERC721 contract for the asset
    ///        being auctioned.
    /// @param tokenId The ERC721 token ID of the asset being auctioned.
    /// @param seller The address selling the auctioned asset.
    /// @param startTime The unix timestamp at which bidding can start.
    /// @param bidPeriod The duration of the bidding period, in seconds.
    /// @param revealPeriod The duration of the commitment reveal period, 
    ///        in seconds.
    /// @param reservePrice The minimum price that the asset will be sold for.
    ///        If no bids exceed this price, the asset is returned to `seller`.
    event AuctionCreated(
        address tokenContract,
        uint256 tokenId,
        address seller,
        uint32 startTime,
        uint32 bidPeriod,
        uint32 revealPeriod,
        uint96 reservePrice
    );

    /// @notice Emitted when a bid commitment is opened.
    /// @param tokenContract The address of the ERC721 contract for the asset
    ///        being auctioned.
    /// @param tokenId The ERC721 token ID of the asset being auctioned.
    /// @param commitment The commitment that was opened.
    /// @param bidder The bidder whose bid was revealed.
    /// @param nonce The random input used to obfuscate the commitment.
    /// @param bidValue The value of the bid.
    event BidRevealed(
        address tokenContract,
        uint256 tokenId,
        bytes20 commitment,
        address bidder,
        bytes32 nonce,
        uint96 bidValue
    );

    /// @notice A mapping storing auction parameters and state, indexed by
    ///         the ERC721 contract address and token ID of the asset being
    ///         auctioned.
    mapping(address => mapping(uint256 => Auction)) public auctions;

    /// @notice A mapping storing bid commitments and records of collateral, 
    ///         indexed by: ERC721 contract address, token ID, auction index, 
    ///         and bidder address. If the commitment is `bytes20(0)`, either
    ///         no commitment was made or the commitment was opened.
    mapping(address // ERC721 token contract
        => mapping(uint256 // ERC721 token ID
            => mapping(uint64 // Auction index
                => mapping(address // Bidder
                    => Bid)))) public bids;

    /// @notice Creates an auction for the given ERC721 asset with the given
    ///         auction parameters.
    /// @param tokenContract The address of the ERC721 contract for the asset
    ///        being auctioned.
    /// @param tokenId The ERC721 token ID of the asset being auctioned.
    /// @param startTime The unix timestamp at which bidding can start.
    /// @param bidPeriod The duration of the bidding period, in seconds.
    /// @param revealPeriod The duration of the commitment reveal period, 
    ///        in seconds.
    /// @param reservePrice The minimum price that the asset will be sold for.
    ///        If no bids exceed this price, the asset is returned to `seller`.
    function createAuction(
        address tokenContract,
        uint256 tokenId,
        uint32 startTime, 
        uint32 bidPeriod,
        uint32 revealPeriod,
        uint96 reservePrice
    ) 
        external 
        nonReentrant
    {
        Auction storage auction = auctions[tokenContract][tokenId];

        if (startTime == 0) {
            startTime = uint32(block.timestamp);
        } else if (startTime < block.timestamp) {
            revert InvalidStartTimeError(startTime);
        }
        if (bidPeriod < 1 hours) {
            revert BidPeriodTooShortError(bidPeriod);
        }
        if (revealPeriod < 1 hours) {
            revert RevealPeriodTooShortError(revealPeriod);
        }
        
        auction.seller = msg.sender;
        auction.startTime = startTime;
        auction.endOfBiddingPeriod = startTime + bidPeriod;
        auction.endOfRevealPeriod = startTime + bidPeriod + revealPeriod;
        // Reset
        auction.numUnrevealedBids = 0;
        // Both highest and second-highest bid are set to the reserve price.
        // Any winning bid must be at least this price, and the winner will 
        // pay at least this price.
        auction.highestBid = reservePrice;
        auction.secondHighestBid = reservePrice;
        // Reset
        auction.highestBidder = address(0);
        // Increment auction index for this item
        auction.index++;

        ERC721(tokenContract).transferFrom(msg.sender, address(this), tokenId);

        emit AuctionCreated(
            tokenContract,
            tokenId,
            msg.sender,
            startTime,
            bidPeriod,
            revealPeriod,
            reservePrice
        );
    }

    /// @notice Commits to a bid on an item being auctioned. If a bid was
    ///         previously committed to, overwrites the previous commitment.
    ///         Value attached to this call is used as collateral for the bid.
    /// @param tokenContract The address of the ERC721 contract for the asset
    ///        being auctioned.
    /// @param tokenId The ERC721 token ID of the asset being auctioned.
    /// @param commitment The commitment to the bid, computed as
    ///        `bytes20(keccak256(abi.encode(nonce, bidValue)))`.
    function commitBid(
        address tokenContract, 
        uint256 tokenId, 
        bytes20 commitment
    )
        external
        payable
        nonReentrant
    {
        if (commitment == bytes20(0)) {
            revert ZeroCommitmentError();
        }

        Auction storage auction = auctions[tokenContract][tokenId];

        if (
            block.timestamp < auction.startTime || 
            block.timestamp > auction.endOfBiddingPeriod
        ) {
            revert NotInBidPeriodError();
        }

        uint64 auctionIndex = auction.index;
        Bid storage bid = bids[tokenContract][tokenId][auctionIndex][msg.sender];
        // If this is the bidder's first commitment, increment `numUnrevealedBids`.
        if (bid.commitment == bytes20(0)) {
            auction.numUnrevealedBids++;
        }
        bid.commitment = commitment;
        if (msg.value != 0) {
            bid.collateral += uint96(msg.value);
        }
    }

    /// @notice Reveals the value of a bid that was previously committed to. 
    /// @param tokenContract The address of the ERC721 contract for the asset
    ///        being auctioned.
    /// @param tokenId The ERC721 token ID of the asset being auctioned.
    /// @param bidValue The value of the bid.
    /// @param nonce The random input used to obfuscate the commitment.
    function revealBid(
        address tokenContract,
        uint256 tokenId,
        uint96 bidValue,
        bytes32 nonce
    )
        external
        nonReentrant
    {
        Auction storage auction = auctions[tokenContract][tokenId];

        if (
            block.timestamp <= auction.endOfBiddingPeriod ||
            block.timestamp > auction.endOfRevealPeriod
        ) {
            revert NotInRevealPeriodError();
        }

        uint64 auctionIndex = auction.index;
        Bid storage bid = bids[tokenContract][tokenId][auctionIndex][msg.sender];

        // Check that the opening is valid
        bytes20 bidHash = bytes20(keccak256(abi.encode(nonce, bidValue)));
        if (bidHash != bid.commitment) {
            revert InvalidOpeningError(bidHash, bid.commitment);
        } else {
            // Mark commitment as open
            bid.commitment = bytes20(0);
            auction.numUnrevealedBids--;
        }

        uint96 collateral = bid.collateral;
        if (collateral < bidValue) {
            // Return collateral
            bid.collateral = 0;
            msg.sender.safeTransferETH(collateral);
        } else {
            // Update record of (second-)highest bid as necessary
            uint96 currentHighestBid = auction.highestBid;
            if (bidValue > currentHighestBid) {
                auction.highestBid = bidValue;
                auction.secondHighestBid = currentHighestBid;
                auction.highestBidder = msg.sender;
            } else {
                if (bidValue > auction.secondHighestBid) {
                    auction.secondHighestBid = bidValue;
                }
                // Return collateral
                bid.collateral = 0;
                msg.sender.safeTransferETH(collateral);
            }

            emit BidRevealed(
                tokenContract,
                tokenId,
                bidHash,
                msg.sender,
                nonce,
                bidValue
            );
        }
    }
    
    /// @notice Ends an active auction. Can only end an auction if the bid reveal
    ///         phase is over, or if all bids have been revealed. Disburses the auction
    ///         proceeds to the seller. Transfers the auctioned asset to the winning
    ///         bidder and returns any excess collateral. If no bidder exceeded the
    ///         auction's reserve price, returns the asset to the seller.
    /// @param tokenContract The address of the ERC721 contract for the asset auctioned.
    /// @param tokenId The ERC721 token ID of the asset auctioned.
    function endAuction(address tokenContract, uint256 tokenId)
        external
        nonReentrant
    {
        Auction storage auction = auctions[tokenContract][tokenId];
        if (auction.index == 0) {
            revert InvalidAuctionIndexError(0);
        }

        if (block.timestamp <= auction.endOfBiddingPeriod) {
            revert BidPeriodOngoingError();
        } else if (block.timestamp <= auction.endOfRevealPeriod) {
            if (auction.numUnrevealedBids != 0) {
                // cannot end auction early unless all bids have been revealed
                revert RevealPeriodOngoingError();
            }
        }

        address highestBidder = auction.highestBidder;
        if (highestBidder == address(0)) {
            // No winner, return asset to seller.
            ERC721(tokenContract).safeTransferFrom(address(this), auction.seller, tokenId);
        } else {
            // Transfer auctioned asset to highest bidder
            ERC721(tokenContract).safeTransferFrom(address(this), highestBidder, tokenId);
            uint96 secondHighestBid = auction.secondHighestBid;
            auction.seller.safeTransferETH(secondHighestBid);

            // Return excess collateral
            Bid storage bid = bids[tokenContract][tokenId][auction.index][highestBidder];
            uint96 collateral = bid.collateral;
            bid.collateral = 0;
            if (collateral - secondHighestBid != 0) {
                highestBidder.safeTransferETH(collateral - secondHighestBid);
            }
        }
    }

    /// @notice Withdraws collateral. Bidder must have opened their bid commitment
    ///         and cannot be in the running to win the auction.
    /// @param tokenContract The address of the ERC721 contract for the asset
    ///        that was auctioned.
    /// @param tokenId The ERC721 token ID of the asset that was auctioned.
    /// @param auctionIndex The index of the auction that was being bid on.
    function withdrawCollateral(
        address tokenContract,
        uint256 tokenId,
        uint64 auctionIndex
    )
        external
        nonReentrant        
    {
        Auction storage auction = auctions[tokenContract][tokenId];
        uint64 currentAuctionIndex = auction.index;
        if (auctionIndex > currentAuctionIndex) {
            revert InvalidAuctionIndexError(auctionIndex);
        }

        Bid storage bid = bids[tokenContract][tokenId][auctionIndex][msg.sender];
        if (bid.commitment != bytes20(0)) {
            revert UnrevealedBidError();
        }

        if (auctionIndex == currentAuctionIndex) {
            // If bidder has revealed their bid and is not currently in the 
            // running to win the auction, they can withdraw their collateral.
            if (msg.sender == auction.highestBidder) {
                revert CannotWithdrawError();    
            }
        }
        // Return collateral
        uint96 collateral = bid.collateral;
        bid.collateral = 0;
        msg.sender.safeTransferETH(collateral);
    }

    /// @notice Gets the parameters and state of an auction in storage.
    /// @param tokenContract The address of the ERC721 contract for the asset auctioned.
    /// @param tokenId The ERC721 token ID of the asset auctioned.
    function getAuction(address tokenContract, uint256 tokenId)
        external
        view
        returns (Auction memory auction)
    {
        return auctions[tokenContract][tokenId];
    }
}
