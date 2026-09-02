#include <stdint.h>

#include "sleep.h"
#include "xil_cache.h"
#include "xil_io.h"
#include "xil_printf.h"
#include "xiltimer.h"

#include "ebnn_bdot_images.h"

#define IMEM_BASE         0xA0000000U
#define DMEM_BASE         0xA2000000U
#define CONTROL_GPIO_BASE 0xA3000000U
#define ACTIVATION0_BASE  0xA4000000U
#define ACTIVATION1_BASE  0xA4010000U
#define WEIGHT_BASE       0xA5000000U

#define IMEM_BYTES       0x00020000U
#define DMEM_BYTES       0x00010000U
#define ACTIVATION_BYTES 0x00008000U
#define WEIGHT_BYTES     0x00064000U
#define WORD_BYTES       4U

#define GPIO_DATA_OFFSET  0x0U
#define GPIO_TRI_OFFSET   0x4U
#define GPIO2_DATA_OFFSET 0x8U
#define GPIO2_TRI_OFFSET  0xCU
#define GPIO_LOAD_MODE    0x1U
#define GPIO_ASYNC_RESET  0x2U
#define GPIO_BDOT_ERROR   0x2U

#define RESULT_STATUS_WORD       0U
#define RESULT_PREDICTION_WORD   1U
#define RESULT_EXPECTED_WORD     2U
#define RESULT_CORRECT_WORD      3U
#define RESULT_CHECKSUM_WORD     4U
#define RESULT_BDOT_COUNT_WORD   5U
#define RESULT_SCORE_BASE_WORD   16U
#define RESULT_SCORE_COUNT       10U

#define RV32I_CLOCK_HZ 35000000ULL
#define RUN_TIMEOUT_US 1000000U

#ifndef EBNN_BDOT_FULL_READBACK
#define EBNN_BDOT_FULL_READBACK 1
#endif

static const uint32_t expected_score_bits[RESULT_SCORE_COUNT] = {
    0xBE9A0152U, 0xBF3C8938U, 0xBEE0D7FEU, 0x4015220BU, 0xBFB6AE47U,
    0x40815608U, 0xBD9BDA49U, 0x3FB3DF63U, 0xBE806104U, 0xBFAEBDC9U
};

static void gpio_set_control(uint32_t value)
{
    Xil_Out32(CONTROL_GPIO_BASE + GPIO_DATA_OFFSET, value & 0x3U);
}

static uint32_t gpio_get_status(void)
{
    return Xil_In32(CONTROL_GPIO_BASE + GPIO2_DATA_OFFSET) & 0x3U;
}

static void clear_words(uint32_t base, uint32_t words)
{
    uint32_t index;
    for (index = 0U; index < words; ++index) {
        Xil_Out32((UINTPTR)base + (UINTPTR)index * WORD_BYTES, 0U);
    }
}

static void write_words(uint32_t base, uint32_t origin,
                        const uint32_t *image, uint32_t words)
{
    uint32_t index;
    for (index = 0U; index < words; ++index) {
        Xil_Out32((UINTPTR)base + (UINTPTR)(origin + index) * WORD_BYTES,
                  image[index]);
    }
}

static int verify_words(uint32_t base, uint32_t origin,
                        const uint32_t *expected, uint32_t words,
                        const char *name)
{
    uint32_t index;
    for (index = 0U; index < words; ++index) {
        const uint32_t actual = Xil_In32(
            (UINTPTR)base + (UINTPTR)(origin + index) * WORD_BYTES);
        if (actual != expected[index]) {
            xil_printf("READBACK FAIL %s word=%lu expected=%08lx actual=%08lx\r\n",
                       name, (unsigned long)(origin + index),
                       (unsigned long)expected[index], (unsigned long)actual);
            return 1;
        }
    }
    xil_printf("READBACK PASS %s words=%lu\r\n",
               name, (unsigned long)words);
    return 0;
}

static int verify_zero_words(uint32_t base, uint32_t words, const char *name)
{
    uint32_t index;
    for (index = 0U; index < words; ++index) {
        const uint32_t actual = Xil_In32(
            (UINTPTR)base + (UINTPTR)index * WORD_BYTES);
        if (actual != 0U) {
            xil_printf("READBACK FAIL %s word=%lu actual=%08lx\r\n",
                       name, (unsigned long)index, (unsigned long)actual);
            return 1;
        }
    }
    xil_printf("READBACK PASS %s zero words=%lu\r\n",
               name, (unsigned long)words);
    return 0;
}

static uint32_t ticks_to_us(XTime ticks)
{
    return (uint32_t)(((uint64_t)ticks * 1000000ULL +
                       COUNTS_PER_SECOND / 2ULL) / COUNTS_PER_SECOND);
}

static uint32_t read_result(uint32_t word)
{
    return Xil_In32((UINTPTR)DMEM_BASE + (UINTPTR)word * WORD_BYTES);
}

static int check_sizes(void)
{
    if (((EBNN_BDOT_IMEM_IMAGE_ORIGIN_WORD + EBNN_BDOT_IMEM_IMAGE_WORDS) *
         WORD_BYTES > IMEM_BYTES) ||
        ((EBNN_BDOT_DMEM_IMAGE_ORIGIN_WORD + EBNN_BDOT_DMEM_IMAGE_WORDS) *
         WORD_BYTES > DMEM_BYTES) ||
        (EBNN_BDOT_WEIGHT_IMAGE_WORDS * WORD_BYTES > WEIGHT_BYTES)) {
        xil_printf("LOAD FAIL: eBNN image exceeds BRAM capacity\r\n");
        return 1;
    }
    return 0;
}

static int load_and_verify(void)
{
    int failures = 0;
    clear_words(IMEM_BASE, IMEM_BYTES / WORD_BYTES);
    clear_words(DMEM_BASE, DMEM_BYTES / WORD_BYTES);
    clear_words(ACTIVATION0_BASE, ACTIVATION_BYTES / WORD_BYTES);
    clear_words(ACTIVATION1_BASE, ACTIVATION_BYTES / WORD_BYTES);
    write_words(IMEM_BASE, EBNN_BDOT_IMEM_IMAGE_ORIGIN_WORD,
                ebnn_bdot_imem_image, EBNN_BDOT_IMEM_IMAGE_WORDS);
    write_words(DMEM_BASE, EBNN_BDOT_DMEM_IMAGE_ORIGIN_WORD,
                ebnn_bdot_dmem_image, EBNN_BDOT_DMEM_IMAGE_WORDS);
    write_words(WEIGHT_BASE, 0U, ebnn_bdot_weight_image,
                EBNN_BDOT_WEIGHT_IMAGE_WORDS);

#if EBNN_BDOT_FULL_READBACK
    failures += verify_words(IMEM_BASE, EBNN_BDOT_IMEM_IMAGE_ORIGIN_WORD,
                             ebnn_bdot_imem_image,
                             EBNN_BDOT_IMEM_IMAGE_WORDS, "IMEM");
    failures += verify_words(DMEM_BASE, EBNN_BDOT_DMEM_IMAGE_ORIGIN_WORD,
                             ebnn_bdot_dmem_image,
                             EBNN_BDOT_DMEM_IMAGE_WORDS, "DMEM");
    failures += verify_zero_words(ACTIVATION0_BASE,
                                  ACTIVATION_BYTES / WORD_BYTES, "ACT0");
    failures += verify_zero_words(ACTIVATION1_BASE,
                                  ACTIVATION_BYTES / WORD_BYTES, "ACT1");
    failures += verify_words(WEIGHT_BASE, 0U, ebnn_bdot_weight_image,
                             EBNN_BDOT_WEIGHT_IMAGE_WORDS, "WEIGHT");
#else
    failures += verify_words(IMEM_BASE, EBNN_BDOT_IMEM_IMAGE_ORIGIN_WORD,
                             ebnn_bdot_imem_image, 1U, "IMEM sample");
    failures += verify_words(DMEM_BASE, EBNN_BDOT_DMEM_IMAGE_ORIGIN_WORD,
                             ebnn_bdot_dmem_image, 1U, "DMEM sample");
    failures += verify_words(WEIGHT_BASE, 0U,
                             ebnn_bdot_weight_image, 1U, "WEIGHT sample");
#endif
    return failures;
}

static int wait_for_completion(XTime start, XTime *finish)
{
    for (;;) {
        const int32_t status = (int32_t)read_result(RESULT_STATUS_WORD);
        XTime now;
        XTime_GetTime(&now);
        if ((gpio_get_status() & GPIO_BDOT_ERROR) != 0U) {
            *finish = now;
            xil_printf("RUN FAIL: bdot_error asserted\r\n");
            return -1;
        }
        if (status == 1 || status < 0) {
            *finish = now;
            return status;
        }
        if (ticks_to_us(now - start) >= RUN_TIMEOUT_US) {
            *finish = now;
            xil_printf("RUN TIMEOUT status=%ld\r\n", (long)status);
            return status;
        }
    }
}

static int check_results(void)
{
    const int32_t status = (int32_t)read_result(RESULT_STATUS_WORD);
    const int32_t prediction = (int32_t)read_result(RESULT_PREDICTION_WORD);
    const int32_t expected = (int32_t)read_result(RESULT_EXPECTED_WORD);
    const int32_t correct = (int32_t)read_result(RESULT_CORRECT_WORD);
    const uint32_t checksum = read_result(RESULT_CHECKSUM_WORD);
    const uint32_t bdot_count = read_result(RESULT_BDOT_COUNT_WORD);
    uint32_t index;
    int failures = 0;

    xil_printf("status=%ld prediction=%ld expected=%ld correct=%ld checksum=%08lx bdot=%lu\r\n",
               (long)status, (long)prediction, (long)expected, (long)correct,
               (unsigned long)checksum, (unsigned long)bdot_count);
    if (status != 1 || prediction != 5 || expected != 5 || correct != 1 ||
        checksum != 0x82552330U || bdot_count != 3250U) {
        ++failures;
    }
    xil_printf("score_bits=[");
    for (index = 0U; index < RESULT_SCORE_COUNT; ++index) {
        const uint32_t actual = read_result(RESULT_SCORE_BASE_WORD + index);
        xil_printf("%08lx%s", (unsigned long)actual,
                   index + 1U == RESULT_SCORE_COUNT ? "" : ",");
        if (actual != expected_score_bits[index]) {
            ++failures;
        }
    }
    xil_printf("]\r\n");
    return failures;
}

int main(void)
{
    XTime start;
    XTime finish;
    uint32_t elapsed_us;
    int run_status;
    int failures;

    Xil_DCacheDisable();
    xil_printf("\r\nWide-BDOT128 eBNN Binary-MNIST Ultra96-V1 PS loader\r\n");
    if (check_sizes() != 0) {
        return 1;
    }
    Xil_Out32(CONTROL_GPIO_BASE + GPIO_TRI_OFFSET, 0U);
    Xil_Out32(CONTROL_GPIO_BASE + GPIO2_TRI_OFFSET, 0xFFFFFFFFU);
    gpio_set_control(GPIO_LOAD_MODE | GPIO_ASYNC_RESET);

    failures = load_and_verify();
    if (failures != 0) {
        xil_printf("LOAD FAIL: %d read-back region(s) failed\r\n", failures);
        return 1;
    }

    gpio_set_control(GPIO_LOAD_MODE);
    usleep(1U);
    XTime_GetTime(&start);
    gpio_set_control(0U);
    run_status = wait_for_completion(start, &finish);
    gpio_set_control(GPIO_LOAD_MODE | GPIO_ASYNC_RESET);

    elapsed_us = ticks_to_us(finish - start);
    xil_printf("run=%lu us, approximately %lu RV32I cycles @ 35 MHz\r\n",
               (unsigned long)elapsed_us,
               (unsigned long)(((uint64_t)elapsed_us * RV32I_CLOCK_HZ +
                                500000ULL) / 1000000ULL));
    if (run_status != 1) {
        xil_printf("Wide-BDOT128 eBNN RUN FAIL: status=%d\r\n", run_status);
        return 1;
    }

    failures = check_results();
    if (failures == 0) {
        xil_printf("Wide-BDOT128 eBNN Binary-MNIST PASS\r\n");
        return 0;
    }
    xil_printf("Wide-BDOT128 eBNN FAIL: %d mismatch(es)\r\n", failures);
    return 1;
}
