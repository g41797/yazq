// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

/// Mailbox with owned Envelope (non-intrusive)
pub fn MailBox(comptime Letter: type) type {
    return struct {
        const Self = @This();

        /// Envelope inside FIFO wrapping the actual letter.
        pub const Envelope = struct {
            prev: ?*Envelope = null,
            next: ?*Envelope = null,
            letter: Letter,
        };

        first: ?*Envelope = null,
        last: ?*Envelope = null,
        len: usize = 0,
        // not initiated mailbox has "closed" state
        closed: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
        interrupted: bool = false,

        mutex: Io.Mutex = .init,
        cond: Io.Condition = .init,
        io: ?Io = null, // "managed"

        /// Initialize mailbox with Io backend
        pub fn init(io: ?Io) Self {
            return .{
                .io = if (io == null) std.Io.Threaded.global_single_threaded.*.io() else io.?,
                .closed = std.atomic.Value(bool).init(false),
            };
        }

        /// Append a new Envelope to the tail
        /// and wake-up waiting on receive threads.
        /// Arguments:
        ///     new_Envelope: Pointer to the new Envelope to append.
        /// If mailbox was closed (or not initiated) - returns error.Closed
        pub fn send(mbox: *Self, new_Envelope: *Envelope) error{Closed}!void {
            if (mbox.closed.load(.acquire)) return error.Closed;
            const io = mbox.io orelse return error.Closed;

            mbox.mutex.lock(io) catch return error.Closed;
            defer mbox.mutex.unlock(io);

            if (mbox.closed.load(.acquire)) {
                return error.Closed;
            }

            mbox.enqueue(new_Envelope);

            mbox.cond.signal(io);
        }

        /// Wake-up waiting on receive thread.
        /// If mailbox was closed - returns error.Closed
        /// If waiting was already interrupted -  - returns error.AlreadyInterrupted
        pub fn interrupt(mbox: *Self) error{ Closed, AlreadyInterrupted }!void {
            if (mbox.closed.load(.acquire)) return error.Closed;
            const io = mbox.io orelse return error.Closed;

            mbox.mutex.lock(io) catch return error.Closed;
            defer mbox.mutex.unlock(io);

            if (mbox.closed.load(.acquire)) {
                return error.Closed;
            }

            if (mbox.interrupted) {
                return error.AlreadyInterrupted;
            }

            mbox.interrupted = true;

            mbox.cond.signal(io);
        }

        /// Blocks thread  maximum timeout_ns till Envelope in head of FIFO will be available.
        /// If not available - returns error.Timeout.
        /// Otherwise removes Envelope from the head and returns it to the caller.
        /// If mailbox was closed - returns error.Closed
        /// If interrupt was issued - returns error.Interrupted
        pub fn receive(mbox: *Self, timeout_ns: u64) error{ Timeout, Closed, Interrupted }!*Envelope {
            if (mbox.closed.load(.acquire)) return error.Closed;
            const io = mbox.io orelse return error.Closed;

            const timeout = Io.Timeout{
                .duration = .{
                    .raw = .{
                        .nanoseconds = @as(i96, @intCast(timeout_ns)),
                    },
                    .clock = .real,
                },
            };

            const deadline = timeout.toDeadline(io);

            mbox.mutex.lock(io) catch return error.Closed;
            defer mbox.mutex.unlock(io);

            while (mbox.len == 0) {
                if (mbox.closed.load(.acquire))
                    return error.Closed;

                if (mbox.interrupted) {
                    mbox.interrupted = false;
                    return error.Interrupted;
                }

                switch (deadline) {
                    .none => {},
                    .deadline => |d| {
                        if (d.untilNow(io).raw.nanoseconds >= 0)
                            return error.Timeout;
                    },
                    .duration => unreachable,
                }

                condition_waitTimeout(
                    &mbox.cond,
                    io,
                    &mbox.mutex,
                    deadline,
                ) catch |err| switch (err) {
                    error.Timeout => return error.Timeout,
                    error.Canceled => return error.Closed,
                };
            }

            if (mbox.closed.load(.acquire)) {
                return error.Closed;
            }

            if (mbox.interrupted) {
                mbox.interrupted = false;
                return error.Interrupted;
            }

            const first = mbox.dequeue();

            if (first) |firstEnvelope| {
                // defer mbox.cond.signal(io);
                return firstEnvelope;
            } else {
                return error.Timeout;
            }
        }

        /// # of letters in internal queue.
        /// May be called also on closed mailbox.
        pub fn letters(mbox: *Self) usize {
            if (mbox.io == null or mbox.closed.load(.acquire)) return 0;

            mbox.mutex.lock(mbox.io.?) catch return 0;
            defer mbox.mutex.unlock(mbox.io.?);
            return mbox.len;
        }

        /// First close disabled further client calls and returns head of Envelopes
        /// for de-allocation
        pub fn close(mbox: *Self) ?*Envelope {
            if (mbox.closed.swap(true, .acq_rel)) return null;
            if (mbox.io == null) return null;

            mbox.mutex.lock(mbox.io.?) catch return null;
            defer mbox.mutex.unlock(mbox.io.?);

            const head = mbox.first;

            mbox.first = null;
            mbox.last = null;
            mbox.len = 0;
            mbox.interrupted = false;

            mbox.cond.broadcast(mbox.io.?);

            return head;
        }

        fn enqueue(fifo: *Self, new_Envelope: *Envelope) void {
            new_Envelope.prev = null;
            new_Envelope.next = null;

            if (fifo.len == 0) {
                std.debug.assert(fifo.first == null);
                std.debug.assert(fifo.last == null);
                fifo.first = new_Envelope;
            }

            if (fifo.last) |last| {
                last.next = new_Envelope;
                new_Envelope.prev = last;
            } else {
                fifo.first = new_Envelope;
            }

            fifo.last = new_Envelope;
            fifo.len += 1;

            return;
        }

        fn dequeue(fifo: *Self) ?*Envelope {
            if (fifo.len == 0) {
                return null;
            }

            var result = fifo.first;
            fifo.first = result.?.next;

            if (fifo.len == 1) {
                fifo.last = null;
            } else {
                fifo.first.?.prev = null;
            }

            result.?.prev = null;
            result.?.next = null;
            fifo.len -= 1;

            return result;
        }
    };
}

/// Intrusive Mailbox - Envelope must contain prev/next pointers
pub fn MailBoxIntrusive(comptime Envelope: type) type {
    return struct {
        const Self = @This();

        /// Envelope has following structure
        /// in order to be intrusive
        /// pub const T = struct {
        ///     prev: ?*T = null,
        ///     next: ?*T = null,
        ///     additional stuff
        /// };
        first: ?*Envelope = null,
        last: ?*Envelope = null,
        len: usize = 0,

        closed: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
        interrupted: bool = false,

        mutex: Io.Mutex = .init,
        cond: Io.Condition = .init,
        io: ?Io = null,

        /// Initialize mailbox with Io backend
        pub fn init(io: ?Io) Self {
            return .{
                .io = if (io == null) std.Io.Threaded.global_single_threaded.*.io() else io.?,
                .closed = std.atomic.Value(bool).init(false),
            };
        }

        /// Append a new Envelope to the tail
        /// and wake-up waiting on receive threads.
        /// Arguments:
        ///     new_Envelope: Pointer to the new Envelope to append.
        /// If mailbox was closed - returns error.Closed
        pub fn send(mbox: *Self, new_Envelope: *Envelope) error{Closed}!void {
            if (mbox.closed.load(.acquire)) return error.Closed;
            const io = mbox.io orelse return error.Closed;

            mbox.mutex.lock(io) catch return error.Closed;
            defer mbox.mutex.unlock(io);

            if (mbox.closed.load(.acquire)) return error.Closed;

            mbox.enqueue(new_Envelope);
            mbox.cond.signal(io);
        }

        /// Wake-up waiting on receive thread.
        /// If mailbox was closed - returns error.Closed
        /// If waiting was already interrupted -  - returns error.AlreadyInterrupted
        pub fn interrupt(mbox: *Self) error{ Closed, AlreadyInterrupted }!void {
            if (mbox.closed.load(.acquire)) return error.Closed;
            const io = mbox.io orelse return error.Closed;

            mbox.mutex.lock(io) catch return error.Closed;
            defer mbox.mutex.unlock(io);

            if (mbox.closed.load(.acquire)) return error.Closed;
            if (mbox.interrupted) return error.AlreadyInterrupted;

            mbox.interrupted = true;
            mbox.cond.signal(io);
        }

        /// Blocks thread  maximum timeout_ns till Envelope in head of FIFO will be available.
        /// If not available - returns error.Timeout.
        /// Otherwise removes Envelope from the head and returns it to the caller.
        /// If mailbox was closed - returns error.Closed
        /// If interrupt was issued - returns error.Interrupted
        pub fn receive(mbox: *Self, timeout_ns: u64) error{ Timeout, Closed, Interrupted }!*Envelope {
            if (mbox.closed.load(.acquire)) return error.Closed;
            const io = mbox.io orelse return error.Closed;

            const timeout = Io.Timeout{
                .duration = .{
                    .raw = .{
                        .nanoseconds = @as(i96, @intCast(timeout_ns)),
                    },
                    .clock = .real,
                },
            };

            const deadline = timeout.toDeadline(io);

            mbox.mutex.lock(io) catch return error.Closed;
            defer mbox.mutex.unlock(io);

            while (mbox.len == 0) {
                if (mbox.closed.load(.acquire))
                    return error.Closed;

                if (mbox.interrupted) {
                    mbox.interrupted = false;
                    return error.Interrupted;
                }

                switch (deadline) {
                    .none => {},
                    .deadline => |d| {
                        if (d.untilNow(io).raw.nanoseconds >= 0)
                            return error.Timeout;
                    },
                    .duration => unreachable,
                }

                condition_waitTimeout(
                    &mbox.cond,
                    io,
                    &mbox.mutex,
                    deadline,
                ) catch |err| switch (err) {
                    error.Timeout => return error.Timeout,
                    error.Canceled => return error.Closed,
                };
            }

            if (mbox.closed.load(.acquire)) return error.Closed;
            if (mbox.interrupted) {
                mbox.interrupted = false;
                return error.Interrupted;
            }

            const first = mbox.dequeue();

            if (first) |firstEnvelope| {
                // defer mbox.cond.signal(io);
                return firstEnvelope;
            } else {
                return error.Timeout;
            }
        }

        /// # of letters in internal queue.
        pub fn letters(mbox: *Self) usize {
            if (mbox.io == null or mbox.closed.load(.acquire)) return 0;
            mbox.mutex.lock(mbox.io.?) catch return 0;
            defer mbox.mutex.unlock(mbox.io.?);
            return mbox.len;
        }

        /// First close disabled further client calls and returns head of Envelopes
        /// for de-allocation
        pub fn close(mbox: *Self) ?*Envelope {
            if (mbox.closed.swap(true, .acq_rel)) return null;
            if (mbox.io == null) return null;

            mbox.mutex.lock(mbox.io.?) catch return null;
            defer mbox.mutex.unlock(mbox.io.?);

            const head = mbox.first;
            mbox.first = null;
            mbox.last = null;
            mbox.len = 0;
            mbox.interrupted = false;

            mbox.cond.broadcast(mbox.io.?);
            return head;
        }

        fn enqueue(fifo: *Self, new_Envelope: *Envelope) void {
            new_Envelope.prev = null;
            new_Envelope.next = null;

            if (fifo.len == 0) {
                std.debug.assert(fifo.first == null);
                std.debug.assert(fifo.last == null);
                fifo.first = new_Envelope;
            }

            if (fifo.last) |last| {
                last.next = new_Envelope;
                new_Envelope.prev = last;
            } else {
                fifo.first = new_Envelope;
            }

            fifo.last = new_Envelope;
            fifo.len += 1;

            return;
        }

        fn dequeue(fifo: *Self) ?*Envelope {
            if (fifo.len == 0) {
                return null;
            }

            var result = fifo.first;
            fifo.first = result.?.next;

            if (fifo.len == 1) {
                fifo.last = null;
            } else {
                fifo.first.?.prev = null;
            }

            result.?.prev = null;
            result.?.next = null;
            fifo.len -= 1;

            return result;
        }
    };
}

/// Intrusive, type-erased mailbox based on std.DoublyLinkedList.
/// The stored objects must embed `std.DoublyLinkedList.Node`.
/// const Envelope = struct {
///     // user data
///     node: std.DoublyLinkedList.Node,
/// };
pub const TypeErasedMailbox = struct {
    const Self = @This();

    pub const Node = std.DoublyLinkedList.Node;
    pub const List = std.DoublyLinkedList;

    list: List = .{
        .first = null,
        .last = null,
    },

    len: usize = 0, // tracking the length separately according to recommendation
    closed: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    interrupted: bool = false,

    mutex: Io.Mutex = .init,
    cond: Io.Condition = .init,
    io: ?Io = null,

    /// Initialize mailbox with Io backend
    pub fn init(io: ?Io) Self {
        return .{
            .io = if (io == null) std.Io.Threaded.global_single_threaded.*.io() else io.?,
            .closed = std.atomic.Value(bool).init(false),
        };
    }

    /// Append a node to the tail of the mailbox.
    /// Fails if mailbox is closed.
    pub fn send(mbox: *Self, node: *Node) error{Closed}!void {
        if (mbox.closed.load(.acquire)) return error.Closed;
        const io = mbox.io orelse return error.Closed;

        mbox.mutex.lock(io) catch return error.Closed;
        defer mbox.mutex.unlock(io);

        if (mbox.closed.load(.acquire)) return error.Closed;

        mbox.list.append(node);
        mbox.len += 1;
        mbox.cond.signal(io);
    }

    /// Interrupt a waiting receiver.
    pub fn interrupt(mbox: *Self) error{ Closed, AlreadyInterrupted }!void {
        if (mbox.closed.load(.acquire)) return error.Closed;
        const io = mbox.io orelse return error.Closed;

        mbox.mutex.lock(io) catch return error.Closed;
        defer mbox.mutex.unlock(io);

        if (mbox.closed.load(.acquire)) return error.Closed;
        if (mbox.interrupted) return error.AlreadyInterrupted;

        mbox.interrupted = true;
        mbox.cond.signal(io);
    }

    /// Receive a node from the head of the mailbox.
    /// Blocks up to `timeout_ns`.
    pub fn receive(
        mbox: *Self,
        timeout_ns: u64,
    ) error{ Timeout, Closed, Interrupted }!*Node {
        if (mbox.closed.load(.acquire)) return error.Closed;
        const io = mbox.io orelse return error.Closed;

        const timeout = Io.Timeout{
            .duration = .{
                .raw = .{
                    .nanoseconds = @as(i96, @intCast(timeout_ns)),
                },
                .clock = .real,
            },
        };

        const deadline = timeout.toDeadline(io);

        mbox.mutex.lock(io) catch return error.Closed;
        defer mbox.mutex.unlock(io);

        while (mbox.len == 0) {
            if (mbox.closed.load(.acquire))
                return error.Closed;

            if (mbox.interrupted) {
                mbox.interrupted = false;
                return error.Interrupted;
            }

            switch (deadline) {
                .none => {},
                .deadline => |d| {
                    if (d.untilNow(io).raw.nanoseconds >= 0)
                        return error.Timeout;
                },
                .duration => unreachable,
            }

            condition_waitTimeout(
                &mbox.cond,
                io,
                &mbox.mutex,
                deadline,
            ) catch |err| switch (err) {
                error.Timeout => return error.Timeout,
                error.Canceled => return error.Closed,
            };
        }

        if (mbox.closed.load(.acquire)) return error.Closed;
        if (mbox.interrupted) {
            mbox.interrupted = false;
            return error.Interrupted;
        }

        const node = mbox.list.popFirst() orelse return error.Timeout;
        mbox.len -= 1;
        // mbox.cond.signal(io);
        return node;
    }

    /// Number of queued items.
    pub fn letters(mbox: *Self) usize {
        if (mbox.io == null or mbox.closed.load(.acquire)) return 0;
        mbox.mutex.lock(mbox.io.?) catch return 0;
        defer mbox.mutex.unlock(mbox.io.?);
        return mbox.len;
    }

    /// Close mailbox.
    /// Returns the head node of the remaining list (caller cleans).
    pub fn close(mbox: *Self) ?*Node {
        if (mbox.closed.swap(true, .acq_rel)) return null;
        if (mbox.io == null) return null;

        mbox.mutex.lock(mbox.io.?) catch return null;
        defer mbox.mutex.unlock(mbox.io.?);

        const head = mbox.list.first;
        mbox.list = .{};
        mbox.len = 0;
        mbox.interrupted = false;

        mbox.cond.broadcast(mbox.io.?);
        return head;
    }
};

const std = @import("std");
const Io = std.Io;

//----------------------------------------------
// https://codeberg.org/ziglang/zig/issues/31278
//----------------------------------------------

const Condition = Io.Condition;
const Mutex = Io.Mutex;

pub const WaitTimeoutError = Io.Cancelable || Io.Timeout.Error;

/// Blocks until the condition is signaled, canceled, or the provided
/// timeout expires.
///
/// See also:
/// * `wait`
/// * `waitUncancelable`
pub fn condition_waitTimeout(cond: *Condition, io: Io, mutex: *Mutex, timeout: Io.Timeout) WaitTimeoutError!void {
    const deadline = timeout.toDeadline(io);

    var epoch = cond.epoch.load(.acquire); // `.acquire` to ensure ordered before state load

    {
        const prev_state = cond.state.fetchAdd(.{ .waiters = 1, .signals = 0 }, .monotonic);
        std.debug.assert(prev_state.waiters < std.math.maxInt(u16)); // overflow caused by too many waiters
    }

    mutex.unlock(io);
    defer mutex.lockUncancelable(io);

    while (true) {
        const result = io.futexWaitTimeout(u32, &cond.epoch.raw, epoch, deadline);

        epoch = cond.epoch.load(.acquire); // `.acquire` to ensure ordered before `state` laod

        // Even on error, try to consume a pending signal first. Otherwise a race might
        // cause a signal to get stuck in the state with no corresponding waiter.
        {
            var prev_state = cond.state.load(.monotonic);
            while (prev_state.signals > 0) {
                prev_state = cond.state.cmpxchgWeak(prev_state, .{
                    .waiters = prev_state.waiters - 1,
                    .signals = prev_state.signals - 1,
                }, .acquire, .monotonic) orelse {
                    // We successfully consumed a signal.
                    return;
                };
            }
        }

        // There are no more signals available; this was a spurious wakeup or an error. If it
        // was an error, we will remove ourselves as a waiter and return that error. If a
        // timeout was specified and the deadline has passed, we remove ourselves as a waiter
        // and return `error.Timeout`. Otherwise, we'll loop back to the futex wait.
        result catch |err| {
            const prev_state = cond.state.fetchSub(.{ .waiters = 1, .signals = 0 }, .monotonic);
            std.debug.assert(prev_state.waiters > 0); // underflow caused by illegal state
            return err;
        };
        switch (deadline) {
            .none => {},
            .deadline => |d| if (d.untilNow(io).raw.nanoseconds >= 0) {
                const prev_state = cond.state.fetchSub(.{ .waiters = 1, .signals = 0 }, .monotonic);
                assert(prev_state.waiters > 0); // underflow caused by illegal state
                return error.Timeout;
            },
            .duration => unreachable,
        }
    }
}

const math = std.math;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;
