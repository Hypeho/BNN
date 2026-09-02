#include <stdint.h>

#include "binary_mnist.h"
#include "binary_mnist_data.h"

#define RESULT_BASE 0x20000000u
#define EBNN_SAMPLE_COUNT 20
#ifndef EBNN_RUN_SAMPLES
#define EBNN_RUN_SAMPLES EBNN_SAMPLE_COUNT
#endif
#define EBNN_INPUT_BYTES (((28 * 28) + 7) / 8)
#define EBNN_CLASS_COUNT 10

enum ResultWord {
  kStatus = 0,
  kSampleCount = 1,
  kCorrectCount = 2,
  kFirstFailIndex = 3,
  kPredictionChecksum = 4,
  kLastPredicted = 5,
  kLastExpected = 6,
  kInputBytes = 7,
  kClassCount = 8,
  kPredBase = 16,
  kExpectedBase = kPredBase + EBNN_SAMPLE_COUNT,
};

enum StatusCode {
  kStatusStarted = 0x100,
  kStatusInputReady = 0x110,
  kStatusInferenceDone = 0x120,
  kStatusOk = 1,
};

volatile int32_t* const result_mailbox = (volatile int32_t*)RESULT_BASE;

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

  result_mailbox[kStatus] = kStatusStarted;
  result_mailbox[kSampleCount] = EBNN_RUN_SAMPLES;
  result_mailbox[kCorrectCount] = 0;
  result_mailbox[kFirstFailIndex] = -1;
  result_mailbox[kPredictionChecksum] = 0;
  result_mailbox[kInputBytes] = EBNN_INPUT_BYTES;
  result_mailbox[kClassCount] = EBNN_CLASS_COUNT;

  result_mailbox[kStatus] = kStatusInputReady;

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
    result_mailbox[kPredBase + j] = pred;
    result_mailbox[kExpectedBase + j] = expected;
    result_mailbox[kLastPredicted] = pred;
    result_mailbox[kLastExpected] = expected;
  }

  result_mailbox[kStatus] = kStatusInferenceDone;
  result_mailbox[kCorrectCount] = correct;
  result_mailbox[kFirstFailIndex] = first_fail;
  result_mailbox[kPredictionChecksum] = (int32_t)checksum;
  result_mailbox[kStatus] = kStatusOk;

  return kStatusOk;
}
