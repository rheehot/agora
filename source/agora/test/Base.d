/*******************************************************************************

    Contains utilities to be used by tests to easily set up test environments

    Since our business code is decoupled from our network code,
    thanks to the `vibe.web.rest` generator, we can fairly naturally make
    unittests for network behavior.
    By using the `localrest` library, we assign each node to a thread and use
    an RPC-style approach to call functions.
    This is non-deterministic, but models a real-life behaviour better.

    Copyright:
        Copyright (c) 2019 BOS Platform Foundation Korea
        All rights reserved.

    License:
        MIT License. See LICENSE for details.

*******************************************************************************/

module agora.test.Base;

version (unittest):

import agora.common.Amount;
import agora.common.BanManager;
import agora.common.BitField;
import agora.common.Config;
import agora.common.Types;
import agora.common.Hash;
import agora.common.Metadata;
import agora.common.Set;
import agora.common.Task;
import agora.common.TransactionPool;
import agora.common.crypto.Key;
import agora.consensus.data.Block;
import agora.consensus.data.Enrollment;
import agora.consensus.data.ConsensusParams;
import agora.consensus.data.PreImageInfo;
import agora.consensus.data.Transaction;
import agora.consensus.data.UTXOSetValue;
import agora.consensus.UTXOSet;
import agora.consensus.EnrollmentManager;
import agora.consensus.data.genesis.Test;
import agora.network.NetworkManager;
import agora.node.BlockStorage;
import agora.node.FullNode;
import agora.node.Ledger;
import agora.node.Validator;
import agora.utils.Log;
import agora.utils.PrettyPrinter;
import agora.api.FullNode : NodeInfo, NetworkState;
import agora.api.Validator : ValidatorAPI = API;

import scpd.types.Stellar_SCP;

static import geod24.LocalRest;
import geod24.Registry;

import std.array;
import std.exception;

import core.runtime;
import core.stdc.time;

/* The following imports are frequently needed in tests */

 // Contains utilities for testing, e.g. `retryFor`
public import agora.utils.Test;
// `core.time` provides duration-related utilities, used e.g. for `retryFor`
public import core.time;
// Useful to express complex pipeline simply
public import std.algorithm;
// Provides `to`, a template to convert anything to anything else
public import std.conv;
// `format` is often used to provide useful error messages
public import std.format;
// Range utilities are often used in combination with `std.algorithm`
public import std.range;
// To print messages to the screen while debugging a test
public import std.stdio;

shared static this()
{
    Runtime.extendedModuleUnitTester = &customModuleUnitTester;
}

/// Custom unnitest runner as a workaround for multi-threading issue:
/// Agora unittests spawn threads, which allocate. The Ocean tests
/// inspect GC stats for memory allocation changes, and potentially fail
/// if during such a test a runaway Agora unnittest child thread allocates.
/// Workaround: Don't run ocean submodule unittests
private UnitTestResult customModuleUnitTester ()
{
    import std.parallelism;
    import std.process;
    import std.string;
    import std.uni;
    import core.atomic;

    // by default emit only errors during unittests.
    // can be re-set by calling code.
    Log.root.level(Log.root.Level.Error, true);

    //
    const chatty = !!("dchatty" in environment);
    auto filter = environment.get("dtest").toLower();
    size_t filtered;

    // can't use ModuleInfo[], opApply returns temporaries..
    struct ModTest
    {
        string name;
        void function() test;
    }

    ModTest[] mod_tests;
    ModTest[] single_threaded;
    ModTest[] heavy_tests;

    foreach (ModuleInfo* mod; ModuleInfo)
    {
        if (mod is null)
            continue;

        auto fp = mod.unitTest;
        if (fp is null)
            continue;

        if (mod.name.startsWith("agora") ||
            mod.name.startsWith("scpd"))
        {
            if (filter.length > 0 &&
                !canFind(mod.name.toLower(), filter.save))
            {
                filtered++;
                continue;
            }

            // this test checks GC usage stats before / after tests,
            // but other threads can change the outcome of the GC usage stats
            if (mod.name == "agora.common.Serializer")
                single_threaded ~= ModTest(mod.name, fp);
            else if (mod.name == "agora.test.ManyValidators")
                heavy_tests ~= ModTest(mod.name, fp);
        }
    }

    shared size_t executed;
    shared size_t passed;

    void runTest (ModTest mod)
    {
        atomicOp!"+="(executed, 1);
        try
        {
            if (chatty)
            {
                auto output = stdout.lockingTextWriter();
                output.formattedWrite("Unittesting %s..\n", mod.name);
            }

            mod.test();
            atomicOp!"+="(passed, 1);
        }
        catch (Throwable ex)
        {
            auto output = stdout.lockingTextWriter();
            output.formattedWrite("Module tests failed: %s\n", mod.name);
            output.formattedWrite("%s\n", ex);
            // print logs of the work thread
            CircularAppender().print(output);
        }
    }

    // Run single-threaded tests
    foreach (mod; single_threaded)
        runTest(mod);

    foreach (mod; parallel(mod_tests))
        runTest(mod);

    foreach (mod; parallel(heavy_tests))
        runTest(mod);

    UnitTestResult result = { executed : executed, passed : passed };
    if (filtered > 0)
        writefln("Ran %s/%s tests (%s filtered)", result.executed,
            result.executed + filtered, filtered);

    //result.summarize = true;
    result.runMain = false;
    return result;
}

/// A custom serializer for LocalRest
public struct Serializer
{
    import agora.common.Serializer;

    static immutable(ubyte)[] serialize (T) (auto ref T value) @trusted nothrow
    {
        // `serializeFull` should be `@safe`, but `assumeUnique` is not
        try
            return ((arr) @trusted => assumeUnique(arr))(serializeFull(value));
        catch (Throwable t)
        {
            try
            {
                writeln("ERROR: Serializable: ", T.stringof);
                writeln(t);
            }
            catch (Exception ignored) {}
            assert(0);
        }
    }

    static QT deserialize (QT) (scope immutable(ubyte)[] data) @trusted nothrow
    {
        try
            return deserializeFull!QT(data);
        catch (Throwable t)
        {
            try
            {
                writeln("ERROR: Deserialize:", QT.stringof);
                writeln(t);
            }
            catch (Exception ignored) {}
            assert(0);
        }
    }
}

/// A different default serializer from `LocalRest` for `RemoteAPI`
public alias RemoteAPI (APIType) = geod24.LocalRest.RemoteAPI!(APIType, Serializer);

/*******************************************************************************

    Task manager backed by LocalRest's event loop.

*******************************************************************************/

public class LocalRestTaskManager : TaskManager
{
    static import geod24.LocalRest;

    /***************************************************************************

        Run an asynchronous task in LocalRest's event loop.

        Params:
            dg = the delegate the task should run

    ***************************************************************************/

    public override void runTask (void delegate() dg)
    {
        geod24.LocalRest.runTask(dg);
    }

    /***************************************************************************

        Suspend the current task for the given duration

        Params:
            dur = the duration for which to suspend the task for

    ***************************************************************************/

    public override void wait (Duration dur) nothrow
    {
        geod24.LocalRest.sleep(dur);
    }

    /***************************************************************************

        Run an asynchronous task after a given time in LocalRest's

        The task will first run after the given `timeout`, and
        can either repeat or run only once (the default).
        Works similarly to Vibe.d's `setTimer`.

        Params:
            timeout = Determines the minimum amount of time that elapses before
                the timer fires.
            dg = This delegate will be called when the timer fires.
            periodic = Specifies if the timer fires repeatedly or only once.

        Return:
           An `ITimer` interface with the ability to control the timer

    ***************************************************************************/

    public override ITimer setTimer (Duration timeout, void delegate() dg,
        Periodic periodic = Periodic.No)
    {
        return new LocalRestTimer(geod24.LocalRest.setTimer(timeout, dg,
            periodic));
    }
}

/*******************************************************************************

    LocalRest only timer (for unittests)

*******************************************************************************/

private final class LocalRestTimer : ITimer
{
    import LocalRest = geod24.LocalRest;

    private LocalRest.Timer timer;

    public this (LocalRest.Timer timer)
    {
        this.timer = timer;
    }

    /// Ditto
    public override void stop ()
    {
        this.timer.stop();
    }
}

/// A ban manager with a fake clock for reliable unittesting
public class FakeClockBanManager : BanManager
{
    /// the fake current time
    public __gshared time_t time;

    /// Ctor
    public this (Config conf)
    {
        super(conf, null);
    }

    /// Return the fake time
    protected override time_t getCurTime () const @trusted
    {
        return time;
    }

    /// no-op
    public override void load () { }

    /// no-op
    public override void dump () { }
}

/// We use a pair of (key, client) rather than a hashmap client[key],
/// since we want to know the order of the nodes which were configured
/// in the makeTestNetwork() call.
public struct NodePair
{
    ///
    public Address address;

    ///
    public RemoteAPI!TestAPI client;
}

/*******************************************************************************

    Used by unittests to send messages to individual nodes.
    This class is instantiated once per unittest.

*******************************************************************************/

public class TestAPIManager
{
    /// Used by the unittests in order to directly interact with the nodes,
    /// without trying to handshake or do any automatic network discovery.
    /// Also kept here to avoid any eager garbage collection.
    public NodePair[] nodes;

    /// Contains the initial blockchain state of all nodes
    public immutable(Block)[] blocks;

    /// convenience: returns a random-access range which lets us access clients
    auto clients ()
    {
        return nodes.map!(np => np.client);
    }

    /// Registry holding the nodes
    protected Registry reg;

    ///
    public this (immutable(Block)[] blocks)
    {
        this.blocks = blocks;
        this.reg.initialize();
    }

    /***************************************************************************

        Create a new node

        Params:
            conf = the configuration passed on to the Node constructor

    ***************************************************************************/

    public void createNewNode (Config conf)
    {
        RemoteAPI!TestAPI api;

        if (conf.node.is_validator)
        {
            api = RemoteAPI!TestAPI.spawn!TestValidatorNode(conf, &this.reg,
                this.blocks, conf.node.timeout);
        }
        else
        {
            api = RemoteAPI!TestAPI.spawn!TestFullNode(conf, &this.reg,
                this.blocks, conf.node.timeout);
        }

        this.reg.register(conf.node.address, api.tid());
        this.nodes ~= NodePair(conf.node.address, api);
    }

    /***************************************************************************

        Start each of the nodes

        Params:
            count = Expected number of nodes

    ***************************************************************************/

    public void start ()
    {
        foreach (node; this.nodes)
        {
            // have to wait indefinitely as the constructor is
            // currently a slow routine, stalling the call to start().
            node.client.ctrl.withTimeout(0.msecs,
                (scope TestAPI api) {
                    api.start();
                });
        }
    }

    /***************************************************************************

        Shut down each of the nodes

        Params:
          printLogs = Whether or not to print nodes logs

    ***************************************************************************/

    public void shutdown (bool printLogs = false)
    {
        foreach (node; this.nodes)
            enforce(this.reg.unregister(node.address));

        /// Private functions used for `shutdown`
        static void shutdownWithLogs (TestAPI node)
        {
            node.printLog();
            (cast(FullNode)node).shutdown();
        }
        static void shutdownSilent (TestAPI node)
        {
            (cast(FullNode)node).shutdown();
        }

        foreach (ref node; this.nodes)
        {
            node.client.ctrl.shutdown(
                printLogs ? &shutdownWithLogs : &shutdownSilent);
            node.client = null;
        }

        this.nodes = null;
    }

    /***************************************************************************

        Restart a specific node

        This routine restarts the given `client`, making sure it gracefully
        shuts down then restart properly.

        Params:
          client = Reference to the client to restart

    ***************************************************************************/

    public void restart (scope RemoteAPI!TestAPI client)
    {
        client.ctrl.restart((TestAPI node) { (cast(FullNode)node).shutdown(); });
        client.ctrl.withTimeout(0.msecs, (scope TestAPI api) { api.start(); });
    }

    /***************************************************************************

        Print out the logs for each node

    ***************************************************************************/

    public void printLogs (string file = __FILE__, size_t line = __LINE__)
    {
        synchronized  // make sure logging output is not interleaved
        {
            writefln("%s(%s): Node logs:\n", file, line);
            foreach (node; this.nodes)
            {
                try
                {
                    node.client.printLog();
                }
                catch (Exception ex)
                {
                    writefln("Could not print logs for node: %s", ex.message);
                }
            }
        }
    }

    /***************************************************************************

        Keep polling for nodes to reach discovery, up to 5 seconds.

        If network discovery isn't reached, it will throw an Error.

    ***************************************************************************/

    public void waitForDiscovery (string file = __FILE__, size_t line = __LINE__)
    {
        try
        {
            const timeout = 5.seconds;
            this.nodes.each!(node =>
                retryFor(node.client.getNodeInfo().ifThrown(NodeInfo.init)
                    .state == NetworkState.Complete,
                    timeout,
                    format("Node %s has not completed discovery after %s.",
                        node.address, timeout)));
        }
        catch (Error ex)  // better UX
        {
            ex.file = file;
            ex.line = line;
            throw ex;
        }
    }
}

/*******************************************************************************

    Base class for `NetworkManager` used in unittests.
    This class is instantiated once per unittested node.

    The `NetworkManager` class is the mean used to communicate with other nodes.
    In regular build, it does network communication, but in unittests it should
    not do IO (or appear not to).

    In the current design, all nodes should be instantiated upfront,
    registered via `geod24.Registry`, and located by `getClient`.

*******************************************************************************/

public class TestNetworkManager : NetworkManager
{
    import agora.api.handler.BlockExternalizedHandler;
    import agora.api.handler.PreImageReceivedHandler;

    ///
    public Registry* registry;

    /// Constructor
    public this (NodeConfig config, BanManager.Config ban_conf,
        in string[] peers, in string[] dns_seeds, Metadata metadata,
        TaskManager taskman, Registry* reg)
    {
        this.registry = reg;
        super(config, ban_conf, peers, dns_seeds, metadata, taskman);
    }

    /// No "http://" in unittests, we just use the string as-is
    protected final override string getAddress ()
    {
        return this.node_config.address;
    }

    ///
    protected final override ValidatorAPI getClient (Address address,
        Duration timeout)
    {
        auto tid = this.registry.locate(address);
        if (tid != typeof(tid).init)
            return new RemoteAPI!ValidatorAPI(tid, timeout);
        assert(0, "Trying to access node at address '" ~ address ~
               "' without first creating it");
    }

    /***************************************************************************

        Params:
            conf = ban manager config

        Returns:
            an instance of a BanManager with a fake clock

    ***************************************************************************/

    protected override BanManager getBanManager (in BanManager.Config conf,
        cstring _data_dir)
    {
        return new FakeClockBanManager(conf);
    }

    ///
    protected final override BlockExternalizedHandler getBlockExternalizedHandler
        (Address address)
    {
        assert(0, "Not supported");
    }

    ///
    protected final override PreImageReceivedHandler getPreimageReceivedHandler
        (Address address)
    {
        assert(0, "Not supported");
    }
}

/*******************************************************************************

    API implemented by the test nodes runs by LocalRest

    This API inherits from ValidatorAPI, and simply adds a few functions that
    should not be public in a real-world scenario, but are needed in our test
    setup. Those functions trigger a specific action (e.g. `start`, `printLog`),
    or in rare cases are a way to force a node to take a specific action.

    However, adding a method here should be carefully considered, as most of the
    time, the prefered approach to test a specific behavior on a node would be
    to instantiate a different kind of node (derive from `TestFullNode` or
    `TestValidatorNode` and implement the desired behavior), as this approach
    will be localized to the test, instead of being available to every tests.

    Besides the current functions, extra functionalities that would fit in this
    interface would be machine state changes, e.g. `setTime` or `removeDisk`.

*******************************************************************************/

public interface TestAPI : ValidatorAPI
{
    /***************************************************************************

        Start the node

        The `FullNode` have a `start` method that is scheduled by the `main`
        function to start discovery / catchup, etc...
        Since our node is not instantiated through `main`, the `APIManager`
        will call this function directly after instantiating a new node.

    ***************************************************************************/

    public abstract void start ();

    /***************************************************************************

        Print out the contents of the log

        Each node logs to their own buffer in their own Thread, which is written
        to a circular buffer to save on memory.
        Calling this function will dump the content of the node's log buffer
        to stderr. `TestAPIManager` provides a convenient way to call
        this method for every node, and most tests will do this on test failure.

    ***************************************************************************/

    public abstract void printLog ();

    /***************************************************************************

        TEMPORARY: Create a valid `Enrollment` for this node

        This method is a temporary workaround to create an Enrollment for a node
        in tests. In the future it will be replaced by a simple function call,
        once Enrollment catch-up is fixed and all node keypairs are well-known.

    ***************************************************************************/

    public abstract Enrollment createEnrollmentData();

    ///
    public QuorumConfig getQuorumConfig ();

    /// Get the active validator count for the current block height
    public ulong getValidatorCount ();
}

/// Contains routines which are implemented by both TestFullNode and
/// TestValidator. Used because TestValidator inherits from Validator but
/// cannot inherit from TestFullNode, as it already inherits from Validator class
/// (multiple-inheritance is not supported in D)
private mixin template TestNodeMixin ()
{
    private Registry* registry;

    /// Blocks to preload into the memory storage
    private immutable(Block)[] blocks;

    ///
    public this (Config config, Registry* reg, immutable(Block)[] blocks)
    {
        this.registry = reg;
        this.blocks = blocks;
        super(config);
    }

    ///
    public override void start ()
    {
        super.start();
    }

    /// Prints out the log contents for this node
    public void printLog ()
    {
        auto output = stdout.lockingTextWriter();
        output.formattedWrite("Log for node: %s\n", this.config.node.address);
        output.put("======================================================================\n");
        CircularAppender().print(output);
        output.put("======================================================================\n\n");
    }

    protected override IBlockStorage getBlockStorage (string data_dir) @system
    {
        return new MemBlockStorage(this.blocks);
    }

    /// Used by the node
    public override Metadata getMetadata (string _unused) @system
    {
        return new MemMetadata();
    }

    /// Return a transaction pool backed by an in-memory SQLite db
    public override TransactionPool getPool (string) @system
    {
        return new TransactionPool(":memory:");
    }

    /// Return a UTXO set backed by an in-memory SQLite db
    protected override UTXOSet getUtxoSet (string data_dir)
    {
        return new UTXOSet(":memory:");
    }

    /// Return a LocalRest-backed task manager
    protected override TaskManager getTaskManager ()
    {
        return new LocalRestTaskManager();
    }

    /// Return an instance of the custom TestNetworkManager
    protected override NetworkManager getNetworkManager (
        in NodeConfig node_config, in BanManager.Config banman_conf,
        in string[] peers, in string[] dns_seeds, Metadata metadata,
        TaskManager taskman)
    {
        assert(taskman !is null);
        return new TestNetworkManager(node_config, banman_conf, peers,
            dns_seeds, metadata, taskman, this.registry);
    }

    /// Return an enrollment manager backed by an in-memory SQLite db
    protected override EnrollmentManager getEnrollmentManager (
        string data_dir, in NodeConfig node_config,
        immutable(ConsensusParams) params)
    {
        return new EnrollmentManager(":memory:", node_config.key_pair, params);
    }

    /// Get the active validator count for the current block height
    public override ulong getValidatorCount ()
    {
        return this.enroll_man.validatorCount();
    }
}

/// A FullNode which also implements test routines in TestAPI
public class TestFullNode : FullNode, TestAPI
{
    ///
    mixin TestNodeMixin!();

    /// FullNode does not implement this
    public override Enrollment createEnrollmentData ()
    {
        assert(0);
    }

    /// FullNode does not implement this
    public override PublicKey getPublicKey () @safe
    {
        // NetworkManager assumes that if key == PublicKey.init,
        // we are *not* a Validator node, treated as a FullNode instead.
        return PublicKey.init;
    }

    /// FullNode does not implement this
    public override void receiveEnvelope (SCPEnvelope envelope) @safe
    {
        assert(0);
    }

    /// ditto
    public override QuorumConfig getQuorumConfig ()
    {
        assert(0);
    }
}

/// A Validator which also implements test routines in TestAPI
public class TestValidatorNode : Validator, TestAPI
{
    ///
    mixin TestNodeMixin!();

    /// Create an enrollment data used as information for an validator
    public override Enrollment createEnrollmentData ()
    {
        Hash[] utxo_hashes;
        auto pubkey = this.getPublicKey();
        auto utxos = this.utxo_set.getUTXOs(pubkey);
        foreach (key, utxo; utxos)
        {
            if (utxo.type == TxType.Freeze &&
                utxo.output.value.integral() >= Amount.MinFreezeAmount.integral())
            {
                utxo_hashes ~= key;
            }
        }

        return this.enroll_man.createEnrollment(utxo_hashes[0]);
    }


    /// ditto
    public override QuorumConfig getQuorumConfig ()
    {
        return this.qc;
    }
}

/// Describes a network topology for testing purpose
public enum NetworkTopology
{
    /// The nodes know about each other's IPs,
    /// and additionally outsider nodes will connect to them.
    FullyConnected,

    /// The nodes are connected in a chain: v1 <- v2 <- v3 <- v1,
    /// and additionally outsider nodes are minimally connected to them
    /// via v1 <- o1, v2 <- o2 (o = outsider node)
    MinimallyConnected,
}

/// Node / Network / Quorum configuration for use with makeTestNetwork
public struct TestConf
{
    /// Network topology to use
    NetworkTopology topology = NetworkTopology.FullyConnected;

    /// Extra blocks to generate in addition to the genesis block
    size_t extra_blocks = 0;

    /// Number of validator nodes to instantiate
    size_t validators = 4;

    /// Number of full nodes to instantiate
    size_t full_nodes = 0;

    /// Number of extra validators which are initially outside the network
    size_t outsider_validators = 0;

    /// Number of extra full nodes which are initially outside the network
    size_t outsider_full_nodes = 0;

    /// The value to give the `ValidatorCycle` of nodes
    uint validator_cycle = 1008;

    /// Maximum number of quorums in the autogenerated quorum sets
    uint max_quorum_nodes = 7;

    /// whether to set up the peers in the config
    bool configure_network = true;

    /// the delay between request retries
    Duration retry_delay = 100.msecs;

    /// minimum clients to connect to (defaults to nodes.length - 1)
    size_t min_listeners;

    /// max retries before a request is considered failed
    size_t max_retries = 20;

    /// request timeout for each node
    Duration timeout = 5.seconds;

    /// max failed requests before a node is banned
    size_t max_failed_requests = 100;

    /// max listener nodes. If set to 0, set to this.nodes - 1
    size_t max_listeners;
}

/*******************************************************************************

    Creates a test network with the desired topology

    This function's only usage is to create the network topology.
    The actual behavior of the nodes that are part of the network is decided
    by the `TestNetworkManager` implementation.

    Params:
        APIManager = Type of API manager to instantiate
        test_conf = the test configuration
        params = the consensus-critical constants

    Returns:
        The set of public key added to the node

*******************************************************************************/

public APIManager makeTestNetwork (APIManager : TestAPIManager = TestAPIManager)(
    in TestConf test_conf)
{
    import agora.common.Serializer;
    import std.digest;
    import std.range;

    // We know we're in the main thread
    // Vibe.d messes with the scheduler - reset it
    static import std.concurrency;
    std.concurrency.scheduler = null;

    const TotalNodes = test_conf.validators + test_conf.full_nodes +
        test_conf.outsider_validators + test_conf.outsider_full_nodes;

    assert(TotalNodes >= 2, "Creating a network require at least 2 nodes");

    size_t full_node_idx;
    size_t validator_idx;

    NodeConfig makeNodeConfig (bool is_validator, KeyPair node_key)
    {
        Address address;

        if (is_validator)
            address = format("Validator #%s (%s)",
                validator_idx++, node_key.address.prettify);
        else
            address = format("FullNode #%s", full_node_idx++);

        NodeConfig conf =
        {
            address : address,
            is_validator : is_validator,
            key_pair : node_key,
            retry_delay : test_conf.retry_delay,
            max_retries : test_conf.max_retries,
            timeout : test_conf.timeout,
            validator_cycle : test_conf.validator_cycle,
            max_quorum_nodes : test_conf.max_quorum_nodes,
            min_listeners : test_conf.min_listeners == 0
                ? (test_conf.validators + test_conf.full_nodes) - 1
                : test_conf.min_listeners,
            max_listeners : (test_conf.max_listeners == 0)
                ? TotalNodes - 1 : test_conf.max_listeners,
        };

        return conf;
    }

    BanManager.Config ban_conf =
    {
        max_failed_requests : test_conf.max_failed_requests,
        ban_duration: 300
    };

    Config makeMainConfig (size_t idx, NodeConfig self, NodeConfig[] node_confs)
    {
        auto other_nodes =
            node_confs
                .filter!(conf => conf != self)
                .map!(conf => conf.address);

        string[] network;
        if (test_conf.configure_network)
        {
            // nodes form a network chain: n2 <- n0 <- n1 <- n2
            if (test_conf.topology == NetworkTopology.MinimallyConnected)
            {
                auto prev_node = idx == 0 ? node_confs[$ - 1] : node_confs[idx - 1];
                network = [prev_node.address];
            }
            else
            {
                network = other_nodes.array;
            }
        }

        Config conf =
        {
            banman : ban_conf,
            node : self,
            network : assumeUnique(network),
        };

        return conf;
    }

    auto key_range = WK.Keys.byRange();
    auto keys = refRange(&key_range);

    NodeConfig[] node_configs;
    Config[] main_configs;

    keys.take(test_conf.validators)
        .each!(key => node_configs ~= makeNodeConfig(true, key));
    keys.take(test_conf.full_nodes)
        .each!(key => node_configs ~= makeNodeConfig(false, key));

    // network these nodes together using the configured NetworkTopology
    node_configs.enumerate.each!(
        pair => main_configs ~= makeMainConfig(
            pair.index, pair.value, node_configs));

    NodeConfig[] extra_node_configs;
    keys.take(test_conf.outsider_validators)
        .each!(key => extra_node_configs ~= makeNodeConfig(true, key));
    keys.take(test_conf.outsider_full_nodes)
        .each!(key => extra_node_configs ~= makeNodeConfig(false, key));

    // generate the outsider main_configs. pair.index is correct here despite
    // passing 'node_configs'. in 'MinimallyConnected' mode the connection will be
    // n2 <- n1 <- n2 and n1 <- o1 and n2 <- o2, (o = outsider).
    // otherwise it will be [n1 <-> n2] <- o1 and [n1 <-> n2] <- o2
    extra_node_configs.enumerate.each!(
        pair => main_configs ~= makeMainConfig(
            pair.index % node_configs.length, pair.value, node_configs));

    auto gen_block = makeGenesisBlock(
        node_configs
            .filter!(conf => conf.is_validator)
            .map!(conf => conf.key_pair)
            .array, test_conf.validator_cycle);

    immutable string gen_block_hex = gen_block
        .serializeFull()
        .toHexString();

    foreach (ref conf; main_configs)
        conf.node.genesis_block = gen_block_hex;

    immutable(Block)[] blocks = generateBlocks(gen_block,
        test_conf.extra_blocks);

    auto net = new APIManager(blocks);
    foreach (ref conf; main_configs)
        net.createNewNode(conf);

    return net;
}

/// Returns: the entire ledger from the provided node
public const(Block)[] getAllBlocks (TestAPI node)
{
    import std.range;
    const(Block)[] blocks;

    // note: may return less than asked for, hence the loop
    size_t starting_block = 0;
    while (1)
    {
        auto new_blocks = node.getBlocksFrom(starting_block, uint.max);
        if (new_blocks.length == 0)  // no blocks left
            break;

        // ensure sequential consistency
        foreach (block; new_blocks)
            assert(block.header.height == starting_block++);

        blocks ~= new_blocks;
    }

    return blocks;
}

/// Returns: true if all the nodes contain the same blocks
public bool containSameBlocks (APIS)(APIS nodes, size_t height)
{
    auto first_blocks = nodes[0].getAllBlocks();

    foreach (node; nodes)
    {
        if (node.getBlockHeight() != height)
            return false;

        if (node.getAllBlocks() != first_blocks)
            return false;
    }

    return true;
}

/// Asserts that all nodes in the range are at height `expected`
public void ensureConsistency (APIS)(
    APIS nodes, ulong expected, Duration timeout = 2.seconds)
    if (isInputRange!APIS)
{
    foreach (idx, node; nodes.enumerate())
    {
        retryFor(node.getBlockHeight() == expected, timeout,
                 format("Node #%d was at height %d (expected: %d)",
                        idx, node.getBlockHeight(), expected));
    }
}


/*******************************************************************************

    Generate a genesis block.

    For each key pair, a freeze transaction and an Enrollment
    will be created and added to the generated Genesis block.
    The first transaction is the unittest's `GenesisTransaction`

    Params:
        key_pairs = key pairs for signing enrollments with
        validator_cycle = the consensus-critical `ValidatorCycle` value

    Returns:
        The genesis block

*******************************************************************************/

private immutable(Block) makeGenesisBlock (in KeyPair[] key_pairs,
    uint validator_cycle)
{
    import agora.common.Serializer;

    // 1 payment tx, the rest are freeze txs
    Transaction[] txs;
    // This function is only called from unittests so we assume that
    // GenesisBlock is `UnitTestGenesisBlock`
    txs ~= GenesisBlock.txs.serializeFull.deserializeFull!(Transaction[]);
    Enrollment[] enrolls;

    foreach (key_pair; key_pairs)
    {
        Transaction tx =
        {
            type : TxType.Freeze,
            outputs : [Output(Amount.MinFreezeAmount, key_pair.address)]
        };

        txs ~= tx;
        const utxo = UTXOSetValue.getHash(tx.hashFull(), 0);
        enrolls ~= EnrollmentManager.makeEnrollment(
            key_pair, utxo, validator_cycle);
    }

    enrolls.sort!("a.utxo_key < b.utxo_key");

    txs.sort;
    Hash[] merkle_tree;
    auto merkle_root = Block.buildMerkleTree(txs, merkle_tree);

    immutable(BlockHeader) makeHeader ()
    {
        return immutable(BlockHeader)(
            Hash.init,   // prev
            Height(0),   // height
            merkle_root,
            BitField!uint.init,
            Signature.init,
            enrolls.assumeUnique,
        );
    }
    return immutable(Block)(
        makeHeader(),
        txs.assumeUnique,
        merkle_tree.assumeUnique
    );
}

/*******************************************************************************

    Generate a set of blocks with spend transactions

    Params:
        gen_block = the genesis block
        count = the number of extra blocks to generate. If 0, the return
                blockchain will only contain the genesis block.

    Returns:
        The blockchain, including the provided genesis block

*******************************************************************************/

private immutable(Block)[] generateBlocks (
    ref immutable Block gen_block, size_t count)
{
    const(Block)[] blocks = [gen_block];
    if (count == 0)
        return blocks.assumeUnique;  // just the genesis block

    const(Transaction)[] prev_txs;
    foreach (_; 0 .. count)
    {
        // see `agora.consensus.data.genesis.Test` for the magic amount
        auto txs = makeChainedTransactions(WK.Keys.Genesis,
            prev_txs, 1, 61_000_000uL * 10_000_000uL * Block.TxsInBlock);

        const NoEnrollments = null;
        blocks ~= makeNewBlock(blocks[$ - 1], txs, NoEnrollments);
        prev_txs = txs;
    }

    return blocks.assumeUnique;
}
