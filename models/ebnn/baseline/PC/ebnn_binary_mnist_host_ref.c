#include <stdint.h>
#include <stdio.h>

#include "binary_mnist.h"
#include "binary_mnist_data.h"

#define EBNN_SAMPLE_COUNT 20
#ifndef EBNN_RUN_SAMPLES
#define EBNN_RUN_SAMPLES EBNN_SAMPLE_COUNT
#endif
#define EBNN_INPUT_BYTES (((28 * 28) + 7) / 8)

static uint32_t UpdateChecksum(uint32_t h, uint8_t pred, uint8_t expected) {
  h ^= (uint32_t)pred;
  h *= 16777619u;
  h ^= (uint32_t)expected;
  h *= 16777619u;
  return h;
}

int main(void) {
  uint8_t output[1];
  int correct = 0;
  int first_fail = -1;
  uint32_t checksum = 2166136261u;

  printf("ebnn_binary_mnist_host_ref\n");
  printf("sample_count=%d input_bytes=%d\n", EBNN_RUN_SAMPLES,
         EBNN_INPUT_BYTES);
  printf("predictions=[");
  for (int j = 0; j < EBNN_RUN_SAMPLES; ++j) {
    const int index = EBNN_INPUT_BYTES * j;
    const uint8_t expected = (uint8_t)((int)train_labels[j]);
    output[0] = 0;
    ebnn_compute(&train_data[index], output);
    const uint8_t pred = output[0];
    if (pred == expected) {
      ++correct;
    } else if (first_fail < 0) {
      first_fail = j;
    }
    checksum = UpdateChecksum(checksum, pred, expected);
    printf("%u%s", (unsigned)pred, j == EBNN_RUN_SAMPLES - 1 ? "" : ",");
  }
  printf("]\n");
  printf("correct=%d first_fail=%d checksum=0x%08x\n", correct, first_fail,
         checksum);
  return 0;
}
