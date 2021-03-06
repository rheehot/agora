/*******************************************************************************

    Contains networking tests with a variety of different validator node counts.

    Copyright:
        Copyright (c) 2020 BOS Platform Foundation Korea
        All rights reserved.

    License:
        MIT License. See LICENSE for details.

*******************************************************************************/

module agora.test.ManyValidators;

version (unittest):

import agora.api.Validator;
import agora.common.Amount;
import agora.common.Config;
import agora.consensus.data.ConsensusParams;
import agora.common.crypto.Key;
import agora.common.Hash;
import agora.consensus.data.Block;
import agora.consensus.data.Enrollment;
import agora.consensus.data.Transaction;
import agora.node.FullNode;
import agora.test.Base;

import std.algorithm;
import std.format;
import std.range;

import core.thread;
import core.time;

/// 16 nodes
unittest
{
    TestConf conf = {
        validators : 6,
        outsider_validators : 10,
        extra_blocks : 7,
        validator_cycle : 11 };

    auto network = makeTestNetwork(conf);
    network.start();
    scope(exit) network.shutdown();
    scope(failure) network.printLogs();
    network.waitForDiscovery();

    auto nodes = network.clients;

    nodes.enumerate.each!((idx, node) =>
        retryFor(node.getBlockHeight() == 7, 5.seconds,
            format("Node %s has block height %s. Expected: %s",
                idx, node.getBlockHeight(), 7)));

    auto spendable = network.blocks[$ - 1].txs
        .filter!(tx => tx.type == TxType.Payment)
        .map!(tx => iota(tx.outputs.length)
            .map!(idx => TxBuilder(tx, cast(uint)idx)))
        .joiner().array;

    // discarded UTXOs (just to trigger block creation)
    auto txs = spendable[0 .. 6]
        .map!(txb => txb.refund(WK.Keys.Genesis.address).sign())
        .array;

    // 16 utxos for freezing, 8 utxos for creating a block later
    txs ~= spendable[6].split(WK.Keys.byRange.take(16).map!(k => k.address)).sign();
    txs ~= spendable[7].split(WK.Keys.Genesis.address.repeat(8)).sign();
    txs.each!(tx => nodes[0].putTransaction(tx));

    // block 8
    nodes.enumerate.each!((idx, node) =>
        retryFor(node.getBlockHeight() == 8, 5.seconds,
            format("Node %s has block height %s. Expected: %s",
                idx, node.getBlockHeight(), 8)));

    // freeze builders
    auto freezable = txs[$ - 2]  // contains 16 payment UTXOs
        .outputs.length.iota
        .takeExactly(16)  // there might be more UTXOs
        .map!(idx => TxBuilder(txs[$ - 2], cast(uint)idx))
        .array;

    // create 16 freeze TXs
    auto freeze_txs = freezable
        .enumerate
        .map!(pair => pair.value.refund(WK.Keys[pair.index].address)
            .sign(TxType.Freeze))
        .array;

    // block 9
    freeze_txs[0 .. 8].each!(tx => nodes[0].putTransaction(tx));
    nodes.enumerate.each!((idx, node) =>
        retryFor(node.getBlockHeight() == 9, 5.seconds,
            format("Node %s has block height %s. Expected: %s",
                idx, node.getBlockHeight(), 9)));

    // block 10
    freeze_txs[8 .. 16].each!(tx => nodes[0].putTransaction(tx));
    nodes.enumerate.each!((idx, node) =>
        retryFor(node.getBlockHeight() == 10, 5.seconds,
            format("Node %s has block height %s. Expected: %s",
                idx, node.getBlockHeight(), 10)));

    // now we re-enroll existing validators (extension),
    // and enroll 10 new validators.
    foreach (node; nodes)
    {
        Enrollment enroll = node.createEnrollmentData();
        node.enrollValidator(enroll);

        // check enrollment
        nodes.each!(n =>
            retryFor(n.getEnrollment(enroll.utxo_key) == enroll, 5.seconds));
    }

    // at block height 11 the validator set changes
    txs = txs[$ - 1]  // take those 8 UTXOs from #L184
            .outputs.length.iota.map!(idx => TxBuilder(txs[$ - 1], cast(uint)idx))
            .takeExactly(8)  // there might be more than 8
            .map!(txb => txb.refund(WK.Keys.Genesis.address).sign()).array;
        txs.each!(tx => nodes[0].putTransaction(tx));

    nodes.enumerate.each!((idx, node) =>
        retryFor(node.getBlockHeight() == 11, 3.seconds,
            format("Node %s has block height %s. Expected: %s",
                idx, node.getBlockHeight(), 11)));

    // sanity check
    nodes.enumerate.each!((idx, node) =>
        retryFor(node.getValidatorCount() == 16, 3.seconds,
            format("Node %s has validator count %s. Expected: %s",
                idx, node.getValidatorCount(), 16)));

    // first validated block using 16 nodes
    txs = txs
        .map!(tx => iota(tx.outputs.length)
            .map!(idx => TxBuilder(tx, cast(uint)idx)))
        .joiner()
        .map!(txb => txb.refund(WK.Keys.Genesis.address).sign())
        .takeExactly(8)
        .array;
    txs.each!(tx => nodes[0].putTransaction(tx));

    // consensus check
    nodes.enumerate.each!((idx, node) =>
        retryFor(node.getBlockHeight() == 12, 3.seconds,
            format("Node %s has block height %s. Expected: %s",
                idx, node.getBlockHeight(), 12)));
}

/// 32 nodes
/// Disabled due to significant network overhead,
/// Block creation fails for 32 nodes.
version (none)
unittest
{
    TestConf conf = {
        timeout : 10.seconds,
        validators : 6,
        outsider_validators : 26,
        extra_blocks : 7,
        validator_cycle : 13 };

    auto network = makeTestNetwork(conf);
    network.start();
    scope(exit) network.shutdown();
    scope(failure) network.printLogs();
    network.waitForDiscovery();

    auto nodes = network.clients;

    nodes.enumerate.each!((idx, node) =>
        retryFor(node.getBlockHeight() == 7, 5.seconds,
            format("Node %s has block height %s. Expected: %s",
                idx, node.getBlockHeight(), 7)));

    auto spendable = network.blocks[$ - 1].txs
        .filter!(tx => tx.type == TxType.Payment)
        .map!(tx => iota(tx.outputs.length)
            .map!(idx => TxBuilder(tx, cast(uint)idx)))
        .joiner().array;

    // discarded UTXOs (just to trigger block creation)
    auto txs = spendable[0 .. 6]
        .map!(txb => txb.refund(WK.Keys.Genesis.address).sign())
        .array;

    // 32 utxos for freezing, 8 utxos for creating a block later
    txs ~= spendable[6].split(WK.Keys.byRange.take(32).map!(k => k.address)).sign();
    txs ~= spendable[7].split(WK.Keys.Genesis.address.repeat(8)).sign();
    txs.each!(tx => nodes[0].putTransaction(tx));

    // block 8
    nodes.enumerate.each!((idx, node) =>
        retryFor(node.getBlockHeight() == 8, 5.seconds,
            format("Node %s has block height %s. Expected: %s",
                idx, node.getBlockHeight(), 8)));

    // freeze builders
    auto freezable = txs[$ - 2]  // contains 32 payment UTXOs
        .outputs.length.iota
        .takeExactly(32)  // there might be more UTXOs
        .map!(idx => TxBuilder(txs[$ - 2], cast(uint)idx))
        .array;

    // create 32 freeze TXs
    auto freeze_txs = freezable
        .enumerate
        .map!(pair => pair.value.refund(WK.Keys[pair.index].address)
            .sign(TxType.Freeze))
        .array;
    assert(freeze_txs.length == 32);

    // block 9
    freeze_txs[0 .. 8].each!(tx => nodes[0].putTransaction(tx));
    nodes.enumerate.each!((idx, node) =>
        retryFor(node.getBlockHeight() == 9, 5.seconds,
            format("Node %s has block height %s. Expected: %s",
                idx, node.getBlockHeight(), 9)));

    // block 10
    freeze_txs[8 .. 16].each!(tx => nodes[0].putTransaction(tx));
    nodes.enumerate.each!((idx, node) =>
        retryFor(node.getBlockHeight() == 10, 5.seconds,
            format("Node %s has block height %s. Expected: %s",
                idx, node.getBlockHeight(), 10)));

    // block 11
    freeze_txs[16 .. 24].each!(tx => nodes[0].putTransaction(tx));
    nodes.enumerate.each!((idx, node) =>
        retryFor(node.getBlockHeight() == 11, 10.seconds,
            format("Node %s has block height %s. Expected: %s",
                idx, node.getBlockHeight(), 11)));

    // block 12
    freeze_txs[24 .. 32].each!(tx => nodes[0].putTransaction(tx));
    nodes.enumerate.each!((idx, node) =>
        retryFor(node.getBlockHeight() == 12, 10.seconds,
            format("Node %s has block height %s. Expected: %s",
                idx, node.getBlockHeight(), 12)));

    // now we re-enroll existing validators (extension),
    // and enroll 10 new validators.
    foreach (node; nodes)
    {
        Enrollment enroll = node.createEnrollmentData();
        node.enrollValidator(enroll);

        // check enrollment
        nodes.each!(n =>
            retryFor(n.getEnrollment(enroll.utxo_key) == enroll, 5.seconds));
    }

    // at block height 13 the validator set changes
    txs = txs[$ - 1]  // take those 8 UTXOs from #L184
            .outputs.length.iota.map!(idx => TxBuilder(txs[$ - 1], cast(uint)idx))
            .takeExactly(8)  // there might be more than 8
            .map!(txb => txb.refund(WK.Keys.Genesis.address).sign()).array;
        txs.each!(tx => nodes[0].putTransaction(tx));

    nodes.enumerate.each!((idx, node) =>
        retryFor(node.getBlockHeight() == 13, 5.seconds,
            format("Node %s has block height %s. Expected: %s",
                idx, node.getBlockHeight(), 13)));

    // sanity check
    nodes.enumerate.each!((idx, node) =>
        retryFor(node.getValidatorCount() == 32, 8.seconds,
            format("Node %s has validator count %s. Expected: %s",
                idx, node.getValidatorCount(), 32)));

    // first validated block using 32 nodes
    txs = txs
        .map!(tx => iota(tx.outputs.length)
            .map!(idx => TxBuilder(tx, cast(uint)idx)))
        .joiner()
        .map!(txb => txb.refund(WK.Keys.Genesis.address).sign())
        .takeExactly(8)
        .array;
    txs.each!(tx => nodes[0].putTransaction(tx));

    // consensus check
    nodes.enumerate.each!((idx, node) =>
        retryFor(node.getBlockHeight() == 14, 10.seconds,
            format("Node %s has block height %s. Expected: %s",
                idx, node.getBlockHeight(), 14)));
}
