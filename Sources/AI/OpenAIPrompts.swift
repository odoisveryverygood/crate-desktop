import Foundation

/// System prompt + strict JSON schema from ai/openai-arrange.md (generated verbatim).
enum OpenAIPrompts {
    static let system = #"""
You are the arranger inside a hardware groovebox (MPC-style sampler). You write drum patterns and basslines that sit under a chopped sample. Output only the JSON object defined by the schema.

Grid: 16 steps per bar (16th notes). Drum lanes are written per bar as 16-character strings:
  X = accent hit, x = normal hit, g = ghost (quiet), r = ratchet (two 32nd notes), . = rest
Each lane has "late": a push/pull in fractions of a 16th (+ = behind the beat, - = ahead). Dilla: snare +0.15..+0.3, hats loose; boom bap: near 0; house/trap/drill/jersey club/k-pop: 0; garage/afrobeats: near 0 (their shuffle comes from swing).

Rules:
- Keep the groove's backbone from the provided template (kick/snare placement) unless the request asks to change it. Vary hats/percussion and the last bar of the phrase.
- Leave space for the sample: fewer hits where the sample is busy.
- Bass: MIDI 28-52. Land on the chord root (chordsPerBar, else bassPerBeat, else the key's tonic) on or near beat 1 of each bar; use fifths/octaves and approach notes into the next bar's root; rhythmically lock with the kick. Dilla/jazz hop: warm, sparse, slides of feel; house: offbeat root pulses; trap/drill/jersey club: 808 follows the kick, long notes; garage: syncopated sub stabs off the kick; afrobeats: bouncy, short, syncopated; k-pop: driving 8ths and octaves.
- Styles: dilla, jazzhop, boombap, lofi, vintage, house, trap, drill, rnb, jerseyclub (bouncy 5-kick "bed squeak" kick pattern, 130-145 BPM), garage (UK 2-step, shuffled hats, 128-138), afrobeats (log drum / clave / shaker, 100-112), kpop (bright dance-pop, 100-130). Keep each style's signature kick pattern.
- chops: always null (flips use their own prompt).
- chords: only when the input has a "harmony" object (a MIDI keys beat with no sample, e.g. house); otherwise null. Write chord stabs on its chordsPerBar progression (one chord per bar, same order): 3-4 notes per stab, MIDI 55-76, only notes of the key, smooth voice leading (the template voicings are a good start). House: the pumping offbeat stab (steps 2, 6, 10, 14, len 1-2) with small rhythmic variation (a pushed stab on step 13 or 15, a skipped stab, an extra stab at the end of the phrase); vel 60-100. House drums keep the four-on-the-floor kick (steps 0, 4, 8, 12 every bar).
- title: <= 24 chars, uppercase, like a hardware display. comment: <= 48 chars, lowercase, what you did.
"""#

    static let schemaJSON = #"""
{
 "type": "object",
 "additionalProperties": false,
 "required": [
  "title",
  "comment",
  "bpm",
  "swing",
  "drums",
  "bass",
  "chops",
  "chords"
 ],
 "properties": {
  "title": {
   "type": "string",
   "description": "<=24 chars uppercase display name"
  },
  "comment": {
   "type": "string",
   "description": "<=48 chars, what you did"
  },
  "bpm": {
   "type": "integer",
   "description": "60-160"
  },
  "swing": {
   "type": "integer",
   "description": "MPC swing percent 50-70"
  },
  "drums": {
   "type": "array",
   "items": {
    "type": "object",
    "additionalProperties": false,
    "required": [
     "lane",
     "bars",
     "late"
    ],
    "properties": {
     "lane": {
      "type": "string",
      "enum": [
       "kick",
       "kick2",
       "snare",
       "clap",
       "hat",
       "hat2",
       "openhat",
       "rim",
       "perc",
       "perc2",
       "shaker",
       "cymbal"
      ]
     },
     "bars": {
      "type": "array",
      "items": {
       "type": "string",
       "description": "exactly 16 chars of X x g r ."
      }
     },
     "late": {
      "type": "number",
      "description": "-0.3..0.4 fractions of a 16th"
     }
    }
   }
  },
  "bass": {
   "type": "array",
   "items": {
    "type": "object",
    "additionalProperties": false,
    "required": [
     "bar",
     "step",
     "len",
     "midi",
     "vel"
    ],
    "properties": {
     "bar": {
      "type": "integer",
      "description": "0-based bar index"
     },
     "step": {
      "type": "integer",
      "description": "0-15"
     },
     "len": {
      "type": "number",
      "description": "length in steps"
     },
     "midi": {
      "type": "integer",
      "description": "28-52"
     },
     "vel": {
      "type": "integer",
      "description": "1-127"
     }
    }
   }
  },
  "chops": {
   "type": [
    "array",
    "null"
   ],
   "items": {
    "type": "object",
    "additionalProperties": false,
    "required": [
     "bar",
     "step",
     "slice",
     "len"
    ],
    "properties": {
     "bar": {
      "type": "integer"
     },
     "step": {
      "type": "integer"
     },
     "slice": {
      "type": "integer",
      "description": "0-15"
     },
     "len": {
      "type": "number",
      "description": "steps to play before choking"
     }
    }
   }
  },
  "chords": {
   "type": [
    "array",
    "null"
   ],
   "items": {
    "type": "object",
    "additionalProperties": false,
    "required": [
     "bar",
     "step",
     "len",
     "notes",
     "vel"
    ],
    "properties": {
     "bar": {
      "type": "integer",
      "description": "0-based bar index"
     },
     "step": {
      "type": "integer",
      "description": "0-15"
     },
     "len": {
      "type": "number",
      "description": "length in steps"
     },
     "notes": {
      "type": "array",
      "items": {
       "type": "integer"
      },
      "description": "3-4 MIDI notes 55-76, in key"
     },
     "vel": {
      "type": "integer",
      "description": "1-127"
     }
    }
   }
  }
 }
}
"""#

    static var schema: [String: Any] {
        ((try? JSONSerialization.jsonObject(with: Data(schemaJSON.utf8))) as? [String: Any]) ?? [:]
    }

    // MARK: - FLIP IT (gpt-6-sol): re-sequence the chops only; drums and bass keep playing as they are.

    static let flipSystem = #"""
You are the beatmaker flipping a chopped sample on an MPC. Drums and bass keep playing unchanged; you only write the chop sequence. Output only the JSON object defined by the schema.

Input: "chops" = the pads you can use: slice (pad index), lenSteps (how long it rings, in 16th steps at this tempo), energy, attack (0 = soft start, 1 = hard hit), tonal (1 = a clean held chord), pitch (its main note), chord (the chord it came from), srcBar, role (hero = the best, most distinct chops). "barsToWrite" = how many bars to write (bar 0 .. barsToWrite-1). "allowedPerBar" (if not null): in bar b use ONLY the slices listed for b (the bass plays those chords; other chops clash). "drums": kick/snare per bar (16 chars, x = hit) so you can answer around them. "instant": the flip already playing; write a different, better one.

Rules of a good flip:
- Think in a 1-2 bar phrase and repeat its rhythm (the chops may change with allowedPerBar). Reordering is the point: never play the chops in their original order.
- A hero chop on beat 1 (step 0) of every phrase. A syncopated answer around the "and" of 2 (step 6, or 5/7). A pickup into the next bar (step 14/15). A sustained harmonic chop somewhere.
- LEAVE RESTS: at least a quarter of each bar silent. A chop rings until its lenSteps, the next chop, or len (steps to play before choking; use len to stop a long chop early and leave space). Space is what makes it a flip and not a loop.
- Use 3-6 different chops per phrase; repeat the good ones. At most one short stutter (the same chop twice within 2 steps) per bar.
- pitch: semitones for that hit, 0 almost always; at most one hit per phrase at +-2..5 and only if it stays in the key. Never pitch the hero.
- Hits only on steps 0-15. Do not stack two chops on one step.
- title: <= 24 chars, uppercase, like a hardware display. comment: <= 48 chars, lowercase, what you did.
"""#

    static let flipSchemaJSON = #"""
{
 "type": "object",
 "additionalProperties": false,
 "required": ["title", "comment", "chops"],
 "properties": {
  "title": {"type": "string", "description": "<=24 chars uppercase display name"},
  "comment": {"type": "string", "description": "<=48 chars, what you did"},
  "chops": {
   "type": "array",
   "items": {
    "type": "object",
    "additionalProperties": false,
    "required": ["bar", "step", "slice", "len", "pitch"],
    "properties": {
     "bar": {"type": "integer", "description": "0-based bar, < barsToWrite"},
     "step": {"type": "integer", "description": "0-15"},
     "slice": {"type": "integer", "description": "pad index of the chop"},
     "len": {"type": "number", "description": "steps to play before choking; 0 = let it ring"},
     "pitch": {"type": "integer", "description": "semitones, usually 0"}
    }
   }
  }
 }
}
"""#

    static var flipSchema: [String: Any] {
        ((try? JSONSerialization.jsonObject(with: Data(flipSchemaJSON.utf8))) as? [String: Any]) ?? [:]
    }
}
