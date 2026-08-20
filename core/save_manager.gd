class_name GameSaveManager
extends Node

## Versioned, named sandbox saves.
##
## Preferences remain in `user://settings.cfg`; world snapshots live in their
## own files so loading one game never rolls back graphics, audio, or controls.
## Snapshot values are Godot Variants because the world already speaks in
## Transform3D, Vector3, Color, and packed arrays for multiplayer catch-up.

signal catalog_changed
signal operation_failed(message: String)

const SAVE_DIRECTORY := "user://saves"
const FILE_EXTENSION := ".sandbox"
const FILE_MAGIC := 0x4D535031 # "MSP1"
const FILE_FORMAT_VERSION := 1
const SNAPSHOT_SCHEMA_VERSION := 1
const MAX_DISPLAY_NAME_LENGTH := 32

var last_error := ""


func list_saves(mode := "") -> Array[Dictionary]:
	last_error = ""
	var rows: Array[Dictionary] = []
	var directory_path := ProjectSettings.globalize_path(SAVE_DIRECTORY)
	if not DirAccess.dir_exists_absolute(directory_path):
		return rows
	for filename: String in DirAccess.get_files_at(SAVE_DIRECTORY):
		if not filename.ends_with(FILE_EXTENSION):
			continue
		var document := _read_document("%s/%s" % [SAVE_DIRECTORY, filename])
		if document.is_empty():
			continue
		var metadata := _metadata_from_document(document)
		if metadata.is_empty() or (
				not mode.is_empty() and String(metadata.get("mode", "")) != mode):
			continue
		rows.append(metadata)
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var a_time := int(a.get("updated_unix", 0))
		var b_time := int(b.get("updated_unix", 0))
		if a_time == b_time:
			return String(a.get("name", "")) < String(b.get("name", ""))
		return a_time > b_time
	)
	return rows


func save_exists(save_id: String, mode := "") -> bool:
	last_error = ""
	var document := _read_document(_save_path(_clean_id(save_id)))
	if document.is_empty():
		return false
	return mode.is_empty() or String(document.get("mode", "")) == mode


func create_save(display_name: String, mode: String,
		snapshot: Dictionary) -> Dictionary:
	var clean_name := clean_display_name(display_name)
	var clean_mode := mode.strip_edges().to_lower()
	if clean_name.is_empty():
		return _failure("Enter a name for this save.")
	if clean_mode.is_empty() or snapshot.is_empty():
		return _failure("The game did not provide a valid snapshot.")
	var save_id := _new_id()
	var now := int(Time.get_unix_time_from_system())
	var document := {
		"file_format_version": FILE_FORMAT_VERSION,
		"snapshot_schema_version": SNAPSHOT_SCHEMA_VERSION,
		"id": save_id,
		"name": clean_name,
		"mode": clean_mode,
		"created_unix": now,
		"updated_unix": now,
		"snapshot": snapshot.duplicate(true),
	}
	var error := _write_document(_save_path(save_id), document)
	if error != OK:
		return _failure("Could not create the save (%s)." % error_string(error))
	last_error = ""
	catalog_changed.emit()
	return {
		"ok": true,
		"id": save_id,
		"name": clean_name,
		"metadata": _metadata_from_document(document),
	}


func overwrite_save(save_id: String, snapshot: Dictionary) -> Dictionary:
	last_error = ""
	var clean_id := _clean_id(save_id)
	var document := _read_document(_save_path(clean_id))
	if document.is_empty() or String(document.get("id", "")) != clean_id:
		return _failure("That save is no longer available.")
	if snapshot.is_empty():
		return _failure("The game did not provide a valid snapshot.")
	document["file_format_version"] = FILE_FORMAT_VERSION
	document["snapshot_schema_version"] = SNAPSHOT_SCHEMA_VERSION
	document["updated_unix"] = int(Time.get_unix_time_from_system())
	document["snapshot"] = snapshot.duplicate(true)
	var error := _write_document(_save_path(clean_id), document)
	if error != OK:
		return _failure("Could not update the save (%s)." % error_string(error))
	last_error = ""
	catalog_changed.emit()
	return {
		"ok": true,
		"id": clean_id,
		"name": String(document.get("name", clean_id)),
		"metadata": _metadata_from_document(document),
	}


func load_save(save_id: String, expected_mode := "") -> Dictionary:
	last_error = ""
	var clean_id := _clean_id(save_id)
	if clean_id.is_empty():
		return _failure("Select a save to load.")
	var document := _read_document(_save_path(clean_id))
	if document.is_empty() or String(document.get("id", "")) != clean_id:
		return _failure(
			last_error if not last_error.is_empty()
				else "That save is no longer available.")
	var mode := String(document.get("mode", ""))
	if not expected_mode.is_empty() and mode != expected_mode:
		return _failure("This save belongs to %s mode." % mode.capitalize())
	var snapshot_value: Variant = document.get("snapshot", {})
	if not snapshot_value is Dictionary or (snapshot_value as Dictionary).is_empty():
		return _failure("The save contains no world snapshot.")
	last_error = ""
	return {
		"ok": true,
		"id": clean_id,
		"name": String(document.get("name", clean_id)),
		"mode": mode,
		"snapshot": (snapshot_value as Dictionary).duplicate(true),
		"metadata": _metadata_from_document(document),
	}


func delete_save(save_id: String) -> Error:
	var clean_id := _clean_id(save_id)
	if clean_id.is_empty():
		return ERR_INVALID_PARAMETER
	var path := ProjectSettings.globalize_path(_save_path(clean_id))
	if not FileAccess.file_exists(path):
		return ERR_FILE_NOT_FOUND
	var error := DirAccess.remove_absolute(path)
	if error == OK:
		catalog_changed.emit()
	else:
		_failure("Could not delete the save (%s)." % error_string(error))
	return error


static func clean_display_name(value: String) -> String:
	var clean := ""
	for character in value.strip_edges():
		var codepoint := character.unicode_at(0)
		if codepoint >= 32 and codepoint != 127:
			clean += character
			if clean.length() >= MAX_DISPLAY_NAME_LENGTH:
				break
	return clean.strip_edges()


func _metadata_from_document(document: Dictionary) -> Dictionary:
	var save_id := _clean_id(String(document.get("id", "")))
	var name := clean_display_name(String(document.get("name", "")))
	var mode := String(document.get("mode", "")).strip_edges().to_lower()
	if save_id.is_empty() or name.is_empty() or mode.is_empty():
		return {}
	return {
		"id": save_id,
		"name": name,
		"mode": mode,
		"created_unix": maxi(int(document.get("created_unix", 0)), 0),
		"updated_unix": maxi(int(document.get("updated_unix", 0)), 0),
		"snapshot_schema_version": maxi(
			int(document.get("snapshot_schema_version", 0)), 0),
	}


func _read_document(path: String) -> Dictionary:
	if path.is_empty() or not FileAccess.file_exists(path):
		return {}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		_failure("Could not open a save (%s)." % error_string(
			FileAccess.get_open_error()))
		return {}
	if file.get_length() < 8 or file.get_32() != FILE_MAGIC:
		file.close()
		_failure("A save has an invalid file header.")
		return {}
	var format_version := int(file.get_32())
	if format_version <= 0 or format_version > FILE_FORMAT_VERSION:
		file.close()
		_failure("This save was written by an unsupported game version.")
		return {}
	var value: Variant = file.get_var(false)
	var read_error := file.get_error()
	file.close()
	if read_error != OK and read_error != ERR_FILE_EOF:
		_failure("A save is incomplete or damaged.")
		return {}
	if not value is Dictionary:
		_failure("A save contains an invalid document.")
		return {}
	var document := value as Dictionary
	var schema := int(document.get("snapshot_schema_version", 0))
	if schema <= 0 or schema > SNAPSHOT_SCHEMA_VERSION:
		_failure("This world's save format is not supported.")
		return {}
	return document


func _write_document(path: String, document: Dictionary) -> Error:
	var directory_path := ProjectSettings.globalize_path(SAVE_DIRECTORY)
	var directory_error := DirAccess.make_dir_recursive_absolute(directory_path)
	if directory_error != OK:
		return directory_error
	var final_path := ProjectSettings.globalize_path(path)
	var temporary_path := final_path + ".tmp"
	var backup_path := final_path + ".bak"
	_remove_if_present(temporary_path)
	_remove_if_present(backup_path)

	var file := FileAccess.open(temporary_path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_32(FILE_MAGIC)
	file.store_32(FILE_FORMAT_VERSION)
	file.store_var(document, false)
	file.flush()
	var write_error := file.get_error()
	file.close()
	if write_error != OK:
		_remove_if_present(temporary_path)
		return write_error

	var had_previous := FileAccess.file_exists(final_path)
	if had_previous:
		var backup_error := DirAccess.rename_absolute(final_path, backup_path)
		if backup_error != OK:
			_remove_if_present(temporary_path)
			return backup_error
	var replace_error := DirAccess.rename_absolute(temporary_path, final_path)
	if replace_error != OK:
		if had_previous:
			DirAccess.rename_absolute(backup_path, final_path)
		_remove_if_present(temporary_path)
		return replace_error
	_remove_if_present(backup_path)
	return OK


func _new_id() -> String:
	var stamp := int(Time.get_unix_time_from_system())
	var nonce := randi()
	var save_id := "%d_%08x" % [stamp, nonce]
	while FileAccess.file_exists(_save_path(save_id)):
		nonce = randi()
		save_id = "%d_%08x" % [stamp, nonce]
	return save_id


static func _clean_id(value: String) -> String:
	var clean := ""
	for character in value.strip_edges().to_lower():
		if character in "abcdefghijklmnopqrstuvwxyz0123456789_-":
			clean += character
	return clean.substr(0, 64)


static func _save_path(save_id: String) -> String:
	return "%s/%s%s" % [SAVE_DIRECTORY, save_id, FILE_EXTENSION] \
		if not save_id.is_empty() else ""


static func _remove_if_present(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)


func _failure(message: String) -> Dictionary:
	last_error = message
	operation_failed.emit(message)
	return {"ok": false, "message": message}
