module main

import os
import mcp
import time

import torabot

const server_name = 'discord-v'
const server_version = '0.1.0'

// tool_context bundles the Discord client with the handler context so tool
// closures stay short.
struct Env {
mut:
	client &torabot.Discord = unsafe { nil }
}

// main starts the Discord MCP server on stdio. The bot token is read from
// DISCORD_TOKEN; if it is missing the server still starts and reports the
// problem through its tools, so the client can surface an actionable message
// instead of the process dying silently at launch.
fn main() {
	mut env := Env{}

	token := os.getenv('DISCORD_TOKEN')
	if token != '' {
		env.client = torabot.new(token, os.getenv('DISCORD_API_BASE'))
	} else {
		eprintln('torabot: DISCORD_TOKEN is not set; tools will report a configuration error')
	}

	mut server := mcp.new_server(
		name:        server_name
		version:     server_version
		title:       'Discord'
		description: 'Read and send Discord messages through a bot account.'
		instructions: 'Use list_guilds to find the server, list_channels to find a ' +
			'channel id, then read_messages or read_all_messages to read history. ' +
			'search_messages filters by text. Channel ids are snowflakes, not names. ' +
			'The bot only sees channels it has been invited to.'
		enable_logging: true
	)

	register_tools(mut &server, env)

	server.serve_stdio() or {
		eprintln('torabot: stdio server failed: ${err}')
		exit(1)
	}
}

// require_client returns the Discord client, or a configuration error when the
// server was started without a token.
fn require_client(env Env) !&torabot.Discord {
	if env.client == unsafe { nil } {
		return error('DISCORD_TOKEN is not set. Set it in the environment before ' +
			'starting the server, then restart the MCP client.')
	}
	return env.client
}

// register_tools exposes the Discord tools over MCP.
fn register_tools(mut server &mcp.Server, env Env) {
	server.add_tool(mcp.Tool{
		name:        'list_guilds'
		title:       'List servers'
		description: 'List the Discord servers the bot has been invited to. ' +
			'Call this first to obtain a guild_id for the other tools.'
		input_schema: '{"type":"object","properties":{},' +
			'"additionalProperties":false}'
		annotations: mcp.ToolAnnotations{
			read_only_hint:   true
			destructive_hint: false
			idempotent_hint:  true
			open_world_hint:  true
		}
	}, fn [env] (_ mcp.Context, _ string) !mcp.ToolResult {
		d := require_client(env) or { return mcp.tool_text_result(err.str()) }
		guilds := d.list_guilds() or { return api_failure(err) }
		return mcp.tool_text_result(format_guilds(guilds))
	}) or { eprintln('torabot: failed to register list_guilds: ${err}') }

	server.add_tool(mcp.Tool{
		name:        'list_channels'
		title:       'List channels'
		description: 'List the channels of a server, including text channels, ' +
			'categories, voice channels and threads. Pass text_only to hide voice ' +
			'and category channels.'
		input_schema: '{"type":"object","properties":{' +
			'"guild_id":{"type":"string","description":"Server id from list_guilds"},' +
			'"text_only":{"type":"boolean","description":"Only return text and thread channels",' +
			'"default":true}},' +
			'"required":["guild_id"],"additionalProperties":false}'
		annotations: mcp.ToolAnnotations{
			read_only_hint:  true
			open_world_hint: true
		}
	}, fn [env] (_ mcp.Context, arguments string) !mcp.ToolResult {
		d := require_client(env) or { return mcp.tool_text_result(err.str()) }
		a := torabot.new_args(arguments)
		guild_id := a.req_str('guild_id') or {
			return mcp.tool_text_result(err.str())
		}
		mut channels := d.list_channels(guild_id) or { return api_failure(err) }
		if a.int('text_only', 1) != 0 {
			channels = filter_text_channels(channels)
		}
		return mcp.tool_text_result(format_channels(guild_id, channels))
	}) or { eprintln('torabot: failed to register list_channels: ${err}') }

	server.add_tool(mcp.Tool{
		name:        'read_messages'
		title:       'Read messages'
		description: 'Read up to 100 recent messages from a channel, newest first. ' +
			'Pass before (a message id) to page further back.'
		input_schema: '{"type":"object","properties":{' +
			'"channel_id":{"type":"string","description":"Channel id"},' +
			'"limit":{"type":"integer","description":"1-100, default 50","default":50},' +
			'"before":{"type":"string","description":"Return messages older than this message id"}},' +
			'"required":["channel_id"],"additionalProperties":false}'
		annotations: mcp.ToolAnnotations{
			read_only_hint:  true
			open_world_hint: true
		}
	}, fn [env] (ctx mcp.Context, arguments string) !mcp.ToolResult {
		d := require_client(env) or { return mcp.tool_text_result(err.str()) }
		a := torabot.new_args(arguments)
		channel_id := a.req_str('channel_id') or {
			return mcp.tool_text_result(err.str())
		}
		messages := d.read_messages(channel_id, a.int('limit', 50),
			a.opt_str('before')) or { return api_failure(err) }
		return mcp.tool_text_result(format_messages(messages, channel_id))
	}) or { eprintln('torabot: failed to register read_messages: ${err}') }

	server.add_tool(mcp.Tool{
		name:        'read_all_messages'
		title:       'Read full history'
		description: 'Page through a channel and return its entire history, ' +
			'oldest first. Long histories are rate limited by Discord, so start ' +
			'small and use max_messages to bound the result.'
		input_schema: '{"type":"object","properties":{' +
			'"channel_id":{"type":"string","description":"Channel id"},' +
			'"max_messages":{"type":"integer","description":"Cap on total messages, 0 for no cap",' +
			'"default":500}},' +
			'"required":["channel_id"],"additionalProperties":false}'
		annotations: mcp.ToolAnnotations{
			read_only_hint:  true
			open_world_hint: true
		}
	}, fn [env] (ctx mcp.Context, arguments string) !mcp.ToolResult {
		d := require_client(env) or { return mcp.tool_text_result(err.str()) }
		a := torabot.new_args(arguments)
		channel_id := a.req_str('channel_id') or {
			return mcp.tool_text_result(err.str())
		}
		max_messages := a.int('max_messages', 500)
		// Report progress up front so a long read does not look hung.
		ctx.notify_progress(0, f64(max_messages), 'reading history of ${channel_id}')
		start := time.now()
		messages := d.read_all_messages(channel_id, max_messages) or {
			return api_failure(err)
		}
		_ = time.since(start)
		return mcp.tool_text_result(format_messages(messages, channel_id))
	}) or { eprintln('torabot: failed to register read_all_messages: ${err}') }

	server.add_tool(mcp.Tool{
		name:        'search_messages'
		title:       'Search messages'
		description: 'Search a channel for messages containing a substring. ' +
			'Leave query empty to get the most recent messages instead.'
		input_schema: '{"type":"object","properties":{' +
			'"channel_id":{"type":"string","description":"Channel id"},' +
			'"query":{"type":"string","description":"Text to look for"},' +
			'"limit":{"type":"integer","description":"1-100, default 25","default":25}},' +
			'"required":["channel_id"],"additionalProperties":false}'
		annotations: mcp.ToolAnnotations{
			read_only_hint:  true
			open_world_hint: true
		}
	}, fn [env] (_ mcp.Context, arguments string) !mcp.ToolResult {
		d := require_client(env) or { return mcp.tool_text_result(err.str()) }
		a := torabot.new_args(arguments)
		channel_id := a.req_str('channel_id') or {
			return mcp.tool_text_result(err.str())
		}
		messages := d.search_messages(channel_id, a.opt_str('query'),
			a.int('limit', 25)) or { return api_failure(err) }
		return mcp.tool_text_result(format_messages(messages, channel_id))
	}) or { eprintln('torabot: failed to register search_messages: ${err}') }

	server.add_tool(mcp.Tool{
		name:        'list_threads'
		title:       'List threads'
		description: 'List the active threads of a text or forum channel.'
		input_schema: '{"type":"object","properties":{' +
			'"channel_id":{"type":"string","description":"Parent channel id"}},' +
			'"required":["channel_id"],"additionalProperties":false}'
		annotations: mcp.ToolAnnotations{
			read_only_hint:  true
			open_world_hint: true
		}
	}, fn [env] (_ mcp.Context, arguments string) !mcp.ToolResult {
		d := require_client(env) or { return mcp.tool_text_result(err.str()) }
		a := torabot.new_args(arguments)
		channel_id := a.req_str('channel_id') or {
			return mcp.tool_text_result(err.str())
		}
		threads := d.list_threads(channel_id) or { return api_failure(err) }
		return mcp.tool_text_result(format_threads(threads))
	}) or { eprintln('torabot: failed to register list_threads: ${err}') }

	server.add_tool(mcp.Tool{
		name:        'send_message'
		title:       'Send message'
		description: 'Post a message to a channel. This is the only tool that ' +
			'changes Discord state.'
		input_schema: '{"type":"object","properties":{' +
			'"channel_id":{"type":"string","description":"Channel id"},' +
			'"content":{"type":"string","description":"Message text, up to 2000 characters"}},' +
			'"required":["channel_id","content"],"additionalProperties":false}'
		annotations: mcp.ToolAnnotations{
			read_only_hint:   false
			destructive_hint: false
			idempotent_hint:  false
			open_world_hint:  true
		}
	}, fn [env] (_ mcp.Context, arguments string) !mcp.ToolResult {
		d := require_client(env) or { return mcp.tool_text_result(err.str()) }
		a := torabot.new_args(arguments)
		channel_id := a.req_str('channel_id') or {
			return mcp.tool_text_result(err.str())
		}
		content := a.req_str('content') or { return mcp.tool_text_result(err.str()) }
		msg := d.send_message(channel_id, content) or { return api_failure(err) }
		return mcp.tool_text_result('sent message ${msg.id} to ${channel_id}')
	}) or { eprintln('torabot: failed to register send_message: ${err}') }

	register_live_tools(mut server, env)
}

// register_live_tools exposes the gateway-backed live message tools. They are
// separate from the REST tools because each call opens a short-lived gateway
// connection rather than reusing one.
fn register_live_tools(mut server &mcp.Server, env Env) {
	server.add_tool(mcp.Tool{
		name:        'watch_messages'
		title:       'Watch live messages'
		description: 'Connect to the Discord gateway and collect messages as they ' +
			'are posted, without polling. Needs the MESSAGE CONTENT intent ' +
			'enabled on the bot. Use channel_ids to limit to specific channels. ' +
			'Blocks for the requested duration, so keep it short.'
		input_schema: '{"type":"object","properties":{' +
			'"channel_ids":{"type":"array","items":{"type":"string"},' +
			'"description":"Channel ids to watch; omit to receive every message the bot can see"},' +
			'"seconds":{"type":"integer","description":"How long to listen, 1-120","default":15},' +
			'"max_messages":{"type":"integer","description":"Stop early after this many messages",' +
			'"default":100}},' +
			'"additionalProperties":false}'
		annotations: mcp.ToolAnnotations{
			read_only_hint:  true
			open_world_hint: true
		}
	}, fn [env] (ctx mcp.Context, arguments string) !mcp.ToolResult {
		token := require_token(env) or { return mcp.tool_text_result(err.str()) }
		a := torabot.new_args(arguments)
		mut seconds := a.int('seconds', 15)
		limit := a.int('max_messages', 100)
		if seconds < 1 {
			seconds = 1
		}
		if seconds > 120 {
			seconds = 120
		}
		channels := a.str_array('channel_ids')

		mut g := torabot.new_gateway(token).with_channel_filter(channels)
		g.connect() or {
			return mcp.tool_text_result('gateway connection failed: ${err.msg()}\n' +
				'Check that the bot token is valid and that the gateway is reachable.')
		}
		defer {
			g.close()
		}

		mut collected := &Collector{}
		g.listen(fn [collected] (ev torabot.GatewayEvent) {
			collected.add(ev)
		}, time.Duration(seconds) * time.second) or {}

		lines := collected.lines(limit)
		if lines.len == 0 {
			return mcp.tool_text_result('No messages received in ${seconds}s.' +
				(if channels.len > 0 { ' Watched ${channels.len} channel(s).' } else { '' }) +
				'\nIf you expected traffic, confirm the MESSAGE CONTENT intent is ' +
				'enabled and that the bot is in the channel.')
		}
		mut sb := []string{}
		sb << 'Received ${lines.len} message(s) in ${seconds}s:'
		sb << lines.join('\n')
		return mcp.tool_text_result(sb.join('\n'))
	}) or { eprintln('torabot: failed to register watch_messages: ${err}') }
}

// Collector accumulates live gateway events for one watch_messages call. It
// lives behind a reference because the gateway handler is a closure that cannot
// mutate captured locals directly.
struct Collector {
mut:
	items []string
	seen  map[string]bool
}

// add records one event, ignoring duplicates.
fn (mut c Collector) add(ev torabot.GatewayEvent) {
	if ev.name != 'MESSAGE_CREATE' {
		return
	}
	line := format_live_event(ev)
	if line == '' {
		return
	}
	key := line.all_after_first('ch=')
	if c.seen[key] {
		return
	}
	c.seen[key] = true
	c.items << line
}

// lines returns at most limit collected messages, oldest first.
fn (c Collector) lines(limit int) []string {
	if limit > 0 && c.items.len > limit {
		return c.items[..limit]
	}
	return c.items
}

// require_token returns the bot token, or a configuration error when the server
// was started without one.
fn require_token(_env Env) !string {
	token := os.getenv('DISCORD_TOKEN')
	if token == '' {
		return error('DISCORD_TOKEN is not set, so live messages cannot be read.')
	}
	return token
}

// format_live_event renders one MESSAGE_CREATE dispatch as a single line, or
// returns an empty string when the message carries no text content.
fn format_live_event(ev torabot.GatewayEvent) string {
	obj := torabot.as_object(ev.parsed_data()) or { return '' }
	content := torabot.opt_string(obj, 'content')
	if content == '' {
		return ''
	}
	mut username := ''
	if author := torabot.as_object(obj['author'] or { torabot.json_null() }) {
		username = torabot.opt_string(author, 'username')
	}
	channel := torabot.opt_string(obj, 'channel_id')
	who := if username != '' { username } else { 'unknown' }
	return 'ch=${channel}: ${who}: ${content}'
}

// api_failure turns an ApiError into a tool result that explains what went
// wrong and, for the common cases, what to do about it.
fn api_failure(err IError) mcp.ToolResult {
	mut msg := err.str()
	if err is &torabot.ApiError {
		e := err as &torabot.ApiError
		match e.status_code {
			401 {
				msg += '\nThe bot token was rejected. Check DISCORD_TOKEN and that ' +
					'the token was not reset.'
			}
			403 {
				msg += '\nThe bot lacks a permission in that channel. Grant it ' +
					'View Channel and Read Message History, and invite the bot with ' +
					'those permissions.'
			}
			404 {
				msg += '\nNot found. Verify the id, and confirm the bot is a member ' +
					'of that server.'
			}
			429 {
				msg += '\nRate limited. Wait a moment and retry with a smaller limit.'
			}
			else {}
		}
		if e.status_code == 0 {
			msg += '\nThis was a transport or decoding failure, not a Discord API response.'
		}
	}
	return mcp.tool_text_result(msg)
}

// filter_text_channels keeps text, announcement, forum and thread channels,
// dropping voice, stage, directory and category entries.
fn filter_text_channels(channels []torabot.Channel) []torabot.Channel {
	text_kinds := [
		torabot.channel_type_guild_text,
		torabot.channel_type_guild_announcement,
		torabot.channel_type_guild_forum,
		torabot.channel_type_guild_media,
		torabot.channel_type_public_thread,
		torabot.channel_type_private_thread,
		torabot.channel_type_announcement_thread,
	]
	mut out := []torabot.Channel{cap: channels.len}
	for c in channels {
		if text_kinds.contains(c.kind) {
			out << c
		}
	}
	return out
}

// format_guilds renders guilds as a readable list.
fn format_guilds(guilds []torabot.Guild) string {
	if guilds.len == 0 {
		return 'The bot is not a member of any server yet. Invite it with the ' +
			'install link from the Discord Developer Portal.'
	}
	mut sb := []string{}
	sb << 'Servers the bot is in (${guilds.len}):'
	for g in guilds {
		sb << '- ${g.name} (id: ${g.id})'
	}
	return sb.join('\n')
}

// format_channels renders channels with their type so the model can tell text
// channels apart from categories.
fn format_channels(guild_id string, channels []torabot.Channel) string {
	if channels.len == 0 {
		return 'No matching channels in guild ${guild_id}. The bot may be missing ' +
			'the View Channel permission.'
	}
	mut sb := []string{}
	sb << 'Channels in ${guild_id} (${channels.len}):'
	for c in channels {
		kind := channel_kind_name(c.kind)
		sb << '- [${kind}] ${c.name} (id: ${c.id})'
	}
	return sb.join('\n')
}

// format_threads renders a thread list.
fn format_threads(threads []torabot.Channel) string {
	if threads.len == 0 {
		return 'No active threads.'
	}
	mut sb := []string{}
	sb << 'Active threads (${threads.len}):'
	for t in threads {
		sb << '- ${t.name} (id: ${t.id})'
	}
	return sb.join('\n')
}

// format_messages renders messages oldest-first with an ISO timestamp, which is
// the order a reader needs to follow a conversation.
fn format_messages(messages []torabot.Message, channel_id string) string {
	if messages.len == 0 {
		return 'No messages found in channel ${channel_id}.'
	}
	mut sb := []string{}
	sb << '${messages.len} message(s) in channel ${channel_id} (oldest first):'
	for m in messages {
		stamp := time.unix(m.ts)
		author := if m.username != '' { m.username } else { m.author_id }
		sb << '[${stamp.format_ss_micro()}] ${author}: ${m.content}'
	}
	return sb.join('\n')
}

// channel_kind_name maps a Discord channel type to a readable label.
fn channel_kind_name(kind int) string {
	return match kind {
		torabot.channel_type_guild_text { 'text' }
		torabot.channel_type_guild_voice { 'voice' }
		torabot.channel_type_guild_category { 'category' }
		torabot.channel_type_guild_announcement { 'announcement' }
		torabot.channel_type_announcement_thread { 'announcement-thread' }
		torabot.channel_type_public_thread { 'thread' }
		torabot.channel_type_private_thread { 'private-thread' }
		torabot.channel_type_guild_stage_voice { 'stage' }
		torabot.channel_type_guild_directory { 'directory' }
		torabot.channel_type_guild_forum { 'forum' }
		torabot.channel_type_guild_media { 'media' }
		else { 'type-${kind}' }
	}
}