#include <stdint.h>

#ifdef FINN_HOST
#include <stdio.h>
#endif

#include "cnv_params.h"

#define RESULT_BASE 0x20000000u

enum ResultWord {
  kStatus = 0,
  kPrediction = 1,
  kExpected = 2,
  kCorrect = 3,
  kLayerChecksOk = 4,
  kScoreBase = 16,
};

#ifdef FINN_HOST
static volatile int32_t host_mailbox[64];
#define result_mailbox host_mailbox
#else
volatile int32_t* const result_mailbox = (volatile int32_t*)RESULT_BASE;
#endif

static uint32_t buffer_a[1800];
static uint32_t buffer_b[1800];

static uint32_t word_checksum(const uint32_t* words, uint32_t count) {
  uint32_t value = 2166136261u;
  for (uint32_t index = 0; index < count; ++index) {
    value ^= words[index];
    value *= 16777619u;
  }
  return value;
}

static uint32_t popcount32(uint32_t value) {
  value = value - ((value >> 1) & 0x55555555u);
  value = (value & 0x33333333u) + ((value >> 2) & 0x33333333u);
  value = (value + (value >> 4)) & 0x0f0f0f0fu;
  value = value + (value >> 8);
  value = value + (value >> 16);
  return value & 0x3fu;
}

__attribute__((noinline)) static uint32_t xnor_word(uint32_t activation,
                                                     uint32_t weight) {
  return popcount32(~(activation ^ weight));
}

static uint32_t threshold_bit(uint32_t ge, const uint32_t* polarity,
                              uint32_t channel) {
  return ge == ((polarity[channel >> 5] >> (channel & 31u)) & 1u);
}

__attribute__((noinline)) static void conv1_q7(
    const int8_t* input, const int8_t* weights, const int16_t* thresholds,
    const uint32_t* polarities, uint32_t* output) {
  const uint32_t output_h = 30, output_w = 30, output_ch = 64;
  for (uint32_t index = 0; index < output_h * output_w * 2; ++index) output[index] = 0;
  for (uint32_t oy = 0; oy < output_h; ++oy) {
    for (uint32_t ox = 0; ox < output_w; ++ox) {
      for (uint32_t oc = 0; oc < output_ch; ++oc) {
        int32_t sum = 0;
        const int8_t* weight = weights + oc * 27;
        for (uint32_t ky = 0; ky < 3; ++ky) {
          for (uint32_t kx = 0; kx < 3; ++kx) {
            const int8_t* pixel = input + (((oy + ky) * 32 + ox + kx) * 3);
            for (uint32_t ic = 0; ic < 3; ++ic) {
              const int32_t value = pixel[ic];
              sum += *weight++ > 0 ? value : -value;
            }
          }
        }
        const uint32_t ge = sum >= thresholds[oc];
        if (threshold_bit(ge, polarities, oc)) {
          output[(oy * output_w + ox) * 2 + (oc >> 5)] |= 1u << (oc & 31u);
        }
      }
    }
  }
}

__attribute__((noinline)) static void binary_conv3x3(
    const uint32_t* input, uint32_t input_h, uint32_t input_w, uint32_t input_ch,
    const uint32_t* weights, uint32_t output_ch, const uint16_t* thresholds,
    const uint32_t* polarities, uint32_t* output) {
  const uint32_t input_words = input_ch >> 5;
  const uint32_t output_h = input_h - 2;
  const uint32_t output_w = input_w - 2;
  const uint32_t output_words = output_ch >> 5;
  for (uint32_t index = 0; index < output_h * output_w * output_words; ++index) output[index] = 0;
  for (uint32_t oy = 0; oy < output_h; ++oy) {
    for (uint32_t ox = 0; ox < output_w; ++ox) {
      for (uint32_t oc = 0; oc < output_ch; ++oc) {
        uint32_t matches = 0;
        const uint32_t* weight = weights + oc * 9 * input_words;
        for (uint32_t ky = 0; ky < 3; ++ky) {
          for (uint32_t kx = 0; kx < 3; ++kx) {
            const uint32_t* pixel = input + (((oy + ky) * input_w + ox + kx) * input_words);
            for (uint32_t word = 0; word < input_words; ++word) {
              matches += xnor_word(pixel[word], *weight++);
            }
          }
        }
        const uint32_t ge = matches >= thresholds[oc];
        if (threshold_bit(ge, polarities, oc)) {
          output[(oy * output_w + ox) * output_words + (oc >> 5)] |= 1u << (oc & 31u);
        }
      }
    }
  }
}

static void maxpool2x2(const uint32_t* input, uint32_t input_h, uint32_t input_w,
                       uint32_t channels, uint32_t* output) {
  const uint32_t words = channels >> 5;
  const uint32_t output_h = input_h >> 1;
  const uint32_t output_w = input_w >> 1;
  for (uint32_t oy = 0; oy < output_h; ++oy) {
    for (uint32_t ox = 0; ox < output_w; ++ox) {
      for (uint32_t word = 0; word < words; ++word) {
        const uint32_t top = ((oy << 1) * input_w + (ox << 1)) * words + word;
        const uint32_t bottom = top + input_w * words;
        output[(oy * output_w + ox) * words + word] =
            input[top] | input[top + words] | input[bottom] | input[bottom + words];
      }
    }
  }
}

__attribute__((noinline)) static void binary_fc(
    const uint32_t* input, uint32_t input_bits, const uint32_t* weights,
    uint32_t output_bits, const uint16_t* thresholds,
    const uint32_t* polarities, uint32_t* output) {
  const uint32_t words = input_bits >> 5;
  for (uint32_t index = 0; index < (output_bits >> 5); ++index) output[index] = 0;
  for (uint32_t neuron = 0; neuron < output_bits; ++neuron) {
    uint32_t matches = 0;
    const uint32_t* weight = weights + neuron * words;
    for (uint32_t word = 0; word < words; ++word) {
      matches += xnor_word(input[word], weight[word]);
    }
    const uint32_t ge = matches >= thresholds[neuron];
    if (threshold_bit(ge, polarities, neuron)) {
      output[neuron >> 5] |= 1u << (neuron & 31u);
    }
  }
}

__attribute__((noinline)) static int finn_cnv_inference(int32_t scores[10],
                                                        uint32_t checksums[10]) {
  conv1_q7(cnv_input_q7_hwc, cnv_w0_i8, cnv_threshold0, cnv_polarity0, buffer_a);
  checksums[0] = word_checksum(buffer_a, 1800);
  binary_conv3x3(buffer_a, 30, 30, 64, cnv_w1, 64, cnv_threshold1, cnv_polarity1, buffer_b);
  checksums[1] = word_checksum(buffer_b, 1568);
  maxpool2x2(buffer_b, 28, 28, 64, buffer_a);
  checksums[2] = word_checksum(buffer_a, 392);
  binary_conv3x3(buffer_a, 14, 14, 64, cnv_w2, 128, cnv_threshold2, cnv_polarity2, buffer_b);
  checksums[3] = word_checksum(buffer_b, 576);
  binary_conv3x3(buffer_b, 12, 12, 128, cnv_w3, 128, cnv_threshold3, cnv_polarity3, buffer_a);
  checksums[4] = word_checksum(buffer_a, 400);
  maxpool2x2(buffer_a, 10, 10, 128, buffer_b);
  checksums[5] = word_checksum(buffer_b, 100);
  binary_conv3x3(buffer_b, 5, 5, 128, cnv_w4, 256, cnv_threshold4, cnv_polarity4, buffer_a);
  checksums[6] = word_checksum(buffer_a, 72);
  binary_conv3x3(buffer_a, 3, 3, 256, cnv_w5, 256, cnv_threshold5, cnv_polarity5, buffer_b);
  checksums[7] = word_checksum(buffer_b, 8);
  binary_fc(buffer_b, 256, cnv_fc_w0, 512, cnv_fc_threshold0, cnv_fc_polarity0, buffer_a);
  checksums[8] = word_checksum(buffer_a, 16);
  binary_fc(buffer_a, 512, cnv_fc_w1, 512, cnv_fc_threshold1, cnv_fc_polarity1, buffer_b);
  checksums[9] = word_checksum(buffer_b, 16);

  int prediction = 0;
  int32_t best = CNV_FINAL_GAIN_POSITIVE ? (-2147483647 - 1) : 2147483647;
  for (uint32_t neuron = 0; neuron < 10; ++neuron) {
    uint32_t matches = 0;
    const uint32_t* weight = cnv_fc_w2 + neuron * 16;
    for (uint32_t word = 0; word < 16; ++word) matches += xnor_word(buffer_b[word], weight[word]);
    const int32_t score = (int32_t)(matches << 1) - 512;
    scores[neuron] = score;
    if ((CNV_FINAL_GAIN_POSITIVE && score > best) || (!CNV_FINAL_GAIN_POSITIVE && score < best)) {
      best = score;
      prediction = (int)neuron;
    }
  }
  return prediction;
}

int main(void) {
  int32_t scores[10];
  uint32_t checksums[10];
  result_mailbox[kStatus] = 0x100;
  const int prediction = finn_cnv_inference(scores, checksums);
  int checks_ok = 1;
  for (int index = 0; index < 10; ++index) {
    if (checksums[index] != cnv_expected_layer_checksums[index]) checks_ok = 0;
  }
  result_mailbox[kPrediction] = prediction;
  result_mailbox[kExpected] = CNV_EXPECTED_CLASS;
  result_mailbox[kCorrect] = prediction == CNV_EXPECTED_CLASS && checks_ok;
  result_mailbox[kLayerChecksOk] = checks_ok;
  for (int index = 0; index < 10; ++index) result_mailbox[kScoreBase + index] = scores[index];
  result_mailbox[kStatus] = 1;
#ifdef FINN_HOST
  printf("prediction=%d expected=%d correct=%d layer_checks=%d scores=", prediction,
         CNV_EXPECTED_CLASS, prediction == CNV_EXPECTED_CLASS, checks_ok);
  for (int index = 0; index < 10; ++index) printf("%s%d", index ? "," : "", scores[index]);
  printf("\n");
#endif
  return prediction == CNV_EXPECTED_CLASS && checks_ok ? 0 : 1;
}
