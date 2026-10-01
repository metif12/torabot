module torabot

import compress.deflate

// zlib_stream_decompress returns payload as text, inflating it only when it is
// not already plain JSON.
//
// The gateway is connected without compression, so frames arrive as JSON and
// this is normally a pass-through. If an edge node compresses anyway, the
// payload is inflated; if inflation fails, the original bytes are returned so
// the caller can surface the raw frame rather than losing it.
pub fn zlib_stream_decompress(payload []u8) ![]u8 {
	// A JSON object starts with '{'; neither a zlib nor a gzip container can,
	// and a raw DEFLATE stream is high-entropy rather than ASCII punctuation.
	if payload.len > 0 && payload[0] == `{` {
		return payload
	}
	return deflate.decompress(payload) or { return payload }
}