module torabot

fn test_parse_status_code() {
	assert parse_status_code('HTTP/1.1 200 OK') or { -1 } == 200
	assert parse_status_code('HTTP/1.1 404 Not Found') or { -1 } == 404
	assert parse_status_code('HTTP/1.1 429 Too Many Requests') or { -1 } == 429
}

fn test_parse_status_code_malformed() {
	assert parse_status_code('garbage') == none
	assert parse_status_code('') == none
}

fn test_parse_response_simple() {
	raw := 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 13\r\n\r\n{"url":"x"}!!'
	resp := parse_response(raw) or { return }
	assert resp.status_code == 200
	assert resp.body == '{"url":"x"}!!'
	assert resp.header('Content-Type') == 'application/json'
}

fn test_parse_response_header_lookup_is_case_insensitive() {
	raw := 'HTTP/1.1 200 OK\r\nX-RateLimit-Remaining: 4\r\n\r\n{}'
	resp := parse_response(raw) or { return }
	assert resp.header('x-ratelimit-remaining') == '4'
	assert resp.header('X-RateLimit-Remaining') == '4'
	assert resp.header('missing') == ''
}

fn test_parse_response_no_headers() {
	resp := parse_response('HTTP/1.1 204 No Content\r\n\r\n') or { return }
	assert resp.status_code == 204
	assert resp.body == ''
}

fn test_parse_response_missing_terminator() {
	if _ := parse_response('HTTP/1.1 200 OK\r\nContent-Type: text/plain') {
		assert false, 'expected an error for a response with no header terminator'
	}
}

fn test_parse_response_chunked() {
	// Two chunks then the terminator.
	raw := 'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n' +
		'5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n'
	resp := parse_response(raw) or { return }
	assert resp.body == 'hello world'
}

fn test_parse_response_chunked_with_extension() {
	raw := 'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n' +
		'5;name=value\r\nhello\r\n0\r\n\r\n'
	resp := parse_response(raw) or { return }
	assert resp.body == 'hello'
}

fn test_build_wire_request_includes_host_and_length() {
	req := HttpRequest{
		method:  'POST'
		host:    'discord.com'
		path:    '/api/v10/x'
		headers: {'Authorization': 'Bot t'}
		body:    'abc'
	}
	wire := build_wire_request(req)
	assert wire.starts_with('POST /api/v10/x HTTP/1.1\r\n')
	assert wire.contains('Host: discord.com')
	assert wire.contains('Authorization: Bot t')
	assert wire.contains('Content-Length: 3')
	assert wire.ends_with('\r\n\r\nabc')
}