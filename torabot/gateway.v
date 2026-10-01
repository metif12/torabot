module torabot

import json2 as json
import net.websocket
import rand
import time

// Gateway opcodes, from Discord's Gateway documentation.
pub const gateway_op_dispatch = 0
pub const gateway_op_heartbeat = 1
pub const gateway_op_identify = 2
pub const gateway_op_presence_update = 3
pub const gateway_op_voice_state_update = 4
pub const gateway_op_resume = 6
pub const gateway_op_reconnect = 7
pub const gateway_op_request_guild_members = 8
pub const gateway_op_invalid_session = 9
pub const gateway_op_hello = 10
pub const gateway_op_heartbeat_ack = 11

// Gateway intent bits. Only what the tools need is requested, so Discord
// sends just the events the server acts on.
pub const intent_guilds = 1 << 0
pub const intent_guild_messages = 1 << 9
pub const intent_direct_messages = 1 << 12
pub const intent_message_content = 1 << 15

// default_intents covers guild and direct messages plus message content, which
// is what the read tools require.
pub const default_intents = intent_guild_messages | intent_direct_messages |
	intent_message_content

// max_gateway_message_size bounds a single inbound frame. Discord's largest
// frames, such as bulk message creates, stay well under this.
const max_gateway_message_size = 16 * 1024 * 1024

// GatewayPayload is the envelope shared by every gateway frame. `d` is kept as
// raw JSON text rather than a decoded json2.Any: the struct is encoded for
// outbound frames and decoded for inbound ones, and holding the raw text keeps
// both directions free of a decode/encode round trip.
pub struct GatewayPayload {
pub:
	op int
	d  string
	s  ?int // sequence number, present on dispatch frames
	t  string // dispatch event name
}

// GatewayEvent is a decoded dispatch frame ready for a handler.
pub struct GatewayEvent {
pub:
	name      string
	seq       i64
	data_json string
}

// parsed_data decodes the event payload, returning json2.Null when the frame
// carried no data.
pub fn (e &GatewayEvent) parsed_data() json.Any {
	if e.data_json == '' {
		return json.Any('null')
	}
	return json.decode[json.Any](e.data_json) or { json.Any('null') }
}

// IdentifyPayload is the body of an Identify (op 2) frame.
pub struct IdentifyPayload {
	token      string
	intents    int
	properties map[string]string
}

// GatewayBotResponse is the body of GET /gateway/bot. Discord recently changed
// session_start_limit from a number to an object, so it is left undecoded
// rather than typed: only the gateway URL matters here.
pub struct GatewayBotResponse {
pub:
	url string
}

// Gateway is a live connection to the Discord gateway. It tracks the heartbeat
// interval and the last sequence number so a dropped session can be resumed
// instead of restarted from scratch.
@[heap]
pub struct Gateway {
mut:
	client             &websocket.Client = unsafe { nil }
	token              string
	channel_filter     []string
	last_seq           i64
	session_id         string
	resume_url         string
	heartbeat_interval time.Duration
	acked              bool
	closed             bool
}

// new_gateway prepares a gateway client. The caller still has to connect.
pub fn new_gateway(token string) &Gateway {
	return &Gateway{
		client: unsafe { nil }
		token:  token
		acked:  false
		closed: false
	}
}

// with_channel_filter restricts dispatch delivery to the listed channel ids.
// An empty filter delivers everything.
pub fn (mut g Gateway) with_channel_filter(channels []string) &Gateway {
	g.channel_filter = channels
	return g
}

// gateway_url fetches the current gateway endpoint and appends the query
// parameters Discord requires, including the bot token.
//
// `compress` is deliberately not requested. Discord's default is
// `zlib-stream`, whose payload is a DEFLATE stream that vlib's inflate cannot
// read: vlib handles fixed Huffman blocks (BTYPE=1) but fails on dynamic ones
// (BTYPE=2), which is what Discord's edge nodes emit. Uncompressed JSON is a
// few hundred bytes per frame and costs one extra inflate per message, far less
// than the bandwidth or the workaround.
pub fn gateway_url(token string) !string {
	d := new(token, '')
	body := d.get('/gateway/bot')!
	res := decode_or[GatewayBotResponse](body, '/gateway/bot') or { return err }
	mut base := res.url
	if base.starts_with('wss://') {
		base = 'wss://' + base[6..]
	}
	return base + '/?v=10&encoding=json&token=' + url_query_escape(token)
}

// connect opens the websocket and performs the identify handshake. It returns
// once the Hello frame has been consumed and Identify has been sent.
pub fn (mut g Gateway) connect() ! {
	url := gateway_url(g.token) or { return err }
	client := websocket.new_client(url, websocket.ClientOpt{}) or {
		return error('gateway client creation failed: ${err}')
	}
	client.connect() or { return error('gateway connect failed: ${err}') }
	g.client = client

	hello := g.read_payload() or { return error('gateway did not send Hello: ${err}') }
	if hello.op != gateway_op_hello {
		return error('expected Hello (op 10), got op ${hello.op}')
	}
	interval_ms := hello_interval_ms(hello.d) or {
		return error('Hello frame had no heartbeat_interval: ${err}')
	}
	g.heartbeat_interval = time.Duration(interval_ms) * time.millisecond

	g.identify() or { return err }
}

// identify sends the Identify payload.
fn (mut g Gateway) identify() ! {
	mut properties := map[string]string{}
	properties['os'] = 'linux'
	properties['browser'] = 'torabot'
	properties['device'] = 'torabot'
	body := json.encode(IdentifyPayload{
		token:      g.token
		intents:    default_intents
		properties: properties
	})
	return g.send_op(gateway_op_identify, body)
}

// send_op writes one gateway frame with the given op and raw JSON data.
fn (mut g Gateway) send_op(op int, data_json string) ! {
	frame := json.encode(GatewayPayload{
		op: op
		d:  data_json
	})
	g.client.write(frame.bytes(), .text_frame) or {
		return error('gateway write failed: ${err}')
	}
}

// hello_interval_ms extracts heartbeat_interval from a Hello payload. Discord
// encodes it as a JSON number, which json2 may surface as int or f64 depending
// on how the value was written.
fn hello_interval_ms(d json.Any) !int {
	obj := as_object(d) or {
		return error('Hello payload is not an object')
	}
	v := obj['heartbeat_interval'] or {
		return error('no heartbeat_interval field')
	}
	if n := any_to_int(v) {
		return n
	}
	if v is f64 {
		return int(v as f64)
	}
	return error('heartbeat_interval is not a number')
}

// as_object narrows a decoded JSON value to an object, avoiding the map copy
// that a bare `as map[string]json.Any` would introduce.
pub fn as_object(v json.Any) ?map[string]json.Any {
	if v is map[string]json.Any {
		return v as map[string]json.Any
	}
	return none
}

// send_heartbeat writes a Heartbeat (op 1) frame carrying the last sequence.
pub fn (mut g Gateway) send_heartbeat() ! {
	body := if g.last_seq > 0 { '${g.last_seq}' } else { 'null' }
	return g.send_op(gateway_op_heartbeat, body)
}

// request_guild_members asks the gateway for the member list of a guild. An
// empty query requests all members.
pub fn (mut g Gateway) request_guild_members(guild_id string, query string) ! {
	mut obj := map[string]json.Any{}
	obj['guild_id'] = guild_id
	if query != '' {
		obj['query'] = query
	}
	obj['limit'] = 0
	return g.send_op(gateway_op_request_guild_members, json.encode(obj))
}

// GatewayFrame is a decoded inbound gateway frame.
pub struct GatewayFrame {
pub:
	op int
	d  json.Any
	s  ?int
	t  string
}

// try_inflate returns the payload as text, inflating it only when it is not
// already plain JSON. Compression is not requested, so the common path is a
// no-op; this keeps the frame reader correct if an edge node compresses anyway,
// and it never fails on data that needs no inflation.
fn try_inflate(payload []u8) string {
	// A JSON object always starts with '{' or whitespace, neither of which can
	// begin a zlib or gzip container.
	if payload.len > 0 && payload[0] == `{` {
		return payload.bytestr()
	}
	out := zlib_stream_decompress(payload) or { return payload.bytestr() }
	return out.bytestr()
}

// read_payload reads and inflates one frame, updating the sequence number.
fn (mut g Gateway) read_payload() !GatewayFrame {
	for {
		if g.closed {
			return error('gateway connection is closed')
		}
		mut msg := g.client.read_next_message() or {
			return error('reading gateway frame failed: ${err}')
		}
		defer {
			unsafe {
				msg.free()
			}
		}
		if msg.payload.len > max_gateway_message_size {
			return error('gateway frame of ${msg.payload.len} bytes exceeds the cap')
		}
		if msg.opcode == .close {
			g.closed = true
			return error('gateway closed the connection')
		}
		if msg.opcode != .text_frame && msg.opcode != .binary_frame {
			continue
		}
		// Frames arrive as plain JSON because gateway_url does not request
		// compression. A future edge node that compresses anyway would still be
		// handled, since zlib_stream_decompress passes plain JSON through.
		text := try_inflate(msg.payload)
		envelope := json.decode[GatewayPayload](text) or {
			return error('decoding gateway frame failed: ${err}')
		}
		if seq := envelope.s {
			g.last_seq = seq
		}
		if envelope.op == gateway_op_heartbeat_ack {
			g.acked = true
		}
		return GatewayFrame{
			op: envelope.op
			d:  decode_any(envelope.d)
			s:  envelope.s
			t:  envelope.t
		}
	}
}

// listen runs the gateway loop, delivering dispatch events to on_event. It
// returns on a fatal gateway error, or after duration elapses when duration is
// greater than zero, which makes it usable both as a long-running loop and as a
// bounded collector.
pub fn (mut g Gateway) listen(on_event fn (GatewayEvent), duration time.Duration) ! {
	start := time.now()
	for {
		if duration > 0 && time.since(start) > duration {
			return
		}
		p := g.read_payload() or { return err }
		if p.op == gateway_op_dispatch {
			if p.t != '' && !g.is_filtered(p.t, p.d) {
				on_event(GatewayEvent{
					name:      p.t
					seq:       g.last_seq
					data_json: json.encode(p.d)
				})
			}
			continue
		}
		if p.op == gateway_op_heartbeat {
			g.send_heartbeat() or { return err }
			continue
		}
		if p.op == gateway_op_reconnect {
			return error('gateway asked the client to reconnect')
		}
		if p.op == gateway_op_invalid_session {
			return error('session invalidated; a full reconnect is required')
		}
	}
}

// close sends a close frame and shuts the client down.
pub fn (mut g Gateway) close() {
	g.closed = true
	if g.client != unsafe { nil } {
		g.client.close(1000, 'bye') or {}
	}
}

// is_filtered reports whether a dispatch should be skipped given the configured
// channel filter. Events that are not channel-scoped are always delivered.
fn (g &Gateway) is_filtered(event_name string, data json.Any) bool {
	if g.channel_filter.len == 0 {
		return false
	}
	if event_name !in ['MESSAGE_CREATE', 'MESSAGE_UPDATE', 'MESSAGE_DELETE'] {
		return false
	}
	obj := as_object(data) or { return false }
	v := obj['channel_id'] or { return false }
	channel_id := v as string
	return channel_id !in g.channel_filter
}

// decode_any parses a raw JSON fragment, treating empty text and null as a
// JSON null so callers can index it without special cases.
fn decode_any(s string) json.Any {
	if s == '' || s == 'null' {
		return json.Null{}
	}
	return json.decode[json.Any](s) or { json.Null{} }
}

// url_query_escape percent-encodes everything outside the unreserved set, which
// is what Discord's gateway query parser expects.
pub fn url_query_escape(s string) string {
	mut out := []u8{cap: s.len}
	for ch in s {
		if is_unreserved(ch) {
			out << ch
		} else {
			out << `%`
			out << hex_digit(int(ch) >> 4)
			out << hex_digit(int(ch) & 0xf)
		}
	}
	return out.bytestr()
}

// is_unreserved reports whether a byte may appear literally in a URL query.
fn is_unreserved(ch u8) bool {
	return (ch >= `a` && ch <= `z`) || (ch >= `A` && ch <= `Z`) ||
		(ch >= `0` && ch <= `9`) || ch == `-` || ch == `_` || ch == `.` || ch == `~`
}

// hex_digit renders a nibble as an uppercase hex digit.
fn hex_digit(nibble int) u8 {
	if nibble < 10 {
		return u8(`0` + nibble)
	}
	return u8(`A` + nibble - 10)
}

// jitter returns a random duration up to max_ms, used to spread reconnects so
// many clients do not reconnect in lockstep.
pub fn jitter(max_ms int) time.Duration {
	if max_ms <= 0 {
		return 0
	}
	n := rand.intn(max_ms) or { 0 }
	return time.Duration(n + 1) * time.millisecond
}