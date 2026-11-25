###################################################
# Part of Bosca Ceoil Blue                        #
# Provided under MIT                              #
###################################################

# Run with Godot and the project's GDSiON dependency installed:
# godot --headless --path . --script tests/swing_timing.gd
extends SceneTree


func _initialize() -> void:
	var types := [
		Instrument.SwingType.SWING_CLASSIC,
		Instrument.SwingType.SWING_MPC,
		Instrument.SwingType.SWING_TR_909,
		Instrument.SwingType.SWING_SP_1200,
	]
	var maxima := [ 60, 60, 60, 50 ]
	
	for i in types.size():
		var previous := -1
		for amount in range(0, 101, 5):
			var offset := MusicPlayer.get_swing_offset(types[i], amount, 10)
			if offset < previous || offset < 0 || offset > maxima[i]:
				printerr("Invalid swing offset for type %d, amount %d: %d" % [ types[i], amount, offset ])
				quit(1)
				return
			if (amount == 0 && offset != 0) || (amount == 100 && offset != maxima[i]):
				printerr("Incorrect swing endpoint for type %d, amount %d" % [ types[i], amount ])
				quit(1)
				return
			previous = offset
	
	var cases := [
		[ Instrument.SwingType.SWING_GLOBAL, 0, 10, -96 ],
		[ Instrument.SwingType.SWING_GLOBAL, 100, -10, 96 ],
		[ Instrument.SwingType.SWING_GLOBAL, 100, 0, 0 ],
		[ Instrument.SwingType.SWING_CLASSIC, 40, 0, 24 ],
		[ Instrument.SwingType.SWING_MPC, 40, 0, 20 ],
		[ Instrument.SwingType.SWING_TR_909, 65, 0, 40 ],
		[ Instrument.SwingType.SWING_SP_1200, 80, 0, 40 ],
	]
	for test in cases:
		if MusicPlayer.get_swing_offset(test[0], test[1], test[2]) != test[3]:
			printerr("Swing timing test failed: ", test)
			quit(1)
			return
	
	print("Swing timing profiles passed.")
	quit()
