const Server = @import("server.zig").Server;
const std = @import("std");
const wlr = @import("wlroots");
const Toplevel = @import("toplevel.zig").Toplevel;

pub const Layout = struct {
    name: []const u8,
    boxs: [15][4]f64, // 15: 5 different splits maximum for each workspace for now
};

pub fn sumSize(n: usize) usize {
    var sum: usize = 0;
    var i: usize = 1;
    while (n >= i) : (i += 1) {
        sum += i;
    }
    return sum;
}

pub fn refreshLayout(server: *Server, layout_idx: usize) void {
    const num = server.toplevels.length();
    if (num == 0) return;
    const origin = sumSize(num - 1);
    // const ending=sumSize(num);
    const boxs = server.layouts.items[layout_idx].boxs;
    var screen: wlr.Box = undefined;
    server.output_layout.getBox(null, &screen);
    const width: f64 = @floatFromInt(screen.width);
    const height: f64 = @floatFromInt(screen.height);
    var it = server.toplevels.iterator(.forward);
    var i: usize = 0;
    while (it.next()) |toplvl| {
        const x_f: f64 = width * boxs[origin + i][0];
        const y_f: f64 = height * boxs[origin + i][1];
        const w_f: f64 = width * boxs[origin + i][2];
        const h_f: f64 = height * boxs[origin + i][3];
        toplvl.x = @intFromFloat(x_f);
        toplvl.y = @intFromFloat(y_f);
        _ = toplvl.xdg_toplevel.setSize(@intFromFloat(w_f), @intFromFloat(h_f));
        toplvl.scene_tree.node.setPosition(toplvl.x, toplvl.y);
        i += 1;
    }
}

pub fn loadLayouts(server: *Server) !void {
    const allocator = std.heap.page_allocator;
    const home_dir = std.posix.getenv("HOME") orelse return error.MissingHomeDir;
    const file_path = try std.fs.path.join(allocator, &.{ home_dir, ".config", "blake", "layouts.json" });
    defer allocator.free(file_path);
    var file = try std.fs.openFileAbsolute(file_path, .{});
    defer file.close();
    const buffer = try file.readToEndAlloc(allocator, 4096);
    defer allocator.free(buffer);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, buffer, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;

    var it = obj.iterator();
    while (it.next()) |entry| {
        const tableKey = entry.key_ptr;
        const tableValue = entry.value_ptr;
        const outerArray = tableValue.array;

        var layout = Layout{
            .name = try allocator.dupe(u8, tableKey.*),
            .boxs = .{.{0.0} ** 4} ** 15,
        };
        var i: usize = 0;
        var l: usize = 0;
        while (i < outerArray.items.len) : (i += 1) {
            const outerSet = outerArray.items[i];
            const innerArray = outerSet.array;
            var j: usize = 0;
            while (j < innerArray.items.len) : (j += 1) {
                const innerSet = innerArray.items[j];
                const quadruple = innerSet.array;
                var k: usize = 0;
                while (k < quadruple.items.len) : (k += 1) {
                    const numVal = quadruple.items[k];
                    const num = switch (numVal) {
                        .float => numVal.float,
                        else => {
                            std.debug.print("All values for proportionality must be of the form 1.0, 0.0, and values in between them.\n", .{});
                            continue;
                        },
                    };
                    layout.boxs[l][k] = num;
                }
                l += 1;
            }
        }
        try server.layouts.append(layout);
    }
}
