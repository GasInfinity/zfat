const std = @import("std");
const nzfat = @import("nzfat");

// This implements a basic 'BlockDevice' backed by sequential 'sectors' of 512 bytes
// A BlockDevice which will only be mounted only needs three important functions:
// - `map`: Maps a sector of the disk into memory. It is recommended to cache maps for now as they are really frequent
// - 'commit': Syncs the written contents into the disk (May be cached by the underlying implementation). The driver will NEVER write into memory without commiting it after.
// - `unmap`: Unmaps a previous sector of the disk, it only signals to the implementation that the driver has finished using it. The unmapped block MAY be mapped shortly in the future.
// - `setLogicalBlockSize`: Currently is only used when mounting a device, to signal to the underlying implementation to switch to the requested block size or error out if unsupported.
//
// These next functions are only needed when formatting a BlockDevice:
// - `getLogicalBlockSize`: Returns the current block size or the most optimal one if it has not been set by the driver.
// - `getSize`: Returns the size (in sectors) of the block device with its current block size (i.e: getSize() * getLogicalBlockSize() would get the real size in bytes of the device)
// -------------------------------------------------------------------------------------------------------------------------
// NOTES:
// It is recommended to use block sizes of 512 or 4096. Other sizes in-between are supported but I cannot guarantee anything
const BasicBlockContext = struct {
    data: [][512]u8,

    pub const BlockSizeError = error{UnalignedSizeError};
    pub const MapError = error{};
    pub const CommitError = error{};

    pub const Sector = usize;
    // XXX: A struct like this cannot currently have a `[512]u8` for example, as the underlying FatFilesystem driver does `const sector = ...;` and the data is const so cannot create a mutable slice.
    pub const MapResult = struct {
        data: []u8,

        pub inline fn asSlice(result: MapResult) []u8 {
            return result.data;
        }
    };

    pub fn map(ctx: *BasicBlockContext, sector: Sector) MapError!MapResult {
        return MapResult{ .data = &ctx.data[sector] };
    }

    pub fn commit(ctx: *BasicBlockContext, sector: Sector, result: MapResult) CommitError!void {
        ctx.data[sector] = result.data;
    }

    pub fn unmap(_: BasicBlockContext, _: Sector, _: MapResult) void {}

    pub fn setLogicalBlockSize(_: BasicBlockContext, new_logical_block_size: usize) BlockSizeError!void {
        if (new_logical_block_size != 512) {
            return BlockSizeError.UnalignedSizeError;
        }
    }

    pub fn getLogicalBlockSize(_: BasicBlockContext) usize {
        return 512;
    }

    pub fn getSize(ctx: BasicBlockContext) usize {
        return ctx.data.len;
    }
};

// Implements a FAT Filesystem as specified in official documentation.
const Fat = nzfat.FatFilesystem(BasicBlockContext, .{
    // Configures the maximum supported FAT type, it's very important that you set this correctly as if you don't need larger cluster sizes you won't pay for them at compile-time
    // Table of compile-time stored cluster type:
    //   - .fat32 -> Stored cluster size u32
    //   - .fat16 -> Stored cluster size u16
    //   - .fat12 -> Stored cluster size u12
    // Not only it changes the stored cluster type, it also brings down code-size due to comptime dead code.
    .maximum_supported_type = .fat32,

    // A value of `null` means no support for long filenames. As above, it's recommended to not use long filenames if not needed as it brings down code-size greatly.
    .long_filenames = .{
        // Self-explanatory, supported lengths of less characters affects the size of some structures (as an entry will span more sectors) but it's not recommended to change this unless it's really needed.
        .maximum_supported_len = 255,

        // Implements the conversion of the system codepage to UTF-16 and the comparison of UTF-16 strings. The default one ONLY and ONLY handles Ascii-insensitive comparison
        // .context =
    },

    // Implements basic toUpper and toLower functions that must return `struct{ BoundedArray(u8, N), ?bool };`, the first return being the converted character and the second whether it was lower, upper or non-alpha (null)
    // Why do we need to return a BoundedArray? Cursed DBCS FAT volumes exist and you may want to interop with them...
    // The default one ONLY and ONLY handles Ascii conversions, leaving the upper 128 characters unchanged.
    // .codepage_context =

    // The only supported option right now, maybe in the future a static and dynamic caches will be implemented
    .cache = .none,
});

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .safety = true }){};
    defer _ = gpa.deinit();

    const alloc = gpa.allocator();

    // Emulate a standard 1.44MB floppy disk
    const data = alloc.alloc([512]u8, 2880);
    var blk = BasicBlockContext{ .data = data };

    // This will make a FAT12 filesystem with some predefined parameters as 1.44MB floppy disks are well known.
    // But you can try to make a FAT16 filesystem or even FAT32! However it is advised against and an error will be returned if there are not enough clusters.
    try nzfat.format.make(&blk, .{
        // The only mandatory config
        .volume_id = [_]u8{ 0x00, 0x00, 0x00, 0x00 },
    });

    // See nzfat.zig for all possible MountError values
    var fat_ctx = try Fat.mount(&blk);

    // Now we have a fat context! (if no error has happened hopefully)
    // All operations you'd want are supported! From creating and deleting files/dirs to searching inside a directory and iterating it. Even moving files without copying (That includes renaming files)!
    // You can write and read to and from files in a very zig-inspired way!

    // Any directory entry converted to a file or dir MUST NOT be used after being converted as they won't be updated (Maybe instead store a pointer to the entry instead of copying?)
    // This creates a short directory entry inside '/' (null dir means root), the new entry is a file with an initial size of "Hello World!".len (WARNING: Left uninitialized!)
    // If you try to iterate the directory from Windows NT, you'll see that the filename will be lowercase as we handle those flags also! NOTE: Make this configurable?
    var created_file = (try fat_ctx.createShort(&blk, null, "short.txt", .{
        .type = .{ .file = "Hello World!".len },
    })).toFile();

    // Write the data we allocated before
    try created_file.writeAll(&fat_ctx, &blk, "Hello World!");

    // Now unmount the FAT filesystem gracefully and signal that no errors occurred.
    try fat_ctx.unmount(&blk, true);

    // There you have! You just created a FAT12 filesystem and added a file named SHORT.TXT with the contents 'Hello World!'
    // As you have seen not a single byte of heap memory has been allocated by the underlying implementation as it only reads and writes from the block device
}
