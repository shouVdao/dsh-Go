package io.github.ccch1mneyyy.dsh_app.nativemedia

import ai.onnxruntime.OrtEnvironment
import android.content.res.AssetManager
import android.util.Log

/**
 * The models ship in the APK; where ONNX Runtime cannot load them, or once
 * crashed the app on this phone ([NativeTrial]), the energy gate does the work.
 */
object SpeechGates {
    /** The trial of the call that is running now, if it got as far as loading. */
    private var live: NativeTrial? = null

    fun create(assets: AssetManager, echoCancelled: Boolean, marks: NativeTrial.Marks): TurnGate {
        var vad: OrtSilero? = null
        var turn: OrtSmartTurn? = null
        var trial: NativeTrial? = null
        try {
            trial = NativeTrial(marks, "ort-" + OrtEnvironment.getEnvironment().version)
            if (trial.blocked()) {
                Log.w("SpeechGates", "ONNX Runtime crashed here before; using energy gate")
                return SpeechGate(echoCancelled)
            }
            // The mark stays for the whole call, not just the proving run: an
            // inference that aborts the process can happen at any point, and the
            // next call has to know about it. [settled] clears it again when the
            // call ends normally.
            trial.begin()
            live = trial
            val proving = !trial.proven
            vad = OrtSilero(load(assets, "silero_vad.onnx"))
            turn = OrtSmartTurn(load(assets, "smart-turn-v3.2-cpu.onnx"))
            // Initialize the streaming VAD; smart-turn runs on its worker, and
            // once here the first time, so both have answered before the mark goes.
            vad.probability(ShortArray(512))
            vad.reset()
            if (proving) {
                turn.probability(FloatArray(NeuralGate.WINDOW_SAMPLES))
                trial.passed()
            }
            return NeuralGate(vad, turn, echoCancelled, onTurnFailed = {
                Log.w("SpeechGates", "Turn model failed; pauses end after the energy gate's hangover", it)
            })
        } catch (e: Exception) {
            trial?.dropped()
            live = null
            Log.w("SpeechGates", "Neural models unavailable; using energy gate", e)
        } catch (e: LinkageError) {
            trial?.dropped()
            live = null
            Log.w("SpeechGates", "ONNX Runtime unavailable; using energy gate", e)
        }
        turn?.close()
        vad?.close()
        return SpeechGate(echoCancelled)
    }

    /**
     * The call ended and the process is still here: the trial's mark can go, so
     * the next call does not read it as a crash.
     */
    fun settled() {
        live?.dropped()
        live = null
    }

    private fun load(assets: AssetManager, name: String): ByteArray = assets.open("speech/$name").use { it.readBytes() }
}
