module torabot

import json2 as json
import strconv

// Args is a decoded MCP tool-arguments object. Tool arguments are always a
// JSON object keyed by parameter name, so storing the decoded map keeps
// lookups cheap and lets a missing or mistyped field produce a message the
// model can act on instead of a panic.
pub struct Args {
	obj map[string]json.Any
}

// new_args decodes the raw JSON arguments string handed to a tool handler. An
// empty string, or a value that is not a JSON object, yields empty arguments
// so that a malformed call surfaces as a clear "missing argument" message.
pub fn new_args(raw string) Args {
	if raw.trim_space() == '' {
		return Args{}
	}
	obj := json.decode[map[string]json.Any](raw) or { return Args{} }
	return Args{
		obj: obj
	}
}

// str_or returns the string field named key, or def when it is absent or not
// a string.
pub fn (a &Args) str_or(key string, def string) string {
	s := a.str_opt(key) or { return def }
	return s
}

// str_opt returns the string field named key, or none when it is absent or is
// not a string.
pub fn (a &Args) str_opt(key string) ?string {
	v := a.obj[key] or { return none }
	if v is string {
		return v as string
	}
	return none
}

// req_str returns a mandatory, non-empty string field, or an error naming the
// offending key so the model can retry with a corrected call.
pub fn (a &Args) req_str(key string) !string {
	s := a.str_opt(key) or { return error('missing required argument: ${key}') }
	if s == '' {
		return error('argument ${key} must not be empty')
	}
	return s
}

// int returns the integer field named key, or def when it is absent.
pub fn (a &Args) int(key string, def int) int {
	n := a.int_opt(key) or { return def }
	return n
}

// int_opt returns the integer field named key, or none when it is absent or is
// not a number.
pub fn (a &Args) int_opt(key string) ?int {
	v := a.obj[key] or { return none }
	return any_to_int(v)
}

// json_null is the decoded representation of a JSON null, used when a field is
// absent and code still needs a json.Any to work with.
pub fn json_null() json.Any {
	return json.Null{}
}

// raw_value returns the decoded arguments object, or none when the arguments
// were absent or malformed.
pub fn (a &Args) raw_value() ?json.Any {
	if a.obj.len == 0 {
		return none
	}
	return json.Any(a.obj)
}

// str_array returns the array-of-strings field named key, skipping entries that
// are not strings. An absent field yields an empty slice.
pub fn (a &Args) str_array(key string) []string {
	v := a.obj[key] or { return []string{} }
	if v is []json.Any {
		items := v as []json.Any
		mut out := []string{cap: items.len}
		for item in items {
			if item is string {
				out << item as string
			}
		}
		return out
	}
	return []string{}
}

// any_to_int narrows a decoded JSON value to an int.
//
// json2 represents every JSON number as f64, and Discord sends its ids as JSON
// strings, so both shapes are accepted here. A string that is not a valid
// integer yields none rather than a silent zero, which keeps a malformed id
// from turning into "channel 0".
pub fn any_to_int(v json.Any) ?int {
	if v is int {
		return v as int
	}
	if v is f64 {
		return int(v as f64)
	}
	if v is string {
		s := (v as string).trim_space()
		if s.len == 0 {
			return none
		}
		return strconv.parse_int(s, 10, 64) or { return none }
	}
	return none
}

// opt_string reads a string field from a decoded JSON object, returning an empty
// string when the key is absent or not a string.
pub fn opt_string(obj map[string]json.Any, key string) string {
	v := obj[key] or { return '' }
	if v is string {
		return v as string
	}
	return ''
}

// bool returns the boolean field named key, or def when it is absent.
pub fn (a &Args) bool(key string, def bool) bool {
	v := a.obj[key] or { return def }
	if v is bool {
		return v as bool
	}
	return def
}

// opt_str returns the string field named key, or an empty string when absent.
pub fn (a &Args) opt_str(key string) string {
	return a.str_or(key, '')
}