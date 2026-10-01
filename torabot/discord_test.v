module torabot

// A standard emoji (thumbs up, U+1F44D) must survive encode_emoji unchanged:
// Discord accepts raw unicode for these and rejects a percent-encoded form.
const thumbs_up = '\xF0\x9F\x91\x8D'

fn test_encode_emoji_standard() {
	assert encode_emoji(thumbs_up) == thumbs_up
}

fn test_encode_emoji_custom() {
	assert encode_emoji('<:blobwave:123456789>') == 'blobwave%3A123456789'
}

fn test_encode_emoji_animated_custom() {
	assert encode_emoji('<a:party:987>') == 'party%3A987'
}

fn test_encode_emoji_escapes_reserved() {
	assert encode_emoji('a b') == 'a%20b'
	assert encode_emoji('a/b') == 'a%2Fb'
	assert encode_emoji('50%') == '50%25'
}

fn test_clamp_limit_bounds() {
	assert clamp_limit(0) == 1
	assert clamp_limit(-5) == 1
	assert clamp_limit(50) == 50
	assert clamp_limit(100) == 100
	// Discord rejects limits above 100.
	assert clamp_limit(500) == 100
}

fn test_snowflake_to_unix() {
	// 175928847299117063 >> 22 = 41944705796 ms since the epoch
	// (1971-05-01T11:18:25Z), which is 41944705 seconds.
	assert snowflake_to_unix('175928847299117063') == 41944705
}

fn test_snowflake_to_unix_invalid() {
	assert snowflake_to_unix('not-a-number') == 0
	assert snowflake_to_unix('') == 0
}