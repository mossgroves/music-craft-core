import Foundation

/// Decodes Basic Pitch's frame + onset activation matrices into polyphonic note events.
///
/// A faithful Swift re-implementation of Spotify's `output_to_notes_polyphonic`,
/// `get_infered_onsets`, the `scipy.signal.argrelmax` peak-pick, and the "melodia trick"
/// (`basic_pitch/note_creation.py` @ spotify/basic-pitch fa5997af, Apache-2.0). Pure numeric
/// array logic — no I/O, no external calls. `infer_onsets`, `melodia_trick`, `energy_tol`, and
/// the ±1-frequency suppression match the upstream defaults. `constrain_frequency` and
/// pitch-bend are omitted in Phase 1 (default min/max freq are unbounded; pitch-bend deferred).
enum BasicPitchDecoder {

    struct NoteEvent: Equatable {
        let startFrame: Int
        let endFrame: Int
        let freqIdx: Int       // 0…87; MIDI pitch = freqIdx + 21
        let amplitude: Double  // mean note activation over [startFrame, endFrame)
    }

    static let energyTol = 11   // upstream energy_tol
    static let nDiff = 2        // upstream get_infered_onsets n_diff

    /// `frames` / `onsets`: F × 88 activation matrices. Returns note events.
    static func outputToNotes(frames: [[Double]],
                              onsets rawOnsets: [[Double]],
                              onsetThresh: Double,
                              frameThresh: Double,
                              minNoteLen: Int) -> [NoteEvent] {
        let nFrames = frames.count
        guard nFrames > 1, let nFreq = frames.first?.count, nFreq > 0 else { return [] }
        let maxFreqIdx = nFreq - 1

        // infer_onsets=True: combine predicted onsets with frame-difference onsets.
        let onsets = inferredOnsets(onsets: rawOnsets, frames: frames)

        // argrelmax along the time axis (strictly greater than both temporal neighbours),
        // gated by onsetThresh. Collected in row-major (time-major) order, then iterated in
        // reverse (descending time) — matching upstream `[::-1]`.
        var onsetPeaks: [(t: Int, f: Int)] = []
        for t in 1 ..< (nFrames - 1) {
            for f in 0 ..< nFreq {
                let v = onsets[t][f]
                if v > onsets[t - 1][f] && v > onsets[t + 1][f] && v >= onsetThresh {
                    onsetPeaks.append((t, f))
                }
            }
        }
        onsetPeaks.reverse()

        var remaining = frames   // remaining_energy = copy(frames)
        var events: [NoteEvent] = []

        for (noteStart, f) in onsetPeaks {
            if noteStart >= nFrames - 1 { continue }

            // Walk forward until energy stays below frameThresh for energyTol frames.
            var i = noteStart + 1
            var k = 0
            while i < nFrames - 1 && k < energyTol {
                if remaining[i][f] < frameThresh { k += 1 } else { k = 0 }
                i += 1
            }
            i -= k   // back to the last frame above threshold

            if i - noteStart <= minNoteLen { continue }

            zeroEnergy(&remaining, start: noteStart, end: i, freq: f, maxFreqIdx: maxFreqIdx)
            let amp = meanActivation(frames, start: noteStart, end: i, freq: f)
            events.append(NoteEvent(startFrame: noteStart, endFrame: i, freqIdx: f, amplitude: amp))
        }

        // Melodia trick: keep extracting the strongest remaining energy until it falls below
        // frameThresh, growing each note forward and backward.
        while true {
            guard let (iMid, f, maxVal) = argmax2D(remaining), maxVal > frameThresh else { break }
            remaining[iMid][f] = 0

            // forward pass
            var i = iMid + 1
            var k = 0
            while i < nFrames - 1 && k < energyTol {
                if remaining[i][f] < frameThresh { k += 1 } else { k = 0 }
                remaining[i][f] = 0
                if f < maxFreqIdx { remaining[i][f + 1] = 0 }
                if f > 0 { remaining[i][f - 1] = 0 }
                i += 1
            }
            let iEnd = i - 1 - k

            // backward pass
            i = iMid - 1
            k = 0
            while i > 0 && k < energyTol {
                if remaining[i][f] < frameThresh { k += 1 } else { k = 0 }
                remaining[i][f] = 0
                if f < maxFreqIdx { remaining[i][f + 1] = 0 }
                if f > 0 { remaining[i][f - 1] = 0 }
                i -= 1
            }
            let iStart = max(0, i + 1 + k)

            if iEnd - iStart <= minNoteLen { continue }
            let amp = meanActivation(frames, start: iStart, end: max(iStart + 1, iEnd), freq: f)
            events.append(NoteEvent(startFrame: iStart, endFrame: max(iStart + 1, iEnd), freqIdx: f, amplitude: amp))
        }

        return events
    }

    // MARK: - Helpers (faithful to upstream)

    /// `get_infered_onsets`: max of the predicted onsets and the (rescaled, clamped) minimum
    /// forward frame-difference over 1…nDiff steps.
    private static func inferredOnsets(onsets: [[Double]], frames: [[Double]]) -> [[Double]] {
        let nFrames = frames.count
        guard nFrames > 0, let nFreq = frames.first?.count else { return onsets }

        var frameDiff = [[Double]](repeating: [Double](repeating: 0, count: nFreq), count: nFrames)
        for t in 0 ..< nFrames {
            for f in 0 ..< nFreq {
                if t < nDiff { frameDiff[t][f] = 0; continue }
                // min over n in 1...nDiff of (frames[t] - frames[t-n])
                var minDiff = Double.greatestFiniteMagnitude
                for n in 1 ... nDiff {
                    minDiff = Swift.min(minDiff, frames[t][f] - frames[t - n][f])
                }
                frameDiff[t][f] = Swift.max(0, minDiff)
            }
        }

        let onsetsMax = onsets.flatMap { $0 }.max() ?? 0
        let diffMax = frameDiff.flatMap { $0 }.max() ?? 0
        if diffMax > 0 {
            let scale = onsetsMax / diffMax
            for t in 0 ..< nFrames { for f in 0 ..< nFreq { frameDiff[t][f] *= scale } }
        }

        var out = onsets
        for t in 0 ..< nFrames { for f in 0 ..< nFreq { out[t][f] = Swift.max(onsets[t][f], frameDiff[t][f]) } }
        return out
    }

    private static func zeroEnergy(_ m: inout [[Double]], start: Int, end: Int, freq: Int, maxFreqIdx: Int) {
        for r in start ..< end {
            m[r][freq] = 0
            if freq < maxFreqIdx { m[r][freq + 1] = 0 }
            if freq > 0 { m[r][freq - 1] = 0 }
        }
    }

    private static func meanActivation(_ frames: [[Double]], start: Int, end: Int, freq: Int) -> Double {
        guard end > start else { return 0 }
        var sum = 0.0
        for r in start ..< end { sum += frames[r][freq] }
        return sum / Double(end - start)
    }

    private static func argmax2D(_ m: [[Double]]) -> (Int, Int, Double)? {
        var best: (Int, Int, Double)? = nil
        for t in 0 ..< m.count {
            for f in 0 ..< m[t].count {
                let v = m[t][f]
                if best == nil || v > best!.2 { best = (t, f, v) }
            }
        }
        return best
    }
}
