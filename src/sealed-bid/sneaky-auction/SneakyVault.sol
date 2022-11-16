// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "solmate/utils/SafeTransferLib.sol";
import "./SneakyAuction.sol"; 

/// @title A contract deployed via `CREATE2` by the `SneakyAuction` contract. Bidders
///        send their collateral to the address of the SneakyVault before it is deployed.
contract SneakyVault {
    using SafeTransferLib for address;

    constructor(
        address tokenContract,
        uint256 tokenId,
        uint32 /* auctionIndex */,
        address bidder,
        uint48 /* bidValue */
    ) {
        // This contract should be deployed via `CREATE2` by a `SneakyAuction`
        SneakyAuction auctionContract = SneakyAuction(msg.sender);
        // If this vault holds the collateral for the winning bid, send the bid amount
        // to the seller
        if (auctionContract.getHighestBidVault(tokenContract, tokenId) == address(this)) {
            uint256 bidAmount = auctionContract.getSecondHighestBid(tokenContract, tokenId);
            assert(address(this).balance >= bidAmount);
            auctionContract.getSeller(tokenContract, tokenId).safeTransferETH(bidAmount);
        }
        // Self-destruct, returning excess ETH to the bidder
        selfdestruct(payable(bidder));
    }
}
