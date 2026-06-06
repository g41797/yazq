// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

//-----------------------------
test {
    @import("std").testing.refAllDecls(@This());
}
//-----------------------------

//-----------------------------
test "basic MailBox test" {
    const Mbx = mailbox.MailBox(u32);
    var mbox: Mbx = .init(io);

    try testing.expectError(error.Timeout, mbox.receive(10));

    var one = Mbx.Envelope{ .letter = 1 };
    var two = Mbx.Envelope{ .letter = 2 };
    var three = Mbx.Envelope{ .letter = 3 };
    var four = Mbx.Envelope{ .letter = 4 };
    var five = Mbx.Envelope{ .letter = 5 };

    try mbox.send(&one);
    try mbox.send(&two);
    try mbox.send(&three);
    try mbox.send(&four);
    try mbox.send(&five);

    try testing.expect(mbox.letters() == 5);

    try mbox.interrupt();
    try testing.expectError(error.Interrupted, mbox.receive(10));

    for (1..6) |i| {
        const recv = mbox.receive(1000);

        if (recv) |val| {
            try testing.expect(val.letter == i);
        } else |_| {
            try testing.expect(false);
        }
    }

    try testing.expectError(error.Timeout, mbox.receive(10));

    try mbox.interrupt();
    _ = mbox.close();
    try testing.expectError(error.Closed, mbox.receive(10));
}
//-----------------------------

//-----------------------------
test "Echo mailboxes test" {

    // Mbx is Mailbox with usize letter(data)
    const Mbx = mailbox.MailBox(usize);

    // Echo - runs on own thread
    // It has two mailboxes
    // "TO" and "FROM" - from the client point of the view
    // Receives letter via 'TO' mailbox
    // Replies letter without change (echo) to "FROM" mailbox
    const Echo = struct {
        const Self = @This();

        to: Mbx = undefined,
        from: Mbx = undefined,
        thread: Thread = undefined,

        // Mailboxes creation and start of the thread
        // Pay attention, that client code does not use
        // any thread "API" - all embedded within Echo
        pub fn start(echo: *Self) void {
            echo.to = .init(io);
            echo.from = .init(io);
            echo.thread = std.Thread.spawn(.{}, run, .{echo}) catch unreachable;
        }

        // Echo thread function
        fn run(echo: *Self) void {
            // Main loop:
            while (true) {
                // Receive - exit from the thread if mailbox was closed
                const envelope = echo.to.receive(100000000) catch break;
                // Reply to the client
                // Exit from the thread if mailbox was closed or interrupted
                _ = echo.from.send(envelope) catch break;
            }
        }

        // Wait exit from the thread
        pub fn waitFinish(echo: *Self) void {
            echo.thread.join();
        }

        // Close mailboxes
        // As result Echo should stop processing
        // and exit from the thread.
        pub fn stop(echo: *Self) !void {
            _ = echo.to.close();
            _ = echo.from.close();
        }
    };

    var echo = try std.testing.allocator.create(Echo);

    // Start Echo(on own thread)
    echo.start();

    defer {
        // Wait finish of Echo
        echo.waitFinish();
        std.testing.allocator.destroy(echo);
    }

    // because nothing was send to 'TO' mailbox, nothing should be received
    // from 'FROM' mailbox
    try testing.expectError(error.Timeout, echo.from.receive(100));

    // Create wrapper for the data
    const envl = try std.testing.allocator.create(Mbx.Envelope);
    defer std.testing.allocator.destroy(envl);

    // Send/Receive loop
    for (0..6) |indx| {
        // Set value for send [0-5]
        envl.letter = indx;

        // Send to 'TO' mailbox
        try echo.to.send(envl);

        // Wait received data from OUT mailbox
        const back = echo.from.receive(1000000);

        if (back) |val| {
            // Expected value == index [0-5]
            try testing.expect(val.letter == indx);
        } else |_| {
            try testing.expect(false);
        }
    }

    // Stop Echo
    try echo.stop();
}

test "compilation MailBoxIntrusive test" {
    const Mbx = mailbox.MailBoxIntrusive(MsgU32);
    var mbox: Mbx = .init(io);
    try testing.expectError(error.Timeout, mbox.receive(10));

    try mbox.interrupt();
    try testing.expectError(error.Interrupted, mbox.receive(10));
}

const MsgU32 = struct {
    prev: ?*MsgU32 = null,
    next: ?*MsgU32 = null,
    stuff: u32 = undefined,
};

//-----------------------------
test "basic TypeErased test" {
    const Node = std.DoublyLinkedList.Node;
    const Mbx = mailbox.TypeErasedMailbox;

    // Message envelope (intrusive)
    const Msg = struct {
        value: usize = 0,
        node: Node = .{},
    };

    var mbox: Mbx = .init(io);

    try testing.expectError(error.Timeout, mbox.receive(1000));

    var one: Msg = .{
        .value = 1,
    };
    var two: Msg = .{
        .value = 2,
    };
    var three: Msg = .{
        .value = 3,
    };
    var four: Msg = .{
        .value = 4,
    };
    var five: Msg = .{
        .value = 5,
    };

    try mbox.send(&one.node);
    try mbox.send(&two.node);
    try mbox.send(&three.node);
    try mbox.send(&four.node);
    try mbox.send(&five.node);

    try testing.expect(mbox.letters() == 5);

    try mbox.interrupt();
    try testing.expectError(error.Interrupted, mbox.receive(10));

    for (1..6) |i| {
        const recv = mbox.receive(1000);

        if (recv) |node| {
            const rcvd: *Msg = @fieldParentPtr("node", node);
            try testing.expect(rcvd.*.value == i);
        } else |_| {
            try testing.expect(false);
        }
    }

    try testing.expectError(error.Timeout, mbox.receive(10));

    try mbox.interrupt();
    _ = mbox.close();
    try testing.expectError(error.Closed, mbox.receive(10));
}
//-----------------------------

test "Echo TypeErased mailboxes test" {
    const Node = std.DoublyLinkedList.Node;
    const Mailbox = mailbox.TypeErasedMailbox;

    // Message envelope (intrusive)
    const Msg = struct {
        value: usize = 0,
        node: Node = .{},
    };

    // Echo worker (runs on its own thread)
    const Echo = struct {
        const Self = @This();

        to: Mailbox = .init(null),
        from: Mailbox = .init(null),
        thread: Thread = undefined,

        pub fn start(self: *Self) void {
            self.thread = std.Thread.spawn(.{}, run, .{self}) catch unreachable;
        }

        fn run(self: *Self) void {
            while (true) {
                // Receive from TO mailbox
                const node = self.to.receive(100_000_000) catch break;

                // Echo back to FROM mailbox
                _ = self.from.send(node) catch break;
            }
        }

        pub fn stop(self: *Self) void {
            _ = self.to.close();
            _ = self.from.close();
        }

        pub fn waitFinish(self: *Self) void {
            self.thread.join();
        }
    };

    var echo: *Echo = try std.testing.allocator.create(Echo);
    echo.* = .{};
    defer {
        echo.waitFinish();
        std.testing.allocator.destroy(echo);
    }

    echo.start();

    // Nothing sent → nothing received
    try testing.expectEqual(0, echo.from.list.len());
    try testing.expectError(error.Timeout, echo.from.receive(100));

    // Send / receive loop
    for (0..6) |i| {
        const msg = try std.testing.allocator.create(Msg);
        msg.* = .{};

        defer std.testing.allocator.destroy(msg);

        msg.*.value = i;

        // Send to TO mailbox
        try echo.to.send(&msg.node);

        // Receive echoed message
        const node = echo.from.receive(1_000_000) catch {
            try testing.expect(false);
            continue;
        };

        const back: *Msg = @fieldParentPtr("node", node);
        try testing.expect(back.*.value == i);
    }

    // Stop echo thread
    echo.stop();
}

const std = @import("std");
const testing = std.testing;
const Thread = std.Thread;
const mailbox = @import("mailbox.zig");
const io = std.testing.io;
