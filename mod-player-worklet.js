const PAULA_FREQUENCY = 3546894.6;

const ARPEGGIO = 0x00;
const SLIDE_UP = 0x01;
const SLIDE_DOWN = 0x02;
const TONE_PORTAMENTO = 0x03;
const VIBRATO = 0x04;
const TONE_PORTAMENTO_WITH_VOLUME_SLIDE = 0x05;
const VIBRATO_WITH_VOLUME_SLIDE = 0x06;
const TREMOLO = 0x07;
const PANNING = 0x08;
const SAMPLE_OFFSET = 0x09;
const POSITION_JUMP = 0x0B;
const VOLUME_SLIDE = 0x0A;
const SET_VOLUME = 0x0C;
const PATTERN_BREAK = 0x0D;
const EXTENDED = 0x0e;
const SET_SPEED = 0x0f;
const PORTA_UP_FINE = 0xe1;
const PORTA_DOWN_FINE = 0xe2;
const RETRIGGER_NOTE = 0xe9;
const VOLUME_SLIDE_UP_FINE = 0xea;
const VOLUME_SLIDE_DOWN_FINE = 0xeb;
const DELAY_NOTE = 0xed;

const unimplementedEffects = new Set();

class Channel {
    constructor(worklet, index) {
        this.worklet = worklet;
        this.channelIndex = index;
        this.instrument = null;
        this.playing = false;
        this.period = 0;
        this.currentPeriod = 0;
        this.portamentoSpeed = 0;
        this.periodDelta = 0;
        this.vibratoDepth = 0;
        this.vibratoSpeed = 0;
        this.vibratoIndex = 0;
        this.arpeggio = false;
        this.sampleSpeed = 0.0;
        this.sampleIndex = 0;
        this.volume = 64;
        this.currentVolume = 64;
        
        // Panning, Tremolo, Loops und Cut-Note Initialisierung
        this.panning = (index === 1 || index === 4) ? 0 : 255; // LRRL Standard-Panning
        this.tremolo = false;
        this.tremoloSpeed = 0;
        this.tremoloDepth = 0;
        this.tremoloIndex = 0;
        this.patternLoopStartRow = 0;
        this.patternLoopCount = -1;
        this.cutNoteTick = -1;
    }

    nextOutput() {
        if (!this.instrument || !this.period || !this.instrument.bytes || this.instrument.bytes.length === 0) return 0.0;
        
        const idx = this.sampleIndex | 0;
        if (idx < 0 || idx >= this.instrument.bytes.length) {
            return 0.0;
        }
        const sample = this.instrument.bytes[idx];

        this.sampleIndex += this.sampleSpeed;

        if (this.instrument.isLooped) {
            const loopEnd = this.instrument.repeatOffset + this.instrument.repeatLength;
            if (this.sampleIndex >= loopEnd) {
                this.sampleIndex = this.instrument.repeatOffset;
            }
        }
        else if (this.sampleIndex >= this.instrument.length) {
            return 0.0;
        }

        if (typeof sample !== 'number' || isNaN(sample)) {
            return 0.0;
        }

        return sample / 256.0 * this.currentVolume / 64;
    }

    performTick() {
        if (this.volumeSlide && this.worklet.tick > 0) {
            this.currentVolume += this.volumeSlide;
            if (this.currentVolume < 0) this.currentVolume = 0;
            if (this.currentVolume > 64) this.currentVolume = 64;
        }

        if (this.vibrato) {
            this.vibratoIndex = (this.vibratoIndex + this.vibratoSpeed) % 64;
            this.currentPeriod = this.period + Math.sin(this.vibratoIndex / 64 * Math.PI * 2) * this.vibratoDepth;
        }
        else if (this.tremolo) {
            this.tremoloIndex = (this.tremoloIndex + this.tremoloSpeed) % 64;
            const volDelta = Math.sin(this.tremoloIndex / 64 * Math.PI * 2) * this.tremoloDepth;
            this.currentVolume = Math.max(0, Math.min(64, this.volume + volDelta));
        }
        else if (this.periodDelta) {
            if (this.portamento) {
                if (this.currentPeriod != this.period) {
                    const sign = Math.sign(this.period - this.currentPeriod);
                    const distance = Math.abs(this.currentPeriod - this.period);
                    const diff = Math.min(distance, this.periodDelta);
                    this.currentPeriod += sign * diff;
                }
            }
            else {
                this.currentPeriod += this.periodDelta;
            }
        }
        else if (this.arpeggio) {
            const index = this.worklet.tick % this.arpeggio.length;
            const halfNotes = this.arpeggio[index];
            this.currentPeriod = this.period / Math.pow(2, halfNotes / 12);
        }
        else if (this.retrigger && (this.worklet.tick % this.retrigger) == 0) {
            this.sampleIndex = 0;
        }
        else if (this.delayNote === this.worklet.tick) {
            this.instrument = this.setInstrument;
            this.volume = this.setVolume;
            this.currentVolume = this.volume;
            this.period = this.setPeriod;
            this.currentPeriod = this.period;
            this.sampleIndex = 0;
        }

        if (this.currentPeriod < 113) this.currentPeriod = 113;
        if (this.currentPeriod > 856) this.currentPeriod = 856;

        const sampleRate = PAULA_FREQUENCY / this.currentPeriod;
        this.sampleSpeed = sampleRate / this.worklet.sampleRate;

        // Cut-Note Effekt anwenden
        if (this.cutNoteTick === this.worklet.tick) {
            this.currentVolume = 0;
        }
    }

    play(note) {
        let publishNote = false;

        this.setInstrument = false;
        this.setVolume = false;
        this.setPeriod = false;
        this.delayNote = false;
        this.cutNoteTick = -1; // Cut-Note auf neuem Ton zurücksetzen

        if (note.instrument) {
            const inst = this.worklet.mod.instruments[note.instrument];
            if (inst) {
                this.setInstrument = inst;
                this.setVolume = inst.volume;
            } else {
                this.setInstrument = null;
                this.setVolume = 0;
            }
        }

        this.setSampleIndex = false;
        this.setCurrentPeriod = false;

        if (note.period) {
            const instrument = this.setInstrument || this.instrument;
            const finetune = instrument && instrument.finetune || 0;

            this.setPeriod = note.period - finetune;
            this.setCurrentPeriod = true;
            this.setSampleIndex = 0;
            publishNote = true;
        }

        this.effect(note);

        if (this.delayNote) return;

        if (this.setInstrument) {
            this.instrument = this.setInstrument;
        }

        if (this.setVolume !== false) {
            this.volume = this.setVolume;
            this.currentVolume = this.volume;
        }

        if (this.setPeriod) {
            this.period = this.setPeriod;
        }

        if (this.setCurrentPeriod) {
            this.currentPeriod = this.period;
        }

        if (this.setSampleIndex !== false) {
            this.sampleIndex = this.setSampleIndex;
        }

        if (this.worklet.publishNote && publishNote) {
            this.worklet.port.postMessage({
                type: 'note',
                channel: this.channelIndex,
                sample: this.instrument?.index,
                volume: this.currentVolume,
                period: this.period
            });
        }
    }

    effect({hasEffect, effectId, effectData, effectHigh, effectLow}) {
        this.volumeSlide = 0;
        this.periodDelta = 0;
        this.portamento = false;
        this.vibrato = false;
        this.tremolo = false; // Tremolo-Flag zurücksetzen
        this.arpeggio = false;
        this.retrigger = false;
        this.delayNote = false;

        if (!hasEffect) return;

        switch (effectId) {
            case ARPEGGIO:
                this.arpeggio = [0, effectHigh, effectLow];
                break;
            case SLIDE_UP:
                this.periodDelta = -effectData;
                break;
            case SLIDE_DOWN:
                this.periodDelta = effectData;
                break;
            case TONE_PORTAMENTO:
                this.portamento = true;
                if (effectData) this.portamentoSpeed = effectData;
                this.periodDelta = this.portamentoSpeed;
                this.setCurrentPeriod = false;
                this.setSampleIndex = false;
                break;
            case PORTA_UP_FINE:
                this.setPeriod = this.period - effectData;
                break;
            case PORTA_DOWN_FINE:
                this.setPeriod = this.period + effectData;
                break;
            case VIBRATO:
                if (effectHigh) this.vibratoSpeed = effectHigh;
                if (effectLow) this.vibratoDepth = effectLow;
                this.vibrato = true;
                break;
            case TONE_PORTAMENTO_WITH_VOLUME_SLIDE:
                this.portamento = true;
                this.setCurrentPeriod = false;
                this.setSampleIndex = false;
                this.periodDelta = this.portamentoSpeed;
                if (effectHigh) this.volumeSlide = effectHigh;
                else if (effectLow) this.volumeSlide = -effectLow;
                break;
            case VIBRATO_WITH_VOLUME_SLIDE:
                this.vibrato = true;
                if (effectHigh) this.volumeSlide = effectHigh;
                else if (effectLow) this.volumeSlide = -effectLow;
                break;
            case VOLUME_SLIDE:
                if (effectHigh) this.volumeSlide = effectHigh;
                else if (effectLow) this.volumeSlide = -effectLow;
                break;
            case VOLUME_SLIDE_UP_FINE:
                this.setVolume = Math.min(64, this.volume + effectData);
                break;
            case VOLUME_SLIDE_DOWN_FINE:
                this.setVolume = Math.max(0, this.volume - effectData);
                break;
            case SAMPLE_OFFSET:
                this.setSampleIndex = effectData * 256;
                break;
            case SET_VOLUME:
                this.setVolume = effectData;
                break;
            case PATTERN_BREAK:
                const row = effectHigh * 10 + effectLow;
                this.worklet.setPatternBreak(row);
                break;
            case SET_SPEED:
                if (effectData >= 1 && effectData <= 31) {
                    this.worklet.setTicksPerRow(effectData);
                }
                else {
                    this.worklet.setBpm(effectData);
                }
                break;
            case RETRIGGER_NOTE:
                this.retrigger = effectData;
                break;
            case DELAY_NOTE:
                this.delayNote = effectData;
                break;
            case TREMOLO:
                if (effectHigh) this.tremoloSpeed = effectHigh;
                if (effectLow) this.tremoloDepth = effectLow;
                this.tremolo = true;
                break;
            case PANNING:
                this.panning = effectData;
                break;
            case POSITION_JUMP:
                this.worklet.setPositionJump(effectData);
                break;
            case 0xe0:
                // Amiga Filter LED (Dummy)
                break;
            case 0xe6: // Pattern Loop
                if (effectLow === 0) {
                    this.patternLoopStartRow = this.worklet.rowIndex;
                } else {
                    if (this.patternLoopCount < 0) {
                        this.patternLoopCount = effectLow;
                    }
                    if (this.patternLoopCount > 0) {
                        this.patternLoopCount--;
                        this.worklet.setPatternLoopRow(this.patternLoopStartRow);
                    } else {
                        this.patternLoopCount = -1;
                    }
                }
                break;
            case 0xe8: // Extended Panning
                this.panning = effectLow * 17; // Skalieren nach 0..255
                break;
            case 0xec: // Cut Note
                this.cutNoteTick = effectLow;
                break;
            case 0xee: // Pattern Delay
                this.worklet.setPatternDelay(effectLow);
                break;
            default:
                if (!unimplementedEffects.has(effectId)) {
                    unimplementedEffects.add(effectId);
                    console.log(`Unimplemented effect ${effectId.toString(16)}`);
                }
                break;
        }
    }
}

class ModPlayerWorklet extends AudioWorkletProcessor {
    constructor() {
        super();
        this.port.onmessage = this.onmessage.bind(this);
        this.mod = null;
        this.channels = [ new Channel(this, 1), new Channel(this, 2), new Channel(this, 3), new Channel(this,4) ];
        this.patternBreak = false;
        
        // Jump, Loop und Delay States für ProTracker-Effektsteuerung
        this.positionJump = false;
        this.patternLoopRow = false;
        this.patternDelay = 0;
        this.patternDelayCounter = 0;
        
        this.publishRow = false;
        this.publishStop = false;
        this.publishNote = false;
        // Echte VU-Pegel: pro Channel der maximale |Output| seit dem letzten
        // Post ans Main-Thread. So zeigt das Meter, wie laut der Sample
        // tatsaechlich gerade klingt (nicht nur den Note-Trigger).
        this.publishLevels = false;
        this.channelPeaks = [0, 0, 0, 0];
        // process() laeuft pro Render-Block (typischerweise 128 Frames).
        // Wir bundeln mehrere Blocks pro Level-Post, damit der MessagePort
        // nicht mit 300+ Nachrichten/Sekunde geflutet wird.
        // Bei 48000 Hz / 128 Frames = 375 Blocks/sec. levelBlockInterval=8
        // ergibt ~47 Updates/sec — flüssig genug fürs Auge.
        this.blocksUntilLevelPost = 0;
        this.levelBlockInterval = 8;
    }

    onmessage(e) {
        switch (e.data.type) {
            case 'play':
                this.play(e.data.mod, e.data.sampleRate);
                break;
            case 'stop':
                this.stop();
                break;
            case 'resume':
                this.resume();
                break;
            case 'setRow':
                this.setRow(e.data.position, e.data.row);
                break;
            case 'enableRowSubscription':
                this.publishRow = true;
                break;
            case 'disableRowSubscription':
                this.publishRow = false;
                break;
            case 'enableStopSubscription':
                this.publishStop = true;
                break;
            case 'enableNoteSubscription':
                this.publishNote = true;
                break;
            case 'enableLevelSubscription':
                // Aktiviert das echte VU-Tracking (siehe Konstruktor).
                this.publishLevels = true;
                break;
            case 'disableLevelSubscription':
                this.publishLevels = false;
                break;
        }
    }

    play(mod, sampleRate) {
        this.mod = mod;
        this.sampleRate = sampleRate;

        this.setBpm(125);
        this.setTicksPerRow(6);

        // Start at the last tick of the pattern "before the first pattern"
        this.position = -1;
        this.rowIndex = 63;
        this.tick = 5;
        this.ticksPerRow = 6;

        // Immediately move to the first row of the first pattern
        this.outputsUntilNextTick = 0;
        this.playing = true;
    }

    stop() {
        this.playing = false;
    }

    resume() {
        this.playing = true;
    }

    setRow(position, row) {
        this.rowIndex = row - 1;
        if (this.rowIndex == -1) {
            this.rowIndex = 63;
            this.position = position - 1;
        }
        else {
            this.position = position;
        }
        this.tick = this.ticksPerRow - 1;
        this.outputsUntilNextTick = 0;
        this.patternBreak = false;
    }

    setTicksPerRow(ticksPerRow) {
        this.ticksPerRow = ticksPerRow;
    }

    setBpm(bpm) {
        this.bpm = bpm;
        this.outputsPerTick = this.sampleRate * 60 / this.bpm / 4 / 6;
        if ((bpm === 0) && this.publishStop) {
            this.port.postMessage({ type: 'stop' });
        }
    }

    setPatternBreak(row) {
        this.patternBreak = row;
    }

    setPositionJump(pos) {
        this.positionJump = pos;
    }

    setPatternLoopRow(row) {
        this.patternLoopRow = row;
    }

    setPatternDelay(delay) {
        if (this.patternDelayCounter === 0) {
            this.patternDelay = delay;
        }
    }

    nextRow() {
        let targetPosition = this.position;
        let targetRow = this.rowIndex + 1;

        if (this.patternLoopRow !== false) {
            targetRow = this.patternLoopRow;
            this.patternLoopRow = false;
        } else {
            if (this.positionJump !== false) {
                targetPosition = this.positionJump;
                targetRow = 0;
                this.positionJump = false;
            }
            if (this.patternBreak !== false) {
                if (targetPosition === this.position) {
                    targetPosition = this.position + 1;
                }
                targetRow = this.patternBreak;
                this.patternBreak = false;
            } else if (targetRow === 64) {
                targetRow = 0;
                targetPosition = this.position + 1;
            }
        }

        this.position = targetPosition;
        this.rowIndex = targetRow;

        if (this.position >= this.mod.length) {
            this.position = 0;
        }

        const patternIndex = this.mod.patternTable[this.position];
        const pattern = this.mod.patterns[patternIndex];
        const row = pattern.rows[this.rowIndex];
        if (!row) return;

        for (let i = 0; i < 4; ++i) {
            this.channels[i].play(row.notes[i]);
        }

        if (this.publishRow) {
            this.port.postMessage({
                type: 'row',
                position: this.position,
                rowIndex: this.rowIndex,
                bpm: this.bpm,
                speed: this.ticksPerRow
            });
        }
    }

    nextTick() {
        ++this.tick;
        if (this.tick == this.ticksPerRow) {
            if (this.patternDelayCounter > 0) {
                this.patternDelayCounter--;
                this.tick = 0; // Wiederholt aktuelle Zeile (Tick 0)
            } else if (this.patternDelay > 0) {
                this.patternDelayCounter = this.patternDelay;
                this.patternDelay = 0;
                this.tick = 0; // Wiederholt aktuelle Zeile (Tick 0)
            } else {
                this.tick = 0;
                this.nextRow();
            }
        }

        for (let i = 0; i < 4; ++i) {
            this.channels[i].performTick();
        }
    }

    nextOutput() {
        if (!this.mod || !this.playing) return { left: 0.0, right: 0.0 };

        if (this.outputsUntilNextTick <= 0) {
            this.nextTick();
            this.outputsUntilNextTick += this.outputsPerTick;
        }
        this.outputsUntilNextTick--;

        let left = 0.0;
        let right = 0.0;

        for (let i = 0; i < 4; ++i) {
            const chOut = this.channels[i].nextOutput();
            const p = this.channels[i].panning / 255.0;
            // Angenehme Stereo-Verteilung (z. B. 90% Separation)
            const lGain = (1.0 - p) * 0.9 + 0.1 * p;
            const rGain = p * 0.9 + 0.1 * (1.0 - p);
            left += chOut * lGain;
            right += chOut * rGain;

            if (this.publishLevels) {
                const a = chOut < 0 ? -chOut : chOut;
                if (a > this.channelPeaks[i]) this.channelPeaks[i] = a;
            }
        }

        return {
            left: Math.tanh(left),
            right: Math.tanh(right)
        };
    }

    process(inputs, outputs) {
        try {
            const output = outputs[0];
            if (!output || output.length === 0) return true;
            const numChannels = output.length;
            const frameCount = output[0].length;

            if (numChannels >= 2) {
                for (let i = 0; i < frameCount; ++i) {
                    const { left, right } = this.nextOutput();
                    output[0][i] = left;
                    output[1][i] = right;
                }
            } else {
                // Mono fallback
                for (let i = 0; i < frameCount; ++i) {
                    const { left, right } = this.nextOutput();
                    const monoValue = (left + right) * 0.5;
                    for (let c = 0; c < numChannels; ++c) {
                        output[c][i] = monoValue;
                    }
                }
            }
            // Nach jedem Render-Block: Level-Update an Main-Thread,
            // aber nur alle levelBlockInterval Blocks (siehe Konstruktor).
            // Wir senden ein Array mit Kopien der Peaks und resetten danach,
            // damit der nächste Block einen frischen Maximalwert sammelt.
            if (this.publishLevels) {
                this.blocksUntilLevelPost++;
                if (this.blocksUntilLevelPost >= this.levelBlockInterval) {
                    this.port.postMessage({
                        type: 'levels',
                        peaks: [
                            this.channelPeaks[0],
                            this.channelPeaks[1],
                            this.channelPeaks[2],
                            this.channelPeaks[3]
                        ]
                    });
                    this.channelPeaks[0] = 0;
                    this.channelPeaks[1] = 0;
                    this.channelPeaks[2] = 0;
                    this.channelPeaks[3] = 0;
                    this.blocksUntilLevelPost = 0;
                }
            }
        } catch (e) {
            console.error("AudioWorklet error in process:", e);
        }
        return true;
    }
}

registerProcessor('mod-player-worklet', ModPlayerWorklet);
