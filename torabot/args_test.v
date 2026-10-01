module torabot

import json2 as json

fn test_as_object_returns_none_for_scalars() {
	assert as_object(json.Null{}) == none
	assert as_object(json.Any('a string')) == none
}

fn test_as_object_returns_none_for_arrays() {
	arr := json.decode[json.Any]('[1,2,3]') or { panic(err) }
	assert as_object(arr) == none
}

fn test_opt_string_reads_present_key() {
	obj := json.decode[map[string]json.Any]('{"a":"hello"}') or { panic(err) }
	assert opt_string(obj, 'a') == 'hello'
}

fn test_opt_string_missing_key_is_empty() {
	obj := json.decode[map[string]json.Any]('{"a":"hello"}') or { panic(err) }
	assert opt_string(obj, 'b') == ''
}

fn test_opt_string_non_string_is_empty() {
	obj := json.decode[map[string]json.Any]('{"n":42}') or { panic(err) }
	assert opt_string(obj, 'n') == ''
}

fn test_any_to_int_from_number() {
	v := json.decode[json.Any]('42') or { panic(err) }
	assert any_to_int(v) or { -1 } == 42
}

fn test_any_to_int_from_numeric_string() {
	// Discord ids arrive as JSON strings.
	v := json.decode[json.Any]('"123456789012345678"') or { panic(err) }
	assert any_to_int(v) or { -1 } == 123456789012345678
}

fn test_any_to_int_from_non_number() {
	v := json.decode[json.Any]('"not a number"') or { panic(err) }
	assert any_to_int(v) == none
}

fn test_args_req_str_rejects_empty() {
	a := new_args('{"channel_id":""}')
	// The call must fail for an empty value, so the ok path is unreachable here.
	if _ := a.req_str('channel_id') {
		assert false, 'empty channel_id should have been rejected'
	}
}

fn test_args_req_str_names_the_missing_key() {
	a := new_args('{}')
	a.req_str('channel_id') or {
		// `err` is bound by the or-block and names the offending argument.
		assert err.msg().contains('channel_id')
		return
	}
	assert false, 'missing channel_id should have produced an error'
}

fn test_args_int_defaults_and_overrides() {
	a := new_args('{"limit":25,"missing":null}')
	assert a.int('limit', 50) == 25
	assert a.int('missing', 50) == 50
	assert a.int('absent', 50) == 50
}

fn test_args_str_array() {
	a := new_args('{"ids":["1","2","3"]}')
	assert a.str_array('ids') == ['1', '2', '3']
}

fn test_args_str_array_absent_is_empty() {
	a := new_args('{}')
	assert a.str_array('ids') == []string{}
}

fn test_args_malformed_json_yields_empty_args() {
	a := new_args('not json at all')
	if _ := a.req_str('anything') {
		assert false, 'malformed arguments should not satisfy a required field'
	}
}