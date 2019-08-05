/*******************************************************************************

    Workarounds for compiler / runtime / upstream issues

    Live in this module so they can be imported by code that imports other
    module in Agora, such as

    On startup, it tries to connect with a range of known hosts to join the
    quorum. It then starts to listen for requests, using a REST interface.

    Copyright:
        Copyright (c) 2019 BOS Platform Foundation Korea
        All rights reserved.

    License:
        MIT License. See LICENSE for details.

*******************************************************************************/

module agora.utils.Workarounds;

/**
 * Workaround for segfault similar (or identical) to https://github.com/dlang/dub/issues/1812
 * https://dlang.org/changelog/2.087.0.html#gc_parallel
 */
static if (__VERSION__ >= 2087)
    extern(C) __gshared string[] rt_options = [ "gcopt=parallel:0" ];

// Workaround https://issues.dlang.org/show_bug.cgi?id=19937
private void workaround19937 ()
{
    ulong x = 42;
    assert(x > 0);
    // Thise one triggers with LDC 1.20.0
    assert(0 < 42);
}
