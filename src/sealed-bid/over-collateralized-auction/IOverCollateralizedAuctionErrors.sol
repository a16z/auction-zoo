// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;


/// @title Custom errors for OverCollateralizedAuction
interface IOverCollateralizedAuctionErrors {
    error RevealPeriodOngoingError();
    error BidPeriodOngoingError();
    error InvalidAuctionIndexError(uint64 index);
    error BidPeriodTooShortError(uint32 bidPeriod);
    error RevealPeriodTooShortError(uint32 revealPeriod);
    error NotInRevealPeriodError();
    error NotInBidPeriodError();
    error UnrevealedBidError();
    error CannotWithdrawError();
    error ZeroCommitmentError();
    error InvalidStartTimeError(uint32 startTime);
    error InvalidOpeningError(bytes20 bidHash, bytes20 commitment);
}
