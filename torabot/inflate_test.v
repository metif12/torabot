module torabot

import compress.zlib

fn test_zlib_stream_decompress_passes_plain_json() {
	// Uncompressed gateway frames must pass through untouched.
	payload := '{"op":10,"d":{"heartbeat_interval":41250}}'
	out := zlib_stream_decompress(payload.bytes()) or { panic(err) }
	assert out.bytestr() == payload
}

fn test_zlib_stream_decompress_fixed_huffman() {
	// V's own zlib output uses a fixed Huffman block, which vlib can inflate.
	payload := 'hello gateway, this is a discord test payload'
	compressed := zlib.compress(payload.bytes()) or { panic('compress failed: ${err}') }
	// Strip the 2-byte zlib header and 4-byte Adler-32 trailer to get the raw
	// DEFLATE stream.
	raw := compressed[2..compressed.len - 4]
	out := zlib_stream_decompress(raw) or { panic('decompress failed: ${err}') }
	assert out.bytestr() == payload
}

fn test_is_unreserved() {
	assert is_unreserved(`a`)
	assert is_unreserved(`Z`)
	assert is_unreserved(`0`)
	assert is_unreserved(`-`)
	assert is_unreserved(`_`)
	assert is_unreserved(`.`)
	assert is_unreserved(`~`)
	assert !is_unreserved(`%`)
	assert !is_unreserved(`/`)
	assert !is_unreserved(`:`)
}

fn test_url_query_escape_leaves_token_alone() {
	// A Discord bot token is base64-ish with dots and underscores, so it should
	// pass through unescaped. This is a fabricated token, not a real one.
	token := 'MTU1NTE1.Nzg0Ghxfa.REDACTEDnotARealToken0000000000'
	assert url_query_escape(token) == token
}

fn test_url_query_escape_encodes_specials() {
	assert url_query_escape('a b') == 'a%20b'
	assert url_query_escape('a/b') == 'a%2Fb'
	assert url_query_escape('50%') == '50%25'
	assert url_query_escape('a&b=c') == 'a%26b%3Dc'
}

fn test_hex_digit() {
	assert hex_digit(0) == `0`
	assert hex_digit(9) == `9`
	assert hex_digit(10) == `A`
	assert hex_digit(15) == `F`
}