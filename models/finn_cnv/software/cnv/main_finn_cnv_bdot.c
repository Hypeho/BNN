#include <stdint.h>

#include "generated/cnv_bdot_params.h"
#include "../bdot.h"

#define RESULT_BASE 0x20000000u

enum ResultWord {
    kStatus = 0,
    kPrediction = 1,
    kExpected = 2,
    kCorrect = 3,
    kLayerChecksOk = 4,
    kScoreBase = 16,
    kChecksumBase = 32,
};

volatile int32_t* const result_mailbox = (volatile int32_t*)RESULT_BASE;

static uint32_t pixel_stride_words(uint32_t channels)
{
    const uint32_t words = channels >> 5;
    return words < 4u ? 4u : words;
}

// Activation BRAM Port A has one-cycle read latency. Two volatile reads of the
// same address prime the synchronous output and then consume the requested word.
static uint32_t activation_read(uint32_t base, uint32_t index)
{
    volatile uint32_t* const memory = (volatile uint32_t*)base;
    (void)memory[index];
    return memory[index];
}

static void activation_write(uint32_t base, uint32_t index, uint32_t value)
{
    volatile uint32_t* const memory = (volatile uint32_t*)base;
    memory[index] = value;
}

static void clear_activation(uint32_t base, uint32_t words)
{
    for (uint32_t index = 0; index < words; ++index) {
        activation_write(base, index, 0u);
    }
}

static uint32_t word_checksum_padded(
    uint32_t base, uint32_t height, uint32_t width, uint32_t channels)
{
    const uint32_t valid_words = channels >> 5;
    const uint32_t stride = pixel_stride_words(channels);
    uint32_t value = 2166136261u;
    for (uint32_t pixel = 0; pixel < height * width; ++pixel) {
        for (uint32_t word = 0; word < valid_words; ++word) {
            value ^= activation_read(base, pixel * stride + word);
            value *= 16777619u;
        }
    }
    return value;
}

static uint32_t threshold_bit(
    uint32_t ge, const uint32_t* polarity, uint32_t channel)
{
    return ge == ((polarity[channel >> 5] >> (channel & 31u)) & 1u);
}

__attribute__((noinline)) static void conv1_q7(
    const int8_t* input, const int8_t* weights, const int16_t* thresholds,
    const uint32_t* polarities, uint32_t output_base)
{
    const uint32_t output_h = 30u;
    const uint32_t output_w = 30u;
    const uint32_t output_ch = 64u;
    const uint32_t output_stride = pixel_stride_words(output_ch);
    clear_activation(output_base, output_h * output_w * output_stride);
    for (uint32_t oy = 0; oy < output_h; ++oy) {
        for (uint32_t ox = 0; ox < output_w; ++ox) {
            for (uint32_t oc = 0; oc < output_ch; ++oc) {
                int32_t sum = 0;
                const int8_t* weight = weights + oc * 27u;
                for (uint32_t ky = 0; ky < 3u; ++ky) {
                    for (uint32_t kx = 0; kx < 3u; ++kx) {
                        const int8_t* pixel = input + (((oy + ky) * 32u + ox + kx) * 3u);
                        for (uint32_t ic = 0; ic < 3u; ++ic) {
                            const int32_t sample = pixel[ic];
                            sum += *weight++ > 0 ? sample : -sample;
                        }
                    }
                }
                if (threshold_bit(sum >= thresholds[oc], polarities, oc)) {
                    const uint32_t index = (oy * output_w + ox) * output_stride + (oc >> 5);
                    const uint32_t old_value = activation_read(output_base, index);
                    activation_write(output_base, index, old_value | (1u << (oc & 31u)));
                }
            }
        }
    }
}

__attribute__((noinline)) static void binary_conv3x3_bdot(
    uint32_t input_base, uint32_t input_h, uint32_t input_w, uint32_t input_ch,
    uint32_t weight_base, uint32_t weight_kernel_stride,
    uint32_t output_ch, const uint16_t* thresholds,
    const uint32_t* polarities, uint32_t output_base)
{
    const uint32_t input_stride = pixel_stride_words(input_ch);
    const uint32_t output_h = input_h - 2u;
    const uint32_t output_w = input_w - 2u;
    const uint32_t output_stride = pixel_stride_words(output_ch);
    clear_activation(output_base, output_h * output_w * output_stride);
    bcfg_length(input_ch);

    for (uint32_t oy = 0; oy < output_h; ++oy) {
        for (uint32_t ox = 0; ox < output_w; ++ox) {
            for (uint32_t oc = 0; oc < output_ch; ++oc) {
                uint32_t matches = 0u;
                uint32_t weight = weight_base + oc * 9u * weight_kernel_stride;
                for (uint32_t ky = 0; ky < 3u; ++ky) {
                    for (uint32_t kx = 0; kx < 3u; ++kx) {
                        const uint32_t pixel = (oy + ky) * input_w + ox + kx;
                        const uint32_t activation = input_base + pixel * input_stride * 4u;
                        matches += bdot128(activation, weight);
                        weight += weight_kernel_stride;
                    }
                }
                if (threshold_bit(matches >= thresholds[oc], polarities, oc)) {
                    const uint32_t index = (oy * output_w + ox) * output_stride + (oc >> 5);
                    const uint32_t old_value = activation_read(output_base, index);
                    activation_write(output_base, index, old_value | (1u << (oc & 31u)));
                }
            }
        }
    }
}

static void maxpool2x2(
    uint32_t input_base, uint32_t input_h, uint32_t input_w,
    uint32_t channels, uint32_t output_base)
{
    const uint32_t stride = pixel_stride_words(channels);
    const uint32_t valid_words = channels >> 5;
    const uint32_t output_h = input_h >> 1;
    const uint32_t output_w = input_w >> 1;
    clear_activation(output_base, output_h * output_w * stride);
    for (uint32_t oy = 0; oy < output_h; ++oy) {
        for (uint32_t ox = 0; ox < output_w; ++ox) {
            const uint32_t top = ((oy << 1) * input_w + (ox << 1)) * stride;
            const uint32_t bottom = top + input_w * stride;
            for (uint32_t word = 0; word < valid_words; ++word) {
                const uint32_t pooled =
                    activation_read(input_base, top + word) |
                    activation_read(input_base, top + stride + word) |
                    activation_read(input_base, bottom + word) |
                    activation_read(input_base, bottom + stride + word);
                activation_write(output_base, (oy * output_w + ox) * stride + word, pooled);
            }
        }
    }
}

__attribute__((noinline)) static void binary_fc_bdot(
    uint32_t input_base, uint32_t input_bits, uint32_t weight_base,
    uint32_t weight_stride, uint32_t output_bits, const uint16_t* thresholds,
    const uint32_t* polarities, uint32_t output_base)
{
    clear_activation(output_base, output_bits >> 5);
    bcfg_length(input_bits);
    for (uint32_t neuron = 0; neuron < output_bits; ++neuron) {
        const uint32_t matches = bdot128(input_base, weight_base + neuron * weight_stride);
        if (threshold_bit(matches >= thresholds[neuron], polarities, neuron)) {
            const uint32_t index = neuron >> 5;
            const uint32_t old_value = activation_read(output_base, index);
            activation_write(output_base, index, old_value | (1u << (neuron & 31u)));
        }
    }
}

__attribute__((noinline)) static int finn_cnv_bdot_inference(
    int32_t scores[10], uint32_t checksums[10])
{
    conv1_q7(cnv_input_q7_hwc, cnv_w0_i8, cnv_threshold0, cnv_polarity0, CNV_ACT0_BASE);
    checksums[0] = word_checksum_padded(CNV_ACT0_BASE, 30u, 30u, 64u);

    binary_conv3x3_bdot(CNV_ACT0_BASE, 30u, 30u, 64u, CNV_W1_BASE,
                        CNV_W1_STRIDE, 64u, cnv_threshold1, cnv_polarity1, CNV_ACT1_BASE);
    checksums[1] = word_checksum_padded(CNV_ACT1_BASE, 28u, 28u, 64u);
    maxpool2x2(CNV_ACT1_BASE, 28u, 28u, 64u, CNV_ACT0_BASE);
    checksums[2] = word_checksum_padded(CNV_ACT0_BASE, 14u, 14u, 64u);

    binary_conv3x3_bdot(CNV_ACT0_BASE, 14u, 14u, 64u, CNV_W2_BASE,
                        CNV_W2_STRIDE, 128u, cnv_threshold2, cnv_polarity2, CNV_ACT1_BASE);
    checksums[3] = word_checksum_padded(CNV_ACT1_BASE, 12u, 12u, 128u);
    binary_conv3x3_bdot(CNV_ACT1_BASE, 12u, 12u, 128u, CNV_W3_BASE,
                        CNV_W3_STRIDE, 128u, cnv_threshold3, cnv_polarity3, CNV_ACT0_BASE);
    checksums[4] = word_checksum_padded(CNV_ACT0_BASE, 10u, 10u, 128u);
    maxpool2x2(CNV_ACT0_BASE, 10u, 10u, 128u, CNV_ACT1_BASE);
    checksums[5] = word_checksum_padded(CNV_ACT1_BASE, 5u, 5u, 128u);

    binary_conv3x3_bdot(CNV_ACT1_BASE, 5u, 5u, 128u, CNV_W4_BASE,
                        CNV_W4_STRIDE, 256u, cnv_threshold4, cnv_polarity4, CNV_ACT0_BASE);
    checksums[6] = word_checksum_padded(CNV_ACT0_BASE, 3u, 3u, 256u);
    binary_conv3x3_bdot(CNV_ACT0_BASE, 3u, 3u, 256u, CNV_W5_BASE,
                        CNV_W5_STRIDE, 256u, cnv_threshold5, cnv_polarity5, CNV_ACT1_BASE);
    checksums[7] = word_checksum_padded(CNV_ACT1_BASE, 1u, 1u, 256u);

    binary_fc_bdot(CNV_ACT1_BASE, 256u, CNV_FC0_BASE, CNV_FC0_STRIDE,
                   512u, cnv_fc_threshold0, cnv_fc_polarity0, CNV_ACT0_BASE);
    checksums[8] = word_checksum_padded(CNV_ACT0_BASE, 1u, 1u, 512u);
    binary_fc_bdot(CNV_ACT0_BASE, 512u, CNV_FC1_BASE, CNV_FC1_STRIDE,
                   512u, cnv_fc_threshold1, cnv_fc_polarity1, CNV_ACT1_BASE);
    checksums[9] = word_checksum_padded(CNV_ACT1_BASE, 1u, 1u, 512u);

    bcfg_length(512u);
    int prediction = 0;
    int32_t best = -2147483647 - 1;
    for (uint32_t neuron = 0; neuron < 10u; ++neuron) {
        const uint32_t matches = bdot128(
            CNV_ACT1_BASE, CNV_FC2_BASE + neuron * CNV_FC2_STRIDE);
        const int32_t score = (int32_t)(matches << 1) - 512;
        scores[neuron] = score;
        if (score > best) {
            best = score;
            prediction = (int)neuron;
        }
    }
    return prediction;
}

int main(void)
{
    int32_t scores[10];
    uint32_t checksums[10];
    result_mailbox[kStatus] = 0x100;
    const int prediction = finn_cnv_bdot_inference(scores, checksums);
    int checks_ok = 1;
    for (int index = 0; index < 10; ++index) {
        if (checksums[index] != cnv_expected_layer_checksums[index]) {
            checks_ok = 0;
        }
        result_mailbox[kChecksumBase + index] = (int32_t)checksums[index];
    }
    result_mailbox[kPrediction] = prediction;
    result_mailbox[kExpected] = CNV_EXPECTED_CLASS;
    result_mailbox[kCorrect] = prediction == CNV_EXPECTED_CLASS && checks_ok;
    result_mailbox[kLayerChecksOk] = checks_ok;
    for (int index = 0; index < 10; ++index) {
        result_mailbox[kScoreBase + index] = scores[index];
    }
    result_mailbox[kStatus] = 1;
    return 1;
}
