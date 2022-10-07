# The Auction Zoo

Whereas auction formats were once loosely adopted for (and constrained by) the technical limits of blockchains, we’re now starting to see more novel designs adapted especially for blockchains. 
This repository aims to help bridge the gap between auction theory and practice by showcasing Solidity auction implementations that demonstrate interesting theoretical properties or novel constructions.

How can theoretical principles inform implementation decisions? 
And how can on-chain implementations, in turn, inform new directions of theoretical research? Though theory can guide us toward a certain auction design, a seemingly innocuous implementation detail itself may be interesting to analyze with a theoretical lens. 

The auctions are implemented as single-item (ERC721) auctions, with bids denominated in ETH, though we encourage forking to add or change features, e.g. multi-unit auctions, ERC20 bids, different payment rules.

## Contents 
- Sealed-bid auctions
  - [Overcollateralized Vickrey auction](./src/sealed-bid/over-collateralized-auction/OverCollateralizedAuction.sol) [[post](https://a16zcrypto.com/how-auction-theory-informs-implementations/)]

## Accompanying blog posts
1. [On Paper to On-Chain: How Auction Theory Informs Implementations
](https://a16zcrypto.com/how-auction-theory-informs-implementations/)

## Usage

Requires [Foundry](https://book.getfoundry.sh/getting-started/installation).

Install: `forge install`

Build: `forge build`

Test: `forge test`

## Disclaimer

_These smart contracts are being provided as is. No guarantee, representation or warranty is being made, express or implied, as to the safety or correctness of the user interface or the smart contracts. They have not been audited and as such there can be no assurance they will work as intended, and users may experience delays, failures, errors, omissions or loss of transmitted information. THE SMART CONTRACTS CONTAINED HEREIN ARE FURNISHED AS IS, WHERE IS, WITH ALL FAULTS AND WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF MERCHANTABILITY, NON- INFRINGEMENT OR FITNESS FOR ANY PARTICULAR PURPOSE. Further, use of any of these smart contracts may be restricted or prohibited under applicable law, including securities laws, and it is therefore strongly advised for you to contact a reputable attorney in any jurisdiction where these smart contracts may be accessible for any questions or concerns with respect thereto. Further, no information provided in this repo should be construed as investment advice or legal advice for any particular facts or circumstances, and is not meant to replace competent counsel. a16z is not liable for any use of the foregoing, and users should proceed with caution and use at their own risk. See a16z.com/disclosures for more info._
