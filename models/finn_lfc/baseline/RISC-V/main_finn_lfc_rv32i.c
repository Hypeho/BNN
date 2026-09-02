#include <stdint.h>

#include "lfc_params.h"

#define RESULT_BASE 0x20000000u

enum ResultWord {
  kStatus = 0,
  kPrediction = 1,
  kExpected = 2,
  kCorrect = 3,
  kScoreBase = 16,
};

volatile int32_t* const result_mailbox = (volatile int32_t*)RESULT_BASE;

static uint32_t popcount32(uint32_t value) {
  value = value - ((value >> 1) & 0x55555555u);
  value = (value & 0x33333333u) + ((value >> 2) & 0x33333333u);
  value = (value + (value >> 4)) & 0x0f0f0f0fu;
  value = value + (value >> 8);
  value = value + (value >> 16);
  return value & 0x3fu;
}

__attribute__((noinline)) static uint32_t xnor_match32(const uint32_t* activation,
                                                        const uint32_t* weight,
                                                        uint32_t words,
                                                        uint32_t tail_mask) {
  uint32_t matches = 0;
  for (uint32_t index = 0; index < words; ++index) {
    uint32_t equal = ~(activation[index] ^ weight[index]);
    if (index + 1u == words) {
      equal &= tail_mask;
    }
    matches += popcount32(equal);
  }
  return matches;
}

__attribute__((noinline)) static void binary_threshold_layer(
    const uint32_t* input,
    const uint32_t* weights,
    const uint16_t* thresholds,
    const uint32_t* polarities,
    uint32_t input_bits,
    uint32_t output_bits,
    uint32_t* output) {
  const uint32_t words = (input_bits + 31u) >> 5;
  const uint32_t tail_bits = input_bits & 31u;
  const uint32_t tail_mask = tail_bits ? ((1u << tail_bits) - 1u) : 0xffffffffu;
  const uint32_t output_words = (output_bits + 31u) >> 5;
  for (uint32_t index = 0; index < output_words; ++index) {
    output[index] = 0;
  }
  for (uint32_t neuron = 0; neuron < output_bits; ++neuron) {
    const uint32_t matches = xnor_match32(input, weights + neuron * words, words, tail_mask);
    const uint32_t ge = matches >= thresholds[neuron];
    const uint32_t polarity = (polarities[neuron >> 5] >> (neuron & 31u)) & 1u;
    if (ge == polarity) {
      output[neuron >> 5] |= 1u << (neuron & 31u);
    }
  }
}

__attribute__((noinline)) static int finn_lfc_inference(int32_t scores[10]) {
  uint32_t activation_a[32];
  uint32_t activation_b[32];
  binary_threshold_layer(lfc_input, lfc_w0, lfc_threshold0, lfc_polarity0,
                         784, 1024, activation_a);
  binary_threshold_layer(activation_a, lfc_w1, lfc_threshold1, lfc_polarity1,
                         1024, 1024, activation_b);
  binary_threshold_layer(activation_b, lfc_w2, lfc_threshold2, lfc_polarity2,
                         1024, 1024, activation_a);

  int prediction = 0;
  int32_t best = -2147483647 - 1;
  for (uint32_t neuron = 0; neuron < 10; ++neuron) {
    const uint32_t matches = xnor_match32(activation_a, lfc_w3 + neuron * 32u,
                                          32, 0xffffffffu);
    const int32_t score = (int32_t)(matches << 1) - 1024;
    scores[neuron] = score;
    if (score > best) {
      best = score;
      prediction = (int)neuron;
    }
  }
  return prediction;
}

int main(void) {
  int32_t scores[10];
  result_mailbox[kStatus] = 0x100;
  const int prediction = finn_lfc_inference(scores);
  result_mailbox[kPrediction] = prediction;
  result_mailbox[kExpected] = LFC_EXPECTED_CLASS;
  result_mailbox[kCorrect] = prediction == LFC_EXPECTED_CLASS;
  for (int index = 0; index < 10; ++index) {
    result_mailbox[kScoreBase + index] = scores[index];
  }
  result_mailbox[kStatus] = 1;
  return 1;
}
