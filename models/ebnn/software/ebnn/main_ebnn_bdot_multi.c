#include <float.h>
#include <stdint.h>

#include "generated/ebnn_bdot_params.h"
#include "../bdot.h"
#include "binary_mnist.h"
#include "binary_mnist_data.h"

#define RESULT_BASE 0x20000000u
#define ACTIVATION_BASE 0x30000000u
#define INPUT_WIDTH 28u
#define INPUT_BYTES 98u
#define POOL_WIDTH 6u
#define CONV_OUTPUT_BITS 360u
#define EBNN_SAMPLE_COUNT 20

#ifndef EBNN_SAMPLE_ID
#define EBNN_SAMPLE_ID 0
#endif

#if EBNN_SAMPLE_ID < 0 || EBNN_SAMPLE_ID >= EBNN_SAMPLE_COUNT
#error "EBNN_SAMPLE_ID must be in the range 0..19"
#endif

enum ResultWord {
    kStatus = 0,
    kPrediction = 1,
    kGroundTruthLabel = 2,
    kLabelCorrect = 3,
    kActivationChecksum = 4,
    kBdotCount = 5,
    kSampleId = 6,
    kScoreBitsBase = 16,
};

volatile int32_t* const result_mailbox = (volatile int32_t*)RESULT_BASE;
static uint32_t activation_bits[12];
static uint32_t bdot_count;

static uint32_t input_bit(const uint8_t* input, uint32_t index)
{
    return (input[index >> 3] >> (7u - (index & 7u))) & 1u;
}

static void write_activation_word(uint32_t index, uint32_t value)
{
    volatile uint32_t* const activation = (volatile uint32_t*)ACTIVATION_BASE;
    activation[index] = value;
}

static float apply_batch_norm(float value, float bias, float gamma,
                              float beta, float mean, float std)
{
    value += bias;
    value -= mean;
    value /= std;
    value *= gamma;
    value += beta;
    return value;
}

static uint32_t run_bdot(uint32_t activation, uint32_t weight)
{
    ++bdot_count;
    return bdot128(activation, weight);
}

static void pack_conv_window(const uint8_t* input, uint32_t row, uint32_t col)
{
    uint32_t packed = 0u;
    uint32_t bit = 0u;
    for (uint32_t kr = 0u; kr < 3u; ++kr) {
        for (uint32_t kc = 0u; kc < 3u; ++kc) {
            const uint32_t index = (row + kr) * INPUT_WIDTH + col + kc;
            packed |= input_bit(input, index) << bit;
            ++bit;
        }
    }
    write_activation_word(0u, packed);
}

static void binary_conv_pool(const uint8_t* input)
{
    for (uint32_t word = 0u; word < 12u; ++word) {
        activation_bits[word] = 0u;
    }

    bcfg_length(9u);
    for (uint32_t filter = 0u; filter < 10u; ++filter) {
        const uint32_t weight = EBNN_CONV_WEIGHT_BASE +
                                filter * EBNN_CONV_WEIGHT_STRIDE;
        for (uint32_t pool_row = 0u; pool_row < POOL_WIDTH; ++pool_row) {
            for (uint32_t pool_col = 0u; pool_col < POOL_WIDTH; ++pool_col) {
                uint32_t max_matches = 0u;
                for (uint32_t pr = 0u; pr < 3u; ++pr) {
                    for (uint32_t pc = 0u; pc < 3u; ++pc) {
                        pack_conv_window(input,
                                         pool_row * 4u + pr * 2u,
                                         pool_col * 4u + pc * 2u);
                        const uint32_t matches = run_bdot(ACTIVATION_BASE, weight);
                        if (matches > max_matches) {
                            max_matches = matches;
                        }
                    }
                }

                float value = (float)((int32_t)(max_matches * 2u) - 9);
                value = apply_batch_norm(
                    value,
                    l_b_conv_pool_bn_bst0_bconv_b[filter],
                    l_b_conv_pool_bn_bst0_bn_gamma[filter],
                    l_b_conv_pool_bn_bst0_bn_beta[filter],
                    l_b_conv_pool_bn_bst0_bn_mean[filter],
                    l_b_conv_pool_bn_bst0_bn_std[filter]);
                if (value >= 0.0f) {
                    const uint32_t output_bit =
                        filter * POOL_WIDTH * POOL_WIDTH +
                        pool_row * POOL_WIDTH + pool_col;
                    activation_bits[output_bit >> 5] |=
                        1u << (output_bit & 31u);
                }
            }
        }
    }

    for (uint32_t word = 0u; word < 12u; ++word) {
        write_activation_word(word, activation_bits[word]);
    }
}

static int binary_fc(float scores[10])
{
    int prediction = 0;
    float best = -FLT_MAX;

    bcfg_length(CONV_OUTPUT_BITS);
    for (uint32_t output = 0u; output < 10u; ++output) {
        const uint32_t matches = run_bdot(
            ACTIVATION_BASE,
            EBNN_FC_WEIGHT_BASE + output * EBNN_FC_WEIGHT_STRIDE);
        float value = (float)((int32_t)(matches * 2u) - (int32_t)CONV_OUTPUT_BITS);
        value = apply_batch_norm(
            value,
            l_b_linear_bn_softmax1_bl_b[output],
            l_b_linear_bn_softmax1_bn_gamma[output],
            l_b_linear_bn_softmax1_bn_beta[output],
            l_b_linear_bn_softmax1_bn_mean[output],
            l_b_linear_bn_softmax1_bn_std[output]);
        scores[output] = value;
        if (value > best) {
            best = value;
            prediction = (int)output;
        }
    }
    return prediction;
}

static uint32_t activation_checksum(void)
{
    uint32_t value = 2166136261u;
    for (uint32_t index = 0u; index < 12u; ++index) {
        value ^= activation_bits[index];
        value *= 16777619u;
    }
    return value;
}

static uint32_t float_bits(float value)
{
    union {
        float f;
        uint32_t u;
    } converted;
    converted.f = value;
    return converted.u;
}

int main(void)
{
    float scores[10];
    const uint8_t* const input = &train_data[INPUT_BYTES * EBNN_SAMPLE_ID];
    const int label = (int)train_labels[EBNN_SAMPLE_ID];

    result_mailbox[kStatus] = 0x100;
    result_mailbox[kSampleId] = EBNN_SAMPLE_ID;
    bdot_count = 0u;
    binary_conv_pool(input);
    const int prediction = binary_fc(scores);

    result_mailbox[kPrediction] = prediction;
    result_mailbox[kGroundTruthLabel] = label;
    result_mailbox[kLabelCorrect] = prediction == label;
    result_mailbox[kActivationChecksum] = (int32_t)activation_checksum();
    result_mailbox[kBdotCount] = (int32_t)bdot_count;
    for (uint32_t index = 0u; index < 10u; ++index) {
        result_mailbox[kScoreBitsBase + index] = (int32_t)float_bits(scores[index]);
    }
    result_mailbox[kStatus] = 1;
    return 1;
}
