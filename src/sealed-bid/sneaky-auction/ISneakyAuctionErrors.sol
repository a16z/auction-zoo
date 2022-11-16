// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;


/// @title Custom errors for SneakyAuction
interface ISneakyAuctionErrors {
    error RevealPeriodOngoingError();
    error InvalidAuctionIndexError(uint32 index);
    error BidPeriodTooShortError(uint32 bidPeriod);
    error RevealPeriodTooShortError(uint32 revealPeriod);
    error NotInRevealPeriodError();
    error IncorrectVaultAddressError(address expectedVault, address actualVault);
    error UnrevealedBidError();
    error CannotWithdrawError();
    error BidAlreadyRevealedError(address vault);
}
