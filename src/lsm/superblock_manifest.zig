const std = @import("std");
const assert = std.debug.assert;
const log = std.log.scoped(.superblock_manifest);
const mem = std.mem;

const config = @import("../config.zig");

pub const SuperBlockManifest = struct {
    checksums: []u128,
    addresses: []u64,
    trees: []u8,

    count: u32,
    count_max: u32,

    pub fn init(allocator: mem.Allocator, count_max: u32) !SuperBlockManifest {
        const checksums = try allocator.alloc(u128, count_max);
        errdefer allocator.free(checksums);

        const addresses = try allocator.alloc(u64, count_max);
        errdefer allocator.free(addresses);

        const trees = try allocator.alloc(u8, count_max);
        errdefer allocator.free(trees);

        mem.set(u128, checksums, 0);
        mem.set(u64, addresses, 0);
        mem.set(u8, trees, 0);

        return SuperBlockManifest{
            .checksums = checksums,
            .addresses = addresses,
            .trees = trees,
            .count = 0,
            .count_max = count_max,
        };
    }

    pub fn deinit(manifest: *SuperBlockManifest, allocator: mem.Allocator) void {
        allocator.free(manifest.checksums);
        allocator.free(manifest.addresses);
        allocator.free(manifest.trees);
    }

    pub fn encode(manifest: *const SuperBlockManifest, target: []align(@alignOf(u128)) u8) u64 {
        assert(target.len > 0);
        assert(target.len % @sizeOf(u128) == 0);

        var size: u64 = 0;

        const checksums = target[size..][0 .. manifest.count * @sizeOf(u128)];
        mem.copy(u128, mem.bytesAsSlice(u128, checksums), manifest.checksums[0..manifest.count]);
        size += checksums.len;

        const addresses = target[size..][0 .. manifest.count * @sizeOf(u64)];
        mem.copy(u64, mem.bytesAsSlice(u64, addresses), manifest.addresses[0..manifest.count]);
        size += addresses.len;

        const trees = target[size..][0 .. manifest.count * @sizeOf(u8)];
        mem.copy(u8, mem.bytesAsSlice(u8, trees), manifest.trees[0..manifest.count]);
        size += trees.len;

        mem.set(u8, target[size..], 0);

        assert(@divExact(size, BlockReferenceSize) == manifest.count);

        return size;
    }

    pub fn decode(manifest: *SuperBlockManifest, source: []align(@alignOf(u128)) const u8) void {
        manifest.count = @intCast(u32, @divExact(source.len, BlockReferenceSize));
        assert(manifest.count <= manifest.count_max);

        var size: u64 = 0;

        const checksums = source[size..][0 .. manifest.count * @sizeOf(u128)];
        mem.copy(u128, manifest.checksums[0..manifest.count], mem.bytesAsSlice(u128, checksums));
        size += checksums.len;

        const addresses = source[size..][0 .. manifest.count * @sizeOf(u64)];
        mem.copy(u64, manifest.addresses[0..manifest.count], mem.bytesAsSlice(u64, addresses));
        size += addresses.len;

        const trees = source[size..][0 .. manifest.count * @sizeOf(u8)];
        mem.copy(u8, manifest.trees[0..manifest.count], mem.bytesAsSlice(u8, trees));
        size += trees.len;

        assert(size == source.len);

        mem.set(u128, manifest.checksums[manifest.count..], 0);
        mem.set(u64, manifest.addresses[manifest.count..], 0);
        mem.set(u8, manifest.trees[manifest.count..], 0);

        if (config.verify) manifest.verify();
    }

    pub fn append(manifest: *SuperBlockManifest, tree: u8, checksum: u128, address: u64) void {
        assert(address > 0);

        if (config.verify) {
            assert(manifest.find(tree, checksum, address) == null);
        }

        if (manifest.count == manifest.count_max) {
            @panic("superblock manifest: out of space");
        }

        manifest.checksums[manifest.count] = checksum;
        manifest.addresses[manifest.count] = address;
        manifest.trees[manifest.count] = tree;

        manifest.count += 1;

        log.debug("append: tree={} checksum={} address={} count={}/{}", .{
            tree,
            checksum,
            address,
            manifest.count,
            manifest.count_max,
        });

        if (config.verify) {
            if (manifest.find(tree, checksum, address)) |index| {
                assert(index == manifest.count - 1);
                assert(manifest.checksums[index] == checksum);
                assert(manifest.addresses[index] == address);
                assert(manifest.trees[index] == tree);
            } else {
                unreachable;
            }

            manifest.verify();
        }
    }

    pub fn remove(manifest: *SuperBlockManifest, tree: u8, checksum: u128, address: u64) void {
        assert(address > 0);

        if (manifest.find(tree, checksum, address)) |index| {
            assert(index < manifest.count);
            assert(manifest.checksums[index] == checksum);
            assert(manifest.addresses[index] == address);
            assert(manifest.trees[index] == tree);

            const tail = manifest.count - (index + 1);
            mem.copy(u128, manifest.checksums[index..], manifest.checksums[index + 1 ..][0..tail]);
            mem.copy(u64, manifest.addresses[index..], manifest.addresses[index + 1 ..][0..tail]);
            mem.copy(u8, manifest.trees[index..], manifest.trees[index + 1 ..][0..tail]);

            manifest.count -= 1;

            manifest.checksums[manifest.count] = 0;
            manifest.addresses[manifest.count] = 0;
            manifest.trees[manifest.count] = 0;

            log.debug("remove: tree={} checksum={} address={} count={}/{}", .{
                tree,
                checksum,
                address,
                manifest.count,
                manifest.count_max,
            });

            if (config.verify) {
                assert(manifest.find(tree, checksum, address) == null);
                manifest.verify();
            }
        } else {
            unreachable;
        }
    }

    pub fn find(manifest: *const SuperBlockManifest, tree: u8, checksum: u128, address: u64) ?u32 {
        assert(address > 0);

        var index: u32 = 0;
        while (index < manifest.count) : (index += 1) {
            if (manifest.checksums[index] != checksum) continue;
            if (manifest.addresses[index] != address) continue;
            if (manifest.trees[index] != tree) continue;

            return index;
        }

        return null;
    }

    pub const BlockReference = struct {
        checksum: u128,
        address: u64,
        tree: u8,
    };

    pub const BlockReferenceSize = @sizeOf(u128) + @sizeOf(u64) + @sizeOf(u8);

    pub const IteratorReverse = struct {
        manifest: *const SuperBlockManifest,
        tree: u8,
        count: u32,

        pub fn next(it: *IteratorReverse) ?BlockReference {
            assert(it.count <= it.manifest.count);

            while (it.count > 0) {
                it.count -= 1;

                if (it.manifest.trees[it.count] == it.tree) {
                    assert(it.manifest.addresses[it.count] > 0);

                    return BlockReference{
                        .checksum = it.manifest.checksums[it.count],
                        .address = it.manifest.addresses[it.count],
                        .tree = it.manifest.trees[it.count],
                    };
                }
            }
            return null;
        }
    };

    /// Return all block references for a given tree in reverse order, latest-appended-first-out.
    /// Using a reverse iterator is an optimization to avoid redundant updates to tree manifests.
    pub fn iterator_reverse(manifest: *const SuperBlockManifest, tree: u8) IteratorReverse {
        return IteratorReverse{
            .manifest = manifest,
            .tree = tree,
            .count = manifest.count,
        };
    }

    pub fn verify(manifest: *const SuperBlockManifest) void {
        assert(manifest.count <= manifest.count_max);
        assert(manifest.count <= manifest.count_max);
        assert(manifest.count <= manifest.count_max);

        assert(manifest.checksums.len == manifest.count_max);
        assert(manifest.addresses.len == manifest.count_max);
        assert(manifest.trees.len == manifest.count_max);

        for (manifest.checksums[manifest.count..]) |checksum| assert(checksum == 0);

        for (manifest.addresses[0..manifest.count]) |address| assert(address > 0);
        for (manifest.addresses[manifest.count..]) |address| assert(address == 0);

        for (manifest.trees[manifest.count..]) |tree| assert(tree == 0);
    }
};

fn test_iterator_reverse(
    manifest: *SuperBlockManifest,
    tree: u8,
    expect: []const SuperBlockManifest.BlockReference,
) !void {
    const expectEqualSlices = std.testing.expectEqualSlices;

    var reverse: [3]SuperBlockManifest.BlockReference = undefined;
    var reverse_count: usize = 0;

    var it = manifest.iterator_reverse(tree);
    while (it.next()) |block| {
        reverse[reverse_count] = block;
        reverse_count += 1;
    }

    try expectEqualSlices(SuperBlockManifest.BlockReference, expect, reverse[0..reverse_count]);
}

fn test_codec(manifest: *SuperBlockManifest) !void {
    const testing = std.testing;
    const expectEqual = testing.expectEqual;
    const expectEqualSlices = testing.expectEqualSlices;

    var target_a: [32]u128 = undefined;
    const size_a = manifest.encode(mem.sliceAsBytes(&target_a));
    try expectEqual(
        @as(u64, manifest.count * (@sizeOf(u128) + @sizeOf(u64) + @sizeOf(u8))),
        size_a,
    );

    // Test that the decoded instance matches the original instance:
    var decoded = try SuperBlockManifest.init(testing.allocator, manifest.count_max);
    defer decoded.deinit(testing.allocator);

    decoded.decode(mem.sliceAsBytes(&target_a)[0..size_a]);

    try expectEqualSlices(u128, manifest.checksums, decoded.checksums);
    try expectEqualSlices(u64, manifest.addresses, decoded.addresses);
    try expectEqualSlices(u8, manifest.trees, decoded.trees);
    try expectEqual(manifest.count_max, decoded.count_max);
    try expectEqual(manifest.count, decoded.count);

    // Test that the decoded instance encodes correctly:
    var target_b: [32]u128 = undefined;
    const size_b = decoded.encode(mem.sliceAsBytes(&target_b));
    try expectEqual(size_a, size_b);
    try expectEqualSlices(
        u8,
        mem.sliceAsBytes(&target_a)[0..size_a],
        mem.sliceAsBytes(&target_b)[0..size_b],
    );
}

test {
    const testing = std.testing;
    const expectEqual = testing.expectEqual;

    var manifest = try SuperBlockManifest.init(testing.allocator, 3);
    defer manifest.deinit(testing.allocator);

    for (manifest.checksums) |checksum| try expectEqual(@as(u128, 0), checksum);
    for (manifest.addresses) |address| try expectEqual(@as(u64, 0), address);
    for (manifest.trees) |tree| try expectEqual(@as(u8, 0), tree);

    // The arguments to append()/remove() are: tree, checksum, address
    // These will be named variables and should be clear where we use them for real.
    manifest.append(1, 2, 3);
    try expectEqual(@as(?u32, 0), manifest.find(1, 2, 3));

    manifest.append(2, 3, 4);
    try expectEqual(@as(?u32, 1), manifest.find(2, 3, 4));

    manifest.append(1, 4, 5);
    try expectEqual(@as(?u32, 2), manifest.find(1, 4, 5));

    try test_iterator_reverse(
        &manifest,
        1,
        &[_]SuperBlockManifest.BlockReference{
            .{ .checksum = 4, .address = 5, .tree = 1 },
            .{ .checksum = 2, .address = 3, .tree = 1 },
        },
    );

    try test_iterator_reverse(
        &manifest,
        2,
        &[_]SuperBlockManifest.BlockReference{
            .{ .checksum = 3, .address = 4, .tree = 2 },
        },
    );

    try test_codec(&manifest);

    manifest.remove(1, 2, 3);
    try expectEqual(@as(?u32, null), manifest.find(1, 2, 3));
    try expectEqual(@as(?u32, 0), manifest.find(2, 3, 4));
    try expectEqual(@as(?u32, 1), manifest.find(1, 4, 5));

    try expectEqual(@as(u128, 0), manifest.checksums[2]);
    try expectEqual(@as(u64, 0), manifest.addresses[2]);
    try expectEqual(@as(u8, 0), manifest.trees[2]);

    manifest.append(1, 2, 3);
    try expectEqual(@as(?u32, 2), manifest.find(1, 2, 3));

    manifest.remove(1, 4, 5);
    try expectEqual(@as(?u32, null), manifest.find(1, 4, 5));
    try expectEqual(@as(?u32, 1), manifest.find(1, 2, 3));

    manifest.remove(2, 3, 4);
    try expectEqual(@as(?u32, null), manifest.find(2, 3, 4));
    try expectEqual(@as(?u32, 0), manifest.find(1, 2, 3));

    manifest.remove(1, 2, 3);
    try expectEqual(@as(?u32, null), manifest.find(1, 2, 3));
    try expectEqual(@as(?u32, null), manifest.find(2, 3, 4));
    try expectEqual(@as(?u32, null), manifest.find(1, 4, 5));

    for (manifest.checksums) |checksum| try expectEqual(@as(u128, 0), checksum);
    for (manifest.addresses) |address| try expectEqual(@as(u64, 0), address);
    for (manifest.trees) |tree| try expectEqual(@as(u8, 0), tree);

    try expectEqual(@as(u32, 0), manifest.count);
    try expectEqual(@as(u32, 3), manifest.count_max);
}