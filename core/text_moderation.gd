class_name TextModeration
extends RefCounted

## Lightweight client-side guard for user-authored lobby UI text.
## A production backend should repeat moderation server-side.
const BLOCKED_WORDS: PackedStringArray = [
	"asshole", "bastard", "bitch", "cunt", "dick", "fag", "fuck",
	"nigger", "piss", "prick", "pussy", "retard", "shit", "slut", "whore",
]


static func is_allowed(value: String) -> bool:
	var normalized := _normalize(value)
	var words := normalized.split(" ", false)
	for word in words:
		if word in BLOCKED_WORDS:
			return false
	return true


static func _normalize(value: String) -> String:
	var source := value.to_lower()
	var result := ""
	for character in source:
		var mapped := character
		match character:
			"0":
				mapped = "o"
			"1", "!":
				mapped = "i"
			"3":
				mapped = "e"
			"4", "@":
				mapped = "a"
			"5", "$":
				mapped = "s"
			"7":
				mapped = "t"
		var codepoint := mapped.to_ascii_buffer()[0]
		if codepoint >= 97 and codepoint <= 122:
			result += mapped
		else:
			result += " "
	return " ".join(result.split(" ", false))
