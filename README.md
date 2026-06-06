![](_logo/mailboxes.png)


# Mailbox - old new way of inter-thread communication.          

[![CI](https://github.com/g41797/yazq/actions/workflows/ci.yml/badge.svg)](https://github.com/g41797/yazq/actions/workflows/ci.yml)
<img src="https://img.shields.io/badge/Linux-FCC624?style=flat&logo=linux&logoColor=black" width="48" height="24">&nbsp;
<img src="https://img.shields.io/badge/macOS-000000?style=flat&logo=apple&logoColor=white" width="48" height="24">&nbsp;
<img src="https://img.shields.io/badge/Windows-0078D6?style=flat&logo=windows&logoColor=white" width="48" height="24">&nbsp;

## A bit of history, a bit of theory

Mailboxes are one of the fundamental parts of the [actor model originated in **1973**](https://en.wikipedia.org/wiki/Actor_model): 
> An actor is an object that carries out its actions in response to communications it receives.
> Through the mailbox mechanism, actors can decouple the reception of a message from its elaboration.
> A mailbox is nothing more than the data structure (FIFO) that holds messages.

I first encountered MailBox in the late 80s while working on a real-time system: 
> "A **mailbox** is object that can be used for inter-task
communication. When task A wants to send an object to task B, task A
must send the object to the mailbox, and task B must visit the mailbox,
where, if an object isn't there, it has the option of *waiting for any
desired length of time*..." 
> **iRMX 86™ NUCLEUS REFERENCE MANUAL** _Copyright @ 1980, 1981 Intel Corporation.

Since then, I have used it in:

|     OS      | Language(s) |
|:-----------:|:-----------:|
|    iRMX     |  *PL/M-86*  |
|     AIX     |     *C*     |
|   Windows   |  *C++/C#*   |
|    Linux    |    *Go*     |

**Now it's Zig time!!!**

## Why?
If your thread runs in "Fire and Forget" mode, you don't need Mailbox.
 
But in real multithreaded applications, threads communicate with each other as
members of a work team.

**Mailbox** provides a convenient and simple inter-thread communication:
- thread safe
- asynchronous
- interruptable
- no own allocations
- unbounded
- fan-out/fan-in
  

## Example of usage - 'Echo' 
```zig
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
        pub fn start(echo: *Self, io: Io) void {
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
                // Exit from the thread if mailbox was closed
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
    echo.start(std.testing.io);
    defer echo.stop();

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
```

## Boring details

Mailbox of *[]const u8* 'Letters':
```zig
const Rumors = mailbox.MailBox([]const u8);
const rmrsMbx : Rumors = .init(io);
```

**Envelope** is a wrapper of actual user defined type **Letter**.
```zig
        pub const Envelope = struct {
            prev: ?*Envelope = null,
            next: ?*Envelope = null,
            letter: Letter,
        };
```
In fact Mailbox is a queue(FIFO) of Envelope(s).

## APIs

MailBox supports following operations:
- **init** - store Io required for internal synchronization primitives, may be _null_
- **send** *Envelope* to MailBox (*enqueue*) and wakeup waiting receiver(s)
- **receive** *Envelope* from Mailbox (*dequeue*) with time-out
- **interrupt** - wake-up receiver thread
- **close** Mailbox:
  - disables further operations
  - _first_ close returns List of non-processed *Envelope(s)* for free/reuse etc.

## Intrusive mailbox

In order to be intrusive, Envelope should look like

```zig
  pub const T = struct {
       prev: ?*T = null,
       next: ?*T = null,
       additional stuff
  };
```
Dumb example:
```zig
  const MsgU32 = struct {
      prev: ?*MsgU32 = null,
      next: ?*MsgU32 = null,
      stuff: u32 = undefined,
  };
```

_MailBoxIntrusive_ has exactly the same functionality as former _MailBox_.

For curious:
  - [What does it mean for a data structure to be "intrusive"?](https://stackoverflow.com/questions/5004162/what-does-it-mean-for-a-data-structure-to-be-intrusive)
  - [libxev intrusive queue](https://github.com/mitchellh/libxev/blob/main/src/queue.zig#L4)

## TypeErased Mailbox

**TypeErased Mailbox** is an _intrusive_ mailbox that does **not know the message type**.

This implementation relies on [De-Genericify Linked Lists](https://ziglang.org/download/0.15.1/release-notes.html#De-Genericify-Linked-Lists) introduced in Zig 0.15.1.  

In order to work with **_TypeErased Mailbox_** each message must embed a linked list node:
```zig
const Msg = struct {
  <your data>
  node: std.DoublyLinkedList.Node,
};
```

Example:
```zig
    const Node = std.DoublyLinkedList.Node;
    const Mbx = mailbox.TypeErasedMailbox;

    // Message envelope (intrusive)
    const Msg = struct {
        value: usize = 0,
        node: Node = .{},
    };

    var mbox: Mbx = .init(null); // used std.Io.Threaded.global_single_threaded.*.io()

    var msg: Msg = .{
        .value = 1,
    };

    _ = try mbox.send(&msg.node);

    const node: *Node = try mbox.receive(1000);
    const rcvdMsg: *Msg = @fieldParentPtr("node", node);
    var shouldBeOne: usize = rcvdMsg.*.value;
```
_TypeErasedMailbox_ has exactly the same functionality as former _MailBox_.

## Eat your own dog food  

I am using _MailBox_ in own projects:
- [multithreaded tests](https://github.com/g41797/syslog/blob/main/src/syslog_tests.zig)
- [message pool](https://github.com/g41797/nats/blob/main/src/messages.zig#L222)
- [itc](https://github.com/g41797/tofu)


## Installation

With an existing Zig project, adding Mailbox to it is easy:

1. Add mailbox to your `build.zig.zon`
2. Add mailbox to your `build.zig`

To add mailbox to `build.zig.zon` run the following from your project root:

```sh
zig fetch --save=mailbox git+https://github.com/g41797/mailbox
```


Then, in your `build.zig`'s `build` function, add the following before
`b.installArtifact(exe)`:

```zig
    const mailbox = b.dependency("mailbox", .{
        .target = target,
        .optimize = optimize,
    });

    exe.root_module.addImport("mailbox", mailbox.module("mailbox"));
```
From then on, you can use the Mailbox package in your code:
```zig
    const mailbox = @import("mailbox");
```


## License
[MIT](LICENSE)

## Last warning
First rule of multithreading:
>**If you can do without multithreading - do without.**
<br>    

*Powered by*  [![clion](_logo/CLion_icon.png)][refclion]

[refclion]: https://www.jetbrains.com/clion/


