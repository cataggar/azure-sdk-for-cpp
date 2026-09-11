//! Canonical HTTP facade for Azure SDK Core.

const transport = @import("http/transport.zig");
const pipeline = @import("http/pipeline.zig");
const runtime = @import("http/runtime.zig");
const decompression = @import("http/decompression.zig");

pub const Method = transport.Method;
pub const RedirectPolicy = transport.RedirectPolicy;
pub const Request = transport.Request;
pub const RequestHeaders = transport.RequestHeaders;
pub const ResponseHeader = transport.ResponseHeader;
pub const ResponseHeaders = transport.ResponseHeaders;
pub const Response = transport.Response;
pub const CancellationToken = transport.CancellationToken;
pub const StreamingRequestBody = transport.StreamingRequestBody;
pub const ReplayableBytes = transport.ReplayableBytes;
pub const OpenOptions = transport.OpenOptions;
pub const OperationState = transport.OperationState;
pub const HttpOperation = transport.HttpOperation;
pub const HttpTransport = transport.HttpTransport;
pub const StdHttpTransport = transport.StdHttpTransport;
pub const MockTransport = transport.MockTransport;
pub const SequenceMockTransport = transport.SequenceMockTransport;

pub const HttpRuntime = runtime.HttpRuntime;
pub const HttpPolicy = pipeline.HttpPolicy;
pub const HttpPipeline = pipeline.HttpPipeline;
pub const TelemetryPolicy = pipeline.TelemetryPolicy;
pub const LoggingPolicy = pipeline.LoggingPolicy;
pub const RetryPolicy = pipeline.RetryPolicy;
pub const BearerTokenAuthPolicy = pipeline.BearerTokenAuthPolicy;
pub const RequestIdPolicy = pipeline.RequestIdPolicy;
pub const TracingPolicy = pipeline.TracingPolicy;
pub const ensureRequestId = pipeline.ensureRequestId;
pub const DecompressionPolicy = decompression.DecompressionPolicy;

/// WASI HTTP transport, available only on `wasm32-wasi`.
pub const wasi = if (@import("builtin").target.cpu.arch == .wasm32 and
    @import("builtin").target.os.tag == .wasi)
    @import("http/wasi_http.zig")
else
    struct {};

test {
    @import("std").testing.refAllDecls(@This());
}
