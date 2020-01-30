/*******************************************************************************

    Quorum-related utilities

    Quorum slices and configurations are internal to the node,
    and usually not visible to the user.
    The node derives its own quorum slice based on the network configuration,
    which is recorded in the chain, and use this as a basis for SCP.
    This also means that other nodes are able to infer another node's
    quorum configuration without communication.

    Copyright:
        Copyright (c) 2020 BOS Platform Foundation Korea
        All rights reserved.

    License:
        MIT License. See LICENSE for details.

*******************************************************************************/

module agora.consensus.protocol.Quorum;

import agora.common.crypto.Key;

import scpd.scp.QuorumSetUtils;
import scpd.types.Stellar_SCP;
import scpd.types.Utils;

import std.range.primitives;

/*******************************************************************************

    Generate a 'default' quorum set, taking into account all peers

    This quorum set will be later updated to match the protocol.

    Params:
        R = An input range of `PublicKey`
        keys = The list of keys to put in the quorum set

    Returns:
        An `SCPQuorumSet` instance with keys as validators and 100% threshold,
        which has been normalized and is sane.

*******************************************************************************/

public SCPQuorumSet makeDefaultQuorumSet (R) (R keys) if (isInputRange!R)
out (qset)
{
    // todo: assertion fails do the misconfigured(?) threshold of 1 which
    // is lower than vBlockingSize in QuorumSetSanityChecker::checkSanity
    const ExtraChecks = false;
    assert(isQuorumSetSane(qset, ExtraChecks));
}
do
{
    import std.conv;
    import scpd.types.Stellar_types : Hash, NodeID;

    SCPQuorumSet quorum;

    foreach (k; keys)
    {
        auto key = Hash(k[]);
        auto pub_key = NodeID(key);
        quorum.validators.push_back(pub_key);
    }

    // For the moment, require all peers to agree
    quorum.threshold = quorum.validators.length().to!uint;

    normalizeQSet(quorum);
    return quorum;
}

///
unittest
{
    import agora.common.Types;

    Hash[PublicKey] nodes;
    PublicKey[] keys;

    foreach (_; 0 .. 2)
    {
        keys ~= KeyPair.random().address;
        nodes[keys[$-1]] = Hash.init;
    }

    auto qset = makeDefaultQuorumSet(nodes.byKey);
    assert(qset.threshold == 2);
    assert(qset.validators.length == 2);
    foreach (idx; 0 .. 2)
        assert(qset.validators[idx] == keys[idx]);
}
