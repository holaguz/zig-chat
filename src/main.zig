const std = @import("std");

const AppParameters = struct {
    port: u16,
};

const Client = struct {
    socket: std.os.socket_t,
    addr: std.net.Address,

    const HashMapKey = struct {
        addr: std.net.Ip4Address,
    };

    pub fn key(self: Client) HashMapKey {
        return HashMapKey{ .addr = self.addr.in };
    }
};

var app_params = AppParameters{
    .port = 8080,
};

pub fn parseArgs(args: [][:0]u8) !void {
    // TODO: Crash on unknown args, print usage, etc
    const argc = args.len;

    var i: usize = 1;
    while (i < argc) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--port")) {
            app_params.port = std.fmt.parseUnsigned(u16, args[i + 1], 10) catch |err| {
                std.log.err("Couldn't parse port: {s}\n", .{args[i + 1]});
                return err;
            };
            i += 1;
        } else {
            return error.InvalidArgument;
        }
    }
}

pub fn startServer() !std.os.socket_t {
    const socket = try std.os.socket(std.os.AF.INET, std.os.SOCK.STREAM | std.os.SOCK.NONBLOCK, 0);
    const address = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, app_params.port);
    const len = address.getOsSockLen();
    try std.os.bind(socket, &address.any, len);
    try std.os.listen(socket, 128);

    return socket;
}

pub fn acceptClient(server_socket: std.os.socket_t) !Client {
    var client_addr: std.net.Address = undefined;
    var len: std.os.socklen_t = @sizeOf(std.os.sockaddr.in);
    const client_socket = try std.os.accept(server_socket, &client_addr.any, &len, std.os.SOCK.NONBLOCK);

    return Client{ .socket = client_socket, .addr = client_addr };
}

pub fn killClients() void {
    // TODO
}

pub fn receiveMessage(client_socket: *std.os.socket_t) ?[]u8 {
    var buffer: [256]u8 = undefined;
    const received = std.os.recv(client_socket.*, &buffer, 0) catch |err| {
        if (err != error.WouldBlock) {
            std.log.err("Error receiving message: {any}\n", .{err});
        }
        return null;
    };

    if (received == 0) {
        return null;
    }

    return buffer[0..received];
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const allocator = arena.allocator();
    defer arena.deinit();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    try parseArgs(args);

    const serverSocket = try startServer();
    defer std.os.close(serverSocket);

    // If we don't kill the clients the server socket will linger on
    defer killClients();

    var client_list = std.AutoArrayHashMap(Client.HashMapKey, std.os.socket_t).init(allocator);
    defer client_list.deinit();

    const buffer = try allocator.alloc(u8, 1024);
    defer allocator.free(buffer);

    while (true) {
        while (acceptClient(serverSocket)) |c| {
            std.log.info("Accepted new client: {}", .{c.addr.in});

            client_list.put(c.key(), c.socket) catch |err| {
                std.log.err("Couldn't store client: {any}\n", .{err});
            };
        } else |err| {
            if (err != error.WouldBlock) {
                std.log.err("Error accepting client: {any}\n", .{err});
            }
        }

        // Handle received messages
        var it = client_list.iterator();

        while (it.next()) |item| {
            const socket = item.value_ptr;
            const addr = item.key_ptr.*;
            if (receiveMessage(socket)) |msg| {
                std.log.info("{} said: {s}", .{
                    addr.addr,
                    msg[0 .. msg.len - 1],
                });
            }
        }

        std.time.sleep(1E9 * 0.1);
    }
}
