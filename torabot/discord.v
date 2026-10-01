module torabot

import json2 as json
import os
import time

// default_api_base is Discord's current stable REST version.
const default_api_base = '/api/v10'

// default_host is the Discord API hostname.
const default_host = 'discord.com'

// max_messages_per_page is the largest page size Discord accepts for message
// history endpoints. Larger values are rejected with a 400.
const max_messages_per_page = 100

// max_rate_limit_wait_seconds bounds how long a rate-limit sleep may last before
// the call gives up and reports the throttle to the caller instead.
const max_rate_limit_wait_seconds = 30.0

// Discord channel type constants, from the Channel resource documentation.
pub const channel_type_guild_text = 0
pub const channel_type_guild_voice = 2
pub const channel_type_guild_category = 4
pub const channel_type_guild_announcement = 5
pub const channel_type_announcement_thread = 10
pub const channel_type_public_thread = 11
pub const channel_type_private_thread = 12
pub const channel_type_guild_stage_voice = 13
pub const channel_type_guild_directory = 14
pub const channel_type_guild_forum = 15
pub const channel_type_guild_media = 16

// ApiError is the failure mode shared by every Discord call: a transport
// failure or a non-2xx HTTP response carrying Discord's own message. It
// implements IError so it can travel through V's Result type and be recovered
// with an `err is &ApiError` check at the call site.
pub struct ApiError implements IError {
pub:
	status_code int
	message     string
	path        string
}

// msg returns the human-readable error, as required by IError.
pub fn (e &ApiError) msg() string {
	return 'discord api error ${e.status_code} on ${e.path}: ${e.message}'
}

// code returns the HTTP status code, as required by IError.
pub fn (e &ApiError) code() int {
	return e.status_code
}

// str lets an ApiError be interpolated directly.
pub fn (e &ApiError) str() string {
	return e.msg()
}

// transport_error wraps a low-level transport or decode failure as an ApiError
// with status_code 0, so that every failure shares one error type.
fn transport_error(path string, msg string) &ApiError {
	return &ApiError{
		status_code: 0
		message:     msg
		path:        path
	}
}

// decode_or decodes a JSON body into T, converting any decode failure into an
// ApiError tagged with path. This keeps Discord's decode errors on the same
// error channel as its HTTP errors.
fn decode_or[T](body string, path string) !T {
	return json.decode[T](body) or { return transport_error(path, 'decode failed: ${err}') }
}

// Guild is a Discord server the bot has been invited to.
pub struct Guild {
pub:
	id   string
	name string
}

// User is a Discord account. Only fields observable by the bot are kept.
pub struct User {
pub:
	id          string
	username    string
	global_name string
	bot         bool
}

// Channel is a guild text, voice, category, forum or thread channel.
pub struct Channel {
pub:
	id        string
	name      string
	kind      int
	parent_id string
	topic     string
}

// Message is a single Discord message flattened to the fields worth reading.
pub struct Message {
pub:
	id         string
	channel_id string
	author_id  string
	username   string
	content    string
	ts         i64
}

// Discord is a REST client for the Discord API authenticated with a bot token.
pub struct Discord {
	token     string
	host      string
	base_path string
}

// new creates a Discord client. api_base may be empty to use Discord's current
// stable API version; api_base is a path such as `/api/v10`.
pub fn new(token string, api_base string) &Discord {
	return &Discord{
		token:     token
		host:      default_host
		base_path: if api_base == '' { default_api_base } else { api_base }
	}
}

// from_env builds a client from the DISCORD_TOKEN environment variable, and
// optionally DISCORD_API_BASE.
pub fn from_env() !&Discord {
	token := os.getenv('DISCORD_TOKEN')
	if token == '' {
		return error('DISCORD_TOKEN is not set')
	}
	return new(token, os.getenv('DISCORD_API_BASE'))
}

// current_user returns the authenticated bot's user object. This is the
// cheapest call that proves a token is valid and has the right intents.
pub fn (d &Discord) current_user() !User {
	path := '/users/@me'
	body := d.get(path)!
	return decode_or[User](body, path)
}

// list_guilds returns every server the bot is currently a member of.
pub fn (d &Discord) list_guilds() ![]Guild {
	path := '/users/@me/guilds'
	body := d.get(path)!
	return decode_or[[]Guild](body, path)
}

// list_channels returns all channels of a guild, including categories, voice
// channels and threads.
pub fn (d &Discord) list_channels(guild_id string) ![]Channel {
	path := '/guilds/${guild_id}/channels'
	body := d.get(path)!
	return decode_or[[]Channel](body, path)
}

// list_channels_by_type returns only the guild's channels whose type is in
// types, which keeps voice and thread noise out of the result.
pub fn (d &Discord) list_channels_by_type(guild_id string, types []int) ![]Channel {
	all := d.list_channels(guild_id)!
	mut out := []Channel{cap: all.len}
	for c in all {
		if types.contains(c.kind) {
			out << c
		}
	}
	return out
}

// ThreadsResponse is the envelope Discord wraps active threads in.
pub struct ThreadsResponse {
pub:
	threads  []Channel
	members  []json.Any
	has_more bool
}

// list_threads returns the active threads of a text or forum channel.
pub fn (d &Discord) list_threads(channel_id string) ![]Channel {
	path := '/channels/${channel_id}/threads/active'
	body := d.get(path)!
	res := decode_or[ThreadsResponse](body, path)!
	return res.threads
}

// read_messages fetches up to limit messages newest-first, optionally starting
// from the message identified by before (a snowflake id).
pub fn (d &Discord) read_messages(channel_id string, limit int, before string) ![]Message {
	mut q := ['limit=${clamp_limit(limit)}']
	if before != '' {
		q << 'before=${before}'
	}
	path := '/channels/${channel_id}/messages?${q.join("&")}'
	body := d.get(path)!
	return decode_or[[]Message](body, path)
}

// read_all_messages pages backwards through a channel's whole history and
// returns it oldest-first. max_messages caps the total; pass 0 for no cap.
// When the cap trims results the most recent messages are kept, so a caller
// reading a busy channel still sees the current state of the conversation.
pub fn (d &Discord) read_all_messages(channel_id string, max_messages int) ![]Message {
	mut out := []Message{}
	mut before := ''
	mut page := d.read_messages(channel_id, max_messages_per_page, '')!
	for page.len > 0 {
		out.prepend(page)
		if max_messages > 0 && out.len >= max_messages {
			// out is oldest-first, so drop the oldest overflow from the front.
			return out[out.len - max_messages..]
		}
		before = page.last().id
		page = d.read_messages(channel_id, max_messages_per_page, before)!
	}
	return out
}

// SearchResponse is Discord's search envelope. Each hit nests its author in a
// different shape than a plain message, so hits are decoded separately.
pub struct SearchResponse {
pub:
	messages     []SearchHit
	analytics_id string
}

// search_messages queries a channel's history for messages containing
// content_contains. An empty query returns the most recent messages.
pub fn (d &Discord) search_messages(channel_id string, content_contains string,
	limit int) ![]Message {
	mut q := ['limit=${clamp_limit(limit)}']
	if content_contains != '' {
		q << 'content=${content_contains}'
	}
	path := '/channels/${channel_id}/messages/search?${q.join("&")}'
	body := d.get(path)!
	res := decode_or[SearchResponse](body, path)!
	mut out := []Message{cap: res.messages.len}
	for hit in res.messages {
		out << hit.to_message()
	}
	return out
}

// SearchHit is a search result, whose author is a nested user object.
pub struct SearchHit {
pub:
	id       string
	channel_id string
	content  string
	timestamp string
	author   User
}

// to_message flattens a search hit into the common Message shape.
pub fn (h &SearchHit) to_message() Message {
	return Message{
		id:         h.id
		channel_id: h.channel_id
		author_id:  h.author.id
		username:   h.author.username
		content:    h.content
		ts:        snowflake_to_unix(h.id)
	}
}

// SendMessageRequest is the JSON body for creating a message.
pub struct SendMessageRequest {
	content string
}

// send_message posts a message to a channel and returns the created message.
pub fn (d &Discord) send_message(channel_id string, content string) !Message {
	body := d.request('POST', '/channels/${channel_id}/messages',
		json.encode(SendMessageRequest{content: content}))!
	return json.decode[Message](body)!
}

// add_reaction puts an emoji reaction on a message. emoji may be a standard
// unicode emoji or a custom emoji in `<:name:id>` form.
pub fn (d &Discord) add_reaction(channel_id string, message_id string, emoji string) ! {
	d.request_no_content('PUT',
		'/channels/${channel_id}/messages/${message_id}/reactions/${encode_emoji(emoji)}/@me')!
}

// delete_message removes a message the bot authored.
pub fn (d &Discord) delete_message(channel_id string, message_id string) ! {
	d.request_no_content('DELETE', '/channels/${channel_id}/messages/${message_id}')!
}

// get performs an authenticated GET and returns the raw JSON body.
pub fn (d &Discord) get(path string) !string {
	return d.request('GET', path, '')
}

// request performs an authenticated request and returns the raw JSON body.
// body may be empty for requests that carry no payload. Non-2xx responses and
// transport failures are both surfaced as ApiError.
pub fn (d &Discord) request(method string, path string, body string) !string {
	resp := d.send(HttpRequest{
		method:  method
		host:    d.host
		path:    '${d.base_path}${path}'
		headers: d.default_headers(body)
		body:    body
	}) or { return transport_error(path, err.str()) }
	d.check_rate_limit(resp)
	if resp.status_code !in [200, 201, 204] {
		return &ApiError{
			status_code: resp.status_code
			message:     error_message_from(resp.body, resp.status_code)
			path:        path
		}
	}
	if resp.status_code == 204 || resp.body == '' {
		return '{}'
	}
	return resp.body
}

// request_no_content performs an authenticated request and discards the body,
// raising ApiError only when the status indicates failure.
pub fn (d &Discord) request_no_content(method string, path string) ! {
	resp := d.send(HttpRequest{
		method:  method
		host:    d.host
		path:    '${d.base_path}${path}'
		headers: d.default_headers('')
	}) or { return transport_error(path, err.str()) }
	d.check_rate_limit(resp)
	if resp.status_code >= 300 {
		return &ApiError{
			status_code: resp.status_code
			message:     error_message_from(resp.body, resp.status_code)
			path:        path
		}
	}
}

// send dispatches a request through the mbedTLS-backed HTTP client.
fn (d &Discord) send(req HttpRequest) !HttpResponse {
	return do_request(req)
}

// default_headers builds the headers every Discord request carries. Discord
// rejects requests without a User-Agent and answers 401 without a valid
// Authorization header.
fn (d &Discord) default_headers(body string) map[string]string {
	mut headers := map[string]string{
		'Authorization': 'Bot ${d.token}'
		'User-Agent':    'DiscordBot (tora, 0.1.0)'
		'Accept':        'application/json'
	}
	if body != '' {
		headers['Content-Type'] = 'application/json'
	}
	return headers
}

// check_rate_limit sleeps when Discord reports the route bucket is exhausted.
// It honours Retry-After for hard throttles and the remaining count otherwise.
// The wait is deliberately capped: a multi-minute Retry-After should surface as
// an error to the caller rather than silently stalling the MCP tool.
fn (d &Discord) check_rate_limit(resp &HttpResponse) {
	retry_after := resp.header('Retry-After')
	if retry_after != '' {
		secs := retry_after.trim_space().f64()
		if secs > 0 && secs <= max_rate_limit_wait_seconds {
			time.sleep(time.Duration(f64(time.second) * secs))
			return
		}
	}
	if resp.header('X-RateLimit-Remaining') == '0' {
		reset := resp.header('X-RateLimit-Reset-After')
		secs := reset.trim_space().f64()
		if secs > 0 && secs <= max_rate_limit_wait_seconds {
			time.sleep(time.Duration(f64(time.second) * secs))
		}
	}
}

// ApiErrorBody is Discord's standard error envelope.
pub struct ApiErrorBody {
pub:
	code    int
	message string
}

// error_message_from extracts Discord's human-readable error from a failure
// body, falling back to a generic message when the body has another shape.
fn error_message_from(body string, status_code int) string {
	if body == '' {
		return 'empty response body'
	}
	if res := json.decode[ApiErrorBody](body) {
		if res.message != '' {
			return res.message
		}
	}
	return 'http ${status_code}'
}

// clamp_limit forces a message limit into the range Discord accepts.
fn clamp_limit(limit int) int {
	if limit <= 0 {
		return 1
	}
	if limit > max_messages_per_page {
		return max_messages_per_page
	}
	return limit
}

// snowflake_to_unix extracts the embedded creation timestamp from a snowflake
// id. Discord snowflakes put the unix millisecond timestamp in the top 42 bits.
pub fn snowflake_to_unix(id string) i64 {
	n := id.i64()
	return (n >> 22) / 1000
}

// encode_emoji percent-encodes a reaction emoji for use as a URL path segment.
// Discord expects the custom-emoji markup `<:name:id>` reduced to `name:id`,
// and standard emoji passed through as raw unicode.
pub fn encode_emoji(emoji string) string {
	s := emoji.trim_space()
	mut body := s
	if s.len > 4 && s.starts_with('<') && s.ends_with('>') {
		inner := s[1..s.len - 1]
		if inner.starts_with('a:') {
			body = inner[2..]
		} else if inner.starts_with(':') {
			body = inner[1..]
		}
	}
	mut out := []u8{cap: body.len}
	for ch in body {
		match ch {
			`%`, `_`, `~`, `.`, `/`, `?`, `#`, `:`, ` ` {
				out << `%`
				out << hex_char(int(ch) >> 4)
				out << hex_char(int(ch) & 0xf)
			}
			else {
				out << ch
			}
		}
	}
	return out.bytestr()
}

// hex_char renders a nibble as an uppercase hex digit for percent-encoding.
fn hex_char(nibble int) u8 {
	if nibble < 10 {
		return u8(`0` + nibble)
	}
	return u8(`A` + nibble - 10)
}