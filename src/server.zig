//! Server handles connections between the host and clients.
//! After a client has succesfully connected, the server will ensure
//! the request is being parsed and validated. It will then dispatch
//! that request to a user-provided request handler before sending a
//! response to the client and closing the connection.

const std = @import("std");
const root = @import("root");
const Request = @import("Request.zig");
const Response = @import("Response.zig");
const MimeType = @import("MimeType.zig");
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
        max_connections: u32 = 128,
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
        var clients: [options.max_connections]Client(handler) = undefined;
        var client_count: u32 = 0;

        // initialize our tcp server and start listening
        var stream = net.StreamServer.init(.{
            .reuse_address = options.reuse_address,
            .kernel_backlog = options.max_connections,
        });
        try stream.listen(address);

        // Make sure to await any open connections
        defer while (client_count > 0) : (client_count -= 1) {
            await clients[client_count].frame;
        } else stream.deinit();

        // main loop, awaits new connections and dispatches them
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

            // initialize our client.
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

        /// Wraps `server` by catching its error and logging it to stderr.
        /// Will also print the error trace in debug modes.
        /// NOTE: It will not shutdown the server on an error, it will simply close
        /// the connection with the client.
        fn run(self: *Self, gpa: *Allocator) void {
            self.serve(gpa) catch |err| {
                log.err("An error occured handling request: '{s}'", .{@errorName(err)});
                if (@errorReturnTrace()) |trace| {
                    std.debug.dumpStackTrace(trace.*);
                }
            };
        }

        /// Handles the request and response of a transaction.
        /// It will first parse and validate the request.
        /// On success it will call the user-defined handle to allow
        /// the user to customize the response. `serve` ensures the response
        /// is sent to the client by checking if `is_flushed` is set on the `Response`.
        fn serve(self: *Self, gpa: *Allocator) !void {
            // After each transaction, we close the connection.
            defer self.stream.close();

            const buffered_writer = std.io.bufferedWriter(self.stream.writer());
            var body_writer = std.ArrayList(u8).init(gpa);
            defer body_writer.deinit();

            var response = Response{
                .buffered_writer = buffered_writer,
                .body = body_writer.writer(),
            };

            var request_buf: [1026]u8 = undefined;
            const request = Request.parse(self.stream.reader(), &request_buf) catch |err| switch (err) {
                error.EndOfStream,
                error.ConnectionResetByPeer,
                error.ConnectionTimedOut,
                => return, // connection was closed/timedout.
                error.BufferTooSmall => unreachable,
                error.MissingCRLF,
                error.MissingUri,
                error.UriTooLong,
                => {
                    // Client has sent an invalid request. Send a response to inform them and close
                    // the connection.
                    try response.writeHeader(.bad_request, "Malformed request");
                    return;
                },
                else => |e| {
                    // Unhandable error, simply return it and log it.
                    // But do attempt to send a temporary failure response.
                    try response.writeHeader(.temporary_failure, "Unexpected error. Retry later.");
                    return e;
                },
            };

            // call user-defined handle.
            handler(&response, request) catch |err| {
                // An error occured in the user's function. As we do not know the reason it failed,
                // simply tell the client to try again later.
                try response.writeHeader(.temporary_failure, "Unexpected error. Retry later.");
                return err;
            };

            // Ensure the response is sent to the client.
            if (!response.is_flushed) {
                try response.flush(MimeType.fromExtension(".gmi"));
            }
        }
    };
}

test "Full transaction" {
    // We rely on multi-threading for the test
    if (std.builtin.single_threaded) return error.SkipZigTest;

    const ally = std.testing.allocator;
    const addr = try net.Address.parseIp("0.0.0.0", 8081);
    var server = Server.init();

    const ServerThread = struct {
        var _addr: net.Address = undefined;

        fn index(response: *Response, req: Request) !void {
            _ = req;
            try response.body.writeAll("Hello, world!");
        }

        fn runServer(ctx: *Server) !void {
            try ctx.run(ally, _addr, .{ .reuse_address = true }, index);
        }
    };
    ServerThread._addr = addr;

    const thread = try std.Thread.spawn(.{}, ServerThread.runServer, &server);
    errdefer server.shutdown();

    var stream = while (true) {
        var conn = net.tcpConnectToAddress(addr) catch |err| switch (err) {
            error.ConnectionRefused => continue,
            else => |e| return e,
        };

        break conn;
    } else unreachable;

    errdefer stream.close();

    // tell server to shutdown
    // Will finish the current request and then shutdown
    server.shutdown();
    try stream.writer().writeAll("gemini://localhost\r\n");
    var buf: [1024]u8 = undefined;
    const len = try stream.reader().read(&buf);
    stream.close();
    thread.join();

    const content = buf[0..len];
    try std.testing.expectEqualStrings("20", buf[0..2]);
    const body_index = std.mem.indexOf(u8, content, "\r\n").?;
    try std.testing.expectEqualStrings("Hello, world!", content[body_index + 2 ..]);
}
