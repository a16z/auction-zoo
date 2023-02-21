// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;


/// @title Custom errors for AztecConnectAuction
interface IAztecConnectAuctionErrors {
    error RevealPeriodOngoing();
    error AuctionIsNotActive();
    error AuctionIsStillActive();
    error BidPeriodTooShort(uint32 bidPeriod);
    error RevealPeriodTooShort(uint32 revealPeriod);
    error NotInRevealPeriod();
    error UnexpectedAssets();
    error DowncastOverflow();
    error InvalidWithdrawalAddress(address expected, address actual);
    error InputValueAuxDataMismatch(uint256 inputValue, uint64 auxData);
    error UnexpectedCommitmentHash(bytes28 expected, bytes28 actual);
    error InsufficientCollateral(uint256 bidValue, uint256 collateral);
    error CommitedAfterBiddingPeriod(uint32 endOfBiddingPeriod, uint32 commitmentTimestamp);
    error UnexpectedParamsHash(bytes24 expected, bytes24 actual);
    error ZeroInputValue();
    error EmptyOpeningsArray();
}
