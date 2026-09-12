const std = @import("std");
const tracing = @import("root.zig");
const CryptoProvider = @import("../crypto.zig").CryptoProvider;

/// Fixed-capacity, application-drained tracing. Keep this value at a stable
/// address after obtaining its interface. Independent spans may be used from
/// different threads; mutation of a particular span is serialized here as well.
pub const ExportingTracerProvider = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    crypto: CryptoProvider,
    exporter: *tracing.SpanExporter,
    options: Options,
    entries: []Entry,
    scopes: []Scope,
    service_name: [256]u8 = undefined,
    service_name_len: usize,
    mutex: std.Io.Mutex = .init,
    management: std.Io.Mutex = .init,
    head: ?*Entry = null,
    tail: ?*Entry = null,
    closed: bool = false,
    exporter_shutdown: bool = false,
    counters: Counters = .{},
    noop: tracing.NoopTracer = .init(),
    provider: tracing.TracerProvider = .{
        .getTracerFn = getTracer,
        .recordPropagationErrorFn = propagationError,
    },

    pub const Options = struct {
        /// Active, queued, and currently exporting spans share this fixed pool.
        max_spans: usize = 128,
        max_queued_spans: usize = 128,
        max_scopes: usize = 16,
        max_retained_bytes: usize = 1024 * 1024,
        max_attributes: usize = 32,
        max_attribute_bytes: usize = 1024,
        max_batch_size: usize = 32,
        service_name: []const u8 = "unknown_service",
        /// Only used for roots. Valid parents retain their sampling decision.
        sample_roots: bool = true,
        clock: ?Clock = null,
    };

    pub const Clock = struct {
        context: *anyopaque,
        nowFn: *const fn (*anyopaque) Sample,
        pub const Sample = struct { unix_ns: u64, monotonic_ns: i128 };
    };

    pub const Counters = struct {
        started: u64 = 0,
        ended: u64 = 0,
        exported: u64 = 0,
        dropped_spans: u64 = 0,
        dropped_attributes: u64 = 0,
        export_errors: u64 = 0,
        propagation_errors: u64 = 0,
        active_spans: usize = 0,
        queued_spans: usize = 0,
        /// Reserved pool and scope storage, including currently free slots.
        retained_bytes: usize = 0,
    };

    const Scope = struct {
        owner: *ExportingTracerProvider = undefined,
        used: bool = false,
        name: [256]u8 = undefined,
        name_len: usize = 0,
        version: [64]u8 = undefined,
        version_len: usize = 0,
        tracer: tracing.Tracer = .{
            .startSpanFn = startLegacy,
            .startSpanWithOptionsFn = start,
        },
    };

    const Entry = struct {
        owner: *ExportingTracerProvider = undefined,
        state: enum { free, active, queued, exporting } = .free,
        next: ?*Entry = null,
        data: tracing.SpanData = undefined,
        attributes: [32]tracing.Attribute = undefined,
        attribute_count: usize = 0,
        storage: [4096]u8 = undefined,
        used: usize = 0,
        monotonic_start: i128 = 0,
        span: tracing.Span = .{
            .setAttributeFn = setString,
            .setTypedAttributeFn = setTyped,
            .setStatusFn = setStatus,
            .getContextFn = getContext,
            .endFn = end,
        },

        fn copy(self: *Entry, value: []const u8) ![]const u8 {
            if (value.len > self.storage.len - self.used) return error.SpanLimitExceeded;
            const result = self.storage[self.used..][0..value.len];
            @memcpy(result, value);
            self.used += value.len;
            return result;
        }
    };

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        crypto: CryptoProvider,
        exporter: *tracing.SpanExporter,
        options: Options,
    ) !ExportingTracerProvider {
        if (options.max_spans == 0 or options.max_scopes == 0 or
            options.max_queued_spans == 0 or options.max_queued_spans > options.max_spans or
            options.max_attributes > 32 or options.max_attribute_bytes == 0 or options.max_attribute_bytes > 4096 or
            options.max_batch_size == 0 or options.max_batch_size > 64 or
            options.service_name.len > 256 or !std.unicode.utf8ValidateSlice(options.service_name))
            return error.InvalidTracingLimits;
        const entry_bytes = std.math.mul(usize, options.max_spans, @sizeOf(Entry)) catch return error.InvalidTracingLimits;
        const scope_bytes = std.math.mul(usize, options.max_scopes, @sizeOf(Scope)) catch return error.InvalidTracingLimits;
        const total = std.math.add(usize, entry_bytes, scope_bytes) catch return error.InvalidTracingLimits;
        if (total > options.max_retained_bytes) return error.InvalidTracingLimits;
        const entries = try allocator.alloc(Entry, options.max_spans);
        errdefer allocator.free(entries);
        const scopes = try allocator.alloc(Scope, options.max_scopes);
        for (entries) |*entry| entry.* = .{};
        for (scopes) |*scope| scope.* = .{};
        var result: ExportingTracerProvider = .{
            .allocator = allocator,
            .io = io,
            .crypto = crypto,
            .exporter = exporter,
            .options = options,
            .entries = entries,
            .scopes = scopes,
            .service_name_len = options.service_name.len,
            .counters = .{ .retained_bytes = total },
        };
        @memcpy(result.service_name[0..options.service_name.len], options.service_name);
        // No retained slice may point back into a caller's options buffer.
        result.options.service_name = "";
        return result;
    }

    pub fn asProvider(self: *ExportingTracerProvider) *tracing.TracerProvider {
        return &self.provider;
    }

    pub fn stats(self: *ExportingTracerProvider) Counters {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.counters;
    }

    /// Discards retained data without calling the exporter. Call shutdown first
    /// to deliver it. Clients and span handles must no longer be in use.
    pub fn deinit(self: *ExportingTracerProvider) !void {
        if (!self.management.tryLock()) return error.ExportInProgress;
        defer self.management.unlock(self.io);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.counters.active_spans != 0) return error.ActiveSpans;
        self.allocator.free(self.entries);
        self.allocator.free(self.scopes);
        self.entries = &.{};
        self.scopes = &.{};
        self.closed = true;
        self.head = null;
        self.tail = null;
        self.counters.queued_spans = 0;
        self.counters.retained_bytes = 0;
    }

    /// Exports only the completion snapshot taken at entry, never live spans.
    /// Concurrent/reentrant management calls fail rather than blocking a sink.
    pub fn drain(self: *ExportingTracerProvider, timeout_ms: u64) !usize {
        if (!self.management.tryLock()) return error.ExportInProgress;
        defer self.management.unlock(self.io);
        if (self.exporter_shutdown) return error.ProviderShutdown;
        return self.drainSnapshot(tracing.ExportContext.init(self.io, timeout_ms));
    }

    pub fn forceFlush(self: *ExportingTracerProvider, timeout_ms: u64) !void {
        if (!self.management.tryLock()) return error.ExportInProgress;
        defer self.management.unlock(self.io);
        if (self.exporter_shutdown) return error.ProviderShutdown;
        const context = tracing.ExportContext.init(self.io, timeout_ms);
        _ = try self.drainSnapshot(context);
        self.exporter.forceFlush(context) catch |err| {
            self.exportError();
            return err;
        };
    }

    /// Stops new spans. ActiveSpans requires ending existing spans and retrying.
    /// With no live spans, shutdown is called once, even when export fails.
    pub fn shutdown(self: *ExportingTracerProvider, timeout_ms: u64) !void {
        if (!self.management.tryLock()) return error.ExportInProgress;
        defer self.management.unlock(self.io);
        if (self.exporter_shutdown) return;
        self.mutex.lockUncancelable(self.io);
        self.closed = true;
        const active = self.counters.active_spans;
        self.mutex.unlock(self.io);
        if (active != 0) return error.ActiveSpans;
        const context = tracing.ExportContext.init(self.io, timeout_ms);
        var failure: ?anyerror = null;
        _ = self.drainSnapshot(context) catch |err| blk: {
            failure = err;
            break :blk 0;
        };
        self.exporter.forceFlush(context) catch |err| {
            self.exportError();
            if (failure == null) failure = err;
        };
        self.exporter.shutdown(context) catch |err| {
            self.exportError();
            if (failure == null) failure = err;
        };
        self.exporter_shutdown = true;
        self.mutex.lockUncancelable(self.io);
        while (self.head) |entry| {
            self.head = entry.next;
            entry.state = .free;
            self.counters.dropped_spans +|= 1;
        }
        self.tail = null;
        self.counters.queued_spans = 0;
        self.mutex.unlock(self.io);
        if (failure) |err| return err;
    }

    fn drainSnapshot(self: *ExportingTracerProvider, context: tracing.ExportContext) !usize {
        self.mutex.lockUncancelable(self.io);
        var remaining = self.counters.queued_spans;
        self.mutex.unlock(self.io);
        var exported: usize = 0;
        var failure: ?anyerror = null;
        while (remaining > 0) {
            context.check() catch |err| {
                self.exportError();
                return err;
            };
            var entries: [64]*Entry = undefined;
            var batch: [64]tracing.SpanData = undefined;
            const count = @min(remaining, self.options.max_batch_size);
            self.mutex.lockUncancelable(self.io);
            for (0..count) |i| {
                const entry = self.head.?;
                self.head = entry.next;
                entry.state = .exporting;
                entries[i] = entry;
                batch[i] = entry.data;
            }
            if (self.head == null) self.tail = null;
            self.counters.queued_spans -= count;
            self.mutex.unlock(self.io);
            var success = true;
            self.exporter.exportBatch(batch[0..count], context) catch |err| {
                success = false;
                if (failure == null) failure = err;
            };
            self.mutex.lockUncancelable(self.io);
            for (entries[0..count]) |entry| entry.state = .free;
            if (success) {
                self.counters.exported +|= count;
                exported += count;
            } else {
                self.counters.dropped_spans +|= count;
                self.counters.export_errors +|= 1;
            }
            self.mutex.unlock(self.io);
            remaining -= count;
        }
        if (failure) |err| return err;
        return exported;
    }

    fn exportError(self: *ExportingTracerProvider) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.counters.export_errors +|= 1;
    }

    fn propagationError(provider: *tracing.TracerProvider) void {
        const self: *ExportingTracerProvider = @fieldParentPtr("provider", provider);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.counters.propagation_errors +|= 1;
    }

    fn getTracer(provider: *tracing.TracerProvider, name: []const u8, version: []const u8) *tracing.Tracer {
        const self: *ExportingTracerProvider = @fieldParentPtr("provider", provider);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.closed) return &self.noop.tracer;
        if (name.len <= 256 and version.len <= 64 and
            std.unicode.utf8ValidateSlice(name) and std.unicode.utf8ValidateSlice(version))
        {
            for (self.scopes) |*scope| {
                if (scope.used and std.mem.eql(u8, name, scope.name[0..scope.name_len]) and
                    std.mem.eql(u8, version, scope.version[0..scope.version_len])) return &scope.tracer;
            }
            for (self.scopes) |*scope| {
                if (scope.used) continue;
                scope.owner = self;
                scope.used = true;
                scope.name_len = name.len;
                scope.version_len = version.len;
                @memcpy(scope.name[0..name.len], name);
                @memcpy(scope.version[0..version.len], version);
                return &scope.tracer;
            }
        }
        self.counters.dropped_spans +|= 1;
        return &self.noop.tracer;
    }

    fn now(self: *ExportingTracerProvider) Clock.Sample {
        if (self.options.clock) |clock| return clock.nowFn(clock.context);
        const real = std.Io.Timestamp.now(self.io, .real).toNanoseconds();
        return .{
            .unix_ns = @intCast(std.math.clamp(real, 0, std.math.maxInt(u64))),
            .monotonic_ns = std.Io.Timestamp.now(self.io, .awake).toNanoseconds(),
        };
    }

    fn startLegacy(tracer: *tracing.Tracer, name: []const u8, kind: tracing.SpanKind) !*tracing.Span {
        return start(tracer, name, kind, .{});
    }

    fn start(tracer: *tracing.Tracer, name: []const u8, kind: tracing.SpanKind, options: tracing.StartOptions) !*tracing.Span {
        const scope: *Scope = @fieldParentPtr("tracer", tracer);
        const self = scope.owner;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.closed) return error.ProviderShutdown;
        errdefer self.counters.dropped_spans +|= 1;
        if (name.len > self.options.max_attribute_bytes or !std.unicode.utf8ValidateSlice(name))
            return error.SpanLimitExceeded;
        var selected: ?*Entry = null;
        for (self.entries) |*entry| {
            if (entry.state == .free) {
                selected = entry;
                break;
            }
        }
        const entry = selected orelse return error.SpanLimitExceeded;
        var bytes: [24]u8 = undefined;
        try self.crypto.randomBytes(&bytes);
        var context: tracing.TraceContext = .{
            .trace_id = std.fmt.bytesToHex(bytes[0..16].*, .lower),
            .span_id = std.fmt.bytesToHex(bytes[16..24].*, .lower),
            .trace_flags = if (self.options.sample_roots) 1 else 0,
        };
        var parent_id: ?[16]u8 = null;
        if (options.parent) |parent| {
            if (parent.isValid()) {
                context.trace_id = parent.trace_id;
                context.trace_flags = parent.trace_flags & 1;
                parent_id = parent.span_id;
                if (parent.trace_state) |state| {
                    if (tracing.TraceContext.validTracestate(state)) context.trace_state = state;
                }
            }
        }
        if (!context.isValid()) return error.InvalidTraceId;
        entry.used = 0;
        entry.attribute_count = 0;
        const owned_name = try entry.copy(name);
        if (context.trace_state) |state| context.trace_state = try entry.copy(state);
        const time = self.now();
        entry.owner = self;
        entry.monotonic_start = time.monotonic_ns;
        entry.data = .{
            .context = context,
            .parent_span_id = parent_id,
            .name = owned_name,
            .kind = kind,
            .start_time_unix_nano = time.unix_ns,
            .scope_name = scope.name[0..scope.name_len],
            .scope_version = scope.version[0..scope.version_len],
            .service_name = self.service_name[0..self.service_name_len],
        };
        entry.state = .active;
        self.counters.started +|= 1;
        self.counters.active_spans += 1;
        return &entry.span;
    }

    fn getContext(span: *tracing.Span) ?tracing.TraceContext {
        const entry: *Entry = @alignCast(@fieldParentPtr("span", span));
        entry.owner.mutex.lockUncancelable(entry.owner.io);
        defer entry.owner.mutex.unlock(entry.owner.io);
        return entry.data.context;
    }

    fn setString(span: *tracing.Span, key: []const u8, value: []const u8) !void {
        return setTyped(span, key, .{ .string = value });
    }

    fn setTyped(span: *tracing.Span, key: []const u8, value: tracing.AttributeValue) !void {
        const entry: *Entry = @alignCast(@fieldParentPtr("span", span));
        const self = entry.owner;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (entry.state != .active) return error.SpanEnded;
        if (entry.data.context.trace_flags & 1 == 0) return;
        errdefer {
            entry.data.dropped_attributes_count +|= 1;
            self.counters.dropped_attributes +|= 1;
        }
        if (key.len == 0 or key.len > self.options.max_attribute_bytes or !std.unicode.utf8ValidateSlice(key))
            return error.SpanLimitExceeded;
        var size = key.len;
        switch (value) {
            .string => |s| {
                if (s.len > self.options.max_attribute_bytes or !std.unicode.utf8ValidateSlice(s))
                    return error.SpanLimitExceeded;
                size += s.len;
            },
            .double => |d| if (!std.math.isFinite(d)) return error.InvalidAttributeValue,
            else => {},
        }
        var index = entry.attribute_count;
        for (entry.attributes[0..entry.attribute_count], 0..) |attribute, i| {
            if (std.mem.eql(u8, attribute.key, key)) {
                index = i;
                break;
            }
        }
        if ((index == entry.attribute_count and index >= self.options.max_attributes) or
            size > entry.storage.len - entry.used) return error.SpanLimitExceeded;
        const owned_key = try entry.copy(key);
        var owned_value = value;
        if (value == .string) owned_value = .{ .string = try entry.copy(value.string) };
        entry.attributes[index] = .{ .key = owned_key, .value = owned_value };
        if (index == entry.attribute_count) entry.attribute_count += 1;
        entry.data.attributes = entry.attributes[0..entry.attribute_count];
    }

    fn setStatus(span: *tracing.Span, status: tracing.SpanStatus) void {
        const entry: *Entry = @alignCast(@fieldParentPtr("span", span));
        const self = entry.owner;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (entry.state == .active) entry.data.status = status;
    }

    /// Consumes the handle. Calling any span method after end is invalid.
    fn end(span: *tracing.Span) void {
        const entry: *Entry = @alignCast(@fieldParentPtr("span", span));
        const self = entry.owner;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        std.debug.assert(entry.state == .active);
        const elapsed = std.math.clamp(self.now().monotonic_ns -| entry.monotonic_start, 0, std.math.maxInt(u64));
        entry.data.end_time_unix_nano = entry.data.start_time_unix_nano +| @as(u64, @intCast(elapsed));
        self.counters.active_spans -= 1;
        self.counters.ended +|= 1;
        if (entry.data.context.trace_flags & 1 == 0) {
            entry.state = .free;
            return;
        }
        if (self.counters.queued_spans >= self.options.max_queued_spans) {
            entry.state = .free;
            self.counters.dropped_spans +|= 1;
            return;
        }
        entry.state = .queued;
        entry.next = null;
        if (self.tail) |tail| tail.next = entry else self.head = entry;
        self.tail = entry;
        self.counters.queued_spans += 1;
    }
};

test {
    _ = @import("provider_test.zig");
}
