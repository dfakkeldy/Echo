#include <metal_stdlib>
using namespace metal;

// MARK: - Uniforms

struct VisualizerUniforms {
    float time;
    float rms;
    float peak;
    float spectrum[16];
};

// MARK: - HSV Helper

float3 hsv2rgb(float3 c) {
    float4 K = float4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
    float3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
    return c.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
}

// MARK: - Shared Vertex Shader

vertex float4 vertexMain(uint vertexID [[vertex_id]]) {
    float2 positions[6] = {
        float2(-1, -1), float2( 1, -1), float2(-1,  1),
        float2( 1, -1), float2( 1,  1), float2(-1,  1)
    };
    return float4(positions[vertexID], 0.0, 1.0);
}

// MARK: - Acid Warp

/// Psychedelic colour-cycling fractal driven by RMS amplitude.
fragment float4 acidWarpFragment(
    float4 position [[position]],
    constant VisualizerUniforms &u [[buffer(0)]]
) {
    float2 uv = position.xy / float2(400.0, 800.0);
    float hue = fmod(uv.x + uv.y + u.time * 0.1 + u.rms * 0.5, 1.0);
    float saturation = 0.8 + u.peak * 0.2;
    float brightness = 0.3 + u.rms * 0.7;
    float3 color = hsv2rgb(float3(hue, saturation, brightness));
    return float4(color, 1.0);
}

// MARK: - Spectrum Bars

/// Classic frequency-bar visualiser split into 16 bins.
fragment float4 spectrumBarsFragment(
    float4 position [[position]],
    constant VisualizerUniforms &u [[buffer(0)]]
) {
    float2 uv = position.xy / float2(400.0, 800.0);
    int barIndex = int(uv.x * 16.0);
    float value = u.spectrum[clamp(barIndex, 0, 15)];
    float brightness = uv.y > (1.0 - value) ? 1.0 : 0.1;
    float hue = float(barIndex) / 16.0;
    float3 color = hsv2rgb(float3(hue, 0.7, brightness));
    return float4(color, 1.0);
}

// MARK: - Waveform River

/// Scrolling waveform line whose amplitude follows the audio RMS.
fragment float4 waveformRiverFragment(
    float4 position [[position]],
    constant VisualizerUniforms &u [[buffer(0)]]
) {
    float2 uv = position.xy / float2(400.0, 800.0);
    float x = fmod(uv.x + u.time * 0.2, 1.0);
    float wave = sin(x * 40.0 + u.time) * u.rms * 0.3;
    float brightness = abs(uv.y - 0.5 - wave) < 0.02 ? 1.0 : 0.1;
    float hue = u.rms * 0.6;
    float3 color = hsv2rgb(float3(hue, 0.6, brightness));
    return float4(color, 1.0);
}

// MARK: - Particle Flow

/// Orbiting particles whose radial distance pulses with audio energy.
fragment float4 particleFlowFragment(
    float4 position [[position]],
    constant VisualizerUniforms &u [[buffer(0)]]
) {
    float2 uv = position.xy / float2(400.0, 800.0);
    float2 center = float2(0.5, 0.5);
    float dist = distance(uv, center);
    float flow = u.rms * 0.3;
    float angle = atan2(uv.y - center.y, uv.x - center.x);
    float dx = abs(dist - flow - 0.02 * sin(angle * 8.0 + u.time));
    float sparkle = 1.0 - smoothstep(0.0, 0.05, dx);
    float hue = fmod(angle / (2.0 * 3.14159) + u.time * 0.05, 1.0);
    float3 color = hsv2rgb(float3(hue, 0.8, sparkle));
    return float4(color, 1.0);
}
