/*******************************************************************************

    Contains validation routines for blocks

    Copyright:
        Copyright (c) 2019-2020 BOS Platform Foundation Korea
        All rights reserved.

    License:
        MIT License. See LICENSE for details.

*******************************************************************************/

module agora.consensus.validation.Block;

import agora.common.Amount;
import agora.common.Hash;
import agora.common.Set;
import agora.common.Types;
import agora.consensus.data.Block;
import agora.consensus.data.Enrollment;
import agora.consensus.data.Transaction;
import agora.consensus.data.UTXOSetValue;
import VEn = agora.consensus.validation.Enrollment;
import VTx = agora.consensus.validation.Transaction;

import std.algorithm;

version (unittest)
{
    import agora.common.crypto.ECC;
    import agora.common.crypto.Key;
    import agora.common.crypto.Schnorr;
    import agora.consensus.data.genesis.Test;
    import agora.utils.Test;
}

/*******************************************************************************

    Check the validity of a block.

    A block is considered valid if:
        - its height is the previous block height + 1
        - its prev_hash is the previous block header's hash
        - the number of transactions in the block are equal to Block.TxsInBlock
        - the merkle root in the header matches the re-built merkle tree root
          based on the included transactions in the block
        - Transactions are ordered by their hash value
        - all the transactions pass validation, which implies:
            - signatures are authentic
            - the inputs spend an output which must be found with the
              findUTXO() delegate

    Note that checking for transactions which double-spend is the responsibility
    of the findUTXO() delegate. During validation, whenever this delegate is
    called it should also keep track of the used UTXOs, thereby marking
    it as a spent output. See the `findNonSpent` function in the
    unittest for an example.

    As a special case, the genesis block is rejected by this function.
    Validation of a genesis block should be done through the
    `isGenesisBlockInvalidReason` function.

    Params:
        block = the block to check
        prev_height = the height of the direct ancestor of this block
        prev_hash = the hash of the direct ancestor of this block
        findUTXO = delegate to find the referenced unspent UTXOs with
        active_enrollments = the number of enrollments that do not expire
            at the next block height (prev_height + 1).

    Returns:
        `null` if the block is valid, a string explaining the reason it
        is invalid otherwise.

*******************************************************************************/

public string isInvalidReason (const ref Block block, Height prev_height,
    in Hash prev_hash, UTXOFinder findUTXO,
    size_t active_enrollments) nothrow @safe
{
    import std.algorithm;

    if (block.header.height > prev_height + 1)
        return "Block: Height is above expected height";
    if (block.header.height < prev_height + 1)
        return "Block: Height is under expected height";

    if (block.header.prev_block != prev_hash)
        return "Block: Header.prev_block does not match previous block";

    if (block.txs.length != Block.TxsInBlock)
        return "Block: Number of transaction mismatch";

    if (!block.txs.isSorted())
        return "Block: Transactions are not sorted";

    foreach (const ref tx; block.txs)
    {
        if (auto fail_reason = VTx.isInvalidReason(tx, findUTXO, block.header.height))
            return fail_reason;
    }

    Hash[] merkle_tree;
    if (block.header.merkle_root != Block.buildMerkleTree(block.txs, merkle_tree))
        return "Block: Merkle root does not match header's";

    if (!isStrictlyMonotonic!"a.utxo_key < b.utxo_key"(block.header.enrollments))
        return "Block: The enrollments are not sorted in ascending order";

    if (block.header.enrollments.length + active_enrollments < Enrollment.MinValidatorCount)
            return "Enrollment: Insufficient number of active validators";

    /// FIXME: Use a proper type and sensible memory allocation pattern
    version (all)
    {
        scope extraSet = new TestUTXOSet();
        foreach (const ref tx; block.txs)
            extraSet.put(tx);
        scope extraFinder = extraSet.getUTXOFinder();
        scope UTXOFinder enrollmentsUTXOFinder =
            (Hash hash, size_t index, out UTXOSetValue val)
            {
                if (findUTXO(hash, index, val))
                    return true;
                return extraFinder(hash, index, val);
            };
    }

    foreach (const ref enrollment; block.header.enrollments)
    {
        if (auto fail_reason = VEn.isInvalidReason(enrollment, enrollmentsUTXOFinder))
            return fail_reason;
    }

    return null;
}

/*******************************************************************************

    Check the validity of a genesis block

    Follow the same rules as for `Block` except for the following:
        - Block height must be 0
        - The previous block hash of the block must be empty
        - The number of transactions in the block must be in the range `(0;
          Block.TxsInBlock]`.
        - Transactions must have no input
        - Transactions must have at least one output
        - All the enrollments pass validation, which implies:
            - The enrollments refer to freeze tx's in this block
            - The signature for the Enrollment is valid

    Params:
        block = The genesis block to check

    Returns:
        `null` if the genesis block is valid, otherwise a string explaining
        the reason it is invalid.

*******************************************************************************/

public string isGenesisBlockInvalidReason (const ref Block block) nothrow @safe
{
    if (block.header.height != 0)
        return "GenesisBlock: The height of the block is not 0";

    if (block.header.prev_block != Hash.init)
        return "GenesisBlock: Header.prev_block is not empty";

    if (block.txs.length == 0)
        return "GenesisBlock: Transaction(s) are empty";

    if (block.txs.length > Block.TxsInBlock)
        return "GenesisBlock: The number of transactions is out of bounds";

    if (!block.txs.isSorted())
        return "GenesisBlock: Transactions are not sorted";

    UTXOSetValue[Hash] utxo_set;
    foreach (const ref tx; block.txs)
    {
        if (!(tx.type == TxType.Payment || tx.type == TxType.Freeze))
            return "GenesisBlock: Invalid enum value for type field";

        if (tx.inputs.length != 0)
             return "GenesisBlock: Transactions must not have input";

        if (tx.outputs.length == 0)
            return "GenesisBlock: No output(s) in the transaction";

        Hash tx_hash = tx.hashFull();
        foreach (idx, const ref output; tx.outputs)
        {
            // disallow negative amounts
            if (!output.value.isValid())
                return "GenesisBlock: Output(s) overflow or underflow"
                    ~ "in the transaction";

            // disallow 0 amount
            if (output.value == Amount(0))
                return "GenesisBlock: Value of output is 0"
                    ~ "in the transaction";

            const UTXOSetValue utxo_value = {
                unlock_height: 0,
                type: tx.type,
                output: output
            };
            utxo_set[UTXOSetValue.getHash(tx_hash, idx)] = utxo_value;
        }
    }

    Hash[] merkle_tree;
    if (block.header.merkle_root !=
        Block.buildMerkleTree(block.txs, merkle_tree))
        return "GenesisBlock: Merkle root does not match header's";

    // If there are no enrollments, return them here early.
    if (block.header.enrollments.length == 0)
        return null;

    if (!isStrictlyMonotonic!"a.utxo_key < b.utxo_key"
        (block.header.enrollments))
        return "GenesisBlock: The enrollments should be arranged in "
            ~ "ascending order by the utxo_key";

    Set!Hash used_utxos;
    bool findUTXO (Hash utxo_hash, size_t index, out UTXOSetValue value)
        nothrow @safe
    {
        if (utxo_hash in used_utxos)
            return false;  // double-spend

        if (auto ptr = utxo_hash in utxo_set)
        {
            value = *ptr;
            used_utxos.put(utxo_hash);
            return true;
        }
        return false;
    }

    foreach (const ref enrollment; block.header.enrollments)
    {
        if (auto fail_reason = VEn.isInvalidReason(enrollment, &findUTXO))
            return fail_reason;
    }

    return null;
}

/// Genesis block validation fail test
unittest
{
    import agora.common.Serializer;

    Block block = GenesisBlock.serializeFull.deserializeFull!Block;
    assert(block.isGenesisBlockValid());

    // don't accept block height 0 from the network
    assert(!block.isValid(Height(0), Hash.init, null, Enrollment.MinValidatorCount));

    // height check
    block.header.height = 1;
    assert(!block.isGenesisBlockValid());

    block.header.height = 0;
    assert(block.isGenesisBlockValid());

    // .prev_block check
    block.header.prev_block = block.header.hashFull();
    assert(!block.isGenesisBlockValid());

    block.header.prev_block = Hash.init;
    assert(block.isGenesisBlockValid());

    Transaction[] txs =
        GenesisBlock.txs.serializeFull.deserializeFull!(Transaction[]);

    void checkValidity (const ref Block block)
    {
        auto reason = block.isGenesisBlockInvalidReason();
        assert(reason is null, reason);
    }

    void buildMerkleTree (ref Block block, bool shouldSort = true)
    {
        Hash[] merkle_tree;
        if (shouldSort) block.txs.sort;
        block.header.merkle_root =
            Block.buildMerkleTree(block.txs, merkle_tree);
    }

    Transaction makeNewTx ()
    {
        Transaction new_tx =
        {
            TxType.Payment,
            inputs: [],
            outputs: [Output(Amount(100), KeyPair.random().address)]
        };
        return new_tx;
    }

    // Check consistency of `txs` field
    {
        // Txs length check
        block.txs = null;
        block.header.enrollments = null;
        assert(!block.isGenesisBlockValid());

        foreach (_; 0 .. Block.TxsInBlock)
            block.txs ~= makeNewTx();
        assert(block.txs.length == Block.TxsInBlock);
        buildMerkleTree(block);
        checkValidity(block);

        // Txs sorting check
        block.txs.reverse;
        buildMerkleTree(block, false);
        assert(!block.isGenesisBlockValid());

        block.txs.reverse;
        buildMerkleTree(block, false);
        checkValidity(block);

        // Txs length out of bounds check
        block.txs ~= makeNewTx();
        buildMerkleTree(block);
        assert(block.txs.length == Block.TxsInBlock + 1);
        assert(!block.isGenesisBlockValid());

        block = GenesisBlock.serializeFull.deserializeFull!Block;

        // Txs type check
        auto pre_type_change_txs = block.txs.dup;
        block.txs[0].type = cast(TxType)2;
        buildMerkleTree(block);
        assert(block.isGenesisBlockInvalidReason()
               .canFind("Invalid enum value"));

        block.txs = pre_type_change_txs;
        buildMerkleTree(block);
        checkValidity(block);

        assert(block.txs.any!(tx => tx.type == TxType.Payment));
        assert(block.txs.any!(tx => tx.type == TxType.Freeze));

        // Input empty check
        block.txs[0].inputs ~= Input.init;
        buildMerkleTree(block);
        assert(!block.isGenesisBlockValid());

        block.txs = txs;
        buildMerkleTree(block);
        checkValidity(block);

        // Output not empty check
        block.txs[0].outputs = null;
        buildMerkleTree(block);
        assert(!block.isGenesisBlockValid());

        // disallow 0 amount
        Output zeroOutput =
            Output(Amount.invalid(0), WK.Keys[0].address);
        block.txs[0].outputs ~= zeroOutput;
        buildMerkleTree(block);
        assert(!block.isGenesisBlockValid());
    }

    block = GenesisBlock.serializeFull.deserializeFull!Block;

    // enrollments validation test
    Enrollment[] enrolls;
    enrolls ~= Enrollment.init;
    block.header.enrollments = enrolls;
    assert(!block.isGenesisBlockValid());

    block.header.enrollments.length = 0;
    checkValidity(block);

    block = GenesisBlock.serializeFull.deserializeFull!Block;

    // modify the last hex byte of the merkle root
    block.header.merkle_root[][$ - 1]++;
    assert(!block.isGenesisBlockValid());

    // now restore it back to what it was
    block.header.merkle_root[][$ - 1]--;
    checkValidity(block);
    const last_root = block.header.merkle_root;

    // the previous merkle root should not match the new txs
    block.txs ~= makeNewTx();
    block.header.merkle_root = last_root;
    assert(!block.isGenesisBlockValid());
}

/// Ditto but returns `bool`, only usable in unittests
/// Only the genesis block Validation
version (unittest)
public bool isGenesisBlockValid (const ref Block genesis_block)
    nothrow @safe
{
    return isGenesisBlockInvalidReason(genesis_block) is null;
}

/// Ditto but returns `bool`, only usable in unittests
version (unittest)
public bool isValid (const ref Block block, Height prev_height,
    Hash prev_hash, UTXOFinder findUTXO,
    size_t active_enrollments) nothrow @safe
{
    return isInvalidReason(block, prev_height, prev_hash, findUTXO,
        active_enrollments) is null;
}

///
unittest
{
    import std.algorithm;
    import std.range;

    scope utxos = new TestUTXOSet();
    scope findUTXO = &utxos.findUTXO;

    auto gen_key = WK.Keys.Genesis;
    assert(GenesisBlock.isGenesisBlockValid());
    auto gen_hash = GenesisBlock.header.hashFull();

    GenesisBlock.txs.each!(tx => utxos.put(tx));
    auto block = GenesisBlock.makeNewBlock(makeChainedTransactions(gen_key, null, 1));

    // height check
    assert(block.isValid(GenesisBlock.header.height, gen_hash, findUTXO,
        Enrollment.MinValidatorCount));

    block.header.height = 100;
    assert(!block.isValid(GenesisBlock.header.height, gen_hash, findUTXO,
        Enrollment.MinValidatorCount));

    block.header.height = GenesisBlock.header.height + 1;
    assert(block.isValid(GenesisBlock.header.height, gen_hash, findUTXO,
        Enrollment.MinValidatorCount));

    /// .prev_block check
    block.header.prev_block = block.header.hashFull();
    assert(!block.isValid(GenesisBlock.header.height, gen_hash, findUTXO,
        Enrollment.MinValidatorCount));

    block.header.prev_block = gen_hash;
    assert(block.isValid(GenesisBlock.header.height, gen_hash, findUTXO,
        Enrollment.MinValidatorCount));

    /// Check consistency of `txs` field
    {
        auto saved_txs = block.txs;

        block.txs = saved_txs[0 .. $ - 1];
        assert(!block.isValid(GenesisBlock.header.height, gen_hash, findUTXO,
            Enrollment.MinValidatorCount));

        block.txs = (saved_txs ~ saved_txs).sort.array;
        assert(!block.isValid(GenesisBlock.header.height, gen_hash, findUTXO,
            Enrollment.MinValidatorCount));

        block.txs = saved_txs;
        assert(block.isValid(GenesisBlock.header.height, gen_hash, findUTXO,
            Enrollment.MinValidatorCount));

        /// Txs sorting check
        block.txs.reverse;
        assert(!block.isValid(GenesisBlock.header.height, gen_hash, findUTXO,
            Enrollment.MinValidatorCount));

        block.txs.reverse;
        assert(block.isValid(GenesisBlock.header.height, gen_hash, findUTXO,
            Enrollment.MinValidatorCount));
    }

    /// no matching utxo => fail
    utxos.clear();
    assert(!block.isValid(GenesisBlock.header.height, gen_hash, findUTXO,
        Enrollment.MinValidatorCount));

    GenesisBlock.txs.each!(tx => utxos.put(tx));
    assert(block.isValid(GenesisBlock.header.height, gen_hash, findUTXO,
        Enrollment.MinValidatorCount));

    utxos.clear();  // genesis is spent
    auto prev_txs = block.txs;
    prev_txs.each!(tx => utxos.put(tx));  // these will be spent

    auto prev_block = block;
    block = block.makeNewBlock(makeChainedTransactions(gen_key, prev_txs, 1));
    assert(block.isValid(prev_block.header.height, prev_block.header.hashFull(),
        findUTXO, Enrollment.MinValidatorCount));

    assert(prev_txs.length > 0);  // sanity check
    foreach (tx; prev_txs)
    {
        // one utxo missing from the set => fail
        utxos.storage.remove(UTXOSetValue.getHash(tx.hashFull(), 0));
        assert(!block.isValid(prev_block.header.height, prev_block.header.hashFull(),
            findUTXO, Enrollment.MinValidatorCount));

        utxos.put(tx);
        assert(block.isValid(prev_block.header.height, prev_block.header.hashFull(),
            findUTXO, Enrollment.MinValidatorCount));
    }

    // the key is hashMulti(hash(prev_tx), index)
    Output[Hash] utxo_set;

    foreach (tx; GenesisBlock.txs)
        foreach (idx, ref output; tx.outputs)
            utxo_set[hashMulti(tx.hashFull, idx)] = output;

    assert(utxo_set.length != 0);
    const utxo_set_len = utxo_set.length;

    // contains the used set of UTXOs during validation (to prevent double-spend)
    Output[Hash] used_set;
    UTXOFinder findNonSpent = (Hash hash, size_t index, out UTXOSetValue value)
    {
        auto utxo_hash = hashMulti(hash, index);

        if (utxo_hash in used_set)
            return false;  // double-spend

        if (auto utxo = utxo_hash in utxo_set)
        {
            used_set[utxo_hash] = *utxo;
            value.unlock_height = 0;
            value.type = TxType.Payment;
            value.output = *utxo;
            return true;
        }

        return false;
    };

    // consumed all utxo => fail
    block = GenesisBlock.makeNewBlock(makeChainedTransactions(gen_key, null, 1));
    assert(block.isValid(GenesisBlock.header.height, GenesisBlock.header.hashFull(),
            findNonSpent, Enrollment.MinValidatorCount));

    // All `payment` utxos have been consumed
    assert(GenesisBlock.txs[0].type == TxType.Freeze);
    assert(used_set.length + GenesisBlock.txs[0].outputs.length == utxo_set_len);

    // reset state
    used_set.clear();

    // Double spend => fail
    auto double_spend = block.txs.dup;
    double_spend[$ - 1] = double_spend[$ - 2];
    block = makeNewBlock(GenesisBlock, double_spend);
    assert(!block.isValid(GenesisBlock.header.height, GenesisBlock.header.hashFull(),
            findNonSpent, Enrollment.MinValidatorCount));

    // we stopped validation due to a double-spend
    assert(used_set.length == double_spend.length - 1);

    block = GenesisBlock.makeNewBlock(makeChainedTransactions(gen_key, prev_txs, 1));
    assert(block.isValid(GenesisBlock.header.height, GenesisBlock.header.hashFull(),
        findUTXO, Enrollment.MinValidatorCount));

    // modify the last hex byte of the merkle root
    block.header.merkle_root[][$ - 1]++;

    assert(!block.isValid(GenesisBlock.header.height, GenesisBlock.header.hashFull(),
        findUTXO, Enrollment.MinValidatorCount));

    // now restore it back to what it was
    block.header.merkle_root[][$ - 1]--;
    assert(block.isValid(GenesisBlock.header.height, GenesisBlock.header.hashFull(),
        findUTXO, Enrollment.MinValidatorCount));
    const last_root = block.header.merkle_root;

    // txs with a different amount
    block = GenesisBlock.makeNewBlock(
        makeChainedTransactions(gen_key, prev_txs, 1, 20_000_000));
    assert(block.isValid(GenesisBlock.header.height, GenesisBlock.header.hashFull(),
        findUTXO, Enrollment.MinValidatorCount));

    // the previous merkle root should not match the new txs
    block.header.merkle_root = last_root;
    assert(!block.isValid(GenesisBlock.header.height, GenesisBlock.header.hashFull(),
        findUTXO, Enrollment.MinValidatorCount));
}

///
unittest
{
    import agora.common.Amount;
    import agora.consensus.data.Enrollment;
    import agora.consensus.data.Transaction;

    import std.algorithm;
    import std.range;

    scope utxo_set = new TestUTXOSet();
    UTXOFinder findUTXO = utxo_set.getUTXOFinder();

    auto gen_key = WK.Keys.Genesis;
    assert(GenesisBlock.isGenesisBlockValid());
    auto gen_hash = GenesisBlock.header.hashFull();
    foreach (ref tx; GenesisBlock.txs)
        utxo_set.put(tx);

    auto txs_1 = makeChainedTransactions(gen_key, null, 1,
        400_000_000_000 * Block.TxsInBlock).sort.array;

    auto block1 = makeNewBlock(GenesisBlock, txs_1);
    assert(block1.isValid(GenesisBlock.header.height, gen_hash, findUTXO,
        Enrollment.MinValidatorCount));

    foreach (ref tx; txs_1)
        utxo_set.put(tx);

    KeyPair keypair = KeyPair.random();
    Transaction[] txs_2;
    foreach (idx, pre_tx; txs_1)
    {
        Input input = Input(hashFull(pre_tx), 0);

        Transaction tx =
        {
            TxType.Freeze,
            [input],
        };
        if (idx > 3)
            tx.type = TxType.Payment;

        if (idx == 7)
        {
            foreach (_; 0 .. Block.TxsInBlock)
            {
                Output output;
                output.value = Amount(100);
                output.address = keypair.address;
                tx.outputs ~= output;
            }
        }
        else
        {
            Output output;
            output.value = Amount.MinFreezeAmount;
            output.address = keypair.address;
            tx.outputs ~= output;
        }

        tx.inputs[0].signature = gen_key.secret.sign(hashFull(tx)[]);
        txs_2 ~= tx;
    }

    auto block2 = makeNewBlock(block1, txs_2);
    assert(block2.isValid(block1.header.height, hashFull(block1.header), findUTXO,
        Enrollment.MinValidatorCount));
    foreach (ref tx; txs_2)
        utxo_set.put(tx);

    KeyPair keypair2 = KeyPair.random();
    Transaction[] txs_3;
    foreach (idx; 0 .. Block.TxsInBlock)
    {
        Input input = Input(hashFull(txs_2[7]), idx);

        Transaction tx =
        {
            TxType.Payment,
            [input],
            [Output(Amount(1), keypair2.address)]
        };
        tx.inputs[0].signature = keypair.secret.sign(hashFull(tx)[]);
        txs_3 ~= tx;
    }

    Pair signature_noise = Pair.random;
    Pair node_key_pair;
    node_key_pair.v = secretKeyToCurveScalar(keypair.secret);
    node_key_pair.V = node_key_pair.v.toPoint();

    auto utxo_hash1 = UTXOSetValue.getHash(hashFull(txs_2[0]), 0);
    Enrollment enroll1;
    enroll1.utxo_key = utxo_hash1;
    enroll1.random_seed = hashFull(Scalar.random());
    enroll1.cycle_length = 1008;
    enroll1.enroll_sig = sign(node_key_pair.v, node_key_pair.V, signature_noise.V,
        signature_noise.v, enroll1);

    auto utxo_hash2 = UTXOSetValue.getHash(hashFull(txs_2[1]), 0);
    Enrollment enroll2;
    enroll2.utxo_key = utxo_hash2;
    enroll2.random_seed = hashFull(Scalar.random());
    enroll2.cycle_length = 1008;
    enroll2.enroll_sig = sign(node_key_pair.v, node_key_pair.V, signature_noise.V,
        signature_noise.v, enroll2);

    Enrollment[] enrollments;
    enrollments ~= enroll1;
    enrollments ~= enroll2;
    enrollments.sort!("a.utxo_key < b.utxo_key");
    auto block3 = makeNewBlock(block2, txs_3, enrollments);
    assert(block3.isValid(block2.header.height, hashFull(block2.header), findUTXO,
        Enrollment.MinValidatorCount));
    enrollments.sort!("a.utxo_key > b.utxo_key");
    findUTXO = utxo_set.getUTXOFinder();
    // Block: The enrollments are not sorted in ascending order
    assert(!block3.isValid(block2.header.height, hashFull(block2.header), findUTXO,
        Enrollment.MinValidatorCount));
}

/// test that there must always exist active validators
unittest
{
    import agora.common.Amount;
    import agora.consensus.data.Enrollment;
    import agora.consensus.data.Transaction;

    import std.algorithm;
    import std.range;

    scope utxo_set = new TestUTXOSet();
    UTXOFinder findUTXO = utxo_set.getUTXOFinder();

    auto gen_key = WK.Keys.Genesis;
    assert(GenesisBlock.isGenesisBlockValid());
    auto gen_hash = GenesisBlock.header.hashFull();
    foreach (ref tx; GenesisBlock.txs)
        utxo_set.put(tx);

    auto txs_1 = makeChainedTransactions(gen_key, null, 1,
        400_000_000_000 * 10 * Block.TxsInBlock).sort.array;

    auto block1 = makeNewBlock(GenesisBlock, txs_1);
    assert(block1.isValid(GenesisBlock.header.height, gen_hash, findUTXO,
        Enrollment.MinValidatorCount));

    foreach (ref tx; txs_1)
        utxo_set.put(tx);

    KeyPair keypair = KeyPair.random();
    Transaction[] txs_2;
    foreach (idx, pre_tx; txs_1)
    {
        Transaction tx =
        {
            TxType.Freeze,
            [Input(hashFull(pre_tx), 0)],
        };

        if (idx <= 2)
        {
            tx.outputs ~= Output(Amount.MinFreezeAmount, keypair.address);
            tx.outputs ~= Output(Amount.MinFreezeAmount, keypair.address);
            tx.outputs ~= Output(Amount.MinFreezeAmount, keypair.address);
        }
        else
        {
            tx.type = TxType.Payment;
            foreach (_; 0 .. Block.TxsInBlock)
                tx.outputs ~= Output(Amount(100), keypair.address);
        }

        tx.inputs[0].signature = gen_key.secret.sign(hashFull(tx)[]);
        txs_2 ~= tx;
    }

    auto block2 = makeNewBlock(block1, txs_2);
    assert(block2.isValid(block1.header.height, hashFull(block1.header), findUTXO,
        Enrollment.MinValidatorCount));
    foreach (ref tx; txs_2)
        utxo_set.put(tx);

    // When all existing validators expire at the new block height and the number of enrollments
    // in the new block is 0, the block is considered invalid.
    {
        KeyPair keypair2 = KeyPair.random();
        Transaction[] txs_3;
        foreach (idx; 0 .. Block.TxsInBlock)
        {
            Transaction tx =
            {
                TxType.Payment,
                [Input(hashFull(txs_2[$-4]), idx)],
                [Output(Amount(1), keypair2.address)]
            };
            tx.inputs[0].signature = keypair.secret.sign(hashFull(tx)[]);
            txs_3 ~= tx;
        }

        Pair signature_noise = Pair.random;
        Pair node_key_pair;
        node_key_pair.v = secretKeyToCurveScalar(keypair.secret);
        node_key_pair.V = node_key_pair.v.toPoint();

        auto block3 = makeNewBlock(block2, txs_3);
        assert(block3.header.enrollments.length == 0);
        assert(!block3.isValid(block2.header.height, hashFull(block2.header), findUTXO, 0));
    }

    // When all existing validators expire at the new block height but the number of enrollments
    // in the new block is at least 1, the block may be considered valid.
    {
        KeyPair keypair2 = KeyPair.random();
        Transaction[] txs_3;
        foreach (idx; 0 .. Block.TxsInBlock)
        {
            Transaction tx =
            {
                TxType.Payment,
                [Input(hashFull(txs_2[$-3]), idx)],
                [Output(Amount(1), keypair2.address)]
            };
            tx.inputs[0].signature = keypair.secret.sign(hashFull(tx)[]);
            txs_3 ~= tx;
        }

        Pair signature_noise = Pair.random;
        Pair node_key_pair;
        node_key_pair.v = secretKeyToCurveScalar(keypair.secret);
        node_key_pair.V = node_key_pair.v.toPoint();

        auto utxo_hash1 = UTXOSetValue.getHash(hashFull(txs_2[1]), 0);
        Enrollment enroll1;
        enroll1.utxo_key = utxo_hash1;
        enroll1.random_seed = hashFull(Scalar.random());
        enroll1.cycle_length = 1008;
        enroll1.enroll_sig = sign(node_key_pair.v, node_key_pair.V, signature_noise.V,
            signature_noise.v, enroll1);

        Enrollment[] enrollments;
        enrollments ~= enroll1;
        enrollments.sort!("a.utxo_key < b.utxo_key");
        auto block3 = makeNewBlock(block2, txs_3, enrollments);
        assert(block3.header.enrollments.length == Enrollment.MinValidatorCount);
        assert(block3.isValid(block2.header.height, hashFull(block2.header), findUTXO, 0));
    }

    // When there are still active validators at the new block height,
    // then new block does not need to contain new enrollments to be considered valid
    {
        KeyPair keypair2 = KeyPair.random();
        Transaction[] txs_3;
        foreach (idx; 0 .. Block.TxsInBlock)
        {
            Transaction tx =
            {
                TxType.Payment,
                [Input(hashFull(txs_2[$-1]), idx)],
                [Output(Amount(1), keypair2.address)]
            };
            tx.inputs[0].signature = keypair.secret.sign(hashFull(tx)[]);
            txs_3 ~= tx;
        }

        auto block3 = makeNewBlock(block2, txs_3);
        assert(block3.header.enrollments.length == 0);

        assert(!block3.isValid(block2.header.height, hashFull(block2.header), findUTXO, 0));

        findUTXO = utxo_set.getUTXOFinder();
        assert(block3.isValid(block2.header.height, hashFull(block2.header), findUTXO, 1));
    }
}
