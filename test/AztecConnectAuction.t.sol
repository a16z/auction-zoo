// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "aztec-connect-bridges/bridges/base/ErrorLib.sol";
import "aztec-connect-bridges/test/aztec/base/BridgeTestBase.sol";
import "rollup-encoder/libraries/AztecTypes.sol";
import "../src/sealed-bid/aztec-connect-auction/AztecConnectAuction.sol";
import "../src/sealed-bid/aztec-connect-auction/IAztecConnectAuctionErrors.sol";
import "./utils/TestActors.sol";
import "./utils/TestERC721.sol";

struct AuctionState {
    bytes24 paramsHash;
    uint32 endOfBiddingPeriod;
    uint32 endOfRevealPeriod;
    address highestBidder;
    uint48 highestBid;
    uint48 secondHighestBid;
}

struct CommitmentParams {
    uint48 collateral;
    bytes32 salt;
}

contract AuctionWrapper is AztecConnectAuction {
    constructor(address _rollupProcessor)
        AztecConnectAuction(_rollupProcessor)
    {}

    function getAuction(uint64 auctionId) 
        external 
        view 
        returns (AuctionState memory auction) 
    {
        Auction storage _auction = auctions[auctionId];
        auction.paramsHash = _auction.paramsHash;
        auction.endOfBiddingPeriod = _auction.endOfBiddingPeriod;
        auction.endOfRevealPeriod = _auction.endOfRevealPeriod;
        auction.highestBidder = _auction.highestBidder;
        auction.highestBid = _auction.highestBid;
        auction.secondHighestBid = _auction.secondHighestBid;
    }

    function getPendingWithdrawal(uint64 auctionId, uint256 withdrawalId)
        external
        view
        returns (PendingWithdrawal memory withdrawal)
    {
        return auctions[auctionId].pendingWithdrawals[withdrawalId];
    }
}

contract AztecConnectAuctionTest is IAztecConnectAuctionErrors, BridgeTestBase, TestActors {
    uint256 constant BID_BASE_UNIT = 1000 gwei;
    uint48 constant ONE_ETH = uint48(1 ether / BID_BASE_UNIT);
    uint256 constant TOKEN_ID = 1;
    bytes28 private constant IN_PROGRESS = bytes28(uint224(1));

    address rollupProcessor;
    AuctionWrapper auction;
    TestERC721 erc721;

    uint256 private _virtualAssetId = 1;

    // @dev This method exists on RollupProcessor.sol. It's defined here in order to be able to receive ETH like a real
    //      rollup processor would.
    function receiveEthFromBridge(uint256 _interactionNonce) external payable {}

    function setUp() public override {
        super.setUp();

        rollupProcessor = address(this);
        auction = new AuctionWrapper(rollupProcessor);
        vm.deal(address(auction), 0);
        vm.label(address(auction), "auction contract");
        
        erc721 = new TestERC721();
        vm.label(address(erc721), "erc721 token");
        erc721.mint(alice, TOKEN_ID);
        hoax(alice);
        erc721.setApprovalForAll(address(auction), true);
    }

    function testInvalidCaller(address _callerAddress) public {
        vm.assume(_callerAddress != rollupProcessor);
        vm.prank(_callerAddress);
        vm.expectRevert(ErrorLib.InvalidCaller.selector);
        auction.convert(emptyAsset, emptyAsset, emptyAsset, emptyAsset, 0, 0, 0, address(0));
    }

    function testCannotCreateAuctionForItemThatYouDoNotOwn() external {
        vm.expectRevert("WRONG_FROM");
        createAuction(4);
    }

    function testCreateAuction() external {
        AuctionState memory expectedAuction = AuctionState({
            paramsHash: _paramsHash(),
            endOfBiddingPeriod: uint32(block.timestamp + 1 hours),
            endOfRevealPeriod: uint32(block.timestamp + 2 hours),
            highestBidder: address(0),
            highestBid: ONE_ETH,
            secondHighestBid: ONE_ETH
        });
        AuctionState memory actualAuction = createAuction(TOKEN_ID);
        assertAuctionsEqual(actualAuction, expectedAuction);
    }

    function testCommitment() external {
        uint64 auctionId = auction.nextAuctionId();
        createAuction(TOKEN_ID);

        CommitmentParams[] memory commits = new CommitmentParams[](1);
        commits[0] = CommitmentParams({collateral: ONE_ETH, salt: bytes32(uint256(1234))});
        bid(
            auctionId, 
            bob, 
            5 * ONE_ETH, 
            commits
        );
    }

    function testCannotCommitWithoutCollateral() external {
        uint64 auctionId = auction.nextAuctionId();
        createAuction(TOKEN_ID);

        bytes28 commitment = _commitment(
            auctionId, 
            bob,
            5 * ONE_ETH,
            bytes32(uint256(1234))
        );
        vm.expectRevert(abi.encodeWithSelector(
            UnexpectedCommitmentHash.selector,
            IN_PROGRESS,
            bytes32(0)
        ));
        auction.convert(
            _virtualAsset(1337),          // inputAssetA
            emptyAsset,                   // inputAssetB
            _virtualAsset(0),             // outputAssetA
            emptyAsset,                   // outputAssetB
            uint256(uint224(commitment)), // inputValue
            0,                            // interactionNonce
            ONE_ETH,                      // auxData 
            address(0)                    // rollupBeneficiary
        );
    }

    function testCannotOverwriteExistingCommitment() external {
        uint64 auctionId = auction.nextAuctionId();
        createAuction(TOKEN_ID);

        CommitmentParams[] memory commits = new CommitmentParams[](1);
        commits[0] = CommitmentParams({collateral: ONE_ETH, salt: bytes32(uint256(1234))});
        AztecConnectAuction.BidOpening[] memory openings = bid(
            auctionId, 
            bob, 
            5 * ONE_ETH, 
            commits
        );
        bytes28 commitment = _commitment(
            auctionId, 
            bob,
            5 * ONE_ETH,
            bytes32(uint256(1234))
        );
        vm.expectRevert(abi.encodeWithSelector(
            UnexpectedCommitmentHash.selector,
            IN_PROGRESS,
            commitment
        ));
        auction.convert(
            _virtualAsset(openings[0].virtualAssetId),
            emptyAsset,
            _virtualAsset(0),
            emptyAsset,
            uint256(uint224(commitment)),
            0,
            ONE_ETH,
            address(0)
        );
    }

    function testRevealBid() external {
        uint64 auctionId = auction.nextAuctionId();
        createAuction(TOKEN_ID);

        CommitmentParams[] memory commits = new CommitmentParams[](4);
        commits[0] = CommitmentParams({collateral: ONE_ETH, salt: bytes32(uint256(1))});
        commits[1] = CommitmentParams({collateral: ONE_ETH, salt: bytes32(uint256(2))});
        commits[2] = CommitmentParams({collateral: ONE_ETH, salt: bytes32(uint256(3))});
        commits[3] = CommitmentParams({collateral: ONE_ETH, salt: bytes32(uint256(4))});
        uint48 bidValue = 4 * ONE_ETH;
        AztecConnectAuction.BidOpening[] memory openings = bid(
            auctionId, 
            bob,
            bidValue,
            commits
        );
        skip(1 hours + 30 minutes);
        reveal(auctionId, bob, bidValue, openings, true);
    }

    function testRevealBid2() external {
        uint64 auctionId = auction.nextAuctionId();
        createAuction(TOKEN_ID);

        CommitmentParams[] memory bobCommits = new CommitmentParams[](2);
        bobCommits[0] = CommitmentParams({collateral: ONE_ETH, salt: bytes32(uint256(1))});
        bobCommits[1] = CommitmentParams({collateral: 3 * ONE_ETH, salt: bytes32(uint256(2))});
        uint48 bobBidValue = 4 * ONE_ETH;
        AztecConnectAuction.BidOpening[] memory bobOpenings = bid(
            auctionId, 
            bob,
            bobBidValue,
            bobCommits
        );

        CommitmentParams[] memory charlieCommits = new CommitmentParams[](2);
        charlieCommits[0] = CommitmentParams({collateral: 2 * ONE_ETH, salt: bytes32(uint256(3))});
        charlieCommits[1] = CommitmentParams({collateral: 3 * ONE_ETH, salt: bytes32(uint256(4))});
        uint48 charlieBidValue = 5 * ONE_ETH;
        AztecConnectAuction.BidOpening[] memory charlieOpenings = bid(
            auctionId, 
            charlie,
            charlieBidValue,
            charlieCommits
        );
        skip(1 hours + 30 minutes);
        reveal(auctionId, bob, bobBidValue, bobOpenings, true);
        reveal(auctionId, charlie, charlieBidValue, charlieOpenings, true);
    }

    function testEndAuction() external {
        uint64 auctionId = auction.nextAuctionId();
        createAuction(TOKEN_ID);

        CommitmentParams[] memory bobCommits = new CommitmentParams[](2);
        bobCommits[0] = CommitmentParams({collateral: ONE_ETH, salt: bytes32(uint256(1))});
        bobCommits[1] = CommitmentParams({collateral: 3 * ONE_ETH, salt: bytes32(uint256(2))});
        uint48 bobBidValue = 4 * ONE_ETH;
        AztecConnectAuction.BidOpening[] memory bobOpenings = bid(
            auctionId, 
            bob,
            bobBidValue,
            bobCommits
        );

        CommitmentParams[] memory charlieCommits = new CommitmentParams[](2);
        charlieCommits[0] = CommitmentParams({collateral: 2 * ONE_ETH, salt: bytes32(uint256(3))});
        charlieCommits[1] = CommitmentParams({collateral: 3 * ONE_ETH, salt: bytes32(uint256(4))});
        uint48 charlieBidValue = 5 * ONE_ETH;
        AztecConnectAuction.BidOpening[] memory charlieOpenings = bid(
            auctionId, 
            charlie,
            charlieBidValue,
            charlieCommits
        );
        skip(1 hours + 30 minutes);
        reveal(auctionId, bob, bobBidValue, bobOpenings, true);
        reveal(auctionId, charlie, charlieBidValue, charlieOpenings, true);

        skip(1 hours);
        uint256 aliceBalanceBefore = alice.balance;
        auction.endAuction(
            auctionId,
            alice,
            address(erc721), 
            TOKEN_ID, 
            charlieOpenings[0].virtualAssetId
        );
        uint256 aliceBalanceAfter = alice.balance;
        assertEq(aliceBalanceAfter - aliceBalanceBefore, bobBidValue * BID_BASE_UNIT, "seller revenue");
        assertEq(erc721.ownerOf(TOKEN_ID), charlie, "winner receives token");
        assertEq(auction.getAuction(auctionId).paramsHash, bytes24(0), "paramsHash cleared");

        AztecConnectAuction.PendingWithdrawal memory withdrawal = auction.getPendingWithdrawal(
            auctionId, 
            charlieOpenings[0].virtualAssetId
        );
        assertEq(
            withdrawal.amount, 
            (charlieBidValue - bobBidValue) * BID_BASE_UNIT, 
            "withdrawal.amount"
        );
        assertEq(withdrawal.l1Address, charlie, "withdrawal.l1Address");
    }

    function testWithdrawCollateral() external {
        uint64 auctionId = auction.nextAuctionId();
        createAuction(TOKEN_ID);

        CommitmentParams[] memory bobCommits = new CommitmentParams[](2);
        bobCommits[0] = CommitmentParams({collateral: ONE_ETH, salt: bytes32(uint256(1))});
        bobCommits[1] = CommitmentParams({collateral: 3 * ONE_ETH, salt: bytes32(uint256(2))});
        uint48 bobBidValue = 4 * ONE_ETH;
        AztecConnectAuction.BidOpening[] memory bobOpenings = bid(
            auctionId, 
            bob,
            bobBidValue,
            bobCommits
        );

        CommitmentParams[] memory charlieCommits = new CommitmentParams[](2);
        charlieCommits[0] = CommitmentParams({collateral: 2 * ONE_ETH, salt: bytes32(uint256(3))});
        charlieCommits[1] = CommitmentParams({collateral: 3 * ONE_ETH, salt: bytes32(uint256(4))});
        uint48 charlieBidValue = 5 * ONE_ETH;
        AztecConnectAuction.BidOpening[] memory charlieOpenings = bid(
            auctionId, 
            charlie,
            charlieBidValue,
            charlieCommits
        );
        skip(1 hours + 30 minutes);
        reveal(auctionId, bob, bobBidValue, bobOpenings, true);
        reveal(auctionId, charlie, charlieBidValue, charlieOpenings, true);

        skip(1 hours);
        auction.endAuction(
            auctionId,
            alice,
            address(erc721), 
            TOKEN_ID, 
            charlieOpenings[0].virtualAssetId
        );

        l1Withdraw(
            auctionId, 
            bob, 
            bobOpenings[0].virtualAssetId, 
            bobBidValue * BID_BASE_UNIT
        );
        l2Withdraw(
            auctionId,
            charlieOpenings[0].virtualAssetId,
            (charlieBidValue - bobBidValue) * BID_BASE_UNIT
        );
    }

    ////////////////////////////////////////////////////////

    function createAuction(uint256 tokenId) 
        private 
        returns (AuctionState memory a)
    {
        hoax(alice);
        auction.createAuction(
            address(erc721), 
            tokenId,
            1 hours,
            1 hours,
            ONE_ETH
        );
        uint64 auctionId = auction.nextAuctionId() - 1;
        return auction.getAuction(auctionId);
    }

    function bid(
        uint64 auctionId,
        address bidder,
        uint48 bidValue,
        CommitmentParams[] memory pieces
    )
        private
        returns (AztecConnectAuction.BidOpening[] memory openings)
    {
        openings = new AztecConnectAuction.BidOpening[](pieces.length);

        for (uint256 i = 0; i < pieces.length; i++) {
            uint256 inputValue = pieces[i].collateral * BID_BASE_UNIT;
            AztecTypes.AztecAsset memory virtualAsset = _virtualAsset(_virtualAssetId++);
            (uint256 outputValueA, ,) = auction.convert{value: inputValue}(
                _ethAsset(),          // inputAssetA
                emptyAsset,           // inputAssetB
                virtualAsset,         // outputAssetA
                emptyAsset,           // outputAssetB
                inputValue,           // inputValue
                0,                    // interactionNonce
                pieces[i].collateral, // auxData 
                address(0)            // rollupBeneficiary
            );
            assertEq(outputValueA, type(uint256).max, "outputValueA");
            (bytes28 commitmentHash, ) = auction.commitments(
                virtualAsset.id, 
                pieces[i].collateral
            );
            assertEq(commitmentHash, IN_PROGRESS, "commitment.hash");

            // Step 2
            bytes28 commitment = _commitment(
                auctionId, 
                bidder,
                bidValue,
                pieces[i].salt
            );
            auction.convert(
                virtualAsset,                 // inputAssetA
                emptyAsset,                   // inputAssetB
                _virtualAsset(0),             // outputAssetA
                emptyAsset,                   // outputAssetB
                uint256(uint224(commitment)), // inputValue
                0,                            // interactionNonce
                pieces[i].collateral,         // auxData 
                address(0)                    // rollupBeneficiary
            );
            (commitmentHash, ) = auction.commitments(
                virtualAsset.id, 
                pieces[i].collateral
            );
            assertEq(commitmentHash, commitment, "commitment.hash");            
            openings[i] = AztecConnectAuction.BidOpening({
                virtualAssetId: virtualAsset.id,
                collateral: pieces[i].collateral,
                salt: pieces[i].salt
            });
        }
    }

    function reveal(
        uint64 auctionId,
        address bidder,
        uint48 bidValue,
        AztecConnectAuction.BidOpening[] memory openings,
        bool withdrawImmediatelyIfPossible
    )
        private
    {
        AuctionState memory expectedState = auction.getAuction(auctionId);
        uint256 bidderBalanceBefore = bidder.balance;
        vm.prank(bidder);
        auction.revealBid(auctionId, bidValue, openings, withdrawImmediatelyIfPossible);
        uint256 bidderBalanceAfter = bidder.balance;
        for (uint256 i = 0; i < openings.length; i++) {
            (bytes28 commitmentHash, uint32 timestamp) = auction.commitments(
                openings[i].virtualAssetId, 
                openings[i].collateral
            );
            assertEq(commitmentHash, bytes28(0), "commitment.hash");
            assertEq(timestamp, 0, "commitment.timestamp");
        }
        if (bidValue > expectedState.highestBid) {
            expectedState.highestBidder = bidder;
            expectedState.secondHighestBid = expectedState.highestBid;
            expectedState.highestBid = bidValue;
        } else {
            assertEq(bidderBalanceAfter - bidderBalanceBefore, bidValue, "collateral withdrawn");
            if (bidValue > expectedState.secondHighestBid) {
                expectedState.secondHighestBid = bidValue;
            }
        }
        assertAuctionsEqual(auction.getAuction(auctionId), expectedState);
        AztecConnectAuction.PendingWithdrawal memory withdrawal = auction.getPendingWithdrawal(
            auctionId, 
            openings[0].virtualAssetId
        );
        assertEq(withdrawal.amount, bidValue * BID_BASE_UNIT, "withdrawal.amount");
        assertEq(withdrawal.l1Address, bidder, "withdrawal.l1Address");
    }

    function l1Withdraw(
        uint64 auctionId,
        address bidder,
        uint256 withdrawalId,
        uint256 expectedAmount
    )
        private
    {
        uint256 balanceBefore = bidder.balance;
        vm.prank(bidder);
        auction.withdrawCollateral(auctionId, withdrawalId);
        uint256 balanceAfter = bidder.balance;        
        assertEq(
            balanceAfter - balanceBefore, 
            expectedAmount, 
            "l1 withdrawal"
        );
        AztecConnectAuction.PendingWithdrawal memory withdrawal = auction.getPendingWithdrawal(
            auctionId, 
            withdrawalId
        );
        assertEq(withdrawal.amount, 0, "withdrawal.amount cleared");
        assertEq(withdrawal.l1Address, address(0), "withdrawal.l1Address cleared");
    }

    function l2Withdraw(
        uint64 auctionId,
        uint256 withdrawalId,
        uint256 expectedAmount
    )
        private
    {
        uint256 rollupProcessBalanceBefore = address(this).balance;
        auction.convert(
            _virtualAsset(withdrawalId),
            emptyAsset,
            _ethAsset(),
            emptyAsset,
            1,
            0,
            auctionId,
            address(0)
        );
        uint256 rollupProcessBalanceAfter = address(this).balance;
        assertEq(
            rollupProcessBalanceAfter - rollupProcessBalanceBefore, 
            expectedAmount, 
            "l2 withdrawal"
        );
        AztecConnectAuction.PendingWithdrawal memory withdrawal = auction.getPendingWithdrawal(
            auctionId, 
            withdrawalId
        );
        assertEq(withdrawal.amount, 0, "withdrawal.amount cleared");
        assertEq(withdrawal.l1Address, address(0), "withdrawal.l1Address cleared");
    }

    function assertAuctionsEqual(
        AuctionState memory actualAuction, 
        AuctionState memory expectedAuction
    ) private {
        assertEq(actualAuction.paramsHash, expectedAuction.paramsHash, "paramsHash");
        assertEq(actualAuction.endOfBiddingPeriod, expectedAuction.endOfBiddingPeriod, "endOfBiddingPeriod");
        assertEq(actualAuction.endOfRevealPeriod, expectedAuction.endOfRevealPeriod, "endOfRevealPeriod");
        assertEq(actualAuction.highestBidder, expectedAuction.highestBidder, "highestBidder");
        assertEq(actualAuction.highestBid, expectedAuction.highestBid, "highestBid");
        assertEq(actualAuction.secondHighestBid, expectedAuction.secondHighestBid, "secondHighestBid");
    }

    function _paramsHash()
        private
        view
        returns (bytes24)
    {
        return bytes24(keccak256(abi.encode(
            auction.nextAuctionId(),
            alice,
            address(erc721),
            TOKEN_ID
        )));        
    }

    function _ethAsset()
        private
        pure
        returns (AztecTypes.AztecAsset memory)
    {
        return AztecTypes.AztecAsset({
            id: 0, 
            erc20Address: address(0),
            assetType: AztecTypes.AztecAssetType.ETH
        });
    }

    function _virtualAsset(uint256 assetId)
        private
        pure
        returns (AztecTypes.AztecAsset memory)
    {
        return AztecTypes.AztecAsset({
            id: assetId,
            erc20Address: address(0),
            assetType: AztecTypes.AztecAssetType.VIRTUAL
        });
    }

    function _commitment(
        uint64 auctionId,
        address bidder,
        uint48 bidValue,
        bytes32 salt
    )
        private
        pure
        returns (bytes28)
    {
        return bytes28(keccak256(abi.encode(
            auctionId,
            bidder,
            bidValue,
            salt
        )));
    }
}