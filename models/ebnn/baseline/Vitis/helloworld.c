#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

#include "platform.h"
#include "sleep.h"
#include "xil_cache.h"
#include "xil_io.h"
#include "xil_printf.h"
#include "xparameters.h"
#include "xil_types.h"
#include "xiltimer.h"

#ifndef INST_BRAM_BASE
#ifdef XPAR_AXI_BRAM_CTRL_0_S_AXI_BASEADDR
#define INST_BRAM_BASE XPAR_AXI_BRAM_CTRL_0_S_AXI_BASEADDR
#else
#define INST_BRAM_BASE 0xA0000000U
#endif
#endif

#ifndef DATA_BRAM_BASE
#ifdef XPAR_AXI_BRAM_CTRL_1_S_AXI_BASEADDR
#define DATA_BRAM_BASE XPAR_AXI_BRAM_CTRL_1_S_AXI_BASEADDR
#else
#define DATA_BRAM_BASE 0xA2000000U
#endif
#endif

#ifndef RESET_GPIO_BASE
#ifdef XPAR_AXI_GPIO_0_BASEADDR
#define RESET_GPIO_BASE XPAR_AXI_GPIO_0_BASEADDR
#else
#define RESET_GPIO_BASE 0xA3000000U
#endif
#endif

#define GPIO_DATA_OFFSET 0x0U
#define GPIO_TRI_OFFSET 0x4U
#define WORD_SIZE_BYTES 4U
#define DMEM_MAILBOX_BYTES 0x1000U
#define EBNN_SAMPLE_COUNT 20

#ifndef EBNN_TIMEOUT_US
#define EBNN_TIMEOUT_US 60000000ULL
#endif

#ifndef RV32I_CORE_HZ
#define RV32I_CORE_HZ 35000000ULL
#endif

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

#include "inst_array.c"
#include "data_array.c"

static void WriteWords(uint32_t base, const uint32_t* words, size_t count) {
  for (size_t i = 0; i < count; ++i) {
    Xil_Out32(base + (uint32_t)(i * WORD_SIZE_BYTES), words[i]);
  }
}

static void SetReset(int asserted) {
  Xil_Out32(RESET_GPIO_BASE + GPIO_TRI_OFFSET, 0x0U);
  Xil_Out32(RESET_GPIO_BASE + GPIO_DATA_OFFSET, asserted ? 0U : 1U);
}

static XTime GetTimeTicks(void) {
  XTime now;
  XTime_GetTime(&now);
  return now;
}

static uint32_t TicksToUs(XTime ticks) {
  const uint64_t us =
      ((uint64_t)ticks * 1000000ULL + (COUNTS_PER_SECOND / 2ULL)) /
      COUNTS_PER_SECOND;
  return (uint32_t)us;
}

static uint32_t UsToRv32iCycles(uint32_t us) {
  const uint64_t cycles =
      ((uint64_t)us * RV32I_CORE_HZ + 500000ULL) / 1000000ULL;
  return (uint32_t)cycles;
}

static void PrintElapsedTime(const char* label, XTime start, XTime end) {
  const uint32_t elapsed_us = TicksToUs(end - start);
  xil_printf("%s: %lu.%03lu ms (%lu us)\r\n", label,
             (unsigned long)(elapsed_us / 1000U),
             (unsigned long)(elapsed_us % 1000U),
             (unsigned long)elapsed_us);
#if RV32I_CORE_HZ > 0
  xil_printf("%s: approx %lu RV32I cycles @ %lu Hz\r\n", label,
             (unsigned long)UsToRv32iCycles(elapsed_us),
             (unsigned long)RV32I_CORE_HZ);
#endif
}

int main(void) {
  init_platform();
  Xil_DCacheDisable();
  Xil_ICacheDisable();

  xil_printf("eBNN Binary MNIST PS app\r\n");
  xil_printf("IMEM base=0x%08lx DMEM base=0x%08lx RESET GPIO=0x%08lx\r\n",
             (unsigned long)INST_BRAM_BASE, (unsigned long)DATA_BRAM_BASE,
             (unsigned long)RESET_GPIO_BASE);
  xil_printf("Loading RV32I image: inst_words=%u data_words=%u\r\n",
             (unsigned)(sizeof(inst_array) / sizeof(inst_array[0])),
             (unsigned)(sizeof(data_array) / sizeof(data_array[0])));

  SetReset(1);
  WriteWords(INST_BRAM_BASE, inst_array,
             sizeof(inst_array) / sizeof(inst_array[0]));
  WriteWords(DATA_BRAM_BASE + DMEM_MAILBOX_BYTES, data_array,
             sizeof(data_array) / sizeof(data_array[0]));

  for (int i = 0; i < 64; ++i) {
    Xil_Out32(DATA_BRAM_BASE + (uint32_t)(i * WORD_SIZE_BYTES), 0U);
  }

  xil_printf("Memory load complete. Releasing RV32I reset.\r\n");
  const XTime run_start_ticks = GetTimeTicks();
  SetReset(0);

  uint32_t status = 0;
  uint32_t last_status = 0xFFFFFFFFU;
  XTime done_ticks = run_start_ticks;
  XTime input_ready_ticks = 0;
  XTime inference_done_ticks = 0;
  for (uint64_t t = 0; t < EBNN_TIMEOUT_US; ++t) {
    status = Xil_In32(DATA_BRAM_BASE + kStatus * WORD_SIZE_BYTES);
    if (status != last_status) {
      xil_printf("status=0x%08lx\r\n", (unsigned long)status);
      last_status = status;
      if (status == 0x00000110U) {
        input_ready_ticks = GetTimeTicks();
      } else if (status == 0x00000120U) {
        inference_done_ticks = GetTimeTicks();
      }
    }
    if (status == 1U || (int32_t)status < 0) {
      done_ticks = GetTimeTicks();
      break;
    }
    usleep(1);
  }
  if (status != 1U && (int32_t)status >= 0) {
    done_ticks = GetTimeTicks();
  }
  if (status == 1U && inference_done_ticks == 0) {
    inference_done_ticks = done_ticks;
  }

  const int32_t sample_count =
      (int32_t)Xil_In32(DATA_BRAM_BASE + kSampleCount * 4U);
  const int32_t correct =
      (int32_t)Xil_In32(DATA_BRAM_BASE + kCorrectCount * 4U);
  const int32_t first_fail =
      (int32_t)Xil_In32(DATA_BRAM_BASE + kFirstFailIndex * 4U);
  const uint32_t checksum =
      Xil_In32(DATA_BRAM_BASE + kPredictionChecksum * 4U);

  xil_printf("status=0x%08lx samples=%ld correct=%ld first_fail=%ld checksum=0x%08lx\r\n",
             (unsigned long)status, (long)sample_count, (long)correct,
             (long)first_fail, (unsigned long)checksum);

  xil_printf("predictions=[");
  for (int i = 0; i < EBNN_SAMPLE_COUNT; ++i) {
    const uint32_t v = Xil_In32(DATA_BRAM_BASE + (kPredBase + i) * 4U);
    xil_printf("%lu%s", (unsigned long)v,
               i == EBNN_SAMPLE_COUNT - 1 ? "" : ",");
  }
  xil_printf("]\r\n");

  xil_printf("expected=[");
  for (int i = 0; i < EBNN_SAMPLE_COUNT; ++i) {
    const uint32_t v = Xil_In32(DATA_BRAM_BASE + (kExpectedBase + i) * 4U);
    xil_printf("%lu%s", (unsigned long)v,
               i == EBNN_SAMPLE_COUNT - 1 ? "" : ",");
  }
  xil_printf("]\r\n");

  PrintElapsedTime("eBNN total reset-release-to-status", run_start_ticks,
                   done_ticks);
  if (input_ready_ticks != 0) {
    PrintElapsedTime("eBNN input-ready", run_start_ticks, input_ready_ticks);
  }
  if (input_ready_ticks != 0 && inference_done_ticks != 0) {
    PrintElapsedTime("eBNN inference", input_ready_ticks,
                     inference_done_ticks);
  }
  if (inference_done_ticks != 0 && inference_done_ticks != done_ticks) {
    PrintElapsedTime("eBNN result-store", inference_done_ticks, done_ticks);
  }

  cleanup_platform();
  return 0;
}
