#include <stdint.h>

#include "generated/lfc_bdot_params.h"
#include "../bdot.h"

#define RESULT_BASE 0x20000000u

enum ResultWord {
    kStatus = 0,
    kPrediction = 1,
    kExpected = 2,
    kCorrect = 3,
    kScoreBase = 16,
};

volatile int32_t* const result_mailbox = (volatile int32_t*)RESULT_BASE;

__attribute__((noinline)) static void binary_threshold_layer_bdot(
    uint32_t input_base,
    uint32_t weight_base,
    uint32_t weight_stride,
    const uint16_t* thresholds,
    const uint32_t* polarities,
    uint32_t input_bits,
    uint32_t output_bits,
    uint32_t output_base)
{
    volatile uint32_t* const output = (volatile uint32_t*)output_base;
    const uint32_t output_words = (output_bits + 31u) >> 5;

    bcfg_length(input_bits);
    for (uint32_t word = 0; word < output_words; ++word) {
        uint32_t packed = 0u;
        for (uint32_t bit = 0; bit < 32u; ++bit) {
            const uint32_t neuron = (word << 5) + bit;
            if (neuron >= output_bits) {
                break;
            }
            const uint32_t matches =
                bdot128(input_base, weight_base + neuron * weight_stride);
            const uint32_t ge = matches >= thresholds[neuron];
            const uint32_t polarity =
                (polarities[word] >> bit) & 1u;
            if (ge == polarity) {
                packed |= 1u << bit;
            }
        }
        output[word] = packed;
    }
}

__attribute__((noinline)) static int finn_lfc_bdot_inference(int32_t scores[10])
{
    binary_threshold_layer_bdot(
        LFC_ACT0_BASE, LFC_W0_BASE, LFC_W0_STRIDE,
        lfc_threshold0, lfc_polarity0,
        784u, 1024u, LFC_ACT1_BASE);
    binary_threshold_layer_bdot(
        LFC_ACT1_BASE, LFC_W1_BASE, LFC_W1_STRIDE,
        lfc_threshold1, lfc_polarity1,
        1024u, 1024u, LFC_ACT0_BASE);
    binary_threshold_layer_bdot(
        LFC_ACT0_BASE, LFC_W2_BASE, LFC_W2_STRIDE,
        lfc_threshold2, lfc_polarity2,
        1024u, 1024u, LFC_ACT1_BASE);

    bcfg_length(1024u);
    int prediction = 0;
    int32_t best = -2147483647 - 1;
    for (uint32_t neuron = 0; neuron < 10u; ++neuron) {
        const uint32_t matches =
            bdot128(LFC_ACT1_BASE, LFC_W3_BASE + neuron * LFC_W3_STRIDE);
        const int32_t score = (int32_t)(matches << 1) - 1024;
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

    result_mailbox[kStatus] = 0x100;
    const int prediction = finn_lfc_bdot_inference(scores);
    result_mailbox[kPrediction] = prediction;
    result_mailbox[kExpected] = LFC_EXPECTED_CLASS;
    result_mailbox[kCorrect] = prediction == LFC_EXPECTED_CLASS;
    for (int index = 0; index < 10; ++index) {
        result_mailbox[kScoreBase + index] = scores[index];
    }
    result_mailbox[kStatus] = 1;
    return 1;
}
