const { BlockHeader } = require('@ethereumjs/block');
const Web3 = require('web3');


async function getBalanceProofAsync(web3, address, blockNumber) {
    const proof = await web3.eth.getProof(address, [], blockNumber);
    console.log(proof.accountProof);
}

async function getBlockHeaderAsync(web3, blockNumber) {
    const block = await web3.eth.getBlock(blockNumber);
    const {
        parentHash,
        sha3Uncles,
        miner,
        stateRoot,
        transactionsRoot,
        receiptsRoot,
        logsBloom,
        difficulty,
        number,
        gasLimit,
        gasUsed,
        timestamp,
        extraData,
        mixHash,
        nonce,
        baseFeePerGas,
    } = block;
    const header = BlockHeader.fromHeaderData(
        {
            parentHash,
            uncleHash: sha3Uncles,
            coinbase: miner,
            stateRoot,
            transactionsTrie: transactionsRoot,
            receiptTrie: receiptsRoot,
            logsBloom,
            difficulty: '0x' + BigInt(difficulty).toString(16),
            number,
            gasLimit,
            gasUsed,
            timestamp,
            extraData,
            mixHash,
            nonce,
            baseFeePerGas,
        }, 
        { hardforkByBlockNumber: true }
    );
    const serialized = header.serialize().toString('hex');
    console.log({ blockHeaderRLP: serialized, blockNumber: block.number, blockHash: block.hash });
}

(async () => {
    const { RPC, ADDRESS, BLOCK } = process.env;
    const web3 = new Web3(RPC);
    const blockNumber = BLOCK || (await web3.eth.getBlockNumber() - 10);
    await getBalanceProofAsync(web3, ADDRESS, blockNumber);
    await getBlockHeaderAsync(web3, blockNumber);
})();