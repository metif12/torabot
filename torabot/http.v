module torabot

import net.ssl
import strconv
import time

// HttpResponse is a parsed HTTP/1.1 response.
pub struct HttpResponse {
pub:
	status_code int
	headers     map[string]string
	body        string
}

// header returns the value of key, matched case-insensitively, or an empty
// string when the header is absent.
pub fn (r &HttpResponse) header(key string) string {
	lower := key.to_lower()
	for k, v in r.headers {
		if k.to_lower() == lower {
			return v
		}
	}
	return ''
}

// HttpRequest describes one request to send.
pub struct HttpRequest {
pub:
	method  string
	host    string
	path    string
	headers map[string]string
	body    string
}

// max_response_bytes caps how much of a response is buffered, so a malformed
// or hostile Content-Length cannot exhaust memory. Discord's largest responses
// (a full channel history page) are well under this.
const max_response_bytes = 32 * 1024 * 1024

// default_read_timeout bounds how long a single read may block.
const default_read_timeout = 30 * time.second

// do_request performs a single HTTPS request over an mbedTLS-backed connection.
//
// V's net.http uses Schannel on Windows, which fails the TLS handshake against
// Discord with SEC_E_INTERNAL_ERROR (0x80090308). net.ssl defaults to mbedTLS,
// which negotiates with Discord correctly, so this module speaks just enough
// HTTP/1.1 itself to avoid the broken backend.
pub fn do_request(req &HttpRequest) !HttpResponse {
	mut conn := ssl.new_ssl_conn(ssl.SSLConnectConfig{
		read_timeout: default_read_timeout
	}) or {
		return error('ssl setup failed: ${err}')
	}

	conn.dial(req.host, 443) or {
		return error('tls handshake with ${req.host} failed: ${err}')
	}
	defer {
		conn.close() or {}
	}

	conn.write(build_wire_request(req).bytes()) or {
		return error('sending request failed: ${err}')
	}

	raw := read_all(mut conn) or { return err }
	return parse_response(raw)
}

// build_wire_request renders the request as HTTP/1.1 wire format.
fn build_wire_request(req &HttpRequest) string {
	mut sb := []string{}
	sb << '${req.method} ${req.path} HTTP/1.1'
	// Host is required by HTTP/1.1 and is what Discord routes on.
	sb << 'Host: ${req.host}'
	for k, v in req.headers {
		if k.to_lower() == 'host' {
			continue
		}
		sb << '${k}: ${v}'
	}
	sb << 'Content-Length: ${req.body.len}'
	// Discord closes the connection after each response, which keeps this
	// client stateless and avoids pooling logic.
	sb << 'Connection: close'
	sb << ''
	sb << req.body
	return sb.join('\r\n')
}

// read_all reads the socket until the peer closes it, honouring the timeout
// configured on the connection.
fn read_all(mut conn &ssl.SSLConn) !string {
	mut parts := []string{}
	mut chunk := []u8{len: 16384}
	mut total := 0
	for {
		n := conn.read(mut chunk) or {
			// A clean EOF mid-body means the response ended early; surface
			// whatever arrived so the caller can report it.
			break
		}
		if n <= 0 {
			break
		}
		total += n
		if total > max_response_bytes {
			return error('response exceeded ${max_response_bytes} bytes')
		}
		parts << chunk[..n].bytestr()
	}
	if total == 0 {
		return error('server closed the connection without sending a response')
	}
	return parts.join('')
}

// parse_response splits an HTTP/1.1 response into status, headers and body.
// Chunked transfer encoding is decoded, since Discord uses it for some
// endpoints when the body length is not known up front.
fn parse_response(raw string) !HttpResponse {
	mut sep_index := -1
	mut header_len := 0
	mut crlf_i := raw.index('\r\n\r\n') or { -1 }
	mut lf_i := raw.index('\n\n') or { -1 }
	if crlf_i >= 0 && (lf_i < 0 || crlf_i <= lf_i) {
		sep_index = crlf_i
		header_len = crlf_i + 4
	} else if lf_i >= 0 {
		sep_index = lf_i
		header_len = lf_i + 2
	}
	if sep_index < 0 {
		return error('malformed response: no header terminator in ${raw.len} bytes')
	}

	head := raw[..sep_index]
	mut rest := raw[header_len..]

	lines := head.split_into_lines()
	if lines.len == 0 {
		return error('malformed response: empty status line')
	}

	status_code := parse_status_code(lines[0]) or {
		return error('malformed status line: ${lines[0]}')
	}

	mut headers := map[string]string{}
	for i in 1 .. lines.len {
		line := lines[i].trim_space()
		if line == '' {
			continue
		}
		mut parts := line.split_nth(':', 2)
		if parts.len != 2 {
			continue
		}
		headers[parts[0].trim_space()] = parts[1].trim_space()
	}

	if headers['Transfer-Encoding'].to_lower().contains('chunked') {
		rest = decode_chunked(rest)
	}

	return HttpResponse{
		status_code: status_code
		headers:     headers
		body:        rest
	}
}

// parse_status_code extracts the numeric status from a status line such as
// `HTTP/1.1 200 OK`.
fn parse_status_code(status_line string) ?int {
	mut parts := status_line.split(' ')
	if parts.len < 2 {
		return none
	}
	return parts[1].i64()
}

// decode_chunked reassembles a chunked transfer-encoded body.
fn decode_chunked(body string) string {
	mut out := []string{}
	mut rest := body
	for {
		crlf_i := rest.index('\r\n') or { -1 }
		lf_i := rest.index('\n') or { -1 }
		line_end := if crlf_i >= 0 && (lf_i < 0 || crlf_i <= lf_i) { crlf_i } else { lf_i }
		if line_end < 0 {
			break
		}
		mut size_text := rest[..line_end].trim_space()
		skip := if crlf_i >= 0 && (lf_i < 0 || crlf_i <= lf_i) { 2 } else { 1 }
		rest = rest[line_end + skip..]
		// A chunk size may carry chunk extensions after a semicolon.
		size_text = size_text.split(';')[0]
		size := strconv.parse_int(size_text, 16, 64) or { 0 }
		if size <= 0 {
			break
		}
		end := if size > rest.len { rest.len } else { size }
		out << rest[..end]
		rest = if end + 2 <= rest.len { rest[end + 2..] } else { '' }
	}
	return out.join('')
}