(
var ccP, ccX, ccY, padX, padXY, ccToInd, ccToXY, noteToInd, noteToXY, activeChord, pianoOn, pianoOff, padOn, padOff, midiOut, channel, chordMap, bendCenter, bendCenterSet, bendSignalCenter, bendScale, semaphore, ccHandler, padDownCount, vibratoInd, xCounter, xBuffer, xAvgLen, xHitDelay, nonVibratoWindow, vibratoExp, onNotes, padsDown, padMap, hitVel, yBuffers, rollStates, yLow, yHigh, findRollState, padDiv, isFirstYCC, yCounter, yAvgLen, isRolling, yErrorDelay, yErrorCount, yCountDelay, padPressures, pianoAudioToggle, isPadCC, isPadNote, isBankNote, bankToInd, bankDown, bankChords, pianoToggleNote;
ccP = {|x| (x%3) == 2}; //check if cc is pressure value
ccX = {|x| (x%3) == 0}; //check if cc is x position
ccY = {|x| (x%3) == 1}; //check if cc is y position
noteToInd = {|x| x - 36}; //convert note to pad index
noteToXY = {|x| [noteToInd.(x)%4, floor(noteToInd.(x)/4)]}; //convert note to pad xy (bottom left 0,0)
ccToInd = {|x| floor((x-23)/3)}; //convert cc number to pad index
ccToXY = {|x| [(ccToInd.(x)%4), floor(ccToInd.(x)/4)]}; //convert cc number to pad xy
isPadCC = {|x| (ccToInd.(x) >=0) && (ccToInd.(x) < 16)};
isPadNote = {|x| (noteToInd.(x) >=0) && (noteToInd.(x) < 16)};
isBankNote = {|x| (x > 10) && (x < 19)};
bankToInd = {|x| x-11};

//objects
semaphore = Semaphore(1); //lock for thread safety
activeChord = SortedList.new(); //the base chord from which inversions will be made
onNotes = Set.new(); //collection that prevents pads with shared notes from turning off shared notes
xBuffer = List.new(); //buffer of x values for running average
padsDown = Set.new(); //set of what pads are down for help calculating what notes to turn off
padMap = Dictionary.new; //maps padInd -> [Dict, Dict] where first is piano -> inversion, second is inversion -> piano
yBuffers = all {: List.new(), x <- (1..16)}; //list of buffers of the last 3 y values for each pad
rollStates = all {: 0, x<-(1..16)}; //list of indexes of the current roll position of pads
isFirstYCC = all {: false, x<-(1..16)}; //list of flags indicating if the next cc is the first one after the noteOn message for that pad
isRolling = all {: false, x<-(1..16)}; //list of flags indicating if that pad is currently rolling the chord
padPressures = all {: 0, x<-(1..16)}; //current pressure of the pressed down pad
bankDown = all {:false, x<-(1..8)};
bankChords = all {:SortedList.new, x<-(1..8)};

//constants and default values
channel = 4; //hard coded,
pianoAudioToggle = false;
bendSignalCenter = 8192;
padDownCount = 0; //update this, and when it returns to zero, set bend position back to bendSignalCenter
xCounter = 0;
bendCenter = 63;
hitVel = 0;
yLow = 15;
yHigh = 112; //127 - 15 - TODO: will need to tweak this and yLow if people want to play chords larger than 5
yAvgLen = 3;
yErrorDelay = 9; //HARDWARE BUG? when a value of 0 or 127 is hit on the y control, it jumps to the center and returns over the course of 9 samples.
yErrorCount = all {: 0, x<-(1..16)};
pianoToggleNote = 19;

//x-axis/vibrato stabilization parameters (tweakable)
bendScale = 50;
xAvgLen = 3;
xHitDelay = 9;
nonVibratoWindow = 13;
vibratoExp = 1.1;

//function that maps a chord to its inversion
//TODO: edge case when chord only has 1 note
chordMap = {|chord, ind|
	var len = chord.size();
	if (ind < 8,
		{//maps bottom two rows of pads in Quneo to chord inversions
			//(ind..ind+len-1).postln;
			//(all {: floor((x-2)/len), x <- (ind..ind+len-1)}).postln;
			all {: (floor((x-2)/len)*12) + chord[(x-2)%len], x <- (ind..ind+len-1)};
		},
		{//maps top two rows of pads in Quneo to adjacent notes in chord inversions
			//(ind-8..ind-8+1).postln;
			//(all {: floor((x-3)/len), x <- (ind-8..ind-8+1)}).postln;
			all {: (floor((x-3)/len)*12) + chord[(x-3)%len], x <- (ind-8..ind-8+1)};
	})
};

//given a particular chord size, this returns a list that indicates the positions
//on the pad's y axis that correspond to particular notes of the chord
padDiv = {|num|
	var segmentSize = floor(127/(num+1));
	all {: segmentSize * i, i <-(1..num)}.asList;
};

//given a buffer of y values and the result of padDiv, this
findRollState = {|yBuff, divList|
	var rollInd, segList, avg;
	segList = List.new();
	avg = yBuff.sum/yBuff.size;
	divList.addFirst(0);
	divList.add(127);
	(1..(divList.size-2)).do({|ind|
		segList.add([divList[ind]-5, divList[ind]+5]);
		segList.add([divList[ind]+5, divList[ind+1]-5]);
	});
	segList.addFirst([0, divList[1]-5]);
	segList[segList.size-1][1] = 127;
	(0..segList.size-1).do({|ind|
		if( (segList[ind][0] < avg) && (avg <= segList[ind][1]), {rollInd = ind});
	});
	rollInd
};

yCountDelay = {|padInd| //returns true if you should delay till the next yCC value
	var ybuf = yBuffers[padInd];
	yErrorCount[padInd] = yErrorCount[padInd] + 1;
	(((ybuf.size == 2) && (abs(ybuf[0]-ybuf[1]) > 10)) || (yErrorCount[padInd] < 9));
};

MIDIIn.connectAll;
midiOut = MIDIOut.newByName("IAC Driver", "Bus 1");
midiOut.latency = 0;

//id numbers used in MIDIFunc hardcoded, found using MIDIClient.prlist

//functions for noteOn/Off messages from piano
pianoOn = MIDIFunc.noteOn({|vel, note, chan, port|
	semaphore.wait;
	activeChord.add(note);
	activeChord.postln;
	if(pianoAudioToggle, {midiOut.noteOn(channel, note, vel);});
	semaphore.signal;}, nil, nil, MIDIClient.sources[2].uid);

pianoOff = MIDIFunc.noteOff({|vel, note, chan, port|
	var newInd, oldInd, newChord;
	semaphore.wait;
	padMap.values.do({|map| //not necessary now that each pad remembers its own "on" notes
		if(map.includesKey(note), {midiOut.noteOff(channel, map.at(note))});
		//format("removing % key from %", note, map).postln;
	});

	activeChord.remove(note);
	//TODO: padsDown.Do uses a function of activeChord and index to calculate which note to turn off.
	//Would changing the active chord here make it so that padsDown.Do would not be able to correctly
	//calculate which note to turn off because the activeChord used to calculate the new index has changed.
	//EX padsDown.Do:: f(oldIndex, g(activeChord, ind)) -> newIndex THUS changing active chord changes pads.Down
	//Should probably have each pad save what its "on" notes are and what piano key each "on" note maps to
	if(pianoAudioToggle, {midiOut.noteOff(channel, note, vel);});
	//activeChord.postln;
	semaphore.signal;}, //so there are no "hanging" notes when you release a piano note before a pad
	nil, nil, MIDIClient.sources[2].uid);

//functions for noteOn/off messages from Queneo
a = {|vel, note, chan, port|
	var newChord, padInd, noteMap;
	padInd = noteToInd.(note);
	hitVel = vel;
	noteMap = Dictionary.new();

	semaphore.wait;
	if(isBankNote.(note), {
		if(activeChord.size == 0,
			{
				if(bankChords[bankToInd.(note)].size != 0,
					{bankChords[bankToInd.(note)].do({|bNote| activeChord.add(bNote)})});

			},
			{
				bankChords[bankToInd.(note)] = activeChord.copy; //TODO: check that this doesn't need to be deepCopy
			}
		);
		bankDown[bankToInd.(note)] = true;
		//TODO: if pianoAudioToggle, play chord
	});
	if((activeChord.size != 0) && isPadNote.(note),
		{
			isFirstYCC[padInd] = true;
			padsDown.add(noteToInd.(note));

			newChord = chordMap.(activeChord, padInd);
			(0..newChord.size-1).do({|i|
				noteMap.put(activeChord[(padInd+i)%newChord.size], newChord[i]);
				//noteMap2.put(newChord[i], activeChord[(padInd+i)%newChord.size]); //not needed?
			});
			padMap.put(padInd, noteMap);
			if(isRolling[padInd].not,
				{
					newChord.do({|i| midiOut.noteOn(channel, i, vel+30)});
					"PAD CHORD PLAY".postln;
			});
			onNotes = onNotes | newChord.as(Set);
			//onNotes.postln;
			padDownCount = padDownCount + 1;
			//if several pads pressed at once, LAST pad determines vibrato (used to be first pad - padCounter==1

			xCounter = 0;
			midiOut.bend(channel, bendSignalCenter);
			bendCenterSet = true;
			//"BEND CENTER SETABLE".postln;
			vibratoInd = noteToInd.(note);
		},
	);
	if(note == pianoToggleNote, {pianoAudioToggle = pianoAudioToggle.not;});
	semaphore.signal;
	vel.postln;
};
padOn = MIDIFunc.noteOn(a, nil, nil, MIDIClient.sources[1].uid);

b = {|vel, note, chan, port|
	var newChord, padInd, noteOffSet;
	padInd = noteToInd.(note);
	semaphore.wait;
	if(isBankNote.(note), {
		if(activeChord.size == 0,
			{

			},
			{

			}
		);
		bankChords[bankToInd.(note)].do({|bNote| activeChord.remove(bNote)});
		bankDown[bankToInd.(note)] = false;
		//TODO: if pianoAudioToggle, turn off chord
	});
	if(isPadNote.(note) /*&& (activeChord.size != 0)*/ && (onNotes.size != 0),
		{
			noteOffSet = padMap.at(padInd).values.asSet;
			(padMap.keys - Set[padInd]).do({|ind|
				noteOffSet = noteOffSet - padMap.at(ind).values.asSet;
				//format("notes on at %: %", ind, padMap.at(ind).values).postln;
			});
			//format("note off set %", noteOffSet).postln;
			noteOffSet.do({|i| midiOut.noteOff(channel, i)});
			onNotes = onNotes - noteOffSet;
			//onNotes.postln;
			padMap.removeAt(padInd);
			padDownCount = padDownCount - 1;
			yBuffers[padInd] = List.new();
			isRolling[padInd] = false;
	});
	semaphore.signal;
}; //if two pads share a note and one pad turns off, the shared note turns off - fix this so shared note stays on
padOff = MIDIFunc.noteOff(b, nil, nil, MIDIClient.sources[1].uid);

//vibrato handling function
c = {|vel, note, chan, port|
	var avg, padInd, newRollState;
	padInd = ccToInd.(note);
	if (isPadCC.(note) && ccX.(note) && vibratoInd == padInd,
		{
			semaphore.wait;
			xCounter = xCounter + 1;
			xBuffer.addFirst(vel);
			if(xBuffer.size == (xAvgLen+1), {xBuffer.pop});
			if(bendCenterSet && (xCounter > xHitDelay),
				{
					bendCenter = vel;
					bendCenterSet = false;
					//format("bendCenter %", bendCenter).postln;
				}
			);
			semaphore.signal;
			avg = ((xBuffer.sum / xBuffer.size) - bendCenter);
			//make this a function of the physical movement rather than directly linear
			if(xCounter > xHitDelay && (abs(avg) > nonVibratoWindow), {
				//format("ind: %, center: %, cc: %, hist: %, dif: %",
				//vibratoInd, bendCenter, vel, xBuffer.size, avg).postln;
				midiOut.bend(channel,
					bendSignalCenter + (bendScale * sign(avg) * ((abs(avg)-nonVibratoWindow)**vibratoExp)));
			});
	});
	if (isPadCC.(note) && ccY.(note),
		{
			yBuffers[padInd].addFirst(vel);
			if(yBuffers[padInd].size == (yAvgLen+1), {yBuffers[padInd].pop});
			//format("       %", vel).postln;
			semaphore.wait;
			if(yBuffers[padInd].size == 1, //isFirstYCC[padInd], HARDWARE BUG? - noteOn happens AFTER first ycc message
				{
					format("FIRST %, padInd:%", vel, padInd).postln;
					if((vel < yLow) || (yHigh < vel),
						{
							// format("args - yBuf:%   padDiv:%", yBuffers[padInd], padDiv.value(padMap.at(padInd).size)).postln;
							isRolling[padInd] = true;
							rollStates[padInd] = findRollState.(yBuffers[padInd], padDiv.(padMap.at(padInd).size));
					});
					isFirstYCC[padInd] = false;
				},
				{
					if((isRolling[padInd]  && yCountDelay.(padInd).not),
						{
							// format("args - yBuf:%   padDiv:%", yBuffers[padInd], padDiv.value(3)).postln;
							newRollState = findRollState.(yBuffers[padInd], padDiv.(padMap.at(padInd).size));
							//DONOW if rollState[padInd] is odd, play inversion[floor(rollState[ind]/2])]
							if((newRollState%2 == 1) && (padMap.at(padInd) != nil) && (rollStates[padInd] != newRollState),
								{
									rollStates[padInd] = newRollState;
									rollStates[padInd].postln;
									midiOut.noteOn(
										channel,
										padMap.at(padInd).values.sort[floor(rollStates[padInd]/2)],
										padPressures[padInd]
									);
									padMap.at(padInd).values.sort[floor(rollStates[padInd]/2)].postln;
							});
					});
				}
			);
			semaphore.signal;
	});
	if (isPadCC.(note) && ccP.(note), {
		semaphore.wait;
		padPressures[padInd] = vel;
		semaphore.signal;
	});
};
ccHandler = MIDIFunc.cc(c, nil, nil, MIDIClient.sources[1].uid);

)

//TODO: make it such that piano and bank chords don't turn off each other's notes when playing together


//-------------------------------SCRATCH CODE BELOW----------------------------------------------------




MIDIClient.init;
MIDIClient.sources[1].uid;














