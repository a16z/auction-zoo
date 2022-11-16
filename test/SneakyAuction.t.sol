// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "../src/sealed-bid/sneaky-auction/ISneakyAuctionErrors.sol";
import "../src/sealed-bid/sneaky-auction/SneakyAuction.sol";
import "./utils/TestActors.sol";
import "./utils/TestERC721.sol";


contract SneakyAuctionWrapper is SneakyAuction {
    uint256 bal;

    function setBalance(uint256 _bal) external {
        bal = _bal;
    }

    // Overridden so we don't have to deal with proofs here.
    // See BalanceProofTest.sol for LibBalanceProof unit tests.
    function _getProvenAccountBalance(
        bytes[] memory /* proof */,
        bytes memory /* blockHeaderRLP */,
        bytes32 /* blockHash */,
        address /* account */
    )
        internal
        override
        view
        returns (uint256 accountBalance)
    {
        return bal;
    }
}

contract SneakyAuctionTest is ISneakyAuctionErrors, TestActors {
    SneakyAuctionWrapper auction;
    TestERC721 erc721;

    uint48 constant ONE_ETH = uint48(1 ether / 1000 gwei);
    uint256 constant TOKEN_ID = 1;

    function setUp() public override {
        super.setUp();
        auction = new SneakyAuctionWrapper();
        erc721 = new TestERC721();
        erc721.mint(alice, TOKEN_ID);
        hoax(alice);
        erc721.setApprovalForAll(address(auction), true);
    }

    function testCreateAuction() external {
        SneakyAuction.Auction memory expectedAuction = 
            SneakyAuction.Auction({
                seller: alice,
                endOfBiddingPeriod: uint32(block.timestamp + 1 hours),
                endOfRevealPeriod: uint32(block.timestamp + 2 hours),
                index: 1,
                highestBid: ONE_ETH,
                secondHighestBid: ONE_ETH,
                highestBidVault: address(0),
                collateralizationDeadlineBlockHash: bytes32(0)
            });
        SneakyAuction.Auction memory actualAuction = 
            createAuction(TOKEN_ID);
        assertAuctionsEqual(actualAuction, expectedAuction);
    }
    
    function testCannotCreateAuctionForItemThatYouDoNotOwn() external {
        vm.expectRevert("WRONG_FROM");
        createAuction(4);
    }

    function testRevealBid() external {
        SneakyAuction.Auction memory expectedState = 
            createAuction(TOKEN_ID);
        uint48 bidValue = ONE_ETH + 1;
        bytes32 salt = bytes32(uint256(123));
        address vault = commitBid(
            bob,
            bidValue,
            bidValue,
            salt
        );
        skip(1 hours + 30 minutes);
        hoax(bob);
        auction.revealBid(
            address(erc721),
            TOKEN_ID,
            bidValue,
            salt,
            nullProof()
        );
        expectedState.collateralizationDeadlineBlockHash = blockhash(block.number - 1);
        expectedState.secondHighestBid = expectedState.highestBid;
        expectedState.highestBid = bidValue;
        expectedState.highestBidVault = vault;
        assertAuctionsEqual(auction.getAuction(address(erc721), TOKEN_ID), expectedState);
        assertVaultRevealed(vault);        
    }

    function testCannotRevealBidBeforeRevealPeriod() external {
        createAuction(TOKEN_ID);
        uint48 bidValue = ONE_ETH + 1;
        bytes32 salt = bytes32(uint256(123));
        commitBid(
            bob,
            bidValue,
            bidValue,
            salt
        );
        vm.expectRevert(NotInRevealPeriodError.selector);
        hoax(bob);
        auction.revealBid(
            address(erc721),
            TOKEN_ID,
            bidValue,
            salt,
            nullProof()
        );
    }

    function testCannotRevealBidAfterRevealPeriod() external {
        createAuction(TOKEN_ID);
        uint48 bidValue = ONE_ETH + 1;
        bytes32 salt = bytes32(uint256(123));
        commitBid(
            bob,
            bidValue,
            bidValue,
            salt
        );
        skip(3 hours);
        vm.expectRevert(NotInRevealPeriodError.selector);
        hoax(bob);
        auction.revealBid(
            address(erc721),
            TOKEN_ID,
            bidValue,
            salt,
            nullProof()
        );
    }

    function testRevealUsingDifferentSalt() external {
        SneakyAuction.Auction memory expectedState = createAuction(TOKEN_ID);
        uint48 bidValue = ONE_ETH + 1;
        bytes32 salt = bytes32(uint256(123));
        commitBid(
            bob,
            bidValue,
            bidValue,
            salt
        );
        skip(1 hours + 30 minutes);
        // Vault corresponding to different salt is empty
        hoax(bob);
        auction.revealBid(
            address(erc721),
            TOKEN_ID,
            bidValue,
            bytes32(uint256(salt) + 1),
            nullProof()
        );
        assertAuctionsEqual(
            auction.getAuction(address(erc721), TOKEN_ID), 
            expectedState
        );
        assertVaultRevealed(auction.getVaultAddress(
            address(erc721),
            TOKEN_ID,
            expectedState.index,
            bob,
            bidValue,
            bytes32(uint256(salt) + 1)
        ));
    }

    function testRevealUsingDifferentBidValue() external {
        SneakyAuction.Auction memory expectedState = createAuction(TOKEN_ID);
        uint48 bidValue = ONE_ETH + 1;
        bytes32 salt = bytes32(uint256(123));
        commitBid(
            bob,
            bidValue,
            bidValue,
            salt
        );
        skip(1 hours + 30 minutes);
        hoax(bob);
        auction.revealBid(
            address(erc721),
            TOKEN_ID,
            bidValue + 1,
            salt,
            nullProof()
        );
        assertAuctionsEqual(
            auction.getAuction(address(erc721), TOKEN_ID), 
            expectedState
        );
        assertVaultRevealed(auction.getVaultAddress(
            address(erc721),
            TOKEN_ID,
            expectedState.index,
            bob,
            bidValue + 1,
            salt
        ));
    }

    function testRevealWithInsufficientCollateral1() external {
        SneakyAuction.Auction memory expectedState = createAuction(TOKEN_ID);
        uint48 bidValue = ONE_ETH + 1;
        bytes32 salt = bytes32(uint256(123));
        commitBid(
            bob,
            bidValue,
            bidValue - 1,
            salt
        );
        skip(1 hours + 30 minutes);
        hoax(bob);
        auction.revealBid(
            address(erc721),
            TOKEN_ID,
            bidValue,
            salt,
            nullProof()
        );
        assertAuctionsEqual(
            auction.getAuction(address(erc721), TOKEN_ID), 
            expectedState
        );
        assertVaultRevealed(auction.getVaultAddress(
            address(erc721),
            TOKEN_ID,
            expectedState.index,
            bob,
            bidValue,
            salt
        ));
    }

    function testCannotRevealWithInsufficientCollateral2() external {
        SneakyAuction.Auction memory expectedState = createAuction(TOKEN_ID);
        address bobVault = commitBid(
            bob,
            ONE_ETH + 1,
            ONE_ETH + 1,
            bytes32(uint256(123))
        );
        commitBid(
            charlie,
            ONE_ETH + 2,
            ONE_ETH + 1,
            bytes32(uint256(123))
        );
        skip(1 hours + 30 minutes);
        hoax(bob);
        auction.revealBid(
            address(erc721),
            TOKEN_ID,
            ONE_ETH + 1,
            bytes32(uint256(123)),
            nullProof()
        );
        expectedState.highestBid = ONE_ETH + 1;
        expectedState.highestBidVault = bobVault;
        expectedState.collateralizationDeadlineBlockHash = blockhash(block.number - 1);
        hoax(charlie);
        auction.revealBid(
            address(erc721),
            TOKEN_ID,
            ONE_ETH + 2,
            bytes32(uint256(123)),
            nullProof()
        );
        assertAuctionsEqual(
            auction.getAuction(address(erc721), TOKEN_ID), 
            expectedState
        );
        assertVaultRevealed(auction.getVaultAddress(
            address(erc721),
            TOKEN_ID,
            expectedState.index,
            charlie,
            ONE_ETH + 2,
            bytes32(uint256(123))
        ));
    }

    function testUpdateHighestBidder() external {
        SneakyAuction.Auction memory expectedState = createAuction(TOKEN_ID);
        address bobVault = commitBid(
            bob,
            ONE_ETH + 1,
            ONE_ETH + 1,
            bytes32(uint256(123))
        );
        address charlieVault = commitBid(
            charlie,
            ONE_ETH + 2,
            ONE_ETH + 2,
            bytes32(uint256(123))
        );
        skip(1 hours + 30 minutes);
        hoax(bob);
        auction.revealBid(
            address(erc721),
            TOKEN_ID,
            ONE_ETH + 1,
            bytes32(uint256(123)),
            nullProof()
        );
        expectedState.highestBid = ONE_ETH + 1;
        expectedState.highestBidVault = bobVault;
        expectedState.collateralizationDeadlineBlockHash = blockhash(block.number - 1);
        assertAuctionsEqual(
            auction.getAuction(address(erc721), TOKEN_ID), 
            expectedState
        );
        hoax(charlie);
        auction.revealBid(
            address(erc721),
            TOKEN_ID,
            ONE_ETH + 2,
            bytes32(uint256(123)),
            nullProof()
        );
        expectedState.highestBid = ONE_ETH + 2;
        expectedState.highestBidVault = charlieVault;
        expectedState.secondHighestBid = ONE_ETH + 1;
        assertAuctionsEqual(
            auction.getAuction(address(erc721), TOKEN_ID), 
            expectedState
        );
        assertVaultRevealed(bobVault);
        assertVaultRevealed(charlieVault);
    }

    function testWithdrawsCollateralIfNotHighestBid() external {
        createAuction(TOKEN_ID);
        address bobVault = commitBid(
            bob,
            ONE_ETH,
            ONE_ETH,
            bytes32(uint256(123))
        );
        skip(1 hours + 30 minutes);
        hoax(bob);
        uint256 bobBalanceBefore = bob.balance;
        auction.revealBid(
            address(erc721),
            TOKEN_ID,
            ONE_ETH,
            bytes32(uint256(123)),
            nullProof()
        );
        assertEq(
            bob.balance, 
            bobBalanceBefore + 1 ether, 
            "bob's balance"
        );
        assertVaultRevealed(bobVault);
    }

    function testCannotEndAuctionBeforeEndOfReveal() external {
        createAuction(TOKEN_ID);
        commitBid(
            bob,
            ONE_ETH + 1,
            ONE_ETH + 1,
            bytes32(uint256(123))
        );
        skip(1 hours + 30 minutes);
        vm.expectRevert(RevealPeriodOngoingError.selector);
        auction.endAuction(
            address(erc721), 
            TOKEN_ID,
            bob,
            ONE_ETH + 1,
            bytes32(uint256(123))
        );
    }

    function testEndAuctionWithNoWinner() external {
        createAuction(TOKEN_ID);
        skip(2 hours + 30 minutes);
        auction.endAuction(
            address(erc721), 
            TOKEN_ID,
            address(0),
            0,
            bytes32(0)
        );
        assertEq(
            erc721.ownerOf(TOKEN_ID),
            alice,
            "owner of tokenId 1"
        );
    }

    function testEndAuctionAfterRevealPeriod() external {
        createAuction(TOKEN_ID);
        skip(30 minutes);
        address bobVault = commitBid(
            bob,
            ONE_ETH + 1,
            ONE_ETH + 1,
            bytes32(uint256(123))
        );
        commitBid(
            charlie,
            ONE_ETH + 2,
            ONE_ETH + 2,
            bytes32(uint256(123))
        );
        skip(1 hours);
        hoax(bob);
        auction.revealBid(
            address(erc721),
            TOKEN_ID,
            ONE_ETH + 1,
            bytes32(uint256(123)),
            nullProof()
        );
        skip(1 hours);
        uint256 aliceBalanceBefore = alice.balance;
        auction.endAuction(
            address(erc721), 
            TOKEN_ID,
            bob,
            ONE_ETH + 1,
            bytes32(uint256(123))
        );
        assertEq(
            alice.balance,
            aliceBalanceBefore + 1 ether,
            "alice's balance"
        );
        assertEq(
            erc721.ownerOf(TOKEN_ID),
            bob,
            "owner of tokenId 1"
        );
        assertVaultRevealed(bobVault);
    }

    function testCanWithdrawCollateralIfNotWinner() external {
        createAuction(TOKEN_ID);
        skip(30 minutes);
        address bobVault = commitBid(
            bob,
            ONE_ETH + 1,
            ONE_ETH + 1,
            bytes32(uint256(123))
        );
        address charlieVault = commitBid(
            charlie,
            ONE_ETH + 2,
            ONE_ETH + 2,
            bytes32(uint256(123))
        );
        skip(1 hours);
        hoax(bob);
        auction.revealBid(
            address(erc721),
            TOKEN_ID,
            ONE_ETH + 1,
            bytes32(uint256(123)),
            nullProof()
        );
        hoax(charlie);
        auction.revealBid(
            address(erc721),
            TOKEN_ID,
            ONE_ETH + 2,
            bytes32(uint256(123)),
            nullProof()
        );
        hoax(bob);
        uint256 bobBalanceBefore = bob.balance;
        auction.withdrawCollateral(
            address(erc721),
            TOKEN_ID,
            1,
            bytes32(uint256(123)),
            ONE_ETH + 1
        );
        assertEq(
            bob.balance,
            bobBalanceBefore + (ONE_ETH + 1) * auction.BID_BASE_UNIT(),
            "bob's balance"
        );
        assertVaultRevealed(bobVault);
        assertVaultRevealed(charlieVault);
    }

    function testCannotWithdrawCollateralWithoutRevealingBid() external {
        createAuction(TOKEN_ID);
        skip(30 minutes);
        commitBid(
            bob,
            ONE_ETH + 1,
            ONE_ETH + 1,
            bytes32(uint256(123))
        );
        commitBid(
            charlie,
            ONE_ETH + 2,
            ONE_ETH + 2,
            bytes32(uint256(123))
        );
        skip(1 hours);
        hoax(bob);
        vm.expectRevert(UnrevealedBidError.selector);
        auction.withdrawCollateral(
            address(erc721),
            TOKEN_ID,
            1,
            bytes32(uint256(123)),
            ONE_ETH + 1
        );
    }

    ////////////////////////////////////////////////////////

    function nullProof()
        private
        pure
        returns (SneakyAuction.CollateralizationProof memory proof)
    {
        return proof;
    }
    
    function createAuction(uint256 tokenId) 
        private 
        returns (SneakyAuction.Auction memory a)
    {
        hoax(alice);
        auction.createAuction(
            address(erc721), 
            tokenId,
            1 hours,
            1 hours,
            ONE_ETH
        );
        return auction.getAuction(address(erc721), tokenId);
    }

    function commitBid(
        address from,
        uint48 bidValue,
        uint48 collateral,
        bytes32 salt
    )
        private
        returns (address vault)
    {
        vault = auction.getVaultAddress(
            address(erc721),
            TOKEN_ID,
            1,
            from,
            bidValue,
            salt   
        );
        payable(vault).transfer(collateral * auction.BID_BASE_UNIT());
        auction.setBalance(collateral * auction.BID_BASE_UNIT());        
    }

    function assertVaultRevealed(address vault) private {
        assertTrue(auction.revealedVaults(vault), "revealedVaults");
    }

    function assertAuctionsEqual(
        SneakyAuction.Auction memory actualAuction,
        SneakyAuction.Auction memory expectedAuction
    ) private {
        assertEq(actualAuction.seller, expectedAuction.seller, "seller");
        assertEq(actualAuction.endOfBiddingPeriod, expectedAuction.endOfBiddingPeriod, "endOfBiddingPeriod");
        assertEq(actualAuction.endOfRevealPeriod, expectedAuction.endOfRevealPeriod, "endOfRevealPeriod");
        assertEq(actualAuction.index, expectedAuction.index, "index");
        assertEq(actualAuction.highestBid, expectedAuction.highestBid, "highestBid");
        assertEq(actualAuction.secondHighestBid, expectedAuction.secondHighestBid, "secondHighestBid");
        assertEq(actualAuction.highestBidVault, expectedAuction.highestBidVault, "highestBidVault");
        assertEq(actualAuction.collateralizationDeadlineBlockHash, expectedAuction.collateralizationDeadlineBlockHash, "collateralizationDeadlineBlockHash");
    }
}
