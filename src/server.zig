//! Server handles connections between the host and clients.
//! After a client has succesfully connected, the server will ensure
//! the request is being parsed and validated. It will then dispatch
//! that request to a user-provided request handler before sending a
//! response to the client and closing the connection.

const std = @import("std");
const root = @import("root");
const Request = @import("Request.zig");
const Response = @import("Response.zig");
const net = std.net;
const Allocator = std.mem.Allocator;
const atomic = std.atomic;

/// Scoped logging, prepending [lemon_pie] to our logs.
const log = std.log.scoped(.lemon_pie);

/// User API function signature of a request handler
pub const Handle = fn handle(*Response, Request) anyerror!void;

/// Allows users to set the max buffer size before we allocate memory on the heap to store our data
const max_buffer_size = blk: {
    const given = if (@hasDecl(root, "buffer_size")) root.buffer_size else 1024 * 64; // 64kB (16 pages)
    break :blk std.math.min(given, 1024 * 1024 * 16); // max stack size (16MB)
};

/// Initializes a new `Server` instance and starts listening to a new connection.
/// On exit, will cleanup any resources that were allocated.
///
/// This will use default options when initializing a `Server`, apart from the address.
///
/// If more options are required, such as maximum amount of connections, the ability to quit, etc,
/// then initialize a new `Server` manually by calling `run` and providing the options.
pub fn listenAndServe(
    gpa: *Allocator,
    /// Address the server will bind to.
    address: net.Addres,
    /// User-defined handler that provides access to a `Response`
    /// and a parsed-and-validated `Request`.
    comptime handler: Handle,
) !void {
    try (Server.init()).run(gpa, address, .{ .reuse_address = true }, handler);
}

/// The server handles the connection between the host and the clients.
/// Ensures requests are valid before dispatching to the user and provides
/// safe response handling.
pub const Server = struct {
    should_quit: atomic.Atomic(bool),

    /// Options to control the server
    pub const Options = struct {
        /// When false, disallows to reuse an address until full exit.
        reuse_address: bool = false,
        /// Maximum amount of connections before clients receiving "connection refused".
        comptime max_backlog: u32 = 128,
    };

    /// Initializes a new `Server`
    pub fn init() Server {
        return .{ .should_quit = atomic.Atomic(bool).init(false) };
    }

    /// Tell the server to shutdown gracefully
    pub fn shutdown(self: *Server) void {
        self.should_quit.store(true, .SeqCst);
    }

    /// Starts the server by listening for new connections.
    /// At shutdown, will cleanup any resources that were allocated.
    pub fn run(
        self: *Server,
        /// Allocations are required when the response body is larger
        /// than `max_buffer_size`.
        gpa: *Allocator,
        /// Address to listen on
        address: net.Address,
        /// Options to fine-type the server
        comptime options: Options,
        /// User-defined handler that provides access to a `Response`
        /// and a parsed-and-validated `Request`.
        comptime handler: Handle,
    ) !void {
        _ = gpa;
        var stream = net.StreamServer.init(.{
            .reuse_address = options.reuse_address,
            .max_backlog = options.max_backlog,
        });
        defer stream.deinit();

        defer while (client_count > 0) : (client_count -= 1) {};

        try stream.listen(address);

        var clients: [options.max_backlog]Client(handler) = undefined;
        var client_count: u32 = 0;
        while (!self.should_quit.load(.SeqCst)) {
            var connection = stream.accept() catch |err| switch (err) {
                error.ConnectionResetByPeer,
                error.ConnectionAborted,
                => {
                    log.err("Could not accept connection: '{s}'", .{@errorName(err)});
                    continue;
                },
                else => |e| return e,
            };

            var client: Client(handler) = .{
                .stream = connection.stream,
                .frame = undefined,
            };
            clients[client_count] = client;
            client_count += 1;
            client.frame = async client.run(gpa);
        }
    }
};

/// Generates a generic `Client` type, providing access to a user-defined `Handle`
fn Client(comptime handler: Handle) type {
    return struct {
        const Self = @This();

        /// Reference to its own run function's frame, ensures its
        /// lifetime is extends to `Client`'s own lifetime.
        frame: @Frame(run),
        /// Connection with the client
        stream: net.Stream,

        fn run(self: *Self, gpa: *Allocator) void {
            self.serve(gpa) catch |err| {
                log.err("An error occured handling request: '{s}'", .{@errorName(err)});
                if (@errorReturnTrace()) |trace| {
                    std.debug.dumpStackTrace(trace.*);
                }
            };
        }

        fn serve(self: *Self, gpa: *Allocator) !void {
            _ = self;
            _ = gpa;
            _ = handler;
        }
    };
}
