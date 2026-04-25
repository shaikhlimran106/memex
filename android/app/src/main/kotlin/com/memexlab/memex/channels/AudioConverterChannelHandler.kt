package com.memexlab.memex.channels

import android.app.Activity
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.roundToInt

/**
 * Handles `com.memexlab.memex/audio_converter` MethodChannel.
 * Converts any audio file to WAV 16 kHz mono using MediaCodec.
 */
class AudioConverterChannelHandler {

    companion object {
        private const val CHANNEL = "com.memexlab.memex/audio_converter"

        fun register(flutterEngine: FlutterEngine, activity: Activity) {
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
                .setMethodCallHandler { call, result ->
                    when (call.method) {
                        "convertToWav" -> {
                            val inputPath = call.argument<String>("inputPath")
                            val outputPath = call.argument<String>("outputPath")
                            if (inputPath == null || outputPath == null) {
                                result.error("INVALID_ARGUMENTS", "Missing inputPath or outputPath", null)
                                return@setMethodCallHandler
                            }
                            Thread {
                                try {
                                    convertToWav(inputPath, outputPath)
                                    activity.runOnUiThread { result.success(outputPath) }
                                } catch (e: Exception) {
                                    activity.runOnUiThread { result.error("CONVERT_ERROR", e.message, null) }
                                }
                            }.start()
                        }
                        else -> result.notImplemented()
                    }
                }
        }

        // -- Audio conversion logic --

        private fun convertToWav(inputPath: String, outputPath: String) {
            val extractor = MediaExtractor()
            extractor.setDataSource(inputPath)

            var audioTrackIndex = -1
            for (i in 0 until extractor.trackCount) {
                val format = extractor.getTrackFormat(i)
                val mime = format.getString(MediaFormat.KEY_MIME) ?: ""
                if (mime.startsWith("audio/")) {
                    audioTrackIndex = i
                    break
                }
            }
            if (audioTrackIndex < 0) throw Exception("No audio track found")

            extractor.selectTrack(audioTrackIndex)
            val inputFormat = extractor.getTrackFormat(audioTrackIndex)
            val mime = inputFormat.getString(MediaFormat.KEY_MIME) ?: throw Exception("No MIME type")
            val inputSampleRate = inputFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            val inputChannels = inputFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT)

            val decoder = MediaCodec.createDecoderByType(mime)
            decoder.configure(inputFormat, null, null, 0)
            decoder.start()

            val pcmSamples = mutableListOf<Short>()
            val bufferInfo = MediaCodec.BufferInfo()
            var inputDone = false
            var outputDone = false

            while (!outputDone) {
                if (!inputDone) {
                    val inputBufferIndex = decoder.dequeueInputBuffer(10000)
                    if (inputBufferIndex >= 0) {
                        val inputBuffer = decoder.getInputBuffer(inputBufferIndex)!!
                        val sampleSize = extractor.readSampleData(inputBuffer, 0)
                        if (sampleSize < 0) {
                            decoder.queueInputBuffer(inputBufferIndex, 0, 0, 0,
                                MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputDone = true
                        } else {
                            decoder.queueInputBuffer(inputBufferIndex, 0, sampleSize,
                                extractor.sampleTime, 0)
                            extractor.advance()
                        }
                    }
                }

                val outputBufferIndex = decoder.dequeueOutputBuffer(bufferInfo, 10000)
                if (outputBufferIndex >= 0) {
                    val outputBuffer = decoder.getOutputBuffer(outputBufferIndex)!!
                    val shortBuffer = outputBuffer.order(ByteOrder.LITTLE_ENDIAN).asShortBuffer()
                    val samples = ShortArray(shortBuffer.remaining())
                    shortBuffer.get(samples)

                    if (inputChannels > 1) {
                        for (i in samples.indices step inputChannels) {
                            var sum = 0L
                            for (ch in 0 until inputChannels) {
                                if (i + ch < samples.size) sum += samples[i + ch]
                            }
                            pcmSamples.add((sum / inputChannels).toInt().toShort())
                        }
                    } else {
                        pcmSamples.addAll(samples.toList())
                    }

                    decoder.releaseOutputBuffer(outputBufferIndex, false)
                    if (bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                        outputDone = true
                    }
                }
            }

            decoder.stop()
            decoder.release()
            extractor.release()

            val monoSamples = if (inputSampleRate != 16000) {
                resample(pcmSamples.toShortArray(), inputSampleRate, 16000)
            } else {
                pcmSamples.toShortArray()
            }

            writeWav(outputPath, monoSamples, 16000)
        }

        private fun resample(input: ShortArray, fromRate: Int, toRate: Int): ShortArray {
            val ratio = fromRate.toDouble() / toRate.toDouble()
            val outputLength = (input.size / ratio).roundToInt()
            val output = ShortArray(outputLength)
            for (i in output.indices) {
                val srcIndex = (i * ratio).toInt().coerceAtMost(input.size - 1)
                output[i] = input[srcIndex]
            }
            return output
        }

        private fun writeWav(path: String, samples: ShortArray, sampleRate: Int) {
            val dataSize = samples.size * 2
            val fileSize = 36 + dataSize
            val raf = RandomAccessFile(path, "rw")

            raf.writeBytes("RIFF")
            raf.writeInt(Integer.reverseBytes(fileSize))
            raf.writeBytes("WAVE")
            raf.writeBytes("fmt ")
            raf.writeInt(Integer.reverseBytes(16))
            raf.writeShort(java.lang.Short.reverseBytes(1).toInt())
            raf.writeShort(java.lang.Short.reverseBytes(1).toInt())
            raf.writeInt(Integer.reverseBytes(sampleRate))
            raf.writeInt(Integer.reverseBytes(sampleRate * 2))
            raf.writeShort(java.lang.Short.reverseBytes(2).toInt())
            raf.writeShort(java.lang.Short.reverseBytes(16).toInt())
            raf.writeBytes("data")
            raf.writeInt(Integer.reverseBytes(dataSize))

            val buffer = ByteBuffer.allocate(samples.size * 2).order(ByteOrder.LITTLE_ENDIAN)
            for (sample in samples) {
                buffer.putShort(sample)
            }
            raf.write(buffer.array())
            raf.close()
        }
    }
}
