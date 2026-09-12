const std = @import("std");
const core_symcrypt = @import("azure_sdk_core_symcrypt");

test "manifest-filtered package exports a usable provider" {
    try std.testing.expectEqualStrings("0.2.0", core_symcrypt.version);
    try std.testing.expectEqual(@as(u32, 103), core_symcrypt.symcrypt_version.api);

    var provider = try core_symcrypt.Provider.init();
    defer provider.deinit();
    const digest = try provider.asProvider().sha256("package consumer");
    try std.testing.expectEqual(@as(usize, 32), digest.len);
}
