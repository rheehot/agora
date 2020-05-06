/*******************************************************************************

    Contains a task manager backed by vibe.d's event loop.

    Overriding classes can implement task routines to run
    tasks in their own event loop - for example to be used
    with LocalRest to simulate a network and avoid any I/O.

    Copyright:
        Copyright (c) 2019 BOS Platform Foundation Korea
        All rights reserved.

    License:
        MIT License. See LICENSE for details.

*******************************************************************************/

module agora.common.Task;

import core.time;

/// Ditto
public interface ITaskManager
{
    /***************************************************************************

        Run an asynchronous task

        This should run the delegate provided in its own, independent Task.
        This function is expected to return before `dg` has completed.

        Params:
            dg = the delegate the task should run

    ***************************************************************************/

    public abstract void runTask (void delegate() dg);

    /***************************************************************************

        Suspend the current task for the given duration

        The currently running task is suspended, possibly giving a chance to
        other tasks to run, and won't be active for at least `dur`.
        Note that the next time this task is active could in practice be far
        greater than `dur`, so user code should only rely on it being a minimum.

        Params:
            dur = the duration for which to suspend the task for

    ***************************************************************************/

    public abstract void wait (Duration dur);
}

/// Exposes primitives to run tasks through Vibe.d
public class TaskManager : ITaskManager
{
    static import vibe.core.core;

    ///
    public override void runTask (void delegate() dg)
    {
        vibe.core.core.runTask(dg);
    }

    ///
    public override void wait (Duration dur)
    {
        vibe.core.core.sleep(dur);
    }
}
