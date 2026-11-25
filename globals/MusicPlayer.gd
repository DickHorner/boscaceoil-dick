###################################################
# Part of Bosca Ceoil Blue                        #
# Copyright (c) 2025 Yuri Sizov and contributors  #
# Provided under MIT                              #
###################################################

## Music player component responsible for producing sounds using SiON and
## composition data.
class_name MusicPlayer extends RefCounted

signal playback_started()
signal playback_tick()
signal playback_paused()
signal playback_stopped()
signal playback_bar_changed()

signal export_started()
signal export_ended()

const BEATS_PER_NOTE := 0.0625 # Beat is split into 16 intervals.
const NOTE_LENGTH := 4.0 # In 1/16ths of a beat.
const NOTE_SWING_THRESHOLD := 0.2 # In portion of NOTE_LENGTH (i.e. = 20%).
const NOTE_GRACE_PERIOD := 4

# GDSiON 0.7 uses 480 ticks per beat (120 per sixteenth note).
const SWING_TICKS_PER_NOTE := 120

var _driver: SiONDriver = null
var _effects: Array[SiEffectBase] = []
var _active_effect: SiEffectBase = null

var _music_playing: bool = false
var _music_exporting: bool = false
var _playing_residue: bool = false
var _exporting_callback: Callable = Callable()

## Playback step of current patterns within the active timeline bar, in notes.
## Caps a current song's pattern size.
var _pattern_time: int = -1
## Note residue tracker to make sure we don't cut off the sound during export.
var _note_residue: PackedInt32Array = PackedInt32Array()
var _note_residue_time: int = 0

## Signed onset offsets for the upcoming odd step, keyed by instrument.
var _swing_offsets: Dictionary = {}
var _swing_offset: int = 0
## Delayed notes from the current logical step, in arrangement channel order.
var _swing_patterns: Array[QueuedSwingPattern] = []


# Initialization.

func initialize_driver() -> void:
	if _driver:
		printerr("MusicPlayer: Cannot initialize the driver, an instance already exists.")
		return
	
	var buffer_size := Controller.settings_manager.get_buffer_size()
	_driver = SiONDriver.create(buffer_size)
	_driver.set_beat_callback_interval(1) # In 1/16ths of a beat, can only be one of: 1, 2, 4, 8, 16.
	_driver.set_timer_interval(NOTE_LENGTH)
	
	_initialize_effects()
	
	Controller.add_child(_driver)
	print("Synthesizer driver initialized (buffer: %d)." % [ buffer_size ])


func finalize_driver() -> void:
	if not _driver:
		printerr("MusicPlayer: Cannot finalize the driver, it doesn't exist.")
		return
	
	_driver.stop()
	
	_finalize_effects()
	
	if _driver.get_parent():
		_driver.get_parent().remove_child(_driver)
	
	_driver.free()
	_driver = null


func reset_driver() -> void:
	# SiONDriver.stream enables endless streaming. We use the timer callback (a.k.a. a metronome)
	# to supply the stream with new notes to play based on the composition of the current song.
	
	_driver.stop()
	_reset_swing()
	if _music_playing && Controller.current_song && _pattern_time % 2 == 1 && _pattern_time < Controller.current_song.pattern_size:
		_swing_offset = _prepare_swing_offsets(Controller.current_song)

	update_driver_bpm()
	_driver.stream()
	update_driver_effects()
	print("Synthesizer driver streaming started.")


func update_driver_buffer() -> void:
	var was_playing := false
	if is_playing():
		was_playing = true
		stop_playback()
	
	# Buffer changes require us to recreate the entire driver. This should be relatively safe,
	# although leaks on the driver side are possible (but should be fixed in GDSiON anyway).
	finalize_driver()
	initialize_driver()
	reset_driver()
	
	if was_playing:
		start_playback()


func update_driver_bpm() -> void:
	if Controller.current_song:
		_driver.set_bpm(Controller.current_song.bpm)


func _initialize_effects() -> void:
	_effects.resize(Effect.MAX)
	
	_effects[Effect.EFFECT_DELAY]      = SiEffectStereoDelay.new();
	_effects[Effect.EFFECT_CHORUS]     = SiEffectStereoChorus.new()
	_effects[Effect.EFFECT_REVERB]     = SiEffectStereoReverb.new()
	_effects[Effect.EFFECT_DISTORTION] = SiEffectDistortion.new()
	_effects[Effect.EFFECT_LOW_BOOST]  = SiFilterLowBoost.new()
	_effects[Effect.EFFECT_COMPRESSOR] = SiEffectCompressor.new()
	_effects[Effect.EFFECT_HIGH_PASS]  = SiControllableFilterHighPass.new()


func _finalize_effects() -> void:
	_effects.clear() # Everything is refcounted, so should take care of itself.


func update_driver_effects() -> void:
	var song := Controller.current_song
	
	# Low values deactivate the effect.
	if not song || song.global_effect_power <= 5:
		_active_effect = null
		_driver.get_effector().clear_slot_effects(0)
		return
	
	# If the effect type is different, replace it in the effector. Or if the list is
	# empty, like after a driver reset.
	var next_effect := _effects[song.global_effect]
	if next_effect != _active_effect || _driver.get_effector().get_slot_effects(0).is_empty():
		_active_effect = next_effect
		_driver.get_effector().clear_slot_effects(0)
		_driver.get_effector().add_slot_effect(0, _active_effect)
	
	# Update the effect configuration on the fly.
	var _effect_power := song.global_effect_power / 100.0
	
	# Most of the values set here are default values for the corresponding arguments.
	
	if _active_effect is SiEffectStereoDelay:
		_active_effect.set_params(300.0 * _effect_power, 0.1, false, 0.25) # Feedback uses non-default value.
	
	elif _active_effect is SiEffectStereoChorus:
		_active_effect.set_params(20, 0.2, 4, 10 + 50.0 * _effect_power, 0.5, true)
	
	elif _active_effect is SiEffectStereoReverb:
		_active_effect.set_params(0.7, 0.4 + 0.5 * _effect_power, 0.8, 0.3)
	
	elif _active_effect is SiEffectDistortion:
		_active_effect.set_params(-20 - 80.0 * _effect_power, 18, 2400, 1)
	
	elif _active_effect is SiFilterLowBoost:
		_active_effect.set_params(3000, 1, 4 + 6.0 * _effect_power)
	
	elif _active_effect is SiEffectCompressor:
		_active_effect.set_params(0.7, 50, 20, 20, -6, 0.2 + 0.6 * _effect_power)
	
	elif _active_effect is SiControllableFilterHighPass:
		_active_effect.set_params_manually(1.0 * _effect_power, 0.9)


# Driver interactions.

func _play_note(pattern: Pattern, instrument: Instrument, note_data: Vector3i, current_time: int) -> void:
	if note_data.x < 0 || note_data.y < 0 || note_data.y != current_time || note_data.z < 1:
		# X — note number is invalid.
		# Y — note position in the pattern is invalid or doesn't match current time.
		# Z — note length is shorter than 1 unit of length.
		return
	if not instrument.is_note_valid(note_data):
		return # Custom validation for different instrument types failed.

	# Update the filter.
	instrument.update_filter()

	# If pattern uses recorded instrument values, set them directly.
	if pattern.record_instrument && current_time >= 0 && current_time < pattern.recorded_instrument_values.size():
		var values := pattern.recorded_instrument_values[current_time] # { volume, cutoff, resonance }
		instrument.change_filter_to(values.y, values.z, values.x)

	var note_value := instrument.get_note_value(note_data.x)
	var note_voice := instrument.get_note_voice(note_data.x)
	_driver.note_on(note_value, note_voice, note_data.z * NOTE_LENGTH)
	
	if _music_exporting:
		_note_residue.push_back(note_data.z + NOTE_GRACE_PERIOD) # Each note has a grace period to finish.


func play_note(pattern: Pattern, note_data: Vector3i) -> void:
	var song := Controller.current_song
	if not song || song.instruments.is_empty() || song.patterns.is_empty():
		return
	
	_cutoff_note()
	
	var active_instrument := song.instruments[pattern.instrument_idx]
	_play_note(pattern, active_instrument, note_data, note_data.y)


func _cutoff_note() -> void:
	_driver.note_off(-1, 0, 0, 0, true)
	
	# This ensures no residual sound is produced by the effector, even
	# after the note has been cut off.
	_driver.get_effector().clear_slot_effects(0)
	update_driver_effects()


# Playback.

## Called automatically by the driver's timer.
func _playback_step() -> void:
	if not _driver || not _music_playing:
		return
	
	var song := Controller.current_song
	if not song || song.instruments.is_empty() || song.patterns.is_empty() || not song.arrangement:
		return
	
	# Intermediate callbacks only play the notes queued for this step.
	if not _swing_patterns.is_empty():
		_play_swing_patterns(song)
		return

	# Prepare the next timeline bar in the arrangement.
	if _pattern_time >= song.pattern_size:
		_pattern_time = 0
		
		var timeline_looped := song.arrangement.progress_loop()
		if _music_exporting && timeline_looped:
			_playing_residue = true
		
		song.reset_playing_patterns()
		playback_bar_changed.emit()
	
	# When in the playing residue mode, we don't play new notes and just let existing ones to play out.
	if not _playing_residue:
		# Play everything in the current timeline bar.
		var current_bar := song.get_current_arrangement_bar()
		for channel_idx in Arrangement.CHANNEL_NUMBER:
			var pattern_idx := current_bar[channel_idx]
			if pattern_idx < 0:
				continue # No pattern set.
			
			var pattern := song.patterns[pattern_idx]
			pattern.is_playing = true
			
			var active_instrument := song.instruments[pattern.instrument_idx]
			var offset := _swing_offset
			if _pattern_time % 2 == 1:
				offset = int(_swing_offsets.get(active_instrument, _swing_offset))
			
			var queued: QueuedSwingPattern = null
			for note_idx in pattern.note_amount:
				var note_data := pattern.notes[note_idx]
				if note_data.y != _pattern_time:
					continue
				
				if offset <= _swing_offset:
					_play_note(pattern, active_instrument, note_data, _pattern_time)
				else:
					if not queued:
						queued = QueuedSwingPattern.new()
						queued.offset = offset
						queued.pattern = pattern
						queued.instrument = active_instrument
					queued.notes.push_back(note_data)
			
			if queued:
				_swing_patterns.push_back(queued)

	
	# Finalize the logical step only once, not for intermediate swing callbacks.
	_pattern_time += 1
	_update_residue()
	if _music_playing:
		_schedule_swing_step(song)
		playback_tick.emit()


func _update_residue() -> void:
	if not _music_exporting:
		return
	
	if _playing_residue:
		_note_residue_time += 1
	
	var i := _note_residue.size() - 1
	while i >= 0:
		_note_residue[i] -= 1
		if _note_residue[i] <= 0:
			_note_residue.remove_at(i)
		
		i -= 1
	
	if _playing_residue && _note_residue.size() <= 0:
		_playing_residue = false
		_stop_exporting()


## Odd-step offset in GDSiON ticks. Even steps always stay on the grid.
static func get_swing_offset(swing_type: int, swing_amount: int, global_swing: int) -> int:
	match swing_type:
		Instrument.SwingType.SWING_GLOBAL:
			# Preserve the original playback direction and 20%-180% interval range.
			return roundi(-global_swing * SWING_TICKS_PER_NOTE * (1.0 - NOTE_SWING_THRESHOLD) / 10.0)
		Instrument.SwingType.SWING_CLASSIC:
			# Straight (50%) through 3:1 swing (75%).
			return roundi(swing_amount * SWING_TICKS_PER_NOTE / 200.0)
		Instrument.SwingType.SWING_MPC:
			# Quantize downward on a 96 PPQN grid, up to 12 ticks.
			return floori(swing_amount * 12.0 / 100.0) * 5
		Instrument.SwingType.SWING_TR_909:
			# Seven stages, from 0 to 12 ticks at 96 PPQN.
			return roundi(swing_amount * 6.0 / 100.0) * 10
		Instrument.SwingType.SWING_SP_1200:
			# Six stages, from 0 to 10 ticks at 96 PPQN.
			return roundi(swing_amount * 5.0 / 100.0) * 10
	return 0


func _prepare_swing_offsets(song: Song) -> int:
	_swing_offsets.clear()
	var first_offset := SWING_TICKS_PER_NOTE
	for instrument in song.instruments:
		var offset := get_swing_offset(instrument.swing_type, instrument.swing_amount, song.swing)
		_swing_offsets[instrument] = offset
		first_offset = mini(first_offset, offset)
	
	return first_offset if not _swing_offsets.is_empty() else 0


func _set_swing_interval(ticks: int) -> void:
	# The driver truncates its converted event length to an integer. Half a tick
	# protects exact integer intervals against floating-point rounding.
	_driver.set_timer_interval((ticks + 0.5) * NOTE_LENGTH / SWING_TICKS_PER_NOTE)


func _schedule_swing_step(song: Song) -> void:
	if not _swing_patterns.is_empty():
		var next_offset := SWING_TICKS_PER_NOTE
		for queued in _swing_patterns:
			next_offset = mini(next_offset, queued.offset)
		
		_set_swing_interval(next_offset - _swing_offset)
		_swing_offset = next_offset
		return
	
	# An early global swing needs the next odd step to begin before the grid.
	# Snapshot offsets for that step so edits cannot move already queued events.
	var next_offset := 0
	if _pattern_time < song.pattern_size && _pattern_time % 2 == 1:
		next_offset = _prepare_swing_offsets(song)
	else:
		_swing_offsets.clear()
	
	# All intermediate intervals plus this remainder cover exactly one step.
	_set_swing_interval(SWING_TICKS_PER_NOTE + next_offset - _swing_offset)
	_swing_offset = next_offset


func _play_swing_patterns(song: Song) -> void:
	var i := 0
	while i < _swing_patterns.size():
		var queued := _swing_patterns[i]
		if queued.offset != _swing_offset:
			i += 1
			continue
		
		for note_data in queued.notes:
			_play_note(queued.pattern, queued.instrument, note_data, note_data.y)
		_swing_patterns.remove_at(i)
	
	_schedule_swing_step(song)


func _reset_swing() -> void:
	_swing_patterns.clear()
	_swing_offsets.clear()
	_swing_offset = 0
	if _driver:
		_driver.set_timer_interval(NOTE_LENGTH)


func is_playing() -> bool:
	return _music_playing


func is_stopped() -> bool:
	return not _music_playing && _pattern_time < 0


func get_pattern_time() -> int:
	return _pattern_time


func get_next_pattern_time() -> int:
	# When it's stopped, it's stopped.
	if _pattern_time < 0:
		return _pattern_time
	
	var song := Controller.current_song
	if not song:
		return -1
	
	# When it's playing, it's wrapped.
	if _pattern_time >= song.pattern_size:
		return 0
	return _pattern_time


func get_note_time_length() -> float:
	if not Controller.current_song:
		return 0.0
	
	var beat_length_in_sec := 60.0 / Controller.current_song.bpm
	return beat_length_in_sec * NOTE_LENGTH * BEATS_PER_NOTE


func start_playback() -> void:
	if _music_playing:
		return
	
	if _pattern_time == -1:
		_pattern_time = 0
	
	_reset_swing()
	var song := Controller.current_song
	if song && _pattern_time < song.pattern_size && _pattern_time % 2 == 1:
		_swing_offset = _prepare_swing_offsets(song)
	_music_playing = true
	
	_driver.timer_interval.connect(_playback_step)
	_driver.resume() # Unpauses if it was paused, does nothing otherwise.
	playback_started.emit()


func pause_playback(pause_driver: bool = false) -> void:
	if _music_playing:
		_music_playing = false
		_cutoff_note()
		_driver.timer_interval.disconnect(_playback_step)
	
	_reset_swing()
	if pause_driver:
		_driver.pause() # Make sure driver doesn't try to process anything.
	
	playback_paused.emit()


func stop_playback() -> void:
	if _music_playing:
		_music_playing = false
		_cutoff_note()
		_driver.timer_interval.disconnect(_playback_step)
	
	_reset_swing()
	if Controller.current_song:
		Controller.current_song.reset_arrangement()
	
	_pattern_time = -1
	playback_stopped.emit()


# Data rendering and exporting.

func start_exporting(callback: Callable) -> void:
	if _music_exporting:
		return
	
	_music_exporting = true
	_playing_residue = false
	_note_residue.clear()
	_note_residue_time = 0
	reset_driver() # Clears the output so there is no residue at the start.
	
	_exporting_callback = callback
	_driver.streaming.connect(_exporting_callback)
	_driver.set_stream_event_enabled(true)
	start_playback()
	
	export_started.emit()


func _stop_exporting() -> void:
	if not _music_exporting:
		return
	
	_music_exporting = false
	_playing_residue = false
	
	stop_playback()
	_driver.set_stream_event_enabled(false)
	_driver.streaming.disconnect(_exporting_callback)
	
	export_ended.emit()


func is_playing_residue() -> bool:
	return _playing_residue


func get_residue_time() -> int:
	return _note_residue_time


func render_samples(samples: Array[QueuedSample]) -> void:
	if _music_exporting:
		return
	
	# We are rendering the samples via the medium of MML. This is okay
	# because we don't actually need to produce a sound matching the
	# track in any way. Instead, we render a "neutral" sample which is
	# then pitch corrected by the format player.
	# This is pretty much only needed by XM and how XM works.
	
	# The rendering process is blocking, but pretty quick. So no extra
	# logic is needed to handle the queue visually for the user. Maybe
	# some really big compositions would noticeably hang, but we'll
	# address that when we get there.
	
	_music_exporting = true
	reset_driver() # Clears the output so there is no residue at the start.
	
	for sample in samples:
		var note_octave := Note.get_note_octave(sample.note_value)
		var note_literal := Note.get_note_mml(sample.note_value)
	
		var sample_mml := ""
		sample_mml += sample.voice.get_mml(0) + "\n"
		sample_mml += "%%6@0 o%d%s;" % [ note_octave, note_literal ]
		
		print_verbose("MusicPlayer: Rendering a sample for export:")
		print_verbose(sample_mml)
		
		var buffer := _driver.render(sample_mml, 0, 1)
		print_verbose("MusicPlayer: Rendered %d bytes" % [ buffer.size() ])
		sample.callback.call(buffer)
		
		_driver.clear_data()
	
	_music_exporting = false
	reset_driver() # Restarts the driver, because rendering stops it.


class QueuedSwingPattern:
	var offset: int = 0
	var pattern: Pattern = null
	var instrument: Instrument = null
	var notes: Array[Vector3i] = []


class QueuedSample:
	var voice: SiONVoice = null
	var note_value: int = -1	
	var callback: Callable = Callable()
